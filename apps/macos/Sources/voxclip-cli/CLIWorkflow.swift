import Foundation
import ArgumentParser
import VideoToolbox
import VoxClipCore
import VoxClipMedia
import Synchronization

enum CLIWorkflow {
    static func validateOutputs(_ outputs: [URL], inputs: [URL]) throws {
        let inputs = Set(inputs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        var seen: Set<URL> = []
        for output in outputs {
            let resolved = output.standardizedFileURL.resolvingSymlinksInPath()
            guard !inputs.contains(resolved), seen.insert(resolved).inserted else {
                throw ValidationError("Output paths must not overwrite inputs or each other")
            }
            if let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
               values.isDirectory == true || values.isRegularFile != true {
                throw ValidationError("An output must be a file path, not a folder or special file")
            }
            var parentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.deletingLastPathComponent().path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
                throw ValidationError("The output folder does not exist for \(resolved.path)")
            }
            let reserved: URL
            do { reserved = try ExportSafety.partialURL(for: resolved) }
            catch VoxClipError.exportFailed(_) {
                throw ValidationError("Choose a regular file for each .partial output; directories and links are not allowed.")
            }
            guard !inputs.contains(reserved), !outputs.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == reserved }) else {
                throw ValidationError("Output paths must not overwrite inputs or each other")
            }
        }
    }
    static func hardwareEncoderAvailable() -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 320, height: 180, codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }
    static func success(_ command: String, fields: [String: JSONValue] = [:]) -> JSONValue {
        .object(fields.merging(["ok": .bool(true), "command": .string(command), "version": .string("0.1.0")]) { _, new in new })
    }

    static func success(_ command: String, value: some Encodable) throws -> JSONValue {
        let encoded = try JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encoder().encode(value))
        if case .object(let fields) = encoded { return success(command, fields: fields) }
        return success(command, fields: ["result": encoded])
    }

    static func imported(_ source: URL, probe: MediaProbeResult, transcript: Transcript?) throws -> Project {
        let key = try JSONProjectStore.contentKey(for: source)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let bytes = (attributes[.size] as? NSNumber)?.int64Value else { throw VoxClipError.mediaMissing(source.lastPathComponent) }
        return Project(id: UUID().uuidString, title: source.deletingPathExtension().lastPathComponent, createdAt: Date(), modifiedAt: Date(),
            media: ProjectMedia(source: MediaReference(absolutePath: source.path, sizeBytes: bytes, durationSeconds: probe.durationSeconds,
                                                       contentKey: key, video: probe.video, audio: probe.audio)), transcript: transcript,
            edits: ProjectEdits(pauseThresholdSeconds: transcript?.refined == true ? 0.8 : 1.0))
    }

    static func state(_ project: Project, derivePauses: Bool = true) throws -> EditState {
        guard let transcript = project.transcript else { throw VoxClipError.noSpeech }
        let edits = project.edits
        let pauses = transcript.words.isEmpty || (!derivePauses && edits.cutPauseIds.isEmpty) ? [] :
            try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds)
        return EditState(transcript: transcript, pauses: pauses,
                         pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
                         cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections,
                         clips: edits.clips, activeClipId: edits.activeClipId)
    }

    static func plan(_ project: Project, state supplied: EditState? = nil) throws -> EditPlan {
        var scopedProject = project
        if let supplied { scopedProject.edits = supplied.projectEdits }
        let scope = scopedProject.edits.activeClipId.map { VoiceLabOutputScope.clip($0) } ?? .full
        try VoiceLabProject.requireLegacyRendering(scopedProject, scope: scope)
        return try sourcePlan(project, state: supplied)
    }

    private static func sourcePlan(_ project: Project, state supplied: EditState? = nil) throws -> EditPlan {
        let source = project.media.source
        let rate = Double(source.audio?.sampleRate ?? 48000)
        let edits = project.edits
        if supplied == nil && edits.cutWordIds.isEmpty && edits.cutPauseIds.isEmpty && edits.activeClipId == nil {
            let total = Int64((source.durationSeconds * rate).rounded())
            return EditPlan(sampleRate: rate, totalSamples: total, kept: total > 0 ? [MediaInterval(startSample: 0, endSample: total)] : [])
        }
        let state = try supplied ?? self.state(project)
        return try EditPlan.build(transcript: state.transcript, editState: state, activeClip: state.clips.first { $0.id == state.activeClipId },
                                  duration: source.durationSeconds, sampleRate: rate)
    }

    static func style(_ id: String) throws -> CaptionStyle? {
        if id == "off" { return nil }
        guard !id.contains("/"), !id.contains(".."), !id.contains("\\") else { throw ValidationError("Invalid caption style ID") }
        let url = try SharedResources.locate().root.appendingPathComponent("caption-styles/styles/\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ValidationError("Unknown caption style: \(id)") }
        return try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: url))
    }

    static func transcribed(source: URL, probe: MediaProbeResult, engine: String?, model: String?, language: String?,
                            options: TranscriptionOptions = TranscriptionOptions(), rawOut: String? = nil) async throws -> Transcript {
        let selected = try CLIExecution.engine(engine ?? "whisper")
        let locations = DataLocations()
        let choice: LanguageChoice = language == nil || language == "auto" ? .auto : .forced(language!)
        var model = model
        if selected == .whispercpp && model == nil {
            let catalog = BundledModelCatalog(shared: try SharedResources.locate())
            let descriptors = try await catalog.models()
            let installed = try await ModelStore(catalog: catalog, locations: locations).installedModels()
            let requested = (language ?? "auto").lowercased()
            let primary = requested.split(separator: "-").first.map(String.init) ?? requested
            model = installed.first { id in
                guard let descriptor = descriptors.first(where: { $0.id == id }), descriptor.engine == .whispercpp,
                      descriptor.files.contains(where: { $0.role == "model" }) else { return false }
                let languages = descriptor.languages.map { $0.lowercased() }
                if requested == "auto" { return languages.contains("*") || languages.count > 1 }
                return languages.contains("*") || languages.contains(requested) || languages.contains(primary)
            }
            guard model != nil else { throw VoxClipError.modelMissing("whisper (\(language ?? "auto"))") }
        }
        let key = try JSONProjectStore.contentKey(for: source)
        let extraction = try await CacheStore(locations: locations).extractAudio(sourceURL: source, contentKey: key, durationSeconds: probe.durationSeconds,
            using: AVAudioExtractor()) { _ in }
        let plan = TranscriptionPlan(engine: selected, model: model, language: choice, options: options)
        let adapter: any Transcriber
        switch selected {
        case .whispercpp: adapter = WhisperCppTranscriber()
        case .appleSpeech: adapter = AppleSpeechTranscriber()
        case .elevenlabs:
            let settings = try await JSONSettingsStore(locations: locations).load()
            adapter = await ElevenLabsTranscriber(keys: EnvironmentKeyProvider(), settings: settings)
        }
        let request = TranscriptionRequest(plan: plan, audio: extraction.audio, contentKey: key)
        let transcriber: any Transcriber
        if let rawOut {
            let destination = URL(fileURLWithPath: rawOut).standardizedFileURL.resolvingSymlinksInPath()
            guard destination != source.standardizedFileURL.resolvingSymlinksInPath() else { throw VoxClipError.projectUnreadable("Raw output must not overwrite the source") }
            transcriber = RawOutputTranscriber(base: adapter, destination: destination)
        } else { transcriber = adapter }
        return try await TranscriptionService().transcribe(request, using: transcriber, envelope: extraction.envelope)
    }

    private static func validateExportArguments(_ options: Export, probe: MediaProbeResult, styleID: String) throws {
        if options.audioOut != nil && probe.audio == nil {
            throw ValidationError("This video has no audio track, so --audio-out has nothing to write.")
        }
        if options.srt != nil && styleID == "off" {
            throw ValidationError("Captions are off, so --srt has nothing to write. Choose a caption style with --style.")
        }
    }

    private static func validateRequestedScope(_ options: Export, project: Project) throws {
        if let clip = options.clip, !project.edits.clips.contains(where: { $0.id == clip }) {
            throw ValidationError("The requested clip does not exist.")
        }
        if let range = options.wordRange {
            let indices = range.split(separator: ":").compactMap { Int($0) }
            let wordCount = project.transcript?.words.count ?? 0
            guard indices.count == 2, indices.allSatisfy({ $0 >= 0 && $0 < wordCount }) else {
                throw ValidationError("Word range is outside the transcript.")
            }
        }
    }

    static func export(_ options: Export, input: String) async throws -> JSONValue {
        let inputURL = URL(fileURLWithPath: input).standardizedFileURL
        if inputURL.pathExtension.lowercased() == "voxclip", options.transcript != nil {
            throw ValidationError("--transcript only applies when --open is a media file.")
        }
        let outputs = [options.output, options.srt, options.audioOut].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        let inputs = [inputURL] + (options.transcript.map { [URL(fileURLWithPath: $0)] } ?? [])
        try validateOutputs(outputs, inputs: inputs)
        if let id = options.style { _ = try style(id) }
        var project: Project
        let source: URL
        let probe: MediaProbeResult
        if inputURL.pathExtension.lowercased() == "voxclip" {
            let store = JSONProjectStore()
            project = try await store.load(from: inputURL)
            source = try await store.resolveSource(for: project, projectURL: inputURL)
            try validateOutputs(outputs, inputs: inputs + [source])
            probe = try await AVMediaProbe().probe(source)
            try validateExportArguments(options, probe: probe, styleID: options.style ?? project.captions.styleId)
            try validateRequestedScope(options, project: project)
        } else {
            source = inputURL
            probe = try await AVMediaProbe().probe(source)
            try validateExportArguments(options, probe: probe, styleID: options.style ?? "off")
            if options.clip != nil { throw ValidationError("The requested clip does not exist.") }
            let transcript: Transcript
            if let path = options.transcript {
                do { transcript = try ProjectJSON.decoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
                catch { throw VoxClipError.projectUnreadable("The transcript could not be read") }
            }
            else { transcript = try await transcribed(source: source, probe: probe, engine: options.engine, model: options.model, language: options.language) }
            project = try imported(source, probe: probe, transcript: transcript)
            try validateRequestedScope(options, project: project)
        }
        var state: EditState?
        if options.cutFillers || options.tightenPauses || options.clip != nil || options.wordRange != nil {
            var editState = try self.state(project)
            if let clip = options.clip {
                editState.activeClipId = clip
            }
            if let range = options.wordRange {
                let indices = range.split(separator: ":").compactMap { Int($0) }
                let clip = ClipRange(id: UUID().uuidString, startWordId: editState.transcript.words[indices[0]].id, endWordId: editState.transcript.words[indices[1]].id)
                editState.clips.append(clip); editState.activeClipId = clip.id
            }
            if options.cutFillers { editState = EditReducer.reduce(editState, command: .cutFillers) }
            if options.tightenPauses { editState = EditReducer.reduce(editState, command: .tightenPauses) }
            state = editState
        }
        let effectiveState = try state ?? (project.transcript == nil ? nil : self.state(project, derivePauses: project.schemaVersion >= 3))
        if let effectiveState { project.edits = effectiveState.projectEdits }
        let aspect = options.aspect.flatMap(AspectRatio.init(rawValue:)) ?? project.export.aspect
        let quality = options.quality.flatMap(ExportQuality.init(rawValue:)) ?? project.export.quality
        let styleID = options.style ?? project.captions.styleId
        let style = try self.style(styleID)
        project.captions.styleId = styleID
        project.export.aspect = aspect; project.export.quality = quality
        let scope = project.edits.activeClipId.map { VoiceLabOutputScope.clip($0) } ?? .full
        let voiceLab = try VoiceLabRenderPreflight.prepare(project: project, scope: scope,
            paidRoot: DataLocations().root.appendingPathComponent("VoiceLab", isDirectory: true))
        let plan = try sourcePlan(project, state: effectiveState)
        guard (voiceLab?.prepared.outputPlan.outputSamples ?? plan.outputSamples) > 0,
              voiceLab != nil || effectiveState?.summary.canExport != false else { throw VoxClipError.everythingCut }
        let output = try OutputSpec.resolved(source: probe, aspect: aspect, quality: quality, fps: options.fps.flatMap(Double.init))
        let activeClip = effectiveState.flatMap { state in state.clips.first { $0.id == state.activeClipId } }
        let render: RenderRequest
        switch try await captions(.export(RenderRequest(sourceURL: source, plan: plan, style: style,
            placement: project.captions.positionByAspect[aspect.rawValue] ?? project.captions.position, output: output, voiceLab: voiceLab),
            state: effectiveState, activeClip: activeClip, overrides: project.captions.overrides, language: project.transcript?.language)) {
        case .export(let prepared): render = prepared
        case .render: throw VoxClipError.exportFailed("Invalid caption operation")
        }
        let exporter = AVExporter(appVersion: VoxClipCLI.configuration.version)
        let job = ExportJob(render: render, aspect: aspect, quality: quality, outputURL: URL(fileURLWithPath: options.output!),
            writeSRT: options.srt != nil, srtURL: options.srt.map { URL(fileURLWithPath: $0) })
        let audioDestination = options.audioOut.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        var audioStaging: URL?
        defer { if let audioStaging { try? FileManager.default.removeItem(at: audioStaging) } }
        if let audioDestination {
            try await exporter.preflightCombinedExport(job, editedAudioURL: audioDestination)
            audioStaging = try await exporter.stageEditedAudio(render, to: audioDestination)
        }
        let additionalOutputs = audioDestination.flatMap { destination in
            audioStaging.map { [(partial: $0, destination: destination)] }
        } ?? []
        let reporter = CLIProgressReporter(quiet: options.quiet)
        let result = try await exporter.export(job, additionalOutputs: additionalOutputs) { progress in
            reporter.report(progress)
        }
        guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result)) else { throw VoxClipError.exportFailed("Cannot encode result") }
        fields.removeValue(forKey: "outputURL"); fields.removeValue(forKey: "srtURL")
        fields["output"] = .string(result.outputURL.path); fields["srt"] = result.srtURL.map { .string($0.path) } ?? .null
        fields["captionStyle"] = .string(styleID); fields["aspect"] = .string(aspect.rawValue)
        return success("export", fields: fields)
    }

    static func transcribe(_ options: Transcribe) async throws -> JSONValue {
        let source = URL(fileURLWithPath: options.input).standardizedFileURL
        try validateOutputs(([options.out] + (options.rawOut.map { [$0] } ?? [])).map { URL(fileURLWithPath: $0) }, inputs: [source])
        let probe = try await AVMediaProbe().probe(source)
        let transcript = try await transcribed(source: source, probe: probe, engine: options.engine, model: options.model, language: options.language,
                                               options: TranscriptionOptions(diarize: options.diarize, dtw: !options.noDTW), rawOut: options.rawOut)
        let project = try imported(source, probe: probe, transcript: transcript)
        try await JSONProjectStore().save(project, to: URL(fileURLWithPath: options.out))
        return success("transcribe", fields: ["output": .string(URL(fileURLWithPath: options.out).path), "words": .number(Double(transcript.words.count))])
    }

    static func renderCaption(_ options: RenderCaption) async throws -> JSONValue {
        switch try await captions(.render(options)) {
        case .render(let report): return report
        case .export: throw VoxClipError.exportFailed("Invalid caption operation")
        }
    }

    private enum CaptionOperation {
        case export(RenderRequest, state: EditState?, activeClip: ClipRange?, overrides: [String: JSONValue], language: String?)
        case render(RenderCaption)
    }

    private enum CaptionResult {
        case export(RenderRequest)
        case render(JSONValue)
    }

    private static func captions(_ operation: CaptionOperation) async throws -> CaptionResult {
        switch operation {
        case .export(var request, let state, let activeClip, let overrides, let language):
            if let voiceLab = request.voiceLab {
                if let style = request.style {
                    let project = voiceLab.project, plan = voiceLab.prepared.outputPlan
                    let input = CaptionLayoutInput(style: style.id,
                        frame: .init(width: request.output.size.width, height: request.output.size.height),
                        language: language ?? "und", duration: plan.duration,
                        captions: .init(overrides: project.captions.overrides, position: project.captions.position,
                                        positionByAspect: project.captions.positionByAspect),
                        words: plan.captions.map { .init(id: $0.id, text: $0.text, start: $0.start, end: $0.end) })
                    let pipeline = try CaptionPipeline(shared: SharedResources.locate())
                    let layout = try await pipeline.layout(input: input, style: style)
                    request.captionLayout = layout; request.captions = layout.track
                }
                request.style = nil
                return .export(request)
            }
            guard let style = request.style, let state, !state.transcript.words.isEmpty else { return .export(request) }
            let words = try captionCopy(buildSegments(state, activeClip: activeClip), plan: request.plan)
            let pipeline = try CaptionPipeline(shared: SharedResources.locate())
            let resolution = await pipeline.resolve(style, overrides: overrides, frame: request.output.size)
            let layout = try await pipeline.layout(words: words, language: language, style: resolution.style,
                position: request.placement, frame: request.output.size, duration: request.plan.duration)
            request.style = nil
            request.captionLayout = layout
            request.captions = layout.track
            return .export(request)
        case .render(let options):
            let output = URL(fileURLWithPath: options.out)
            let harness = try CaptionRenderHarness(shared: SharedResources.locate())
            if let fixture = options.fixture {
                _ = try await harness.renderCase(at: URL(fileURLWithPath: fixture), sample: options.sample, out: output)
            } else if let tiles = options.tiles {
                _ = try await harness.renderTiles(at: URL(fileURLWithPath: tiles), out: output)
            } else {
                throw ValidationError("Choose --case or --tiles")
            }
            return .render(success("render-caption", fields: ["output": .string(output.path)]))
        }
    }
}

