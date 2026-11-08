import AVFoundation
import CoreGraphics
import Foundation
import VoxClipCore

/// The export self-check on an exported MP4 (ADR-R49): it reads both tracks' time ranges, decodes the audio once for the
/// shared ADR-R47 meter and once at 16 kHz for a local engine, transcribes it there, and runs `ExportCheck` against the
/// render the export ran. Nothing leaves this Mac: the hearing engine is Whisper or Apple speech, never a provider.
public struct ExportChecker: Sendable {
    /// A local engine and the plan it transcribes with.
    public struct Hearing: Sendable {
        public let transcriber: any Transcriber
        public let plan: TranscriptionPlan
        public init(transcriber: any Transcriber, plan: TranscriptionPlan) { self.transcriber = transcriber; self.plan = plan }
    }

    /// The check's report and how long each part took, seconds.
    public struct Outcome: Sendable {
        public let report: ExportCheckReport
        /// The track read and both audio decodes.
        public let measureSeconds: Double
        /// The local engine's transcription, 0 without one.
        public let hearSeconds: Double
        public let totalSeconds: Double
        /// The engine that heard the export, nil without one.
        public let engine: TranscriptEngine?
        public let model: String?
    }

    public let hearing: Hearing?
    /// Where the 16 kHz copy is written while the engine reads it; removed after.
    public let scratch: URL

    public init(hearing: Hearing?, scratch: URL) { self.hearing = hearing; self.scratch = scratch }

    /// The engine that hears an export of `transcript`'s project, all local: the project's own engine when it is Whisper or
    /// Apple speech and ready, otherwise Whisper with an installed model for the transcript's language; nil when none is
    /// installed (the words check and phrase sync are then skipped). Never ElevenLabs.
    public static func localHearing(transcript: Transcript?, locations: DataLocations, shared: SharedResources) async -> Hearing? {
        let spoken = transcript?.language ?? ""
        let language: LanguageChoice = spoken.isEmpty || spoken == "und" ? .auto : .forced(spoken)
        if transcript?.engine.id == .appleSpeech {
            let apple = AppleSpeechTranscriber(locations: locations)
            let plan = TranscriptionPlan(engine: .appleSpeech, language: language)
            if await apple.supports(language, model: nil), await apple.readiness(for: plan) == .ready {
                return Hearing(transcriber: apple, plan: plan)
            }
        }
        let catalog = BundledModelCatalog(shared: shared)
        let installed = (try? await ModelStore(catalog: catalog, locations: locations).installedModels()) ?? []
        var candidates: [String] = []
        if transcript?.engine.id == .whispercpp, let own = transcript?.engine.modelId, installed.contains(own) { candidates.append(own) }
        for id in installed where !candidates.contains(id) {
            guard let descriptor = try? await catalog.model(id: id), descriptor.engine == .whispercpp,
                  descriptor.files.contains(where: { $0.role == "model" }) else { continue }
            candidates.append(id)
        }
        let whisper = WhisperCppTranscriber(catalog: catalog, locations: locations)
        for model in candidates {
            for choice in [language, .auto] {
                let plan = TranscriptionPlan(engine: .whispercpp, model: model, language: choice)
                if await whisper.supports(choice, model: model), await whisper.readiness(for: plan) == .ready {
                    return Hearing(transcriber: whisper, plan: plan)
                }
            }
        }
        return nil
    }

