import Foundation

public struct VoiceConsentAudit: Codable, Sendable, Equatable {
    public let recordID: String
    public let statementSha256: String?
    public let referenceAudioSha256: String?
    private let method: VoiceConsentRecord.ConsentMethod?
    public var consentMethod: VoiceConsentRecord.ConsentMethod { method ?? .recordedStatement }
    public let recordingSha256s: [String]
    public let createdAt: String
    public let acceptedAt: String
    public let language: String
    public package(set) var remoteVoiceID: String?
    public package(set) var deletedAt: String?
    public package(set) var remoteStateUnknown: Bool?
    private enum CodingKeys: String, CodingKey {
        case recordID, statementSha256, referenceAudioSha256, method = "consentMethod", recordingSha256s
        case createdAt, acceptedAt, language, remoteVoiceID, deletedAt, remoteStateUnknown
    }

    init(record: VoiceConsentRecord) throws {
        try record.validate()
        recordID = record.id; statementSha256 = record.statement?.audioSha256
        method = record.consentMethod == .projectAttestation ? .projectAttestation : nil
        referenceAudioSha256 = record.consentMethod == .projectAttestation ? record.referenceAudioSHA256 : nil
        recordingSha256s = record.samples.map(\.sha256)
        createdAt = record.createdAt; acceptedAt = record.attestations.acceptedAt; language = record.language
        remoteVoiceID = record.voiceId == "pending" ? nil : record.voiceId
        deletedAt = record.deletedAt
    }
    func validate(recordID: String) throws {
        let formatter = ISO8601DateFormatter()
        switch consentMethod {
        case .recordedStatement:
            guard let statementSha256, VoiceConsentRecord.hashValid(statementSha256), referenceAudioSha256 == nil else { throw VoiceConsentError.invalidRecord }
        case .projectAttestation:
            guard statementSha256 == nil, let referenceAudioSha256, VoiceConsentRecord.hashValid(referenceAudioSha256),
                  recordingSha256s.first == referenceAudioSha256 else { throw VoiceConsentError.invalidRecord }
        }
        guard self.recordID == recordID, UUID(uuidString: recordID) != nil,
              !recordingSha256s.isEmpty, recordingSha256s.count <= 24,
              recordingSha256s.allSatisfy(VoiceConsentRecord.hashValid), ["en", "et"].contains(language),
              formatter.date(from: createdAt) != nil, formatter.date(from: acceptedAt) != nil,
              deletedAt.map({ formatter.date(from: $0) != nil }) ?? true,
              remoteVoiceID.map({ $0.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }) ?? true else { throw VoiceConsentError.invalidRecord }
    }
}
