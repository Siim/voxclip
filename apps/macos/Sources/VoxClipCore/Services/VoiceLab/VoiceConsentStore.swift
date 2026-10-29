import Foundation

public actor VoiceConsentStore {
    public nonisolated let root: URL
    public init(locations: DataLocations) { root = locations.root.appendingPathComponent("VoiceLab/consent", isDirectory: true) }
    private func directory(_ id: String, create: Bool = false) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw VoiceConsentError.invalidRecord }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let manager = FileManager.default
        for path in [root.deletingLastPathComponent(), root, directory] {
            if let attributes = try? manager.attributesOfItem(atPath: path.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw VoiceConsentError.invalidRecord }
        }
        if create { try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        return directory
    }
    private func file(_ name: String, in directory: URL) throws -> URL {
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
        try wav.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load(_ id: String) throws -> VoiceConsentRecord {
        let directory = try directory(id)
        let url = try file("record.json", in: directory)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1_024 else { throw VoiceConsentError.invalidRecord }
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: url))
        try record.validate()
        guard record.id == id else { throw VoiceConsentError.invalidRecord }
        if record.status != .deleted {
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
    public func activeVoices() throws -> [VoiceConsentRecord] { try records().filter { $0.status == .active } }
    public func refreshVerification(_ voices: [VoiceLabVoice]) throws {
        for var record in try records() where record.status == .verificationRequired {
            if voices.contains(where: { $0.id == record.voiceId && $0.isOwner && $0.category == "cloned" && $0.isVerified }) {
                record.status = .active
                try save(record)
            }
        }
    }
    public func markDeleted(_ id: String, at date: Date) throws {
        var record = try load(id)
        record.status = .deleted; record.deletedAt = VoiceConsentRecord.timestamp(date)
        try save(record)
        try discardStatement(recordID: id)
    }
    public func discardStatement(recordID: String) throws {
        let directory = try directory(recordID)
        let url = try file("statement.wav", in: directory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public struct VoiceSpeakerCheck: Sendable {
    public let embedder: (any SpeakerEmbedder)?
    public let threshold: Double?
    public init(embedder: (any SpeakerEmbedder)? = nil, calibratedThreshold: Double? = nil) {
        self.embedder = embedder; self.threshold = calibratedThreshold
    }
    public var available: Bool { embedder != nil && threshold.map { $0.isFinite && (0...1).contains($0) } == true }
    public func embedding(_ pcm16k: [Float]) async throws -> [Float] {
        guard available, let embedder else { throw VoiceConsentError.speakerUnavailable }
        guard pcm16k.count >= 48_000, pcm16k.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
        var voiced: [Float] = []
        let frame = 160
        let gate = pow(10.0, -45.0 / 20.0)
        for start in stride(from: 0, through: pcm16k.count - frame, by: frame) {
            let samples = pcm16k[start..<(start + frame)]
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame))
            if rms > gate { voiced.append(contentsOf: samples) }
        }
        guard voiced.count >= 48_000, (1...16_384).contains(embedder.dimension) else { throw VoiceConsentError.speakerMismatch }
        var mean = [Float](repeating: 0, count: embedder.dimension)
        for start in stride(from: 0, through: voiced.count - 48_000, by: 24_000) {
            try Task.checkCancellation()
            let result = try await embedder.embed(Array(voiced[start..<(start + 48_000)]))
            guard result.count == mean.count, result.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
            for index in mean.indices { mean[index] += result[index] }
        }
        let norm = sqrt(mean.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm > 0, norm.isFinite else { throw VoiceConsentError.speakerMismatch }
        return mean.map { Float(Double($0) / norm) }
    }
    public static func cosine(_ left: [Float], _ right: [Float]) throws -> Double {
        guard left.count == right.count, !left.isEmpty else { throw VoiceConsentError.speakerMismatch }
        return zip(left, right).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    }
}

public actor VoiceUseGuard {
    private let store: VoiceConsentStore
    private let check: VoiceSpeakerCheck
    private var cache: Set<String> = []
    public init(store: VoiceConsentStore, check: VoiceSpeakerCheck = VoiceSpeakerCheck()) { self.store = store; self.check = check }
    public func authorize(contentKey: String, recordID: String, speech16k: [Float], voiceChanger: Bool = false, approved: Bool) async throws -> OwnVoicePolicy {
        guard approved else { throw VoiceLabError.consentRequired }
        guard !contentKey.isEmpty else { throw VoiceLabError.invalidInput }
        let record = try await store.load(recordID)
        guard record.status == .active else { throw VoiceConsentError.inactive }
        guard check.available, check.embedder?.modelID == record.speaker.model, check.threshold == record.speaker.threshold,
              let owner = VoiceConsentRecord.decodeEmbedding(record.speaker.embedding) else { throw VoiceConsentError.speakerUnavailable }
        let key = VoiceLabFingerprint.fields([contentKey, recordID, record.speaker.embedding, record.statement.audioSha256])
        if !cache.contains(key) {
            let maximum = voiceChanger ? 480_000 : 160_000
            let candidate = try await check.embedding(Array(speech16k.prefix(maximum)))
            guard try VoiceSpeakerCheck.cosine(owner, candidate) >= record.speaker.threshold else {
                throw VoiceConsentError.voiceOwnerMismatch
            }
            guard try await store.load(recordID).status == .active else { throw VoiceConsentError.inactive }
            if cache.count >= 256 { cache.removeAll() }
            cache.insert(key)
        }
        return OwnVoicePolicy(recordID: recordID, cloneVoiceID: record.voiceId, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
    }
}
