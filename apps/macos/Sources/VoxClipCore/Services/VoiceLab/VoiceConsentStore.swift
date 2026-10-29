import Foundation

public actor VoiceConsentStore {
    public nonisolated let root: URL
    private let temporaryRecordings: URL
    private var liveEnrollments: Set<String> = []
    #if DEBUG
    var fault: (@Sendable (VoiceConsentCheckpoint) throws -> Void)?
    init(locations: DataLocations, fault: @escaping @Sendable (VoiceConsentCheckpoint) throws -> Void) {
        root = locations.root.appendingPathComponent("VoiceLab/consent", isDirectory: true)
        temporaryRecordings = locations.cache.appendingPathComponent("voice-consent", isDirectory: true)
        self.fault = fault
    }
    #endif
    func checkpoint(_ step: VoiceConsentCheckpoint) throws {
        #if DEBUG
        try fault?(step)
        #endif
    }
    public init(locations: DataLocations) {
        root = locations.root.appendingPathComponent("VoiceLab/consent", isDirectory: true)
        temporaryRecordings = locations.cache.appendingPathComponent("voice-consent", isDirectory: true)
    }
    public func reconcileAbandonedEnrollments() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: temporaryRecordings.path) { try manager.removeItem(at: temporaryRecordings) }
        guard manager.fileExists(atPath: root.path) else { return }
        for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let id = entry.lastPathComponent
            guard UUID(uuidString: id) != nil, !liveEnrollments.contains(id) else { continue }
            let directory = try directory(id)
            guard !manager.fileExists(atPath: directory.appendingPathComponent("record.json").path),
                  !manager.fileExists(atPath: directory.appendingPathComponent("creation.json").path) else { continue }
            try manager.removeItem(at: directory)
        }
    }
    public func abandonEnrollment(recordID: String) throws {
        let directory = try directory(recordID)
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("record.json").path) else { return }
        if hasCreation(recordID) {
            var intent = try readJournal(VoiceCreationIntent.self, name: "creation.json", recordID: recordID)
            intent.cancelled = true
            try writeJournal(intent, name: "creation.json", recordID: recordID)
        }
        try discardStatement(recordID: recordID)
        liveEnrollments.remove(recordID)
    }
    func directory(_ id: String, create: Bool = false) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw VoiceConsentError.invalidRecord }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let manager = FileManager.default
        for path in [root.deletingLastPathComponent(), root, directory] {
            if let attributes = try? manager.attributesOfItem(atPath: path.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw VoiceConsentError.invalidRecord }
        }
        if create { try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        return directory
    }
    func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType != .typeRegular { throw VoiceConsentError.invalidRecord }
        return url
    }
    public func saveStatement(_ wav: Data, recordID: String) throws {
        let format = try ElevenLabsVoiceLab.validateWAV(wav, maxBytes: 16 * 1_024 * 1_024)
        let seconds = Double(format.frames) / Double(format.rate)
        guard (5...30).contains(seconds) else { throw VoiceLabError.invalidAudio }
        let directory = try directory(recordID, create: true)
        let url = try file("statement.wav", in: directory)
        try writePrivate(wav, to: url)
        liveEnrollments.insert(recordID)
    }
    public func statement(recordID: String) throws -> Data {
        let directory = try directory(recordID)
        let url = try file("statement.wav", in: directory)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (44...(16 * 1_024 * 1_024)).contains(size) else { throw VoiceConsentError.invalidRecord }
        return try Data(contentsOf: url)
    }
    public func save(_ record: VoiceConsentRecord) throws {
        try record.validate()
        if record.status != .deleted {
            guard VoiceLabFingerprint.bytes(try statement(recordID: record.id)) == record.statement.audioSha256 else { throw VoiceConsentError.invalidRecord }
        }
        let directory = try directory(record.id, create: true)
        let url = try file("record.json", in: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(record), to: url)
    }
    public func load(_ id: String) throws -> VoiceConsentRecord {
        let directory = try directory(id)
        let url = try file("record.json", in: directory)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1_024 else { throw VoiceConsentError.invalidRecord }
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: url))
        try record.validate()
        guard record.id == id else { throw VoiceConsentError.invalidRecord }
        if record.status != .deleted && !hasDeletion(id) {
            guard VoiceLabFingerprint.bytes(try statement(recordID: id)) == record.statement.audioSha256 else { throw VoiceConsentError.invalidRecord }
        }
        return record
    }
    public func records() throws -> [VoiceConsentRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try directories.filter { UUID(uuidString: $0.lastPathComponent) != nil && FileManager.default.fileExists(atPath: $0.appendingPathComponent("record.json").path) }
            .map { try load($0.lastPathComponent) }.sorted { $0.createdAt > $1.createdAt }
    }
    public func activeVoices() throws -> [VoiceConsentRecord] { try records().filter { $0.status == .active && !hasDeletion($0.id) } }
    public func refreshVerification(_ voices: [VoiceLabVoice]) throws {
        for var record in try records() where record.status == .verificationRequired {
            if voices.contains(where: { $0.id == record.voiceId && $0.isOwner && $0.category == "cloned" && $0.isVerified }) {
                record.status = .active
                try save(record)
            }
        }
    }
    public func markDeleted(_ id: String, at date: Date) throws {
        let intent = try beginDeletion(id, region: .default, at: date)
        try finishDeletion(recordRemoteDeletion(intent))
    }
    public func discardStatement(recordID: String) throws {
        let directory = try directory(recordID)
        let url = try file("statement.wav", in: directory)
        try checkpoint(.removeStatement)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try synchronizeDirectory(directory)
        }
    }
}

