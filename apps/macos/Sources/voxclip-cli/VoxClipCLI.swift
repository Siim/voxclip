import Foundation
import Darwin
import ArgumentParser
import VoxClipCore
import VoxClipMedia

/// Architecture §9.1 primary export form, with §9.2 subcommands.
@main struct VoxClipCLI: AsyncParsableCommand {
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asynchronous = command as? any AsyncParsableCommand {
                try await asynchronous.run()
            } else {
                try command.run()
            }
        } catch {
            let status = exitCode(for: error)
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
    @Flag(help: "Tighten pauses before selecting a clip.") var tightenPauses = false
    @Option(help: "standard or high.") var quality: String?
    @Option(help: "Constant output frame rate.") var fps: Double?
    @Option(help: "Destination SRT sidecar.") var srt: String?
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
        if let fps, !fps.isFinite || fps <= 0 || fps > 60 { throw ValidationError("--fps must be greater than zero and at most 60") }
    }

    mutating func run() async throws {
        guard let input, output != nil else { throw CleanExit.helpRequest(self) }
        try await CLIExecution.run(command: "export", json: json) {
            let store: any ProjectStore = JSONProjectStore()
            _ = try await store.load(from: URL(fileURLWithPath: input))
            throw VoxClipError.notImplemented("mac-media")
        }
    }
}

/// Environment-only key source; architecture §9.4. Never reads Keychain.
struct EnvironmentKeyProvider: KeyProvider {
    func key(for provider: String) async throws -> String? {
        let names = ["elevenlabs": "ELEVENLABS_API_KEY", "anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY", "xai": "XAI_API_KEY", "gemini": "GEMINI_API_KEY"]
        guard let name = names[provider] else { return nil }
        return ProcessInfo.processInfo.environment[name]
    }
}

/// Single final JSON object and stable exits; architecture §9.3 and §11.2.
enum CLIExecution {
    static func redactor() -> Redactor {
        let environment = ProcessInfo.processInfo.environment
        let secrets = ["ELEVENLABS_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "XAI_API_KEY", "GEMINI_API_KEY"].compactMap { environment[$0] }
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
        } catch {
            let failure = error is CancellationError ? VoxClipError.cancelled : (error as? VoxClipError ?? .providerError("Unexpected failure"))
            let message = redactor().redact(failure.errorDescription ?? "Cancelled")
            if json {
                try printJSON(.object(["ok": .bool(false), "command": .string(command), "error": .object(["code": .string(failure.code.rawValue), "message": .string(message)]), "version": .string("0.1.0")]))
            } else if failure != .cancelled {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            throw ExitCode(failure.exitCode)
        }
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
            _ = try await probe.probe(URL(fileURLWithPath: media))
            throw VoxClipError.notImplemented("mac-media")
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
            let extractor: any AudioExtractor = AVAudioExtractor()
            let locations = DataLocations()
            _ = try await extractor.extract(AudioExtractionRequest(sourceURL: URL(fileURLWithPath: input), contentKey: "", durationSeconds: 0, cacheDirectory: locations.cache), progress: { _ in })
            throw VoxClipError.notImplemented("mac-speech")
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
                _ = try await catalog.models()
                throw VoxClipError.notImplemented("mac-speech")
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
                throw VoxClipError.notImplemented("mac-speech")
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
                _ = try await downloader.verify(id: id)
                throw VoxClipError.notImplemented("mac-speech")
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
                throw VoxClipError.notImplemented("mac-speech")
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
            _ = try await store.load(from: URL(fileURLWithPath: input))
            throw VoxClipError.notImplemented("mac-editing")
        }
    }
}

struct RenderCaption: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render a transparent caption golden case.")
    @Option(help: "Caption style ID.") var style: String
    @Option(name: .customLong("case"), help: "Caption fixture JSON.") var fixture: String
    @Option(help: "Destination PNG.") var out: String
    @Option(help: "Destination layout JSON.") var layoutOut: String?
    @Flag(help: "Print JSON.") var json = false
    mutating func run() async throws {
        try await CLIExecution.run(command: "render-caption", json: json) {
            _ = CoreTextCaptionRasterizer(shared: try SharedResources.locate()) as any CaptionRasterizer
            throw VoxClipError.notImplemented("mac-captions")
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
            _ = try await store.load(from: URL(fileURLWithPath: input))
            throw VoxClipError.notImplemented("mac-ai")
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
            let service: any LLMConnector = StubLLMConnector(id: try CLIExecution.connector(connector))
            _ = try await service.models(refresh: false)
            throw VoxClipError.notImplemented("mac-ai")
        }
    }
}

struct Encoders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report VideoToolbox H.264 availability.")
    @Flag(help: "Print JSON.") var json = false
    mutating func run() async throws {
        try await CLIExecution.run(command: "encoders", json: json) { throw VoxClipError.notImplemented("mac-media") }
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print VoxClip version and platform.")
    mutating func run() { print("VoxClip 0.1.0 (macOS-arm64)") }
}
