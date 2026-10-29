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
        public let outcome: String?
        public let margin: Margin?
        public let languages: [Language]
        public struct Margin: Codable, Sendable {
            public let policy: String
            public let absoluteFloor: Double
            public let crossRuntimeDrift: Double
            public let percentileProbability: Double
            public let percentileMethod: String
            public let percentileCalibrationImpostorScore: Double
            public let roundingIncrement: Double
            public let maximumCalibrationImpostorScore: Double
            public let candidateThreshold: Double
            public let farLimit: Double
            public let sameSpeakerMinimum: Double
            fileprivate var roundedThreshold: Double? {
                guard percentileCalibrationImpostorScore.isFinite, absoluteFloor.isFinite, crossRuntimeDrift.isFinite,
                      let percentile = Decimal(string: String(percentileCalibrationImpostorScore)),
                      let margin = Decimal(string: String(max(absoluteFloor, crossRuntimeDrift))) else { return nil }
                var value = max(0, percentile + margin)
                var rounded = Decimal()
                NSDecimalRound(&rounded, &value, 2, .up)
                return Double(NSDecimalNumber(decimal: rounded).stringValue)
            }
        }
        public struct Language: Codable, Sendable {
            public let language: String
            public let corpus: String
            public let impostorPairs: Int
            public let sameSpeakerPairs: Int
            public let falseAcceptRate: Double
            public let sameSpeakerPassRate: Double
            public let speakers: Int?
            public let calibrationSpeakers: Int?
            public let independentClips: Int?
            public let audioRenders: Int?
            public let conditions: [Condition]?
        }
        public struct Condition: Codable, Sendable {
            public let corpus: String
            public let sampleRate: Int
            public let role: String
            public let speakers: Int
            public let independentClips: Int
            public let impostorPairs: Int
            public let sameSpeakerPairs: Int
            public let falseAcceptRate: Double
            public let sameSpeakerPassRate: Double
        }
    }
    public func calibratedThreshold(language: String = "en") -> Double? {
        guard language == "en", let threshold, threshold.isFinite, (0...1).contains(threshold),
              preprocessing == SpeakerAudio.version, let calibration, calibration.preprocessing == preprocessing,
              calibration.modelSha256 == files.first(where: { $0.role == "speaker" })?.sha256,
              calibration.vadSha256 == files.first(where: { $0.role == "vad" })?.sha256,
              calibration.outcome == "passed", let margin = calibration.margin,
              margin.policy == "clean-p999-plus-margin-ceil-cent-production-v1",
              margin.percentileProbability == 0.999, margin.percentileMethod == "linear-(n-1)",
              margin.roundingIncrement == 0.01,
              margin.absoluteFloor.isFinite, margin.absoluteFloor >= 0.002,
              margin.crossRuntimeDrift.isFinite, margin.crossRuntimeDrift >= 0,
              margin.maximumCalibrationImpostorScore.isFinite, (-1...1).contains(margin.maximumCalibrationImpostorScore),
              margin.percentileCalibrationImpostorScore.isFinite,
              (-1...margin.maximumCalibrationImpostorScore).contains(margin.percentileCalibrationImpostorScore),
              threshold == margin.candidateThreshold,
              threshold == margin.roundedThreshold,
              margin.farLimit.isFinite, (0...0.005).contains(margin.farLimit),
              margin.sameSpeakerMinimum.isFinite, (0.95...1).contains(margin.sameSpeakerMinimum),
              let result = calibration.languages.first(where: { $0.language == language }),
              let speakers = result.speakers, let calibrationSpeakers = result.calibrationSpeakers,
              let clips = result.independentClips, let renders = result.audioRenders,
              speakers >= calibrationSpeakers, calibrationSpeakers >= 80, clips >= speakers * 3, renders == clips * 2,
              let conditions = result.conditions, conditions.count >= 4,
              Set(conditions.map(\.sampleRate)) == [44_100, 48_000],
              conditions.allSatisfy({ $0.speakers >= 2 && $0.independentClips >= $0.speakers * 3 && $0.impostorPairs >= 200 && $0.sameSpeakerPairs >= 50 && $0.falseAcceptRate.isFinite && (0...margin.farLimit).contains($0.falseAcceptRate) && $0.sameSpeakerPassRate.isFinite && (margin.sameSpeakerMinimum...1).contains($0.sameSpeakerPassRate) }),
              result.impostorPairs >= 200, result.sameSpeakerPairs >= 50,
              result.falseAcceptRate.isFinite, (0...margin.farLimit).contains(result.falseAcceptRate),
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
