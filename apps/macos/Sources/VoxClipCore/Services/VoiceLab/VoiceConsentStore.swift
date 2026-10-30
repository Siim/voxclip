import Foundation

public actor VoiceConsentStore {
    public nonisolated let root: URL
    private let temporaryRecordings: URL
    private var reconciledTemporaryRecordings = false
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
    public func reconcileAbandonedEnrollments() throws {
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
            guard !(try hasOperation(id)) else { continue }
            if try auditTombstone(recordID: id) != nil { continue }
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
        let format = try VoiceConsentAudio.validateWAV(wav, maxBytes: 16 * 1_024 * 1_024)
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
        if try record.status != .deleted && !hasOperation(id) {
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
        let url = try file("statement.wav", in: directory)
        try checkpoint(.removeStatement)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try synchronizeDirectory(directory)
        }
    }
}
