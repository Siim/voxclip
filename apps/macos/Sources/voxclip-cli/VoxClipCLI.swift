import Foundation
import Darwin
import ArgumentParser
import VoxClipCore
import VoxClipMedia
import VideoToolbox

/// Architecture §9.1 primary export form, with §9.2 subcommands.
@main struct VoxClipCLI: AsyncParsableCommand {
    static func main() async {
        signal(SIGINT, SIG_IGN)
        let task = Task { await execute() }
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { @Sendable in task.cancel() }
        interrupt.resume()
        await task.value
        interrupt.cancel()
    }

    static func execute() async {
        do {
            var command = try parseAsRoot()
            if var asynchronous = command as? any AsyncParsableCommand {
                try await asynchronous.run()
            } else {
                try command.run()
            }
        } catch {
            let status = exitCode(for: error)
            if status == .validationFailure, CommandLine.arguments.contains("--json") {
                let first = CommandLine.arguments.dropFirst().first
                let name = first.map { $0.hasPrefix("-") ? "export" : $0 } ?? "export"
                try? CLIExecution.usageError(command: name, message: message(for: error), json: true)
                Darwin.exit(2)
            }
            let message = fullMessage(for: error)
            if !message.isEmpty {
                let sink = status == .success ? FileHandle.standardOutput : FileHandle.standardError
                sink.write(Data((CLIExecution.redactor().redact(message) + "\n").utf8))
            }
            Darwin.exit(status == .validationFailure ? 2 : status.rawValue)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "voxclip-cli", abstract: "Edit video by words. Native, headless VoxClip tools.",
        discussion: "Primary export: voxclip-cli --open <project-or-media> --export <out.mp4> [options]. Use 'voxclip-cli export --help' for export options.",
        version: "0.1.0",
        subcommands: [Export.self, Probe.self, Transcribe.self, Models.self, Plan.self, RenderCaption.self, FindClips.self, LLMTest.self, Encoders.self, Version.self],
        defaultSubcommand: Export.self
    )
}

/// Default subcommand keeps primary export flags from consuming subcommand options; architecture §9.1.
struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export a project or source media (the default command).")
    @Option(name: .customLong("open"), help: "Project or source media file.") var input: String?
    @Option(name: .customLong("export"), help: "Destination MP4.") var output: String?
    @Option(help: "Caption style ID, or off.") var style: String?
    @Option(help: "source, 16:9, 9:16 or 1:1.") var aspect: String?
    @Option(help: "Saved clip ID, mutually exclusive with --range.") var clip: String?
    @Option(name: .customLong("range"), help: "Inclusive startWordIndex:endWordIndex.") var wordRange: String?
    @Option(help: "Fixture words JSON instead of transcription.") var transcript: String?
    @Option(help: "whisper, apple or elevenlabs.") var engine: String?
    @Option(help: "Transcription catalog model ID.") var model: String?
    @Option(help: "auto or BCP 47 language.") var language: String?
    @Flag(help: "Cut fillers before tightening pauses.") var cutFillers = false
    @Flag(help: "Tighten pauses within the selected export scope.") var tightenPauses = false
    @Option(help: "standard or high.") var quality: String?
    @Option(parsing: .unconditional, help: "Constant output frame rate.") var fps: String?
    @Option(help: "Destination SRT sidecar.") var srt: String?
    @Option(help: "Also write edited, faded Float32 WAV.") var audioOut: String?
    @Flag(help: "Print one final JSON object on stdout.") var json = false
    @Flag(help: "Suppress human-readable progress on stderr.") var quiet = false

    mutating func validate() throws {
        if (input == nil) != (output == nil) { throw ValidationError("Primary export requires both --open and --export") }
        if let aspect, AspectRatio(rawValue: aspect) == nil { throw ValidationError("--aspect must be source, 16:9, 9:16 or 1:1") }
        if let quality, ExportQuality(rawValue: quality) == nil { throw ValidationError("--quality must be standard or high") }
        if let engine { _ = try CLIExecution.engine(engine) }
        if clip != nil && wordRange != nil { throw ValidationError("Use either --clip or --range, not both") }
        if let wordRange {
            let pair = wordRange.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, let first = Int(pair[0]), let last = Int(pair[1]), first >= 0, last >= first else { throw ValidationError("--range must be start:end with 0 <= start <= end") }
        }
        if let fps {
            guard let rate = Double(fps), rate.isFinite, rate > 0, rate <= 60 else {
                throw ValidationError("--fps must be greater than zero and at most 60")
            }
        }
    }

    mutating func run() async throws {
        guard let input, output != nil else { throw CleanExit.helpRequest(self) }
        try await CLIExecution.run(command: "export", json: json) {
            try await CLIWorkflow.export(self, input: input)
        }
    }
}

