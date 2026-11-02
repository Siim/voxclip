import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

@Suite("Clip take speech planning")
@MainActor struct ClipTakeSpeechPlanningTests {
    private func fixture(duration: Double = 51) throws -> (Project, AudioEnvelope) {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.voiceLab.segments = []; project.voiceLab.assets = []
        project.edits = ProjectEdits()
        project.media.source.durationSeconds = duration
        project.media.source.audio?.sampleRate = 24_000
        project.transcript?.durationSeconds = duration
        project.transcript?.words = (0..<100).map { index in
            let start = 0.2 + Double(index) * 0.5
            return TimedWord(id: "w\(index)", text: "source", start: start, end: start + 0.3)
        }
        return (project, AudioEnvelope(sampleRate: 24_000, levels: [Float](repeating: 0.01, count: Int(duration * 100))))
    }

    private func hunk(_ indices: ClosedRange<Int>, text: String) -> VoiceLabDiffHunk {
        VoiceLabDiffHunk(kind: .voice, sourceWordIds: indices.map { "w\($0)" }, newTokens: EditingPrimitives.splitWords(text),
            correctedTexts: [], absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: indices.lowerBound,
            sourceEndIndex: indices.upperBound + 1, anchorSeconds: nil)
    }

    private func speechSeconds(_ text: String, project: Project) throws -> Double {
        let rate = try VoiceLabLengthBudget.rate(transcript: RewriteSession.corrected(project))
        return Double(VoiceLabTextLength.length(text)) / rate.charactersPerSecond
    }

