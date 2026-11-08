import Foundation
import ArgumentParser
import Synchronization
import VoxClipCore
import VoxClipMedia

/// ✦ Claude does it all, headless (design.md §6.7, ai.md §16.12): probe, transcribe, Find Clips, then plan the top clips at
/// once (at most three in flight) and apply and export each one as soon as its plan is ready. Paid steps never run here:
/// rewrites in the creator's voice and music are left for the app and listed as pending. The whole video's sentence-frame
/// pass (ADR-R48 part 2) runs beside Find Clips, and each plan request carries its clip's frames: small images to an AI on
/// your plan that takes them, a text summary otherwise (the CLI has no spend cap, so an API key gets the summary).
struct Autopilot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make the top clips of a video postable, as Claude mode does, and time each stage.",
        discussion: "Find Clips and the plans run at extra high effort through the chosen connector. Rewrites and music are left for the app.")
    @Option(name: .customLong("open"), help: "Source media, or a project with a transcript.") var input: String
    @Option(help: "Connector ID.") var connector: String
    @Option(help: "LLM model ID.") var model: String?
    @Option(help: "How many top clips to make (1–12).") var count = 3
    @Option(help: "Find Clips preset: best, hooks, topics or quotes.") var preset = "best"
    @Option(help: "Fixture words JSON instead of transcription.") var transcript: String?
    @Option(help: "whisper, apple or elevenlabs.") var engine: String?
    @Option(name: .customLong("transcription-model"), help: "Transcription catalog model ID.") var transcriptionModel: String?
    @Option(help: "auto or BCP 47 language.") var language: String?
    @Option(name: .customLong("out-dir"), help: "Folder for each clip's MP4 and the project; nothing is exported without it.") var outDir: String?
    @Option(help: "16:9, 9:16 or 1:1.") var aspect = "9:16"
    @Flag(help: "Print each stage's wall time as JSON (in the --json result, else on stdout).") var timings = false
    @Flag(help: "Print one final JSON object on stdout.") var json = false
    @Flag(help: "Suppress human-readable progress on stderr.") var quiet = false

    mutating func validate() throws {
        _ = try CLIExecution.connector(connector)
        guard let id = ClipPresetID(rawValue: preset), id != .custom else { throw ValidationError("--preset must be best, hooks, topics or quotes") }
        guard (1...12).contains(count) else { throw ValidationError("--count must be 1 to 12") }
        guard let ratio = AspectRatio(rawValue: aspect), ratio != .source else { throw ValidationError("--aspect must be 16:9, 9:16 or 1:1") }
        if let engine { _ = try CLIExecution.engine(engine) }
    }

    mutating func run() async throws {
        let options = self
        try await CLIExecution.run(command: "autopilot", json: json) {
            let value = try await CLIWorkflow.autopilot(options)
            if options.timings, !options.json, case .object(let fields) = value, let timings = fields["timings"] {
                try CLIExecution.printJSON(timings)
            }
            return value
        }
    }
}

extension CLIWorkflow {
    /// The connector the CLI sends through, by id.
    static func connector(_ id: ConnectorID, catalog: LLMCatalog) -> any LLMConnector {
        let logger = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        if id == .appleFoundation { return FoundationModelsConnector(log: logger) }
        return StubLLMConnector(id: id, keys: LLMEnvironmentKeyProvider(catalog: catalog), catalog: catalog, log: logger)
    }

