import Foundation

public struct VoiceConsentAudit: Codable, Sendable, Equatable {
    public let recordID: String
    public let statementSha256: String
    public let recordingSha256s: [String]
    public let createdAt: String
    public let acceptedAt: String
    public let language: String
    public package(set) var remoteVoiceID: String?
    public package(set) var deletedAt: String?

    init(record: VoiceConsentRecord) throws {
        try record.validate()
        recordID = record.id; statementSha256 = record.statement.audioSha256
        recordingSha256s = record.samples.map(\.sha256)
        createdAt = record.createdAt; acceptedAt = record.attestations.acceptedAt; language = record.statement.language
        remoteVoiceID = record.voiceId == "pending" ? nil : record.voiceId
        deletedAt = record.deletedAt
    }
    func validate(recordID: String) throws {
        let formatter = ISO8601DateFormatter()
        guard self.recordID == recordID, UUID(uuidString: recordID) != nil,
              VoiceConsentRecord.hashValid(statementSha256), !recordingSha256s.isEmpty, recordingSha256s.count <= 24,
              recordingSha256s.allSatisfy(VoiceConsentRecord.hashValid), ["en", "et"].contains(language),
              formatter.date(from: createdAt) != nil, formatter.date(from: acceptedAt) != nil,
              deletedAt.map({ formatter.date(from: $0) != nil }) ?? true,
              remoteVoiceID.map({ $0.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }) ?? true else { throw VoiceConsentError.invalidRecord }
    }
}
