import Foundation

public struct SpeechModelRuntime: Decodable, Sendable {
    public struct Whisper: Decodable, Sendable {
        public var multilingual: Bool
        public var dtwAheadsPreset: String
        public var initialPromptByLanguage: [String: String]
        public var vadModel: String
        public var dtwDefault: Bool?
    }
    public var kind: String
    public var forcedLanguage: String?
    public var verbatim: Bool
    public var timing: TimingSource
    public var whisper: Whisper?
    private enum CodingKeys: String, CodingKey { case kind, forcedLanguage, verbatim, timing, whisper }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        forcedLanguage = try values.decodeIfPresent(String.self, forKey: .forcedLanguage)
        verbatim = try values.decodeIfPresent(Bool.self, forKey: .verbatim) ?? false
        timing = try values.decodeIfPresent(TimingSource.self, forKey: .timing) ?? .tokenGrouped
        whisper = try values.decodeIfPresent(Whisper.self, forKey: .whisper)
    }
}

struct SpeechCatalogDocument: Decodable {
    struct Entry: Decodable {
        let descriptor: ModelDescriptor
        let runtime: SpeechModelRuntime
        let repo: Repository
        init(from decoder: any Decoder) throws {
            descriptor = try ModelDescriptor(from: decoder)
            runtime = try SpeechModelRuntime(from: decoder)
            repo = try decoder.container(keyedBy: CodingKeys.self).decode(Repository.self, forKey: .repo)
        }
        enum CodingKeys: String, CodingKey { case repo }
    }
    struct Repository: Decodable { let id: String; let revision: String }
    struct Languages: Decodable { let iso639_3: [String: String]; let whisperCodeFor: [String: String] }
    struct Defaults: Decodable {
        struct Platforms: Decodable { let macos: SpeechLanguageDefault; let windows: SpeechLanguageDefault }
        let lowMemoryThresholdBytes: Int64
        let byLanguage: [String: Platforms]
    }
    struct Engine: Decodable { let id: TranscriptEngine }
    let schema: String
    let schemaVersion: Int
    let engines: [Engine]
    let models: [Entry]
    let languageCodes: Languages
    let defaults: Defaults
    func validate() throws {
        guard schema == "voxclip.transcription-catalog", schemaVersion == 1, Set(engines.map(\.id)).count == engines.count else { throw VoxClipError.transcriptionFailed("Invalid model catalogue schema") }
        let identifiers = Set(models.map(\.descriptor.id))
        guard identifiers.count == models.count else { throw VoxClipError.transcriptionFailed("Duplicate model ids") }
        for entry in models {
            let model = entry.descriptor
            guard model.engine == .whispercpp, ["asr", "vad"].contains(entry.runtime.kind),
                  !model.id.isEmpty, model.id.count <= 128, model.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
                  model.requires.allSatisfy(identifiers.contains), model.totalBytes == model.files.reduce(0, { $0 + $1.bytes }),
                  entry.repo.revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else { throw VoxClipError.transcriptionFailed("Invalid model catalogue entry") }
            for file in model.files {
                guard file.bytes > 0, file.name == URL(fileURLWithPath: file.name).lastPathComponent,
                      file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                      file.url.absoluteString.hasPrefix("https://huggingface.co/\(entry.repo.id)/resolve/\(entry.repo.revision)/") else { throw VoxClipError.transcriptionFailed("Invalid pinned model file") }
            }
        }
        for platforms in defaults.byLanguage.values {
            for settings in [platforms.macos, platforms.windows] {
                let referenced = settings.local + [settings.recommendedDownload] + [settings.lowMemoryDownload].compactMap { $0 }
                guard referenced.allSatisfy(identifiers.contains) else { throw VoxClipError.transcriptionFailed("Unknown default model") }
            }
        }
    }
}
