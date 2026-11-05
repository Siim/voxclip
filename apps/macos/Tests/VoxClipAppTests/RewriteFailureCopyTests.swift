import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// MVP23: a take plan's `VoiceLabError.invalidInput` reached the panel as "The operation could not finish." Every error
/// the take plan and the Rewrite report has its own line and a next step, and is logged by type and case only.
@Suite("Rewrite failure copy")
struct RewriteFailureCopyTests {
    private struct Unknown: Error {}
    private enum Described: LocalizedError {
        case broken
        var errorDescription: String? { "The fixture broke." }
    }

    static let voiceLab: [VoiceLabError] = [
        .invalidInput, .consentRequired, .speakerMismatch, .planUnavailable, .noVoiceSlots, .missingKey, .permissionMissing("text_to_speech"),
        .unauthorized, .quotaExceeded, .rateLimited, .subscriptionRequired, .featureUnavailable, .voiceAccessDenied, .modelAccessDenied,
        .unsupportedModel, .unsupportedEndpoint, .unsupportedFormat, .malformedResponse, .invalidAudio, .invalidAlignment,
        .responseTooLarge, .providerFailure(503), .network,
    ]
    static let project: [VoiceLabProjectError] = [
        .invalidAsset, .unsafePath, .invalidSegment, .invalidRange, .invalidWords, .danglingAsset, .overlappingReplacement,
        .missingSegment, .invalidCandidate, .unsupportedRendering, .invalidScope, .missingRenderPolicy, .needsVoiceLabUpgrade,
        .videoModeUnsupported, .alignmentUnavailable, .consentUnverified, .qaRejected, .invalidFadeHandles, .overlappingFades,
        .unsupportedAssetFormat, .cleanAudioUnsupported, .staleRenderContract, .endpointUnsupported, .legacySegmentsNeedReview,
        .requiresVersion3, .invalidVoice, .missingVoice,
    ]
    static let geometry: [VoiceLabGeometryError] = [
        .invalidInput(), .unknownWord("w1"), .reversedWords, .insertionUnsupported, .windowCrossesWord("w1"),
        .seamFadeOutsideTake(isStart: true), .seamFadeCrossesCut(incoming: true, needed: 2, available: 1), .windowTooShort(needed: 2, available: 1),
        .overlapsReplacement("s"), .adjacentReplacement("s"), .insufficientHandle(incoming: false, needed: 2, available: 1),
        .alignmentUnavailable, .alignmentMismatch, .invalidWordTiming, .noVoicedAudio, .roomToneUnavailable, .fitTouchesVoice,
    ]
    static let plan: [ClipTakePlan.Failure] = [
        .placement(.geometry(.windowTooShort(needed: 2, available: 1)), index: 0), .placement(.collidesWithChange(0), index: 1),
        .spendingCap, .unknownSpend, .stale, .noSelection, .nothingToVoice, .tooManyPhrases(count: 140), .priceChanged,
    ]
    static let context: [any Error] = [
        RewriteSpeechContextReview.Failure.unsupported, RewriteSpeechContextReview.Failure.mergeRequired,
        RewriteSpeechContextReview.Failure.stale, RewriteSpeechContextReview.Failure.placementChanged,
        VoiceLabSpeechContextPlan.Failure.invalidInput, VoiceLabSpeechContextPlan.Failure.insufficientSpeech(hunkIndex: 0),
        VoiceLabSpeechContextPlan.Failure.budget, VoiceLabSpeechContextPlan.Failure.placement(.reversedWords),
        VoiceLabSpeechContextPlan.Failure.staleReview, VoiceLabSpeechContextPlan.Failure.quoteBinding,
    ]
    static var everyCase: [any Error] {
        voiceLab as [any Error] + project as [any Error] + geometry as [any Error] + plan as [any Error] + context + [
            VoiceLabLengthBudgetError.invalidInput, VoiceLabLengthBudgetError.rateUnavailable,
            VoiceLabWordDiffError.invalidInput, VoiceLabWordDiffError.tokenLimit(side: .newText, count: 9_000, limit: 8_000),
            VoiceLabAudioMathError.noVoicedAudio, VoiceLabAudioMathError.insufficientContext, VoiceLabAudioMathError.invalidInput,
            VoiceLabSourceAudioError.unreadable, VoiceLabSourceAudioError.altered, VoiceConsentError.inactive, VoiceConsentError.creatorMismatch,
            MicrophoneTakeError.noSpeech, MicrophoneTakeError.transcriptionUnavailable, RewriteSessionError.noSourceAudio,
            LLMError.timeout, LLMError.cliFailed("stopped"), VoxClipError.offline, Described.broken, Unknown(),
        ]
    }

    @Test func everyTakePlanAndRewriteErrorHasItsOwnLineNeverTheGenericOne() {
        for error in Self.everyCase {
            let refusal = RewriteSession.refusal(error)
            let copy = ClipTakePlan.copy(error)
            #expect(!refusal.isEmpty && refusal != UserMessages.generic, "\(String(reflecting: error)): \(refusal)")
            #expect(!copy.isEmpty && copy != UserMessages.generic, "\(String(reflecting: error)): \(copy)")
        }
    }

    @Test func theUsersErrorNowSaysWhatToDo() {
        #expect(ClipTakePlan.copy(VoiceLabError.invalidInput) != UserMessages.generic)
        #expect(ClipTakePlan.copy(VoiceLabError.invalidInput).contains("Get a fresh price"))
        #expect(RewriteSession.refusal(Unknown()).contains("Get a fresh price or ask again"))
        #expect(RewriteSession.refusal(Described.broken) == "The fixture broke. Your edits are saved.")
    }

    @Test func aFailureIsLoggedByTypeAndCaseWithoutItsText() {
        #expect(RewriteSession.failureKind(VoiceLabError.invalidInput) == "type=VoiceLabError case=invalidInput")
        #expect(RewriteSession.failureKind(VoiceLabError.permissionMissing("secret-permission")) == "type=VoiceLabError case=permissionMissing")
        #expect(RewriteSession.failureKind(LLMError.cliFailed("private reply text")) == "type=LLMError case=cliFailed")
        #expect(RewriteSession.failureKind(ClipTakePlan.Failure.placement(.geometry(.unknownWord("w1")), index: 3))
            == "type=ClipTakePlan.Failure case=placement.geometry.unknownWord")
        #expect(RewriteSession.failureKind(ClipTakePlan.Failure.tooManyPhrases(count: 140)) == "type=ClipTakePlan.Failure case=tooManyPhrases")
        #expect(RewriteSession.failureKind(Unknown()).hasPrefix("type=RewriteFailureCopyTests.Unknown domain="))
        for error in Self.everyCase {
            let line = RewriteSession.failureKind(error)
            #expect(line.range(of: #"\A[A-Za-z0-9_.= -]+\z"#, options: .regularExpression) != nil, "\(line)")
        }
    }
}
