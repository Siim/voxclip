import Darwin
import Foundation

enum VoiceConsentCheckpoint: String, Sendable, CaseIterable {
    case deletionIntent, remoteDeleted, removeStatement, saveTombstone, clearDeletion
    case creationIntent, creationResult, saveCreation, clearCreation
}

public struct VoiceCreationIntent: Codable, Sendable {
    public let requestID: UUID
    public let region: ElevenLabsRegion
    public let startedAt: Date
    public var record: VoiceConsentRecord
    public var cancelled: Bool? = nil
}

extension VoiceConsentRecord {
    func assigningVoice(_ voiceID: String, requiresVerification: Bool) -> Self {
        Self(schema: schema, recordId: recordId, provider: provider, type: type, voiceId: voiceID, voiceName: voiceName,
             status: requiresVerification ? .verificationRequired : .active, createdAt: createdAt, deletedAt: nil,
             statement: statement, attestations: attestations, samples: samples, speaker: speaker, app: app)
    }
}

public struct VoiceDeletionIntent: Codable, Sendable {
    public let record: VoiceConsentRecord
    public let region: ElevenLabsRegion
    public let requestedAt: Date
    public var remoteDeleted: Bool
}

extension VoiceConsentStore {
    func hasCreation(_ id: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id)/creation.json").path) }
    func beginCreation(_ intent: VoiceCreationIntent) throws {
        try intent.record.validate()
        guard !hasCreation(intent.record.id), !FileManager.default.fileExists(atPath: root.appendingPathComponent("\(intent.record.id)/record.json").path),
              VoiceLabFingerprint.bytes(try statement(recordID: intent.record.id)) == intent.record.statement.audioSha256 else { throw VoiceConsentError.creationPending }
        try checkpoint(.creationIntent)
        try writeJournal(intent, name: "creation.json", recordID: intent.record.id)
    }
    public func pendingCreations() throws -> [VoiceCreationIntent] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var result: [VoiceCreationIntent] = []
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: entry.lastPathComponent) != nil {
            let id = entry.lastPathComponent
            guard hasCreation(id) else { continue }
            let intent = try readJournal(VoiceCreationIntent.self, name: "creation.json", recordID: id)
            try intent.record.validate()
            guard intent.record.id == id else { throw VoiceConsentError.invalidRecord }
            result.append(intent)
        }
        return result
    }
    func recordCreationResult(_ record: VoiceConsentRecord) throws {
        var intent = try readJournal(VoiceCreationIntent.self, name: "creation.json", recordID: record.id)
        guard intent.record.statement == record.statement, intent.record.samples == record.samples, intent.record.speaker == record.speaker else { throw VoiceConsentError.invalidRecord }
        intent.record = record
        try checkpoint(.creationResult)
        try writeJournal(intent, name: "creation.json", recordID: record.id)
    }
    public func completeCreation(_ record: VoiceConsentRecord) throws {
        guard !hasDeletion(record.id) else { throw VoiceConsentError.inactive }
        if hasCreation(record.id) {
            let intent = try readJournal(VoiceCreationIntent.self, name: "creation.json", recordID: record.id)
            guard intent.cancelled != true else { throw VoiceConsentError.inactive }
        } else {
            guard try load(record.id) == record else { throw VoiceConsentError.invalidRecord }
            return
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("\(record.id)/record.json").path) {
            let existing = try load(record.id)
            guard existing.status != .deleted, existing.voiceId == record.voiceId,
                  existing.assigningVoice(record.voiceId, requiresVerification: record.status == .verificationRequired) == record else { throw VoiceConsentError.inactive }
        }
        try checkpoint(.saveCreation)
        try save(record)
        try checkpoint(.clearCreation)
        try removeJournal("creation.json", recordID: record.id)
    }
    func deleteRecoveredCreation(_ record: VoiceConsentRecord, region: ElevenLabsRegion) throws -> VoiceDeletionIntent {
        let intent = VoiceDeletionIntent(record: record, region: region, requestedAt: Date(), remoteDeleted: false)
        try writeJournal(intent, name: "deletion.json", recordID: record.id)
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("\(record.id)/record.json").path) {
            try writeJournal(record, name: "record.json", recordID: record.id)
        }
        return intent
    }
    func hasDeletion(_ id: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id)/deletion.json").path) }
    func writeJournal<Value: Encodable>(_ value: Value, name: String, recordID: String) throws {
        let directory = try directory(recordID, create: true)
        let url = try file(name, in: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(value), to: url)
    }
    func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }
    func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    func readJournal<Value: Decodable>(_ type: Value.Type, name: String, recordID: String) throws -> Value {
        let url = try file(name, in: directory(recordID))
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1_024 else { throw VoiceConsentError.invalidRecord }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    func removeJournal(_ name: String, recordID: String) throws {
        let url = try file(name, in: directory(recordID))
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }
    public func beginDeletion(_ id: String, region: ElevenLabsRegion, at date: Date) throws -> VoiceDeletionIntent {
        if hasDeletion(id) { return try readJournal(VoiceDeletionIntent.self, name: "deletion.json", recordID: id) }
        let record = try load(id)
        let intent = VoiceDeletionIntent(record: record, region: region, requestedAt: date, remoteDeleted: record.status == .deleted)
        try checkpoint(.deletionIntent)
        try writeJournal(intent, name: "deletion.json", recordID: id)
        return intent
    }
    public func pendingDeletions() throws -> [VoiceDeletionIntent] {
        var result: [VoiceDeletionIntent] = []
        for record in try records() {
            if record.status == .deleted && FileManager.default.fileExists(atPath: root.appendingPathComponent("\(record.id)/statement.wav").path) && !hasDeletion(record.id) {
                _ = try beginDeletion(record.id, region: .default, at: Date())
            }
            if hasDeletion(record.id) {
                let intent = try readJournal(VoiceDeletionIntent.self, name: "deletion.json", recordID: record.id)
                try intent.record.validate()
                guard intent.record.id == record.id, intent.record.voiceId == record.voiceId else { throw VoiceConsentError.invalidRecord }
                result.append(intent)
            }
        }
        return result
    }
    func recordRemoteDeletion(_ intent: VoiceDeletionIntent) throws -> VoiceDeletionIntent {
        var completed = intent; completed.remoteDeleted = true
        try checkpoint(.remoteDeleted)
        try writeJournal(completed, name: "deletion.json", recordID: intent.record.id)
        return completed
    }
    func finishDeletion(_ intent: VoiceDeletionIntent) throws {
        guard intent.remoteDeleted else { throw VoiceConsentError.invalidRecord }
        try discardStatement(recordID: intent.record.id)
        var record = intent.record
        record.status = .deleted; record.deletedAt = VoiceConsentRecord.timestamp(intent.requestedAt)
        try checkpoint(.saveTombstone)
        try save(record)
        try removeJournal("creation.json", recordID: record.id)
        try checkpoint(.clearDeletion)
        try removeJournal("deletion.json", recordID: record.id)
    }
}
