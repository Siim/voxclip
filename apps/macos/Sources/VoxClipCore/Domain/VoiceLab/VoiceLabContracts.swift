import Foundation
import CryptoKit

package enum VoiceLabFingerprint {
    package static func bytes(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    package static func fields(_ fields: [String]) -> String {
        var payload = Data()
        for field in fields {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: field.utf8)
        }
        return bytes(payload)
    }

}

/// Values passed between the Voice Lab UI, Core services and future media integration.
public enum VoiceLabOperation: String, Sendable, Codable { case createClone, deleteClone, textToSpeech, voiceChange, speechToText }
public enum VoiceLabLanguageMode: Sendable, Equatable {
    case explicit(String)
    case autoDetected(expected: String)
}

public enum VoiceLabError: Error, Sendable, Equatable {
    case invalidInput, consentRequired, speakerMismatch, planUnavailable, noVoiceSlots, missingKey
    case permissionMissing(String), unauthorized, quotaExceeded, rateLimited
    case unsupportedModel, unsupportedEndpoint, unsupportedFormat, malformedResponse, invalidAudio, invalidAlignment
    case responseTooLarge, cancelled, providerFailure(Int), network
}

/// Prepared by the service for one exact billable request; preparation performs no provider call.
public struct VoiceLabQuote: Sendable, Equatable {
    public let id: UUID
    public let operation: VoiceLabOperation
    public let requestID: UUID
    public let estimate: CostEstimate
    public let region: ElevenLabsRegion
    public let endpoint: String
    public let languageMode: VoiceLabLanguageMode?
    public let preparedAt: Date
    public let modelID: String?
    package let fingerprint: String
    package let guardAudioHash: String?
    package init(id: UUID, operation: VoiceLabOperation, requestID: UUID, estimate: CostEstimate, region: ElevenLabsRegion,
         endpoint: String, languageMode: VoiceLabLanguageMode?, fingerprint: String, guardAudioHash: String? = nil,
         preparedAt: Date = Date(), modelID: String? = nil) {
        self.id = id; self.operation = operation; self.requestID = requestID; self.estimate = estimate; self.region = region
        self.endpoint = endpoint; self.languageMode = languageMode; self.fingerprint = fingerprint; self.guardAudioHash = guardAudioHash
        self.preparedAt = preparedAt; self.modelID = modelID
    }
}

/// An affirmative answer to a service-issued quote for one concrete request.
public struct VoiceLabAuthorization: Sendable, Equatable {
    public let quote: VoiceLabQuote
    public let approved: Bool
    public var operation: VoiceLabOperation { quote.operation }
    public var requestID: UUID { quote.requestID }
    public var estimate: CostEstimate { quote.estimate }
    public init(quote: VoiceLabQuote, approved: Bool) {
        self.quote = quote; self.approved = approved
    }
}

public struct VoiceLabModel: Sendable, Equatable {
    package init(id: String, name: String, languages: [String], canSpeak: Bool, canConvert: Bool, maximumTextLength: Int?, characterCostMultiplier: Double?) {
        self.id = id; self.name = name; self.languages = languages; self.canSpeak = canSpeak; self.canConvert = canConvert; self.maximumTextLength = maximumTextLength; self.characterCostMultiplier = characterCostMultiplier
    }

    public let id: String
    public let name: String
    public let languages: [String]
    public let canSpeak: Bool
    public let canConvert: Bool
    public let maximumTextLength: Int?
    public let characterCostMultiplier: Double?
    /// v4 is documented for Text to Dialogue; that separate timing path is not implemented here.
    public var supportsTimestampedTTS: Bool { canSpeak && id != "eleven_v4" && id != "eleven_v4_turbo" }
}

public struct VoiceLabSubscription: Sendable, Equatable {
    package init(tier: String, status: String, characterCount: Int, characterLimit: Int, nextResetUnix: Int?, canClone: Bool, voiceSlotsUsed: Int, voiceLimit: Int) {
        self.tier = tier; self.status = status; self.characterCount = characterCount; self.characterLimit = characterLimit; self.nextResetUnix = nextResetUnix; self.canClone = canClone; self.voiceSlotsUsed = voiceSlotsUsed; self.voiceLimit = voiceLimit
    }