    @Test(arguments: ["Development of the flight simulator game", "And yeah, I keep going,", "The next idea is", "to how", "players can collaborate,"])
    func tinyWindowsRefuseBeforeDecodingOrQuoting(text: String) throws {
        let (project, envelope) = try fixture()
        let snapshot = project
        let change = hunk(50...50, text: text)
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: envelope,
            firstWordId: "w50", lastWordId: "w50")
        let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: .full, window: window)
        let rate = try VoiceLabLengthBudget.rate(transcript: RewriteSession.corrected(project))
        let meter = try VoiceLabFitMeter.measure(text: text, window: window, incomingSilence: silence.incoming,
            outgoingSilence: silence.outgoing, rate: rate.charactersPerSecond, newWords: text)
        var decoded = 0
        #expect(throws: ClipTakePlan.Failure.insufficientSpeechWindow(phrase: 1, maximumSeconds: meter.upperBoundSeconds)) {
            _ = try ClipTakePlan(project: project, scope: .full, envelope: envelope, hunks: [change], makeInput: { _ in
                decoded += 1
                throw ClipTakePlan.Failure.stale
            })
        }
        #expect(meter.upperBoundSeconds < ClipTakePlan.minimumGeneratedSpeechSeconds)
        #expect(decoded == 0 && project == snapshot)
    }

    @Test(arguments: ["Development of the flight simulator game", "And yeah, I keep going,", "The next idea is", "to how", "players can collaborate,"])
    func longSourceWindowCannotSubstituteForGeneratedSpeech(text: String) throws {
        let (project, envelope) = try fixture()
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: envelope,
            firstWordId: "w50", lastWordId: "w57")
        #expect(window.end - window.start > ClipTakePlan.minimumGeneratedSpeechSeconds)
        let estimate = try speechSeconds(text, project: project)
        #expect(estimate < ClipTakePlan.minimumGeneratedSpeechSeconds)
        #expect(throws: ClipTakePlan.Failure.insufficientPlannedSpeech(phrase: 1, estimatedSeconds: estimate)) {
            try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope, hunks: [hunk(50...57, text: text)])
        }
    }

    @Test func structuralRefusalDoesNotDependOnWordCountOrTextEstimate() throws {
        let (project, envelope) = try fixture()
        let text = String(repeating: "a", count: 100)
        #expect(try speechSeconds(text, project: project) > ClipTakePlan.minimumGeneratedSpeechSeconds)
        do {
            _ = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope, hunks: [hunk(50...50, text: text)])
            Issue.record("A subsecond source window must not buy three unsupported takes.")
        } catch let ClipTakePlan.Failure.insufficientSpeechWindow(phrase, maximumSeconds) {
            #expect(phrase == 1 && maximumSeconds < ClipTakePlan.minimumGeneratedSpeechSeconds)
        }
    }

    @Test func sourceEdgeSilenceCannotMakeAWindowVerifiable() throws {
        let (project, envelope) = try fixture(duration: 121)
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: envelope,
            firstWordId: "w99", lastWordId: "w99")
        #expect(window.end - window.start > 70 && window.rightSeam.kind == .none)
        do {
            _ = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope,
                hunks: [hunk(99...99, text: String(repeating: "a", count: 100))])
            Issue.record("Source-edge silence is not generated speaker evidence.")
        } catch let ClipTakePlan.Failure.insufficientSpeechWindow(phrase, maximumSeconds) {
            #expect(phrase == 1 && maximumSeconds < ClipTakePlan.minimumGeneratedSpeechSeconds)
        }
    }

    @Test func trimMarginsPunctuationAndWhitespaceDoNotBuySpeakerTime() throws {
        let (project, envelope) = try fixture()
        let rate = try VoiceLabLengthBudget.rate(transcript: RewriteSession.corrected(project))
        let count = Int(ceil(rate.charactersPerSecond * ClipTakePlan.minimumGeneratedSpeechSeconds)) - 1
        let text = String(repeating: "a", count: count) + String(repeating: ".", count: 200) + "   "
        let prepared = EditingPrimitives.splitWords(text).joined(separator: " ")
        let estimate = try speechSeconds(prepared, project: project)
        #expect(estimate < ClipTakePlan.minimumGeneratedSpeechSeconds)
        #expect(try VoiceLabLengthBudget.estimate(text: prepared, rate: rate.charactersPerSecond) > ClipTakePlan.minimumGeneratedSpeechSeconds)
        #expect(throws: ClipTakePlan.Failure.insufficientPlannedSpeech(phrase: 1, estimatedSeconds: estimate)) {
            try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope, hunks: [hunk(50...57, text: text)])
        }
    }

    @Test func sufficientlyLongOneTokenKeepsExactTextWindowAndSourceTimings() throws {
        let (project, envelope) = try fixture()
        let snapshot = project
        let rate = try VoiceLabLengthBudget.rate(transcript: RewriteSession.corrected(project))
        let text = String(repeating: "a", count: Int(ceil(rate.charactersPerSecond * ClipTakePlan.minimumGeneratedSpeechSeconds)))
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: envelope,
            firstWordId: "w50", lastWordId: "w57")
        let phrases = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope, hunks: [hunk(50...57, text: text)])
        #expect(phrases.count == 1 && phrases[0].text == text && phrases[0].window == window)
        #expect(phrases[0].indices == [0] && project == snapshot)
        try VoiceLabRenderContract.validatePlacement(project, scope: .full, windows: phrases.map(\.window))
    }

    @Test func existingGeneratedBridgesCountWithoutExpandingTheReviewedWindow() throws {
        var (project, envelope) = try fixture()
        for index in 47...52 {
            let nextStart = try #require(project.transcript?.words[index + 1].start)
            project.transcript?.words[index].end = nextStart
        }
        project.edits.corrections["w48"] = "corrected"
        let snapshot = project
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: envelope,
            firstWordId: "w50", lastWordId: "w50")
        let phrases = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope,
            hunks: [hunk(50...50, text: "to how")])
        #expect(window.leftBridgeWordIds == ["w47", "w48", "w49"])
        #expect(window.rightBridgeWordIds == ["w51", "w52", "w53"])
        #expect(phrases[0].text == "source corrected source to how source source source")
        #expect(phrases[0].window == window && phrases[0].indices == [0] && project == snapshot)
    }

    @Test func supportedClipPlanPreservesScopeCutsCorrectionsAndHunkIndices() throws {
        var (project, envelope) = try fixture()
        project.edits.clips = [ClipRange(id: "speech-clip", startWordId: "w10", endWordId: "w90")]
        project.edits.corrections["w15"] = "corrected"
        let snapshot = project
        let voice = hunk(50...57, text: "The players can safely collaborate with each other.")
        let cut = VoiceLabDiffHunk(kind: .cut, sourceWordIds: ["w20"], newTokens: [], correctedTexts: [],
            absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 20, sourceEndIndex: 21, anchorSeconds: nil)
        let scope = VoiceLabOutputScope.clip("speech-clip")
        var final = project
        final.edits.cutWordIds.append("w20")
        let window = try VoiceLabWindowPlanner.place(project: final, scope: scope, envelope: envelope,
            firstWordId: "w50", lastWordId: "w57")
        let phrases = try ClipTakePlan.preparePlan(project: project, scope: scope, envelope: envelope, hunks: [cut, voice])
        #expect(phrases.count == 1 && phrases[0].indices == [1])
        #expect(phrases[0].text == voice.newTokens.joined(separator: " ") && phrases[0].window == window)
        #expect(project == snapshot)
        try VoiceLabRenderContract.validatePlacement(final, scope: scope, windows: phrases.map(\.window))
    }

    @Test func entireSetIsCheckedBeforeAnyInputAndExcludedShortChangeIsNotExpanded() throws {
        let (project, envelope) = try fixture()
        let long = hunk(20...27, text: "The players can safely collaborate with each other.")
        let short = hunk(70...70, text: "to how")
        var decoded = 0
        do {
            _ = try ClipTakePlan(project: project, scope: .full, envelope: envelope, hunks: [long, short], makeInput: { _ in
                decoded += 1
                throw ClipTakePlan.Failure.stale
            })
            Issue.record("An unsupported second phrase must refuse the complete set before payment.")
        } catch let ClipTakePlan.Failure.insufficientSpeechWindow(phrase, maximumSeconds) {
            #expect(phrase == 2 && maximumSeconds < ClipTakePlan.minimumGeneratedSpeechSeconds)
        }
        let remaining = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope, hunks: [long])
        #expect(decoded == 0 && remaining.count == 1 && remaining[0].text == long.newTokens.joined(separator: " "))
        #expect(remaining[0].window.end < (try #require(project.transcript?.words[70].start)))
    }

    @Test func missingSpeechRateHasAnExplicitAvailabilityRefusal() throws {
        var (project, envelope) = try fixture()
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: envelope,
            firstWordId: "w50", lastWordId: "w57")
        project.transcript?.words = []
        let phrase = ClipTakePlan.Phrase(id: 0, indices: [0], text: "unchanged prepared wording", window: window)
        #expect(throws: ClipTakePlan.Failure.speechEstimateUnavailable) {
            try ClipTakePlan.validateSpeechAvailability([phrase], project: project, scope: .full)
        }
    }

    @Test func availabilityCopyOffersNoFakeWiderScopeOrPaidRetryRemedy() {
        for failure in [ClipTakePlan.Failure.insufficientSpeechWindow(phrase: 2, maximumSeconds: 0.5),
                        .insufficientPlannedSpeech(phrase: 2, estimatedSeconds: 2.8), .speechEstimateUnavailable] {
            let copy = ClipTakePlan.copy(failure)
            #expect(copy.contains("re-record") && copy.contains("Nothing was sent for takes.") && copy.contains("Your edits are saved."))
            #expect(!copy.contains("wider scope") && !copy.contains("try again") && !copy.contains("doesn't sound like"))
        }
    }
}
