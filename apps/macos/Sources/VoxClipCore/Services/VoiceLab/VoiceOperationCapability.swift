import Foundation

actor VoiceOperationCapability: Equatable {
    private let quote: VoiceLabQuote
    private let validate: @Sendable () async throws -> Void
    private var consumed = false
    init(quote: VoiceLabQuote, validate: @escaping @Sendable () async throws -> Void) {
        self.quote = quote; self.validate = validate
    }
    nonisolated static func == (left: VoiceOperationCapability, right: VoiceOperationCapability) -> Bool { left === right }
    func consume(_ supplied: VoiceLabQuote) async throws {
        guard !consumed, supplied == quote else { throw VoiceLabError.consentRequired }
        consumed = true
        try await validate()
    }
}

extension VoiceConsentStore {
    func validateUse(_ snapshot: VoiceConsentRecord) throws {
        guard snapshot.status == .active, !hasDeletion(snapshot.id), !hasCreation(snapshot.id), try load(snapshot.id) == snapshot else { throw VoiceConsentError.inactive }
    }
    func validateCreation(recordID: String, requestID: UUID, statementHash: String) throws {
        let intent = try readJournal(VoiceCreationIntent.self, name: "creation.json", recordID: recordID)
        guard intent.requestID == requestID, intent.record.statement.audioSha256 == statementHash,
              !hasDeletion(recordID), !FileManager.default.fileExists(atPath: root.appendingPathComponent("\(recordID)/record.json").path),
              VoiceLabFingerprint.bytes(try statement(recordID: recordID)) == statementHash else { throw VoiceConsentError.invalidRecord }
    }
}