    public let tier: String
    public let status: String
    public let characterCount: Int
    public let characterLimit: Int
    public let nextResetUnix: Int?
    public let canClone: Bool
    public let voiceSlotsUsed: Int
    public let voiceLimit: Int
    public var isNonCommercial: Bool { tier == "free" || status == "free" }
}

public struct VoiceLabVoice: Sendable, Equatable {
    public let id: String
    public let name: String
    public let category: String
    public let isOwner: Bool
    public let requiresVerification: Bool
    public let isVerified: Bool
    public let consentRecordID: String?
    public let createdAt: Date?
    public init(id: String, name: String, category: String, isOwner: Bool, requiresVerification: Bool, isVerified: Bool, consentRecordID: String? = nil, createdAt: Date? = nil) {
        self.id = id; self.name = name; self.category = category; self.isOwner = isOwner
        self.requiresVerification = requiresVerification; self.isVerified = isVerified; self.consentRecordID = consentRecordID
        self.createdAt = createdAt
    }
}

/// Per-request TTS inputs (voice-lab §8.5). Core keeps the 300 Unicode scalars of context nearest the window and drops a cut word.
public struct VoiceLabSpeechOptions: Sendable, Equatable {
    public let seed: UInt32
    public let previousText: String?
    public let nextText: String?
    public init(seed: UInt32, previousText: String? = nil, nextText: String? = nil) {
        self.seed = seed; self.previousText = previousText; self.nextText = nextText
    }
}

public struct VoiceLabReceipt: Sendable, Equatable {
    package init(provider: String, region: ElevenLabsRegion, endpoint: String, modelID: String?, voiceID: String?, requestID: UUID, providerRequestID: String?, spendWarning: VoiceLabSpendWarning?) {
        self.provider = provider; self.region = region; self.endpoint = endpoint; self.modelID = modelID; self.voiceID = voiceID; self.requestID = requestID; self.providerRequestID = providerRequestID; self.spendWarning = spendWarning
    }

    public let provider: String
    public let region: ElevenLabsRegion
    public let endpoint: String
    public let modelID: String?
    public let voiceID: String?
    public let requestID: UUID
    public let providerRequestID: String?
    /// Set when the spend ledger could not record this accepted action as asked; voice-lab §3.1. The action still succeeded,
    /// so the caller shows it as a notice, never as a failure.
    public let spendWarning: VoiceLabSpendWarning?
}

/// PCM is signed 16-bit little-endian mono; timing starts at zero in generated audio.
public struct VoiceLabAudioResult: Sendable, Equatable {
    package init(pcm: Data, sampleRate: Int, alignment: [VoiceLabCharacterTiming]?, receipt: VoiceLabReceipt) {
        self.pcm = pcm; self.sampleRate = sampleRate; self.alignment = alignment; self.receipt = receipt
    }

    public let pcm: Data
    public let sampleRate: Int
    public let alignment: [VoiceLabCharacterTiming]?
    public let receipt: VoiceLabReceipt
    public var spendWarning: VoiceLabSpendWarning? { receipt.spendWarning }
}

public struct VoiceLabCharacterTiming: Sendable, Equatable {
    package init(character: String, start: Double, end: Double) {
        self.character = character; self.start = start; self.end = end
    }

    public let character: String
    public let start: Double
    public let end: Double
}

public struct VoiceLabCloneResult: Sendable, Equatable {
    package init(voiceID: String, requiresVerification: Bool, consentRecordID: String, receipt: VoiceLabReceipt) {
        self.voiceID = voiceID; self.requiresVerification = requiresVerification; self.consentRecordID = consentRecordID; self.receipt = receipt
    }