/// Environment-only key source; architecture §9.4. Never reads Keychain.
struct EnvironmentKeyProvider: KeyProvider {
    func key(for provider: String) async throws -> String? {
        let names = ["elevenlabs": "ELEVENLABS_API_KEY", "anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY", "xai": "XAI_API_KEY", "gemini": "GEMINI_API_KEY"]
        guard let name = names[provider] else { return nil }
        return ProcessInfo.processInfo.environment["VOXCLIP_" + name]
    }
}

/// Single final JSON object and stable exits; architecture §9.3 and §11.2.
enum CLIExecution {
    static func redactor() -> Redactor {
        let environment = ProcessInfo.processInfo.environment
        let secrets = ["ELEVENLABS_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "XAI_API_KEY", "GEMINI_API_KEY"].compactMap { environment["VOXCLIP_" + $0] }
        return Redactor(knownSecrets: secrets, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func engine(_ value: String) throws -> TranscriptEngine {
        switch value {
        case "whisper": .whispercpp
        case "apple": .appleSpeech
        case "elevenlabs": .elevenlabs
        default: throw ValidationError("--engine must be whisper, apple or elevenlabs")
        }
    }

    static func connector(_ value: String) throws -> ConnectorID {
        guard let connector = ConnectorID(rawValue: value) else { throw ValidationError("Unknown connector ID") }
        return connector
    }

    static func run(command: String, json: Bool, operation: () async throws -> JSONValue) async throws {
        do {
            let value = try await operation()
            if json { try printJSON(value) }
        } catch let error as ValidationError {
            try usageError(command: command, message: error.message, json: json)
            throw ExitCode(2)
        } catch VoiceLabProjectError.unsupportedRendering {
            let message = "This build cannot preview or export generated voice segments yet. Your video and edits are still here."
            if json {
                try printJSON(.object(["ok": .bool(false), "command": .string(command), "error": .object(["code": .string("exportFailed"), "message": .string(message)]), "version": .string("0.1.0")]))
            } else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
            throw ExitCode(5)
        } catch {
            let failure = error is CancellationError ? VoxClipError.cancelled : (error as? VoxClipError ?? (error is DecodingError ? .projectUnreadable("Invalid input JSON") : .exportFailed(redactor().redact(error.localizedDescription))))
            let message = redactor().redact(failure.errorDescription ?? "")
            if json {
                try printJSON(.object(["ok": .bool(false), "command": .string(command), "error": .object(["code": .string(failure.code.rawValue), "message": .string(message)]), "version": .string("0.1.0")]))
            } else if failure != .cancelled {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            throw ExitCode(failure.exitCode)
        }
    }

    static func usageError(command: String, message: String, json: Bool) throws {
        let message = redactor().redact(message)
        if json {
            try printJSON(.object(["ok": .bool(false), "command": .string(command),
                "error": .object(["code": .string("usageError"), "message": .string(message)]), "version": .string("0.1.0")]))
        } else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    }

    static func printJSON(_ value: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print source media facts.")
    @Argument(help: "Source media.") var media: String
    @Flag(help: "Print JSON.") var json = false
    mutating func run() async throws {
        try await CLIExecution.run(command: "probe", json: json) {
            let probe: any MediaProbe = AVMediaProbe()
            return try CLIWorkflow.success("probe", value: await probe.probe(URL(fileURLWithPath: media)))
        }
    }
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe source media and save a project.")
    @Option(name: .customLong("open"), help: "Source media.") var input: String
    @Option(help: "whisper, apple or elevenlabs.") var engine = "whisper"
    @Option(help: "Catalog model ID.") var model: String?
    @Option(help: "auto or BCP 47 language.") var language = "auto"
    @Option(help: "Destination raw adapter response JSON.") var rawOut: String?
    @Flag(name: .customLong("no-dtw"), help: "Disable whisper DTW.") var noDTW = false
    @Flag(help: "Enable ElevenLabs speaker diarization.") var diarize = false
    @Option(help: "Destination .voxclip project.") var out: String
    @Flag(help: "Print JSON.") var json = false
    @Flag(help: "Suppress progress.") var quiet = false
    mutating func validate() throws { _ = try CLIExecution.engine(engine) }
    mutating func run() async throws {
        try await CLIExecution.run(command: "transcribe", json: json) {
            try await CLIWorkflow.transcribe(self)
        }
    }
}

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage transcription models.", subcommands: [List.self, Install.self, Verify.self, Remove.self])
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List catalog and installed models.")
        @Flag(help: "Print JSON.") var json = false
        mutating func run() async throws {
            try await CLIExecution.run(command: "models list", json: json) {
                let catalog: any ModelCatalog = BundledModelCatalog(shared: try SharedResources.locate())
                return try CLIWorkflow.success("models list", value: await catalog.models())
            }
        }
    }
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install a verified model.")
        @Argument(help: "Catalog model ID.") var id: String
        @Flag(help: "Print JSON.") var json = false
        mutating func run() async throws {
            try await CLIExecution.run(command: "models install", json: json) {
                let catalog = BundledModelCatalog(shared: try SharedResources.locate())
                let downloader: any ModelDownloader = ModelStore(catalog: catalog, locations: DataLocations())
                try await downloader.install(id: id, progress: { _ in })
                return CLIWorkflow.success("models install", fields: ["model": .string(id)])
            }
        }
    }
    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Verify an installed model checksum.")
        @Argument(help: "Catalog model ID.") var id: String
        @Flag(help: "Print JSON.") var json = false
        mutating func run() async throws {
            try await CLIExecution.run(command: "models verify", json: json) {
                let catalog = BundledModelCatalog(shared: try SharedResources.locate())
                let downloader: any ModelDownloader = ModelStore(catalog: catalog, locations: DataLocations())
                let verified = try await downloader.verify(id: id)
                guard verified else { throw VoxClipError.modelChecksumMismatch(id) }
                return CLIWorkflow.success("models verify", fields: ["model": .string(id), "verified": .bool(verified)])
            }
        }
    }
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an installed model.")
        @Argument(help: "Catalog model ID.") var id: String
        @Flag(help: "Print JSON.") var json = false
        mutating func run() async throws {
            try await CLIExecution.run(command: "models remove", json: json) {
                let catalog = BundledModelCatalog(shared: try SharedResources.locate())
                let downloader: any ModelDownloader = ModelStore(catalog: catalog, locations: DataLocations())
                try await downloader.remove(id: id)
                return CLIWorkflow.success("models remove", fields: ["model": .string(id)])
            }
        }
    }
}

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print sample-grid edit plan.")
    @Option(name: .customLong("open"), help: "Project file.") var input: String
    @Flag(help: "Print JSON.") var json = false
    mutating func run() async throws {
        try await CLIExecution.run(command: "plan", json: json) {
            let store: any ProjectStore = JSONProjectStore()
            var project = try await store.load(from: URL(fileURLWithPath: input))
            project.edits.activeClipId = nil
            let plan = try CLIWorkflow.plan(project)
            return CLIWorkflow.success("plan", fields: ["sampleRate": .number(plan.sampleRate), "totalSamples": .number(Double(plan.totalSamples)),
                "outputSamples": .number(Double(plan.outputSamples)), "durationSeconds": .number(plan.duration),
                "cuts": .array(plan.cuts.map { .array([.number(Double($0.startSample)), .number(Double($0.endSample))]) }),
                "kept": .array(plan.kept.map { .array([.number(Double($0.startSample)), .number(Double($0.endSample))]) })])
        }
    }
}

