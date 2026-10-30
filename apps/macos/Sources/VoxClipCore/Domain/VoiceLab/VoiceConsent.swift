import Foundation

public enum VoiceConsentError: Error, LocalizedError, Equatable, Sendable {
    case invalidRecord, invalidName, invalidWords, attestationsRequired, statementMismatch, tooManyAttempts
    case speakerUnavailable, speakerMismatch, voiceOwnerMismatch, inactive, cancelled, creationPending
    case creatorMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a name with 1 to 60 Unicode scalars and no control characters."
        case .invalidWords: "The consent word list isn't available."
        case .attestationsRequired: "Confirm all three statements before recording."
        case .statementMismatch: "That didn't match the statement. Read it again, clearly, in one take."
        case .tooManyAttempts: "Three attempts are allowed per 10 minutes. Please try again later."
        case .speakerUnavailable: "The speaker check isn't available yet. Your voice can't be created until it is."
        case .speakerMismatch: "Some of these recordings don't sound like the voice in your consent statement."
        case .voiceOwnerMismatch: "This doesn't sound like the voice owner. Voice Lab is only for your own videos."
        case .inactive: "This voice is not active. It cannot generate new takes."
        case .cancelled: ""
        case .creationPending: "Voice creation may have completed. Reconcile the pending voice in Settings. Do not create it again."
        case .invalidRecord: "The voice consent record could not be verified. No audio was sent."
        case .creatorMismatch: "This voice was created with a different ElevenLabs key or region. Use that key to delete it, or remove it from VoxClip only; the voice may stay in that ElevenLabs account."
        }
    }
}

public enum VoiceLabGate {
    public static func canCheckOwnVoice(speakerAvailable: Bool, calibratedThreshold: Double?, language: String) -> Bool {
        speakerAvailable && language == "en" && calibratedThreshold.map { $0.isFinite && (0...1).contains($0) } == true
    }
    public static func settingsVisible(enabled: Bool, internalBuild: Bool) -> Bool { true }
    public static func rewriteEnabled(enabled: Bool, noticeAccepted: Bool, internalBuild: Bool) -> Bool {
        enabled && (noticeAccepted || internalBuild)
    }
    public static func canEnroll(enabled: Bool, busy: Bool) -> Bool { enabled && !busy }
}

public struct VoiceConsentStatement: Codable, Sendable, Equatable {
    public let language: String
    public let text: String
    public let nonce: [String]
    public init(language: String, text: String, nonce: [String]) { self.language = language; self.text = text; self.nonce = nonce }
}

public struct VoiceConsentText: Codable, Sendable {
    public let schema: String
    public let templates: [String: String]
    public let months: [String: [String]]
    public init(shared: SharedResources) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: shared.root.appendingPathComponent("voice-lab/statements.json")))
    }
    public static func displayName(_ value: String) throws -> String {
        let scalars = Array(value.unicodeScalars)
        let first = scalars.firstIndex { !$0.properties.isWhitespace }
        let last = scalars.lastIndex { !$0.properties.isWhitespace }
        guard let first, let last else { throw VoiceConsentError.invalidName }
        let name = String(String.UnicodeScalarView(scalars[first...last]))
        guard (1...60).contains(name.unicodeScalars.count), !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw VoiceConsentError.invalidName }
        return name
    }
    public func statementOpening(name: String, language: String) throws -> String {
        guard let template = templates[language], let date = template.range(of: "{date}") else { throw VoiceConsentError.invalidWords }
        return String(template[..<date.lowerBound]).replacingOccurrences(of: "{name}", with: try Self.displayName(name))
    }
    public func statement<R: RandomNumberGenerator>(name: String, language: String?, date: Date, calendar: Calendar = Calendar(identifier: .gregorian),
                                                    words: [String], rng: inout R) throws -> VoiceConsentStatement {
        let name = try Self.displayName(name)
        let language = language == "et" ? "et" : "en"
        guard schema == "voxclip-voice-statements/1", let template = templates[language], let months = months[language], months.count == 12,
              words.count >= 500, Set(words).count == words.count,
              words.allSatisfy({ (4...8).contains($0.count) && $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains) }) else { throw VoiceConsentError.invalidWords }
        var available = words
        var nonce: [String] = []
        for _ in 0..<4 { nonce.append(available.remove(at: Int.random(in: available.indices, using: &rng))) }
        let dateText = try displayDate(date, language: language, calendar: calendar)
        var text = template.replacingOccurrences(of: "{name}", with: name).replacingOccurrences(of: "{date}", with: dateText)
        for index in nonce.indices { text = text.replacingOccurrences(of: "{w\(index + 1)}", with: nonce[index]) }
        return VoiceConsentStatement(language: language, text: text, nonce: nonce)
    }
    public func displayDate(_ date: Date, language: String = "en", calendar: Calendar = Calendar(identifier: .gregorian)) throws -> String {
        let parts = calendar.dateComponents([.day, .month, .year], from: date)
        guard let names = months[language], names.count == 12, let day = parts.day, let month = parts.month,
              (1...12).contains(month), let year = parts.year else { throw VoiceConsentError.invalidRecord }
        return "\(day)\(language == "et" ? "." : "") \(names[month - 1]) \(year)"
    }
}