public struct VoiceSpeakerCheck: Sendable {
    public let embedder: (any SpeakerEmbedder)?
    public let threshold: Double?
    public init() { embedder = nil; threshold = nil }
    package init(verifiedEmbedder: any SpeakerEmbedder, calibratedThreshold: Double) {
        embedder = verifiedEmbedder; threshold = calibratedThreshold
    }
    #if DEBUG
    init(embedder: (any SpeakerEmbedder)?, calibratedThreshold: Double? = nil) {
        self.embedder = embedder; self.threshold = calibratedThreshold
    }
    #endif
    public var available: Bool { embedder != nil && threshold.map { $0.isFinite && (0...1).contains($0) } == true }
    public func embedding(_ pcm16k: [Float]) async throws -> [Float] {
        guard available, let embedder else { throw VoiceConsentError.speakerUnavailable }
        try await embedder.validateAvailability()
        guard pcm16k.count >= 48_000, pcm16k.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
        let voiced = try await embedder.voicedSamples(pcm16k)
        guard voiced.count >= 48_000, (1...16_384).contains(embedder.dimension) else { throw VoiceConsentError.speakerMismatch }
        var mean = [Float](repeating: 0, count: embedder.dimension)
        for window in try SpeakerAudio.windows(voiced) {
            try Task.checkCancellation()
            let result = try await embedder.embed(window)
            guard result.count == mean.count, result.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
            for index in mean.indices { mean[index] += result[index] }
        }
        return try SpeakerAudio.normalized(mean)
    }
    public static func cosine(_ left: [Float], _ right: [Float]) throws -> Double {
        guard left.count == right.count, !left.isEmpty else { throw VoiceConsentError.speakerMismatch }
        let unitLeft = try SpeakerAudio.normalized(left)
        let unitRight = try SpeakerAudio.normalized(right)
        let score = zip(unitLeft, unitRight).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return min(1, max(-1, score))
    }
}

public actor VoiceUseGuard {
    private let store: VoiceConsentStore
    private let check: VoiceSpeakerCheck
    private var cache: Set<String> = []
    package init(store: VoiceConsentStore, check: VoiceSpeakerCheck = VoiceSpeakerCheck()) { self.store = store; self.check = check }
    func authorize(contentKey: String, recordID: String, speech16k: [Float], voiceChanger: Bool = false, approved: Bool) async throws -> OwnVoicePolicy {
        guard approved else { throw VoiceLabError.consentRequired }
        guard !contentKey.isEmpty else { throw VoiceLabError.invalidInput }
        let record = try await store.load(recordID)
        try await store.validateUse(record)
        guard check.available, check.embedder?.modelID == record.speaker.model, check.threshold == record.speaker.threshold,
              let owner = VoiceConsentRecord.decodeEmbedding(record.speaker.embedding) else { throw VoiceConsentError.speakerUnavailable }
        let audioHash = speech16k.withUnsafeBytes { VoiceLabFingerprint.bytes(Data($0)) }
        let key = VoiceLabFingerprint.fields([contentKey, audioHash, String(voiceChanger), recordID, record.speaker.embedding, record.statement.audioSha256])
        try await check.embedder?.validateAvailability()
        if !cache.contains(key) {
            let maximum = voiceChanger ? 480_000 : 160_000
            let candidate = try await check.embedding(Array(speech16k.prefix(maximum)))
            guard try VoiceSpeakerCheck.cosine(owner, candidate) >= record.speaker.threshold else {
                throw VoiceConsentError.voiceOwnerMismatch
            }
            try await store.validateUse(record)
            if cache.count >= 256 { cache.removeAll() }
            cache.insert(key)
        }
        return OwnVoicePolicy(recordID: recordID, cloneVoiceID: record.voiceId, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
    }
    public func authorize(quote: VoiceLabQuote, contentKey: String, recordID: String, speech16k: [Float], approved: Bool) async throws -> OwnVoicePolicy {
        guard quote.operation == .textToSpeech else { throw VoiceLabError.consentRequired }
        return try await authorizeBoundQuote(quote, contentKey: contentKey, recordID: recordID, speech16k: speech16k, approved: approved)
    }
    public func authorizeConversion(quote: VoiceLabQuote, contentKey: String, recordID: String, audio: Data, approved: Bool) async throws -> OwnVoicePolicy {
        guard quote.operation == .voiceChange, quote.guardAudioHash == VoiceLabFingerprint.bytes(audio) else { throw VoiceLabError.consentRequired }
        return try await authorizeBoundQuote(quote, contentKey: contentKey, recordID: recordID, speech16k: VoiceConsentAudio.pcm16k(audio), approved: approved)
    }
    private func authorizeBoundQuote(_ quote: VoiceLabQuote, contentKey: String, recordID: String, speech16k: [Float], approved: Bool) async throws -> OwnVoicePolicy {
        let record = try await store.load(recordID)
        guard quote.operation == .textToSpeech || quote.operation == .voiceChange else { throw VoiceLabError.consentRequired }
        let expected = quote.operation == .textToSpeech ? "v1/text-to-speech/\(record.voiceId)/with-timestamps" : "v1/voice-changer/\(record.voiceId)"
        guard quote.endpoint == expected else { throw VoiceLabError.consentRequired }
        let policy = try await authorize(contentKey: contentKey, recordID: recordID, speech16k: speech16k, voiceChanger: quote.operation == .voiceChange, approved: approved)
        let store = store; let embedder = check.embedder
        return policy.authorized(for: quote) {
            try await embedder?.validateAvailability()
            try await store.validateUse(record)
        }
    }
}