    static func autopilot(_ options: Autopilot) async throws -> JSONValue {
        let clock = ClaudeModeClock()
        let inputURL = URL(fileURLWithPath: options.input).standardizedFileURL
        let outDir = options.outDir.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        if let outDir {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: outDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError("--out-dir must be an existing folder")
            }
        }
        var project: Project
        var source = inputURL
        if inputURL.pathExtension.lowercased() == "voxclip" {
            if options.transcript != nil { throw ValidationError("--transcript only applies when --open is a media file.") }
            let store = JSONProjectStore()
            project = try await store.load(from: inputURL)
            source = try await store.resolveSource(for: project, projectURL: inputURL)
            if project.transcript == nil {
                let probe = try await clock.timed(.probe) { try await AVMediaProbe().probe(source) }
                project.transcript = try await transcribed(source: source, probe: probe, engine: options.engine, model: options.transcriptionModel,
                                                           language: options.language, clock: clock)
            }
        } else {
            let probe = try await clock.timed(.probe) { try await AVMediaProbe().probe(inputURL) }
            let words: Transcript
            if let path = options.transcript {
                do { words = try ProjectJSON.decoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
                catch { throw VoxClipError.projectUnreadable("The transcript could not be read") }
            } else {
                words = try await transcribed(source: inputURL, probe: probe, engine: options.engine, model: options.transcriptionModel,
                                              language: options.language, clock: clock)
            }
            project = try imported(inputURL, probe: probe, transcript: words)
        }
        let shared = try SharedResources.locate()
        let catalog = try LLMCatalog(shared: shared)
        let id = try CLIExecution.connector(options.connector)
        let model = options.model ?? catalog.curatedModels(for: id).first?.id ?? ""
        let lanes: [any LLMConnector] = id == .claudeCode || id == .codex ? [connector(id, catalog: catalog), connector(id, catalog: catalog)] : []
        let report = AutopilotReport(quiet: options.quiet)
        let main = connector(id, catalog: catalog)
        let frames = framePass(project: project, source: source, report: report)
        let images = (id == .claudeCode || id == .codex || id == .appleFoundation || id == .ollama || id == .lmstudio) ? await main.supportsImages() : false
        guard let preset = ClipPresetID(rawValue: options.preset) else { throw ValidationError("Unknown clip preset") }
        let made = try await autopilot(project: project, connector: main, lanes: lanes, model: model,
                                       preset: preset, count: options.count, shared: shared, catalog: catalog, clock: clock,
                                       report: report, frames: frames, images: images) { project, clip, rank in
            guard let outDir else { return [] }
            return try await exportClip(project, clip: clip, rank: rank, outDir: outDir, aspect: options.aspect, quiet: options.quiet, clock: clock)
        }
        var fields: [String: JSONValue] = ["clips": .array(made.clips), "found": .number(Double(made.found)), "model": .string(made.model)]
        if let outDir {
            let saved = outDir.appendingPathComponent("autopilot.voxclip")
            try await JSONProjectStore().save(made.project, to: saved)
            fields["project"] = .string(saved.path)
        }
        if options.timings { fields["timings"] = clock.json() }
        return success("autopilot", fields: fields)
    }

    /// The whole video's frame pass on this Mac (Apple Vision, cached under the content key); nil for audio only.
    static func framePass(project: Project, source: URL, report: AutopilotReport) -> VideoFramePass? {
        guard project.media.source.video != nil, let words = project.transcript?.words, words.contains(where: { $0.kind == .word }) else { return nil }
        return VideoFramePass(analyzer: FrameAnalyzer(cache: FrameAnalysisCache(locations: DataLocations())), source: source,
                              contentKey: project.media.source.contentKey, words: words) { line in report.line(line) }
    }

