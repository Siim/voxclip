import Foundation
import VoxClipCore

extension VoiceLabFingerprint {
    static func policy(_ value: OwnVoicePolicy) -> [String] {
        let legacy = [value.recordID, value.cloneVoiceID ?? "", String(value.recordActive), String(value.providerConsentGranted),
                      String(value.statementVerified), String(value.speakerMatched)]
        return value.consentMethod == .recordedStatement ? legacy : legacy + [value.consentMethod.rawValue]
    }
}

public struct OwnVoicePolicy: Sendable, Equatable {
    let capability: VoiceOperationCapability?
    public let recordID: String
    /// Nil only while creating a new clone. At use or deletion it must match the selected clone.
    public let cloneVoiceID: String?
    /// Supplied by the consent store; a deleted or suspended record cannot authorize generation.
    public let recordActive: Bool
    public let providerConsentGranted: Bool
    public let statementVerified: Bool
    public let consentMethod: VoiceConsentRecord.ConsentMethod
    public let speakerMatched: Bool
    public init(recordID: String, cloneVoiceID: String? = nil, recordActive: Bool,
                providerConsentGranted: Bool, statementVerified: Bool, speakerMatched: Bool,
                consentMethod: VoiceConsentRecord.ConsentMethod = .recordedStatement) {
        self.recordID = recordID; self.cloneVoiceID = cloneVoiceID; self.recordActive = recordActive; self.providerConsentGranted = providerConsentGranted
        self.statementVerified = statementVerified; self.speakerMatched = speakerMatched
        self.consentMethod = consentMethod
        capability = nil
    }
    private init(recordID: String, cloneVoiceID: String?, consentMethod: VoiceConsentRecord.ConsentMethod, capability: VoiceOperationCapability) {
        self.recordID = recordID; self.cloneVoiceID = cloneVoiceID; self.capability = capability
        self.consentMethod = consentMethod
        recordActive = true; providerConsentGranted = true; statementVerified = consentMethod == .recordedStatement; speakerMatched = true
    }
    func authorized(for quote: VoiceLabQuote, proof: VoiceSpeakerMatch) throws -> Self {
        try validate()
        guard proof.recordID == recordID, proof.cloneVoiceID == cloneVoiceID, proof.consentMethod == consentMethod else { throw VoiceLabError.consentRequired }
        return try Self(recordID: recordID, cloneVoiceID: cloneVoiceID, consentMethod: consentMethod, capability: proof.capability(for: quote))
    }
    public func validate() throws {
        guard !recordID.isEmpty, recordActive, providerConsentGranted,
              statementVerified == (consentMethod == .recordedStatement) else { throw VoiceLabError.consentRequired }
        guard speakerMatched else { throw VoiceLabError.speakerMismatch }
    }
}

public enum VoiceLabVoiceChoice: Sendable, Equatable {
    case own(voiceID: String, policy: OwnVoicePolicy)
    case stock(voiceID: String)
    public var id: String { switch self { case .own(let id, _), .stock(let id): id } }
    public func validate() throws { if case .own(_, let policy) = self { try policy.validate() } }
}