struct RenderCaption: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render transparent caption fixture samples.")
    @Option(help: "Caption style override.") var style: String?
    @Option(name: .customLong("case"), help: "Caption fixture JSON.") var fixture: String?
    @Option(help: "Gallery tiles JSON.") var tiles: String?
    @Option(help: "Single sample index.") var sample: Int?
    @Option(help: "Destination PNG.") var out: String
    @Option(help: "Destination layout JSON.") var layoutOut: String?
    @Flag(help: "Print JSON.") var json = false
    mutating func validate() throws {
        guard (fixture != nil) != (tiles != nil) else { throw ValidationError("Choose exactly one of --case or --tiles") }
        if let sample, sample < 0 || fixture == nil { throw ValidationError("--sample requires --case and a nonnegative index") }
        guard style == nil, layoutOut == nil else {
            throw ValidationError("The caption harness uses the fixture style and writes layout JSON beside its samples")
        }
    }
    mutating func run() async throws {
        try await CLIExecution.run(command: "render-caption", json: json) {
            try await CLIWorkflow.renderCaption(self)
        }
    }
}

struct FindClips: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Suggest clips without modifying the project.")
    @Option(name: .customLong("open"), help: "Project file.") var input: String
    @Option(help: "best, hooks, topics, quotes or custom.") var preset: String
    @Option(help: "Extra instructions, required for custom.") var instruction: String?
    @Option(help: "Connector ID.") var connector: String
    @Option(help: "LLM model ID.") var model: String?
    @Flag(name: .customLong("no-snap"), help: "Disable sentence-boundary snapping.") var noSnap = false
    @Flag(help: "Print rendered prompts without sending.") var dryRun = false
    @Flag(help: "Print JSON.") var json = false
    mutating func validate() throws {
        _ = try CLIExecution.connector(connector)
        guard ClipPresetID(rawValue: preset) != nil else { throw ValidationError("Unknown clip preset") }
        if preset == "custom", (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError("--instruction is required for custom") }
    }
    mutating func run() async throws {
        try await CLIExecution.run(command: "find-clips", json: json) {
            let store: any ProjectStore = JSONProjectStore()
            let project = try await store.load(from: URL(fileURLWithPath: input))
            guard let transcript = project.transcript else { throw VoxClipError.noSpeech }
            let shared = try SharedResources.locate()
            let catalog = try LLMCatalog(shared: shared)
            let prompt = try ClipPromptDocument(data: Data(contentsOf: shared.root.appendingPathComponent("prompts/clip-finder.json")))
            guard let selected = ClipPresetID(rawValue: preset), let chosen = prompt.presets.first(where: { $0.id == selected }) else { throw ValidationError("Unknown clip preset") }
            let id = try CLIExecution.connector(connector)
            let selectedModel = model ?? catalog.curatedModels(for: id).first?.id ?? ""
            if dryRun {
                let builder = ClipRequestBuilder(prompt: prompt)
                let words = builder.clipWords(transcript, corrections: project.edits.corrections)
                let context = catalog.curatedModels(for: id).first { $0.id == selectedModel }?.contextTokens ?? 128000
                let windows = try builder.windows(words: words, preset: chosen, instruction: instruction, contextTokens: context, localServer: id == .ollama || id == .lmstudio)
                let requests: [JSONValue] = windows.enumerated().map { index, window in
                    let request = builder.request(words: words, window: window, preset: chosen, instruction: instruction,
                        windowIndex: index, windowCount: windows.count, timeout: catalog.timeout(for: id, feature: .clipFinder), language: transcript.language)
                    return .object(["system": .string(request.system), "cachedBlock": .string(request.cachedBlock ?? ""), "instruction": .string(request.instruction)])
                }
                return CLIWorkflow.success("find-clips", fields: ["prompts": .array(requests)])
            }
            let logger = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            let keys = LLMEnvironmentKeyProvider(catalog: catalog)
            let service: any LLMConnector = id == .appleFoundation ? FoundationModelsConnector(log: logger) : StubLLMConnector(id: id, keys: keys, catalog: catalog, log: logger)
            let finder = ClipFinder(runner: LLMRunner(keys: keys, catalog: catalog, log: logger), shared: shared)
            let result = try await finder.find(ClipFinderRequest(transcript: transcript, corrections: project.edits.corrections,
                cutWordIds: Set(project.edits.cutWordIds), preset: chosen, instruction: instruction, snap: !noSnap),
                connector: service, model: selectedModel)
            return try CLIWorkflow.success("find-clips", value: result)
        }
    }
}

