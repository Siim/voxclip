import Foundation

public struct SpeakerModel: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let dimension: Int
    public let files: [ModelFile]
    public let totalBytes: Int64
    public let languages: [String]
    public let license: String
    public let attribution: String
    public let sourcePage: URL
    public let publisher: String
    public let preprocessing: String
    public let threshold: Double?
    public let calibration: Calibration?
    public struct Calibration: Codable, Sendable {
        public let date: String
        public let preprocessing: String
        public let modelSha256: String
        public let vadSha256: String
        public let languages: [Language]
        public struct Language: Codable, Sendable {
            public let language: String
            public let corpus: String
            public let impostorPairs: Int
            public let sameSpeakerPairs: Int
            public let falseAcceptRate: Double
            public let sameSpeakerPassRate: Double
        }
    }
    public func calibratedThreshold(language: String = "en") -> Double? {
        guard let threshold, threshold.isFinite, (0...1).contains(threshold),
              preprocessing == SpeakerAudio.version, let calibration, calibration.preprocessing == preprocessing,
              calibration.modelSha256 == files.first(where: { $0.role == "speaker" })?.sha256,
              calibration.vadSha256 == files.first(where: { $0.role == "vad" })?.sha256,
              let result = calibration.languages.first(where: { $0.language == language }),
              result.impostorPairs >= 200, result.sameSpeakerPairs >= 50,
              result.falseAcceptRate.isFinite, (0...0.01).contains(result.falseAcceptRate),
              result.sameSpeakerPassRate.isFinite, (0.95...1).contains(result.sameSpeakerPassRate) else { return nil }
        return threshold
    }
    public var download: ModelDescriptor {
        ModelDescriptor(id: id, displayName: displayName, engine: .whispercpp, files: files, totalBytes: totalBytes, languages: languages,
                        license: license, attribution: attribution, sourcePage: sourcePage, publisher: publisher)
    }
    public func directory(_ locations: DataLocations) -> URL { locations.models.appendingPathComponent("voice-lab/\(id)") }
    public func verifiedFiles(at directory: URL) throws -> (model: URL, vad: URL) {
        guard dimension == 256, preprocessing == SpeakerAudio.version, files.count == 2,
              let model = files.first(where: { $0.role == "speaker" }), let vad = files.first(where: { $0.role == "vad" }) else { throw VoiceConsentError.speakerUnavailable }
        for file in files {
            let url = directory.appendingPathComponent(file.name)
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard attributes.isSymbolicLink != true, attributes.isRegularFile == true, Int64(attributes.fileSize ?? 0) == file.bytes,
                  try SpeechSHA256.file(url) == file.sha256 else { throw VoiceConsentError.speakerUnavailable }
        }
        return (directory.appendingPathComponent(model.name), directory.appendingPathComponent(vad.name))
    }
}

public struct SpeakerModelCatalog: ModelCatalog {
    public let entry: SpeakerModel
    public init(shared: SharedResources) throws {
        struct Document: Decodable { let schema: String; let models: [SpeakerModel] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab-models.json")))
        guard document.schema == "voxclip-voice-models/1", document.models.count == 1, let entry = document.models.first,
              entry.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil,
              entry.files.allSatisfy({ $0.name == URL(fileURLWithPath: $0.name).lastPathComponent && !$0.name.hasPrefix(".") && $0.url.scheme == "https" && $0.bytes > 0 && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
              entry.files.reduce(Int64(0), { $0 + $1.bytes }) == entry.totalBytes else { throw VoiceConsentError.speakerUnavailable }
        self.entry = entry
    }
    public func models() async throws -> [ModelDescriptor] { [entry.download] }
    public func model(id: String) async throws -> ModelDescriptor {
        guard id == entry.id else { throw VoxClipError.modelMissing(id) }
        return entry.download
    }
}