    /// Checks `export` against `render` (the request the export rendered, its captions laid out) and `edit` (its words,
    /// phrases and cuts, `ExportCheckExpectation`), with the export's `loudness` setting.
    public func check(export: URL, render: RenderRequest, edit: ExportCheckExpectation.Edit, loudness: ExportLoudness) async throws -> Outcome {
        let clock = ContinuousClock(), started = clock.now
        let asset = AVURLAsset(url: export)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await MediaSupport.audioTrack(in: asset)
        var frameSeconds = 1 / max(1, render.output.fps)
        var videoRange: ExportCheckInput.Track?
        var frame = render.output.size
        if let video {
            videoRange = try await Self.range(video)
            let rate = try await video.load(.nominalFrameRate)
            if rate.isFinite, rate > 0 { frameSeconds = 1 / Double(rate) }
            let size = try await video.load(.naturalSize)
            if size.width > 0, size.height > 0 { frame = PixelSize(width: Int(size.width.rounded()), height: Int(size.height.rounded())) }
        }
        var audioRange: ExportCheckInput.Track?
        var measured: ExportCheckInput.Loudness?
        var heardAudio: ExtractedAudio?
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let wav = scratch.appendingPathComponent("export-check-\(UUID().uuidString)-16k.wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        if let audioTrack {
            audioRange = try await Self.range(audioTrack)
            let decoded = try await Self.decode(asset: asset, track: audioTrack, wav: hearing == nil ? nil : wav)
            measured = ExportCheckInput.Loudness(setting: loudness, integratedLufs: decoded.measurement.integratedLufs(),
                                                 truePeakDbtp: decoded.measurement.truePeakDbtp)
            heardAudio = decoded.wav
        }
        let measuredAt = clock.now
        var heard: [ExportCheckInput.Heard]?
        var skipped = ExportCheck.noLocalEngine
        if let hearing, let heardAudio {
            // An engine that fails (its assets gone, its model unreadable) leaves the words unchecked, not the export.
            do { heard = try await Self.hear(heardAudio, hearing: hearing) }
            catch let error where error is CancellationError || (error as? VoxClipError) == .cancelled || Task.isCancelled { throw error }
            catch { skipped = "The local transcription failed" }
        } else if hearing != nil {
            skipped = "No audio track"
        }
        let heardAt = clock.now
        let input = ExportCheckInput(expected: edit.words, heard: heard, hearingSkipped: skipped, cuts: edit.cuts, phrases: edit.phrases,
                                     video: videoRange, audio: audioRange, frameSeconds: frameSeconds, loudness: measured,
                                     boxes: ExportCheckExpectation.captionBoxes(render: render) + Self.titleBoxes(render: render),
                                     frame: frame)
        let report = ExportCheck.run(input)
        func seconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        return Outcome(report: report, measureSeconds: seconds(started.duration(to: measuredAt)),
                       hearSeconds: heard == nil ? 0 : seconds(measuredAt.duration(to: heardAt)),
                       totalSeconds: seconds(started.duration(to: clock.now)), engine: heard == nil ? nil : hearing?.plan.engine,
                       model: heard == nil ? nil : hearing?.plan.model)
    }

    /// Each title the render draws (Ask Claude's and the hook's), laid out by the compositor's own `titleLayout`, top-left
    /// origin, in fractions of the frame, at its first output second.
    static func titleBoxes(render: RenderRequest) -> [ExportCheckInput.Box] {
        guard let input = render.effects else { return [] }
        let titles = input.effects.filter { $0.kind == .title && !($0.text ?? "").isEmpty }
        guard !titles.isEmpty else { return [] }
        let frames = EffectFrames(input: input)
        let size = CGSize(width: render.output.size.width, height: render.output.size.height)
        guard size.width > 0, size.height > 0 else { return [] }
        return titles.map { title in
            let box = frames.titleLayout(title.text ?? "", position: title.position ?? .top, output: size).box
            // The layout's box has a bottom-left origin in pixels.
            let rect = CaptionRect(x: Double(box.minX / size.width), y: Double(1 - box.maxY / size.height),
                                   width: Double(box.width / size.width), height: Double(box.height / size.height))
            let time = render.speedTiming.rendered(render.timeline.mapTime(max(0, title.start)))
            return ExportCheckInput.Box(kind: .title, time: time, rect: rect)
        }
    }

    static func range(_ track: AVAssetTrack) async throws -> ExportCheckInput.Track {
        let range = try await track.load(.timeRange)
        let start = range.start.seconds, end = range.end.seconds
        guard start.isFinite, end.isFinite else { throw VoxClipError.decodeFailed("The export's track has no time range") }
        return ExportCheckInput.Track(start: start, end: end)
    }