struct LLMTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "llm-test", abstract: "Test a configured connector.")
    @Option(help: "Connector ID.") var connector: String
    @Option(help: "LLM model ID.") var model: String?
    @Flag(help: "Print JSON.") var json = false
    mutating func validate() throws { _ = try CLIExecution.connector(connector) }
    mutating func run() async throws {
        try await CLIExecution.run(command: "llm-test", json: json) {
            let shared = try SharedResources.locate()
            let catalog = try LLMCatalog(shared: shared)
            let id = try CLIExecution.connector(connector)
            let selectedModel = model ?? catalog.curatedModels(for: id).first?.id ?? ""
            let logger = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            let keys = LLMEnvironmentKeyProvider(catalog: catalog)
            let service: any LLMConnector = id == .appleFoundation ? FoundationModelsConnector(log: logger) : StubLLMConnector(id: id, keys: keys, catalog: catalog, log: logger)
            let result = try await LLMRunner(keys: keys, catalog: catalog, log: logger).test(on: service, model: selectedModel)
            guard result.passed else { throw LLMError.invalidOutput(reason: "Connection test did not echo VoxClip") }
            return CLIWorkflow.success("llm-test", fields: ["passed": .bool(result.passed), "model": .string(result.model),
                "usedFallback": .bool(result.usedFallback), "seconds": .number(result.seconds)])
        }
    }
}

struct Encoders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report VideoToolbox H.264 availability.")
    @Flag(help: "Print JSON.") var json = false
    mutating func run() async throws {
        try await CLIExecution.run(command: "encoders", json: json) {
            CLIWorkflow.success("encoders", fields: ["h264_videotoolbox": .bool(CLIWorkflow.hardwareEncoderAvailable())])
        }
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print VoxClip version and platform.")
    mutating func run() {
        #if arch(arm64)
        print("VoxClip 0.1.0 (macos-arm64)")
        #else
        print("VoxClip 0.1.0 (macos-x64)")
        #endif
    }
}