public struct VoiceStatementMatch: Codable, Sendable, Equatable {
    public let wer: Double
    public let transcriptionId: String
    public static func verify(_ transcript: RawTranscript, statement: VoiceConsentStatement) throws -> Self {
        func tokens(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map { EditingPrimitives.normalizeForMatch(String($0)) }.filter { !$0.isEmpty } }
        let expected = tokens(statement.text)
        let recognized = tokens(transcript.tokens.map(\.text).joined(separator: " "))
        guard !expected.isEmpty, recognized.count <= 1_000 else { throw VoiceConsentError.statementMismatch }
        var previous = Array(0...recognized.count)
        for (index, word) in expected.enumerated() {
            var current = [index + 1]
            for (otherIndex, other) in recognized.enumerated() {
                current.append(min(current[otherIndex] + 1, previous[otherIndex + 1] + 1, previous[otherIndex] + (word == other ? 0 : 1)))
            }
            previous = current
        }
        let wer = Double(previous[recognized.count]) / Double(expected.count)
        guard wer <= 0.15, statement.nonce.count == 4, Set(statement.nonce).count == 4,
              statement.nonce.allSatisfy({ recognized.contains(EditingPrimitives.normalizeForMatch($0)) }), transcript.language == statement.language else { throw VoiceConsentError.statementMismatch }
        return Self(wer: wer, transcriptionId: transcript.providerRequestID ?? "")
    }
}

public struct VoiceConsentRecord: Codable, Sendable, Equatable, Identifiable {
    package init(schema: String, recordId: String, provider: String, type: String, voiceId: String, voiceName: String, status: Status, createdAt: String, deletedAt: String?, statement: Statement, attestations: Attestations, samples: [Sample], speaker: Speaker, app: App, region: ElevenLabsRegion? = nil, creator: Creator? = nil) {
        self.schema = schema; self.recordId = recordId; self.provider = provider; self.type = type; self.voiceId = voiceId; self.voiceName = voiceName; self.status = status; self.createdAt = createdAt; self.deletedAt = deletedAt; self.statement = statement; self.attestations = attestations; self.samples = samples; self.speaker = speaker; self.app = app
        self.region = region; self.creator = creator
    }

    public struct Creator: Codable, Sendable, Equatable {
        public let region: ElevenLabsRegion
        public let keyFingerprint: String
        public init(region: ElevenLabsRegion, keyFingerprint: String) {
            self.region = region; self.keyFingerprint = keyFingerprint
        }
    }

    public enum Status: String, Codable, Sendable { case active, verificationRequired, deleted }
    public struct Statement: Codable, Sendable, Equatable {
        package init(language: String, text: String, nonce: [String], audioFile: String, audioSha256: String, stt: VoiceStatementMatch) {
            self.language = language; self.text = text; self.nonce = nonce; self.audioFile = audioFile; self.audioSha256 = audioSha256; self.stt = stt
        }

        public let language: String
        public let text: String
        public let nonce: [String]
        public let audioFile: String
        public let audioSha256: String
        public let stt: VoiceStatementMatch
    }
    public struct Attestations: Codable, Sendable, Equatable {
        public let ownVoice: Bool
        public let adult: Bool
        public let ownVideosOnly: Bool
        public let acceptedAt: String
        public init(ownVoice: Bool, adult: Bool, ownVideosOnly: Bool, acceptedAt: Date) {
            self.ownVoice = ownVoice; self.adult = adult; self.ownVideosOnly = ownVideosOnly; self.acceptedAt = VoiceConsentRecord.timestamp(acceptedAt)
        }
        public var complete: Bool { ownVoice && adult && ownVideosOnly }
    }
    public struct Sample: Codable, Sendable, Equatable {
        package init(sha256: String, seconds: Double, source: String, speakerScore: Double) {
            self.sha256 = sha256; self.seconds = seconds; self.source = source; self.speakerScore = speakerScore
        }