private struct RawOutputTranscriber: Transcriber {
    let base: any Transcriber
    let destination: URL
    var engine: TranscriptEngine { base.engine }
    func capabilities(model: String?) -> TranscriberCapabilities { base.capabilities(model: model) }
    func supports(_ language: LanguageChoice, model: String?) async -> Bool { await base.supports(language, model: model) }
    func readiness(for plan: TranscriptionPlan) async -> Readiness { await base.readiness(for: plan) }
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.prepare(for: plan, progress: progress)
    }
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        let raw = try await base.transcribe(request, progress: progress)
        try ProjectJSON.encoder().encode(raw).write(to: destination, options: .atomic)
        return raw
    }
}

private final class CLIProgressReporter: Sendable {
    private struct State {
        var phase: ExportPhase?
        var last = ContinuousClock.now
    }
    private let state = Mutex(State())
    private let quiet: Bool
    private let redactor = CLIExecution.redactor()
    init(quiet: Bool) { self.quiet = quiet }
    func report(_ progress: ExportProgress) {
        guard !quiet else { return }
        state.withLock { state in
            let changed = state.phase != progress.phase
            guard changed || state.last.duration(to: .now) >= .seconds(1) else { return }
            state.phase = progress.phase; state.last = .now
            let line = changed ? "\(progress.phase.rawValue)…" : "\(Int((progress.fraction ?? 0) * 100))%"
            FileHandle.standardError.write(Data((redactor.redact(line) + "\n").utf8))
        }
    }
}
