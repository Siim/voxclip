import Foundation

enum VoiceConsentCheckpoint: String, Sendable, CaseIterable {
    case deletionIntent, remoteDeleted, removeStatement, saveTombstone, clearDeletion
}

public struct VoiceDeletionIntent: Codable, Sendable {
    public let record: VoiceConsentRecord
    public let region: ElevenLabsRegion
    public let requestedAt: Date
    public var remoteDeleted: Bool
}

extension VoiceConsentStore {
    func hasDeletion(_ id: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id)/deletion.json").path) }
    func writeJournal<Value: Encodable>(_ value: Value, name: String, recordID: String) throws {
        let directory = try directory(recordID, create: true)
        let url = try file(name, in: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func readJournal<Value: Decodable>(_ type: Value.Type, name: String, recordID: String) throws -> Value {
        let url = try file(name, in: directory(recordID))
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1_024 else { throw VoiceConsentError.invalidRecord }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    func removeJournal(_ name: String, recordID: String) throws {
        let url = try file(name, in: directory(recordID))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
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
        try checkpoint(.clearDeletion)
        try removeJournal("deletion.json", recordID: record.id)
    }
}