    /// AVAssetReader is synchronous, so the decodes run on this queue behind a continuation, never on the cooperative pool
    /// (a 3-core runner stops when they fill it; `FrameAnalyzer.look`).
    static let decodeQueue = DispatchQueue(label: "voxclip.export-check.decode", qos: .userInitiated)
    /// The local engine's synchronous model work runs here, as the task's preferred executor.
    static let hearingQueue = DispatchQueue(label: "voxclip.export-check.hearing", qos: .userInitiated)

    private struct UncheckedAsset: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
    }

    /// The export's audio measured by the shared ADR-R47 meter at its own rate and channels, and, with `wav`, written there
    /// as 16 kHz mono PCM for the engine.
    static func decode(asset: AVURLAsset, track: AVAssetTrack, wav: URL?) async throws -> (measurement: SocialLoudnessMeasurement, wav: ExtractedAudio?) {
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first, let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw VoxClipError.noAudioTrack
        }
        let rate = description.mSampleRate, channels = Int(description.mChannelsPerFrame)
        guard rate.isFinite, rate > 0, channels > 0 else { throw VoxClipError.decodeFailed("Unsupported audio format") }
        let held = UncheckedAsset(asset: asset, track: track)
        return try await withCheckedThrowingContinuation { continuation in
            decodeQueue.async {
                continuation.resume(with: Result {
                    let measurement = try meter(held, rate: rate, channels: channels)
                    let extracted = try wav.map { try resample(held, to: $0) }
                    return (measurement, extracted)
                })
            }
        }
    }

    private static func meter(_ held: UncheckedAsset, rate: Double, channels: Int) throws -> SocialLoudnessMeasurement {
        var meter = try SocialLoudnessMeter(sampleRate: Int(rate.rounded()), channels: channels)
        try read(held, settings: MediaSupport.pcm(rate: rate, channels: channels)) { data in
            try data.withUnsafeBytes { raw in try meter.append(raw.bindMemory(to: Float.self)) }
        }
        return meter.finish()
    }

    private static func resample(_ held: UncheckedAsset, to url: URL) throws -> ExtractedAudio {
        let file = try PCMFile(url: url, rate: 16_000, channels: 1, float: false)
        do {
            try read(held, settings: MediaSupport.pcm(rate: 16_000, channels: 1, float: false)) { try file.append($0) }
            try file.finish()
        } catch {
            try? file.handle.close()
            throw error
        }
        return ExtractedAudio(wav16k: url, sampleCount: file.frames, durationSeconds: Double(file.frames) / 16_000)
    }

    /// Reads the whole track as LPCM in `settings`, handing each buffer's bytes to `body`.
    private static func read(_ held: UncheckedAsset, settings: [String: Any], _ body: (Data) throws -> Void) throws {
        let reader = try AVAssetReader(asset: held.asset)
        let output = AVAssetReaderTrackOutput(track: held.track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw VoxClipError.decodeFailed(reader.error?.localizedDescription ?? "Cannot read the export's audio") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw VoxClipError.decodeFailed("Cannot copy the export's audio") }
            try body(data)
        }
        guard reader.status == .completed else { throw VoxClipError.decodeFailed(reader.error?.localizedDescription ?? "The export's audio did not decode") }
    }

    /// The words the local engine hears in `audio`, with their times; its model work runs on `hearingQueue`.
    static func hear(_ audio: ExtractedAudio, hearing: Hearing) async throws -> [ExportCheckInput.Heard] {
        guard audio.durationSeconds > 0 else { return [] }
        let request = TranscriptionRequest(plan: hearing.plan, audio: audio, contentKey: "export-check")
        let raw: RawTranscript
        do {
            raw = try await withTaskExecutorPreference(hearingQueue) {
                try await hearing.transcriber.transcribe(request) { _ in }
            }
        } catch VoxClipError.noSpeech {
            return []
        }
        let grouped = try WordAssembler.group(raw.tokens, rule: raw.grouping, timelineStart: audio.timelineStart)
        let words = try EditingImport.pipeline(grouped, envelope: nil, timing: raw.timing, verbatim: raw.verbatim, duration: audio.durationSeconds).words
        return words.filter { $0.kind == .word }.map { ExportCheckInput.Heard(text: $0.text, start: $0.start, end: $0.end) }
    }
}