        public let sha256: String
        public let seconds: Double
        public let source: String
        public let speakerScore: Double
    }
    public struct Speaker: Codable, Sendable, Equatable {
        package init(model: String, threshold: Double, embedding: String) {
            self.model = model; self.threshold = threshold; self.embedding = embedding
        }

        public let model: String
        public let threshold: Double
        public let embedding: String
    }
    public struct App: Codable, Sendable, Equatable {
        package init(version: String, platform: String) {
            self.version = version; self.platform = platform
        }
        public let version: String
        public let platform: String
    }
    public let schema: String
    public let recordId: String
    public let provider: String
    public let type: String
    public let voiceId: String
    public let voiceName: String
    public var status: Status
    public let createdAt: String
    public var deletedAt: String?
    public let statement: Statement
    public let attestations: Attestations
    public let samples: [Sample]
    public let speaker: Speaker
    public let app: App
    public var region: ElevenLabsRegion?
    public var creator: Creator?
    public var recordedRegion: ElevenLabsRegion { creator?.region ?? region ?? .default }
    public var id: String { recordId }
    private enum CodingKeys: String, CodingKey { case schema, recordId, provider, type, voiceId, voiceName, status, createdAt, deletedAt, statement, attestations, samples, speaker, app, region, creator }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema); try values.encode(recordId, forKey: .recordId)
        try values.encode(provider, forKey: .provider); try values.encode(type, forKey: .type)
        try values.encode(voiceId, forKey: .voiceId); try values.encode(voiceName, forKey: .voiceName)
        try values.encode(status, forKey: .status); try values.encode(createdAt, forKey: .createdAt)
        try values.encode(deletedAt, forKey: .deletedAt); try values.encode(statement, forKey: .statement)
        try values.encode(attestations, forKey: .attestations); try values.encode(samples, forKey: .samples)
        try values.encode(speaker, forKey: .speaker); try values.encode(app, forKey: .app)
        try values.encodeIfPresent(region, forKey: .region); try values.encodeIfPresent(creator, forKey: .creator)
    }
    public static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    public func validate() throws {
        guard creator.map({ $0.keyFingerprint.count == 16 && $0.keyFingerprint.allSatisfy { "0123456789abcdef".contains($0) } }) ?? true,
              creator == nil || region == nil || creator?.region == region else { throw VoiceConsentError.invalidRecord }
        guard schema == "voxclip-consent/1", UUID(uuidString: recordId) != nil, provider == "elevenlabs", type == "ivc",
              !voiceId.isEmpty, voiceId.count <= 128, voiceId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              (1...70).contains(voiceName.unicodeScalars.count), ISO8601DateFormatter().date(from: createdAt) != nil,
              ISO8601DateFormatter().date(from: attestations.acceptedAt) != nil, attestations.complete,
              statement.audioFile == "statement.wav", ["en", "et"].contains(statement.language), !statement.text.isEmpty,
              statement.nonce.count == 4, Set(statement.nonce).count == 4, statement.stt.wer.isFinite, (0...0.15).contains(statement.stt.wer),
              Self.hashValid(statement.audioSha256), !speaker.model.isEmpty, speaker.threshold.isFinite, (0...1).contains(speaker.threshold),
              let embedding = Self.decodeEmbedding(speaker.embedding), !embedding.isEmpty,
              !samples.isEmpty, samples.count <= 24, samples.allSatisfy({ Self.hashValid($0.sha256) && $0.seconds.isFinite && (5...30).contains($0.seconds) && ["project", "readAloud"].contains($0.source) && $0.speakerScore.isFinite && $0.speakerScore >= speaker.threshold && $0.speakerScore <= 1.00001 }),
              app.platform == "macos", !app.version.isEmpty else { throw VoiceConsentError.invalidRecord }
        if status == .deleted { guard let deletedAt, ISO8601DateFormatter().date(from: deletedAt) != nil else { throw VoiceConsentError.invalidRecord } }
        else if deletedAt != nil { throw VoiceConsentError.invalidRecord }
    }
    static func hashValid(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) } }
    public static func encodeEmbedding(_ values: [Float]) -> String {
        var bytes = Data()
        for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) } }
        return bytes.base64EncodedString()
    }
    public static func decodeEmbedding(_ text: String) -> [Float]? {
        guard let data = Data(base64Encoded: text), !data.isEmpty, data.count <= 65_536, data.count.isMultiple(of: 4) else { return nil }
        let values = stride(from: 0, to: data.count, by: 4).map { offset -> Float in
            let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        return values.allSatisfy(\.isFinite) && abs(norm - 1) <= 0.01 ? values : nil
    }
}