    /// Find Clips, then the top `count` clips planned at once on `connector` and `lanes`, each applied (and handed to
    /// `export`) the moment its plan is ready, one at a time. Rewrites and music stay pending. `frames` starts as Find Clips
    /// does and never waits for it; each clip's request takes its frames from the pass (`images` sends them as pictures,
    /// else as a text summary) and starts its opening scan beside the request.
    static func autopilot(project start: Project, connector: any LLMConnector, lanes: [any LLMConnector], model: String, preset: ClipPresetID,
                          count: Int, shared: SharedResources, catalog: LLMCatalog, clock: ClaudeModeClock, report: AutopilotReport,
                          frames: VideoFramePass? = nil, images: Bool = false,
                          export: (_ project: Project, _ clipID: String, _ rank: Int) async throws -> [String]) async throws
        -> (clips: [JSONValue], found: Int, model: String, project: Project) {
        guard let transcript = start.transcript else { throw VoxClipError.noSpeech }
        var project = start
        await frames?.start(clock: clock)
        defer { if let frames { Task { await frames.cancel() } } }
        let logger = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        let runner = LLMRunner(keys: LLMEnvironmentKeyProvider(catalog: catalog), catalog: catalog, log: logger)
        let prompt = try ClipPromptDocument(data: Data(contentsOf: shared.root.appendingPathComponent("prompts/clip-finder.json")))
        guard let chosen = prompt.presets.first(where: { $0.id == preset }) else { throw ValidationError("Unknown clip preset") }
        report.line("Finding clips…")
        let findStart = clock.elapsed
        let found = try await ClipFinder(runner: runner, shared: shared).find(ClipFinderRequest(transcript: transcript, corrections: project.edits.corrections,
            cutWordIds: Set(project.edits.cutWordIds), preset: chosen, snap: true), connector: connector, model: model)
        clock.record(.find, since: findStart)
        // Best first by Find Clips' score; equal scores keep transcript order, as the app's Suggested list does.
        let ranked = found.clips.enumerated().sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score }
            .prefix(count).compactMap { _, clip -> (span: ClosedRange<Int>, moment: ClipAutopilotMoment)? in
                guard let lower = transcript.words.firstIndex(where: { $0.id == clip.startWordId }),
                      let upper = transcript.words.firstIndex(where: { $0.id == clip.endWordId }), lower <= upper else { return nil }
                return (lower...upper, ClipAutopilotMoment.found(lower...upper, title: clip.title, reason: clip.reason, score: clip.score))
            }
        guard !ranked.isEmpty else { return ([], found.clips.count, found.model, project) }
        report.line("Found \(found.clips.count) clips. Planning the top \(ranked.count)…")
        let request = ClipAutopilotRequest(transcript: transcript, edits: project.edits, mode: .clips(ranked.map(\.span)), moments: ranked.map(\.moment))
        let service = ClipAutopilotService(runner: runner, shared: shared)
        let fonts = try ClipAutopilotFonts.load(shared: shared)
        let (ready, plans) = AsyncStream.makeStream(of: (Int, ClipAutopilotPlan).self)
        let progress: @Sendable (ClipAutopilotProgress) -> Void = { event in
            switch event {
            case .planning(let clip, _): clock.begin(.plan, clip: clip + 1)
            case .ready(let clip, _, let plan): clock.end(.plan, clip: clip + 1); plans.yield((clip, plan))
            case .failed(let clip, _): clock.end(.plan, clip: clip + 1)
            default: break
            }
        }
        let sent = ClipFramesSent()
        let source = frames.map { pass in Self.frameSource(pass, words: transcript.words, cutWordIds: Set(start.edits.cutWordIds),
                                                           images: images, clock: clock, sent: sent) }
        let planning = Task { () -> Result<ClipAutopilotResult, any Error> in
            defer { plans.finish() }
            do { return .success(try await service.plan(request, connector: connector, model: model, lanes: lanes, frames: source, progress: progress)) }
            catch { return .failure(error) }
        }
        var clips: [Int: JSONValue] = [:]
        try await withTaskCancellationHandler {
            for await (index, plan) in ready where clips[index] == nil {
                try Task.checkCancellation()
                // The clip's opening scan ran beside its request; it is in hand before the clip is applied.
                await sent.opening(index)?.value
                let clipID = UUID().uuidString.lowercased()
                let applyStart = clock.elapsed
                let operations = try ClipAutopilotMapping.operations(for: plan, clipID: clipID, project: project, fonts: fonts)
                let applied = try ClipAutopilotMapping.apply(operations, to: project)
                project = applied.project
                clock.record(.apply, clip: index + 1, since: applyStart)
                report.line("Clip \(index + 1) ready: score \(plan.score)/10.")
                let outputs = try await export(project, clipID, index + 1)
                var fields: [String: JSONValue] = ["rank": .number(Double(index + 1)), "clipId": .string(clipID), "title": .string(plan.title),
                    "score": .number(Double(plan.score)), "verdict": .string(plan.verdict.rawValue),
                    "startWordId": .string(transcript.words[plan.startWord].id), "endWordId": .string(transcript.words[plan.endWord].id),
                    "pending": .array(applied.pending.map { .string($0.decision.rawValue) }), "outputs": .array(outputs.map(JSONValue.string))]
                if let shown = sent.frames(index) { fields["frames"] = Self.framesJSON(shown, plan: plan) }
                clips[index] = .object(fields)
            }
        } onCancel: { planning.cancel() }
        let outcome = try await planning.value.get()
        try Task.checkCancellation()
        // A clip whose plan failed is listed with the reason; the others went on.
        for index in ranked.indices where clips[index] == nil {
            clips[index] = .object(["rank": .number(Double(index + 1)), "error": .string("planFailed")])
        }
        return (clips.keys.sorted().compactMap { clips[$0] }, found.clips.count, outcome.model, project)
    }

    /// Each clip's frames as its request is sent: from the pass (waiting for it while it runs), the opening scan started
    /// beside the request and timed as `opening` for that clip.
    static func frameSource(_ pass: VideoFramePass, words: [TimedWord], cutWordIds: Set<String>, images: Bool, clock: ClaudeModeClock,
                            sent: ClipFramesSent) -> ClipAutopilotFrameSource {
        { index, span in
            guard let clip = FrameClip(words: words, first: span.lowerBound, last: span.upperBound, cutWordIds: cutWordIds),
                  let found = await pass.frames(for: clip) else { return nil }
            clock.begin(.opening, clip: index + 1)
            let opening = Task.detached {
                _ = await pass.opening(for: clip)
                clock.end(.opening, clip: index + 1)
            }
            let frames = ClipAutopilotFrames(sheet: found.sheet, clipStart: clip.start, clipEnd: clip.end, images: images)
            sent.record(index, frames, opening: opening)
            return frames
        }
    }

    /// What the clip's request carried and what the plan chose from it.
    static func framesJSON(_ frames: ClipAutopilotFrames, plan: ClipAutopilotPlan) -> JSONValue {
        let blurred = plan.frames?.blur.filter(\.blur).compactMap { choice in frames.blurCandidate(choice.id) }.map { candidate -> JSONValue in
            .object(["id": .string(candidate.id), "start": .number(candidate.start), "end": .number(candidate.end)])
        } ?? []
        let cover = plan.frames?.cover.flatMap { frames.coverCandidate($0.id) } ?? frames.cover.first
        return .object(["sent": .number(Double(frames.frames.count)), "images": .bool(frames.sendsImages),
                        "imageTokens": .number(Double(frames.sendsImages ? frames.estimatedImageTokens : 0)),
                        "blur": .array(blurred), "cover": cover.map { .number($0.time) } ?? .null])
    }

    /// One clip in the clip style's caption look, through the export command's own path.
    static func exportClip(_ project: Project, clip: String, rank: Int, outDir: URL, aspect: String, quiet: Bool, clock: ClaudeModeClock) async throws -> [String] {
        let projectURL = outDir.appendingPathComponent("autopilot-\(clip).voxclip")
        try await JSONProjectStore().save(project, to: projectURL)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let output = outDir.appendingPathComponent("clip-\(rank)-\(aspect.replacingOccurrences(of: ":", with: "x")).mp4")
        let options = try Export.parse(["--open", projectURL.path, "--export", output.path, "--clip", clip, "--aspect", aspect] + (quiet ? ["--quiet"] : []))
        let start = clock.elapsed
        _ = try await export(options, input: projectURL.path)
        clock.record(.export, clip: rank, since: start)
        return [output.path]
    }
}

/// The frames each clip's request carried, by clip index.
final class ClipFramesSent: Sendable {
    private let sent = Mutex<[Int: (frames: ClipAutopilotFrames, opening: Task<Void, Never>)]>([:])
    func record(_ index: Int, _ frames: ClipAutopilotFrames, opening: Task<Void, Never>) { sent.withLock { $0[index] = (frames, opening) } }
    func frames(_ index: Int) -> ClipAutopilotFrames? { sent.withLock { $0[index]?.frames } }
    func opening(_ index: Int) -> Task<Void, Never>? { sent.withLock { $0[index]?.opening } }
}

/// Progress lines on stderr.
struct AutopilotReport: Sendable {
    let quiet: Bool
    func line(_ text: String) { if !quiet { FileHandle.standardError.write(Data((text + "\n").utf8)) } }
}

extension ClaudeModeClock {
    /// Times an async `body` as `stage`.
    func timed<T>(_ stage: ClaudeModeStage, clip: Int? = nil, _ body: () async throws -> T) async rethrows -> T {
        let start = elapsed
        defer { record(stage, clip: clip, since: start) }
        return try await body()
    }
}
