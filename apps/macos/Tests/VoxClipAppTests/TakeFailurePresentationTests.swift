import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

@Suite("Take failure presentation", .offlineFixtures)
@MainActor struct TakeFailurePresentationTests {
    @Test(arguments: [VoiceLabJoinAdvisorySeam.Side.left, .right])
    func joinAdvisoryCopyNamesTheTakeDurationAndSide(side: VoiceLabJoinAdvisorySeam.Side) throws {
        let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 4, peakDbfs: -10, speakerScore: 0.9),
            failures: [.loudness], joinSeams: [.init(side: side, excessLu: 4)])
        let take = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, audio: audio(), qa: qa)
        #expect(TakeFailurePresentation.joinAdvisory(take, number: 2)
            == "Take 2 · 1.0 s · The join may sound uneven (\(side.rawValue) side). Listen before using.")
        #expect(TakeFailurePresentation.leftOut(take, number: 2) == nil)
        #expect(TakeFailurePresentation.reason(for: take) == nil)
    }
    private func row(_ failure: VoiceLabTakeFailure? = nil, values: VoiceLabQA? = nil,
                     failures: [VoiceLabTakeQAFailure] = [], audio: VoiceLabTakeAudio? = nil) -> VoiceLabTakeRow {
        VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, audio: audio,
            qa: values.map { VoiceLabTakeQAResult(values: $0, failures: failures) }, failure: failure)
    }

    private func audio(changedDuration: Bool = false) -> VoiceLabTakeAudio {
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: 24_000, windowStart: 1, windowEnd: 2, windowStartSample: 24_000, windowEndSample: 48_000,
            outputFrames: 24_000, words: [.init(text: "Hello", start: 0.1, end: 0.9, synthetic: true)])
        return VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [0.1], mixed: [0.1], patchRange: 0..<1,
            seams: [], gainDb: 0, roomTone: nil,
            fit: changedDuration ? .changedDuration(plan, naturalOut: 1.5, residualSeconds: 0.5) : .exact(plan))
    }

    @Test(arguments: [VoiceLabTakeQAFailure.transcript, .speaker])
    func reviewerFailedTakeNeverClaimsSuccessfulPooledCheck(failure: VoiceLabTakeQAFailure) {
        let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10), failures: [])
        let pending = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, audio: audio(), qa: qa, voiceCheck: .waiting)
        let evidence = VoiceLabShortSpeechEvidence(mode: .pooled, recordId: "own", consentMethod: .recordedStatement,
            voicedFrames: 60_000, takeCount: 3)
        let failed = pending.checkingVoice(.shortSpeech(evidence), score: failure == .speaker ? 0 : 1, failure: .qa([failure]))
        #expect(failed.shortPhraseCopy == nil)
        #expect(TakeFailurePresentation.shortSpeechSummary([failed], selected: nil).isEmpty)
    }

    @Test func reviewerPooledSummaryAppearsOncePerPhrase() {
        let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10), failures: [])
        let evidence = VoiceLabShortSpeechEvidence(mode: .pooled, recordId: "own", consentMethod: .recordedStatement,
            voicedFrames: 60_000, takeCount: 3)
        let rows = (0..<3).map { index in
            VoiceLabTakeRow(id: UUID(), index: index, seed: 1, audio: audio(), qa: qa, voiceCheck: .waiting)
                .checkingVoice(.shortSpeech(evidence), score: 1)
        }
        #expect(TakeFailurePresentation.shortSpeechSummary(rows, selected: rows[0].id)
            == ["Short phrase · words checked · voice checked across 3 takes"])
    }

    @Test func shortPhraseCopyNamesWaitingPooledAndOwnCloneUnmeasuredStates() throws {
        let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10), failures: [])
        let waiting = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, audio: audio(), qa: qa, voiceCheck: .waiting)
        #expect(!waiting.selectable && TakeFailurePresentation.reason(for: waiting) == nil)
        #expect(TakeFailurePresentation.leftOut(waiting, number: 1) == "Take 1 · waiting for the voice check")
        let pooled = VoiceLabShortSpeechEvidence(mode: .pooled, recordId: "own", consentMethod: .recordedStatement,
            voicedFrames: 60_000, takeCount: 3)
        #expect(waiting.checkingVoice(.shortSpeech(pooled), score: 1).shortPhraseCopy == "Short phrase · words checked · voice checked across 3 takes")
        for method: VoiceConsentRecord.ConsentMethod in [.recordedStatement, .projectAttestation] {
            let evidence = VoiceLabShortSpeechEvidence(mode: .unmeasured, recordId: "own", consentMethod: method,
                voicedFrames: 22_400, takeCount: 1)
            let row = waiting.checkingVoice(.shortSpeech(evidence))
            #expect(row.selectable && row.qa?.values.speakerScore == nil && row.failure == nil)
            #expect(row.shortPhraseCopy == "voice couldn't be measured (under 3 s of speech)")
            #expect(TakeFailurePresentation.reason(for: row) == nil)
        }
        let invalid = VoiceLabShortSpeechEvidence(mode: .unmeasured, recordId: "own", consentMethod: .projectAttestation,
            voicedFrames: 48_000, takeCount: 1)
        #expect(!waiting.checkingVoice(.shortSpeech(invalid)).selectable)
    }

    @Test func insufficientSpeechIsUnavailableNotAWordOrSpeakerMismatch() throws {
        let failure = VoiceLabTakeFailure.qa([.insufficientGeneratedSpeech])
        let take = row(failure, values: .init(), failures: [.insufficientGeneratedSpeech], audio: audio())
        let original = take
        let copy = try #require(TakeFailurePresentation.leftOut(take, number: 3))
        #expect(copy.hasPrefix("Take 3:") && copy.hasSuffix("Left out."))
        #expect(copy.contains("Not enough generated speech") && copy.contains("at least 3 seconds of voiced speech"))
        #expect(copy.contains("could not be verified"))
        #expect(!copy.contains("did not pass") && !copy.contains("word check") && !copy.contains("voice did not"))
        #expect(take == original && !take.selectable)
        #expect(take.qa?.values.speakerScore == nil && take.qa?.values.transcriptMatch == nil)
        #expect(VoiceLabTakeRunResult(rows: [take], end: .completed).ranked.isEmpty)
    }

    @Test func legacySpeakerFailureWithoutAScoreDoesNotClaimMismatch() throws {
        let take = row(.qa([.speaker]), values: .init(lufsJumpLu: 0, peakDbfs: -20), failures: [.speaker])
        let copy = try #require(TakeFailurePresentation.reason(for: take))
        #expect(copy.contains("speaker check did not complete"))
        #expect(!copy.contains("voice did not pass") && !copy.contains("word check"))
        #expect(!copy.contains("3 seconds"), "A missing score alone does not establish a duration shortage")
        #expect(!take.selectable)
    }

    @Test func measuredMismatchIsNotRelabeledBecauseAudioIsShort() throws {
        let take = row(.qa([.speaker]), values: .init(speakerScore: 0.1), failures: [.speaker], audio: audio())
        let copy = try #require(TakeFailurePresentation.reason(for: take))
        #expect(copy == "The voice did not pass the speaker-match check.")
        #expect(!copy.contains("Not enough") && !take.selectable)
    }

    @Test(arguments: [VoiceLabTakeQAFailure.transcript, .clipping, .loudness])
    func measuredChecksAreDistinguishedFromMissingResults(check: VoiceLabTakeQAFailure) throws {
        let values = VoiceLabQA(transcriptMatch: 0.5, lufsJumpLu: 4, peakDbfs: 0.1)
        let measured = row(.qa([check]), values: values, failures: [check])
        let unavailable = row(.qa([check]), values: .init(), failures: [check])
        let failed = try #require(TakeFailurePresentation.reason(for: measured))
        let missing = try #require(TakeFailurePresentation.reason(for: unavailable))
        #expect(failed.contains("did not pass") && missing.contains("did not complete"))
        #expect(failed != missing && !measured.selectable && !unavailable.selectable)
        if check == .transcript { #expect(failed.contains("word check")) }
        if check == .clipping { #expect(failed.contains("clipping")) }
        if check == .loudness { #expect(failed.contains("joins")) }
    }

    @Test func nonfiniteScoreDoesNotEstablishAMeasuredMismatch() throws {
        for score in [Double.nan, .infinity, -.infinity] {
            let take = row(.qa([.speaker]), values: .init(speakerScore: score), failures: [.speaker])
            let copy = try #require(TakeFailurePresentation.reason(for: take))
            #expect(copy.contains("No speaker-match result"))
        }
    }

    @Test func multipleMeasuredFailuresRemainDistinctAndNoMissingMetricIsInvented() throws {
        let take = row(.qa([.transcript, .clipping, .loudness, .speaker]),
            values: .init(transcriptMatch: 0.5, lufsJumpLu: 4, peakDbfs: 0.1), failures: [.transcript, .clipping, .loudness, .speaker])
        let copy = try #require(TakeFailurePresentation.reason(for: take))
        #expect(copy.contains("recognized words") && copy.contains("clipping") && copy.contains("joins"))
        #expect(copy.contains("No speaker-match result") && !copy.contains("voice did not pass"))
    }

    @Test func transportTimingAndAudioErrorsNeverMasqueradeAsContentFailures() throws {
        let network = try #require(TakeFailurePresentation.reason(for: row(.provider(.network))))
        let timing = try #require(TakeFailurePresentation.reason(for: row(.invalidAlignment)))
        let audio = try #require(TakeFailurePresentation.reason(for: row(.invalidAudio)))
        let malformed = try #require(TakeFailurePresentation.reason(for: row(.provider(.malformedResponse))))
        let unsupported = try #require(TakeFailurePresentation.reason(for: row(.provider(.unsupportedFormat))))
        #expect(network.contains("connection problem") && malformed.contains("unreadable response"))
        #expect(timing.contains("word timing") && audio.contains("audio could not be validated"))
        #expect(unsupported.contains("format is not supported"))
        #expect(Set([network, timing, audio, malformed, unsupported]).count == 5)
        for copy in [network, timing, audio, malformed, unsupported] {
            #expect(!copy.contains("speech check") && !copy.contains("recognized words") && !copy.contains("voice did not pass"))
        }
    }

    @Test func failedProviderVerificationDoesNotAssertGeneratedVoiceMismatch() throws {
        let copy = try #require(TakeFailurePresentation.reason(for: row(.provider(.speakerMismatch))))
        #expect(copy.contains("No generated-voice match result"))
        #expect(!copy.contains("voice did not pass") && !copy.contains("Not enough"))
    }

    @Test func consentUnavailableAndStoppedChecksDoNotClaimNoAudioWasSent() throws {
        let unavailable = try #require(TakeFailurePresentation.reason(for: row(.consent(.speakerUnavailable))))
        let invalidRecord = try #require(TakeFailurePresentation.reason(for: row(.consent(.invalidRecord))))
        let stopped = try #require(TakeFailurePresentation.reason(for: row(.consent(.cancelled))))
        #expect(unavailable.contains("check is unavailable") && !unavailable.contains("created"))
        #expect(invalidRecord.contains("consent record") && !invalidRecord.contains("No audio was sent"))
        #expect(stopped.contains("stopped") && !stopped.isEmpty)
    }

    @Test func missingChecksAndMissingAudioAreDifferentAndNeverBecomeSelectable() throws {
        let unchecked = row()
        let missingAudio = row(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -20, speakerScore: 0.9))
        let copy = try #require(TakeFailurePresentation.reason(for: unchecked))
        #expect(copy.contains("checks did not complete"))
        #expect(TakeFailurePresentation.reason(for: missingAudio) == "The checked audio is unavailable.")
        #expect(!unchecked.selectable && !missingAudio.selectable)
    }

    @Test func checkedTimingChangesAreNotReportedAsFailedChecks() {
        let take = row(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -20, speakerScore: 0.9), audio: audio(changedDuration: true))
        #expect(take.selectable && !take.fits)
        #expect(TakeFailurePresentation.reason(for: take) == nil)
        let announcement = RewriteGenerationSession.completionAnnouncement(rows: [take], fittedTake: nil)
        #expect(announcement.contains("No take fits yet") && announcement.contains("needs a timing change"))
        #expect(!announcement.contains("ready") && !announcement.contains("left out"))
    }
}