    public let voiceID: String
    public let requiresVerification: Bool
    public let consentRecordID: String
    public let receipt: VoiceLabReceipt
    public var spendWarning: VoiceLabSpendWarning? { receipt.spendWarning }
}

public enum VoiceLabCloneSampleRole: String, Sendable, Equatable { case consentStatement, training }

/// A complete mono PCM16 WAV file. Other upload formats wait for spike S5 (voice-lab §6.5).
public struct VoiceLabCloneSample: Sendable, Equatable {
    public let role: VoiceLabCloneSampleRole
    public let wav: Data
    public init(role: VoiceLabCloneSampleRole, wav: Data) {
        self.role = role; self.wav = wav
    }
}

/// One own-voice clone upload (voice-lab §6.5, §6.7). The single consent statement is sent first, then training samples in caller order.
public struct VoiceLabCloneRequest: Sendable, Equatable {
    public let recoveryNonce: String?
    public let displayName: String
    /// Statement language, `[a-z]{2,3}`, sent as the `language` label.
    public let language: String
    public let samples: [VoiceLabCloneSample]
    /// Sent in the description as RFC 3339 UTC in whole seconds.
    public let createdAt: Date
    public let removeBackgroundNoise: Bool
    public init(displayName: String, language: String, samples: [VoiceLabCloneSample], createdAt: Date, removeBackgroundNoise: Bool, recoveryNonce: String? = nil) {
        self.displayName = displayName; self.language = language; self.samples = samples
        self.createdAt = createdAt; self.removeBackgroundNoise = removeBackgroundNoise
        self.recoveryNonce = recoveryNonce
    }
}

public enum VoiceRewriteScope: String, Codable, Sendable { case passage, fullTake }
/// One passage or full-take rewrite with its length budget (voice-lab §8.9.1). The caller computes the budget; the quote binds it.
public struct VoiceRewriteRequest: Codable, Sendable {
    public let id: UUID
    public let scope: VoiceRewriteScope
    public let sourceWords: [TimedWord]
    public let instruction: String
    public let language: String
    /// `w`, the part of the window the take must fill: finite, above 0 and at most 600 seconds.
    public let targetSeconds: Double
    /// The new words' `VoiceLabTextLength` range, with `1 ≤ minChars ≤ maxChars ≤ 5,000`.
    public let minChars: Int
    public let maxChars: Int
    public init(id: UUID, scope: VoiceRewriteScope, sourceWords: [TimedWord], instruction: String, language: String,
                targetSeconds: Double, minChars: Int, maxChars: Int) {
        self.id = id; self.scope = scope; self.sourceWords = sourceWords; self.instruction = instruction; self.language = language
        self.targetSeconds = targetSeconds; self.minChars = minChars; self.maxChars = maxChars
    }
}

public struct VoiceRewriteQuote: Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID
    public let connector: ConnectorID
    public let model: String
    public let estimate: CostEstimate
    package let fingerprint: String
}

public struct VoiceRewriteAuthorization: Sendable, Equatable {
    public let quote: VoiceRewriteQuote
    public let approved: Bool
    public var requestID: UUID { quote.requestID }
    public var connector: ConnectorID { quote.connector }
    public var model: String { quote.model }
    public var estimate: CostEstimate { quote.estimate }
    public init(quote: VoiceRewriteQuote, approved: Bool) {
        self.quote = quote; self.approved = approved
    }
}

/// Review data is inert. It cannot invoke synthesis or change source word timing.
public struct VoiceRewriteProposal: Sendable {
    public let id: UUID
    public let scope: VoiceRewriteScope
    public let sourceWords: [TimedWord]
    public let sourceText: String
    public let proposedText: String
    public let connector: ConnectorID
    public let model: String
    public let providerRequestID: String?
    /// Core's own `VoiceLabTextLength` of `proposedText`; models miscount, so the reply is never trusted for it.
    public let proposedLength: Int
    /// Whether `proposedLength` lies in the request's range. A proposal outside it is still returned, as it is (§8.9.1).
    public let inRange: Bool
}
