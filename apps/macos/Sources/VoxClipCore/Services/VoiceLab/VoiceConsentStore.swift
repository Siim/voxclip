import Foundation

public actor VoiceConsentStore {
    public nonisolated let root: URL
    private let temporaryRecordings: URL
    private var reconciledTemporaryRecordings = false
    /// IDs only; no statement, training audio, or undecodable journal contents enter diagnostics.
    var abandonedEnrollments: Set<String> = []
    public func takeAbandonedEnrollmentCount() -> Int {
        let count = abandonedEnrollments.count; abandonedEnrollments.removeAll(); return count
    }
    var claimedOperations: Set<UUID> = []
    private var liveEnrollments: Set<String> = []
    #if DEBUG
    package var fault: (@Sendable (VoiceConsentCheckpoint) throws -> Void)?
    package init(locations: DataLocations, fault: @escaping @Sendable (VoiceConsentCheckpoint) throws -> Void) {
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
    public func reconcileAbandonedEnrollments(now: Date = Date()) throws {
        try migrateLegacyOperations()
        let manager = FileManager.default
        if !reconciledTemporaryRecordings {
            if manager.fileExists(atPath: temporaryRecordings.path) { try manager.removeItem(at: temporaryRecordings) }
            reconciledTemporaryRecordings = true
        }
        guard manager.fileExists(atPath: root.path) else { return }
        for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let id = entry.lastPathComponent
            guard UUID(uuidString: id) != nil, !liveEnrollments.contains(id) else { continue }
            let directory = try directory(id)
            let recovery = try enrollmentRecovery(recordID: id, now: now)
            guard !(try hasOperation(id)) else { continue }
            if try auditTombstone(recordID: id) != nil { continue }
            if recovery != nil { continue }
            let recordFile = try file("record.json", in: directory)
            if manager.fileExists(atPath: recordFile.path) {
                let stored = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: recordFile))
                if stored.voiceId != "pending" {
                    let record = try load(id)
                    if record.status == .deleted { try discardStatement(recordID: id) }
                    continue
                }
            }
            try manager.removeItem(at: directory)
        }
    }
    public func abandonEnrollment(recordID: String) throws {
        if !(try hasOperation(recordID)), let record = try? load(recordID), record.voiceId != "pending" { return }
        try clearEnrollmentRecovery(recordID: recordID)
        try withdrawCreation(recordID: recordID)
        liveEnrollments.remove(recordID)
    }
    func directory(_ id: String, create: Bool = false) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw VoiceConsentError.invalidRecord }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let manager = FileManager.default
        for path in [root.deletingLastPathComponent(), root, directory] {
            if let attributes = try? manager.attributesOfItem(atPath: path.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw VoiceConsentError.invalidRecord }
        }
        if create {
            for location in [root.deletingLastPathComponent(), root, directory] where !manager.fileExists(atPath: location.path) {
                try manager.createDirectory(at: location, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try synchronizeDirectory(location.deletingLastPathComponent())
            }
        }
        return directory
    }
    func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType != .typeRegular { throw VoiceConsentError.invalidRecord }
        return url
    }
    public func saveStatement(_ wav: Data, recordID: String) throws {
        try saveReference(wav, recordID: recordID, name: "statement.wav")
    }
    public func saveReferenceAudio(_ wav: Data, recordID: String) throws {
        try saveReference(wav, recordID: recordID, name: "reference.wav")
    }
    private func saveReference(_ wav: Data, recordID: String, name: String) throws {
        let format = try VoiceConsentAudio.validateWAV(wav, maxBytes: 16 * 1_024 * 1_024)
        let seconds = Double(format.frames) / Double(format.rate)
        guard (5...30).contains(seconds) else { throw VoiceLabError.invalidAudio }
        let directory = try directory(recordID, create: true)
        let other = try file(name == "statement.wav" ? "reference.wav" : "statement.wav", in: directory)
        guard !FileManager.default.fileExists(atPath: other.path) else { throw VoiceConsentError.invalidRecord }
        let url = try file(name, in: directory)
        try writePrivate(wav, to: url)
        liveEnrollments.insert(recordID)
    }
    public func statement(recordID: String) throws -> Data {
        try readReference(recordID: recordID, name: "statement.wav")
    }
    public func referenceAudio(recordID: String) throws -> Data {
        let directory = try directory(recordID)
        let recordFile = try file("record.json", in: directory)
        if FileManager.default.fileExists(atPath: recordFile.path) {
            guard (try recordFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1_024 else { throw VoiceConsentError.invalidRecord }
            let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: recordFile))
            try record.validate()
            guard record.id == recordID else { throw VoiceConsentError.invalidRecord }
            return try referenceAudio(for: record)
        }
        let names = try ["statement.wav", "reference.wav"].filter { name in
            FileManager.default.fileExists(atPath: try file(name, in: directory).path)
        }
        guard names.count == 1 else { throw VoiceConsentError.invalidRecord }
        return try readReference(recordID: recordID, name: names[0])
    }
    private func referenceAudio(for record: VoiceConsentRecord) throws -> Data {
        let wav = try readReference(recordID: record.id, name: record.referenceAudioFile)
        guard VoiceLabFingerprint.bytes(wav) == record.referenceAudioSHA256 else { throw VoiceConsentError.invalidRecord }
        return wav
    }
    private func readReference(recordID: String, name: String) throws -> Data {
        guard ["statement.wav", "reference.wav"].contains(name) else { throw VoiceConsentError.invalidRecord }
        let directory = try directory(recordID)
        let url = try file(name, in: directory)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (44...(16 * 1_024 * 1_024)).contains(size) else { throw VoiceConsentError.invalidRecord }
        return try Data(contentsOf: url)
    }
    public func save(_ record: VoiceConsentRecord) throws {
        try record.validate()
        if record.status == .deleted { _ = dispatchGate.revoke(record.id) }
        if record.status != .deleted {
            _ = try referenceAudio(for: record)
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
        if try record.status != .deleted && !hasOperation(id) {
            _ = try referenceAudio(for: record)
        }
        return record
    }
    public func records() throws -> [VoiceConsentRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try directories.filter { UUID(uuidString: $0.lastPathComponent) != nil && FileManager.default.fileExists(atPath: $0.appendingPathComponent("record.json").path) }
            .map { try load($0.lastPathComponent) }.sorted { $0.createdAt > $1.createdAt }
    }
    public func activeVoices() throws -> [VoiceConsentRecord] { try records().filter { try $0.status == .active && !hasOperation($0.id) } }
    public func refreshVerification(_ voices: [VoiceLabVoice]) throws {
        for var record in try records() where record.status == .verificationRequired {
            if voices.contains(where: { $0.id == record.voiceId && $0.isOwner && $0.category == "cloned" && $0.isVerified }) {
                record.status = .active
                try save(record)
            }
        }
    }
    #if DEBUG
    @_spi(Testing) public func markDeleted(_ id: String, at date: Date) throws {
        var record = try load(id)
        try discardStatement(recordID: id)
        record.status = .deleted; record.deletedAt = VoiceConsentRecord.timestamp(date)
        try save(record)
    }
    #endif
    public func discardStatement(recordID: String) throws {
        let directory = try directory(recordID)
        try checkpoint(.removeStatement)
        for name in ["statement.wav", "reference.wav"] {
            let url = try file(name, in: directory)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                try synchronizeDirectory(directory)
            }
        }
    }
}
