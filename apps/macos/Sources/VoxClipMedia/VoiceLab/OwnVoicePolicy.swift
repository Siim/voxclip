import Foundation
import VoxClipCore

extension VoiceLabFingerprint {
    static func policy(_ value: OwnVoicePolicy) -> [String] {
        [value.recordID, value.cloneVoiceID ?? "", String(value.recordActive), String(value.providerConsentGranted),
         String(value.statementVerified), String(value.speakerMatched)]
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
    public let speakerMatched: Bool
    public init(recordID: String, cloneVoiceID: String? = nil, recordActive: Bool,
                providerConsentGranted: Bool, statementVerified: Bool, speakerMatched: Bool) {
        self.recordID = recordID; self.cloneVoiceID = cloneVoiceID; self.recordActive = recordActive; self.providerConsentGranted = providerConsentGranted
        self.statementVerified = statementVerified; self.speakerMatched = speakerMatched
        capability = nil
    }
    private init(recordID: String, cloneVoiceID: String?, capability: VoiceOperationCapability) {
        self.recordID = recordID; self.cloneVoiceID = cloneVoiceID; self.capability = capability
        recordActive = true; providerConsentGranted = true; statementVerified = true; speakerMatched = true
    }
    func authorized(for quote: VoiceLabQuote, reserve: (@Sendable () async throws -> VoiceDispatchPermit)? = nil,
                    validate: @escaping @Sendable () async throws -> Void) -> Self {
        Self(recordID: recordID, cloneVoiceID: cloneVoiceID, capability: VoiceOperationCapability(quote: quote, reserve: reserve, validate: validate))
    }
    public func validate() throws {
        guard !recordID.isEmpty, recordActive, providerConsentGranted, statementVerified else { throw VoiceLabError.consentRequired }
        guard speakerMatched else { throw VoiceLabError.speakerMismatch }
    }
}

public enum VoiceLabVoiceChoice: Sendable, Equatable {
    case own(voiceID: String, policy: OwnVoicePolicy)
    case stock(voiceID: String)
    public var id: String { switch self { case .own(let id, _), .stock(let id): id } }
    public func validate() throws { if case .own(_, let policy) = self { try policy.validate() } }
}
