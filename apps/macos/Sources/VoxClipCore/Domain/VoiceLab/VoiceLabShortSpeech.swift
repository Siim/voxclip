import Foundation

/// Evidence for ADR-R37. An unavailable measurement never carries an invented score.
public struct VoiceLabShortSpeechEvidence: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case pooled, unmeasured }
    public let mode: Mode
    public let recordID: String
    public let consentMethod: VoiceConsentRecord.ConsentMethod
    public let voicedFrames: Int
    public let takeCount: Int

    package init(mode: Mode, recordID: String, consentMethod: VoiceConsentRecord.ConsentMethod,
                 voicedFrames: Int, takeCount: Int) {
        self.mode = mode; self.recordID = recordID; self.consentMethod = consentMethod
        self.voicedFrames = voicedFrames; self.takeCount = takeCount
    }
    public var valid: Bool {
        guard !recordID.isEmpty, voicedFrames >= 0, takeCount > 0 else { return false }
        switch mode {
        case .pooled: return voicedFrames >= SpeakerAudio.windowSize && takeCount >= 2
        case .unmeasured: return voicedFrames < SpeakerAudio.windowSize && ownClone
        }
    }
    public var ownClone: Bool {
        consentMethod == .recordedStatement || consentMethod == .projectAttestation
    }
}

public enum VoiceLabTakeVoiceCheck: Sendable, Equatable {
    case perTake
    case waiting
    case shortSpeech(VoiceLabShortSpeechEvidence)

    public var evidence: VoiceLabShortSpeechEvidence? {
        if case .shortSpeech(let evidence) = self { return evidence }
        return nil
    }
    public var complete: Bool {
        switch self {
        case .perTake: true
        case .waiting: false
        case .shortSpeech(let evidence): evidence.valid
        }
    }
    public var shortPhraseCopy: String? {
        switch self {
        case .perTake: nil
        case .waiting: "waiting for the voice check"
        case .shortSpeech(let evidence):
            evidence.mode == .pooled
                ? "Short phrase · words checked · voice checked across \(evidence.takeCount) takes"
                : "voice couldn't be measured (under 3 s of speech)"
        }
    }
}
