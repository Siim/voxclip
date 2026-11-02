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

    @Test func casualShortPhraseCanBePlannedWithoutExpandingSource() throws {
        let (project, envelope) = try fixture()
        let change = hunk(50...50, text: "to how.")
        let planned = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope, hunks: [change])
        #expect(planned.count == 1 && planned[0].text == "to how.")
        #expect(planned[0].indices == [0])
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

    @Test(arguments: ["Development of the flight simulator game", "And yeah, I keep going,", "The next idea is", "to how", "players can collaborate,"])
    func shortPhrasesKeepTheirReviewedWindowAndOfferAnAdvisory(text: String) throws {
        let (project, envelope) = try fixture()
        let snapshot = project
        for range in [50...50, 50...57] {
            let phrases = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope,
                hunks: [hunk(range, text: text)])
            #expect(phrases.count == 1 && phrases[0].text == text)
            #expect(phrases[0].window.firstWordId == "w50" && phrases[0].window.lastWordId == "w\(range.upperBound)")
            #expect(try #require(phrases[0].estimatedVoicedSeconds) < ClipTakePlan.minimumGeneratedSpeechSeconds)
        }
        #expect(project == snapshot)
    }

    @Test func aSetContainingAShortPhraseDoesNotDecodeOrExpandDuringPlanning() throws {
        let (project, envelope) = try fixture()
        var decoded = 0
        let plan = try ClipTakePlan(project: project, scope: .full, envelope: envelope,
            hunks: [hunk(20...27, text: "The players can safely collaborate with each other."), hunk(70...70, text: "to how")],
            makeInput: { _ in decoded += 1; throw ClipTakePlan.Failure.stale })
        #expect(decoded == 0 && plan.phrases.count == 2)
        #expect(plan.phrases[1].text == "to how" && plan.phrases[1].window.firstWordId == "w70")
        #expect(plan.phrases[0].window.end < plan.phrases[1].window.start)
    }

    @Test func missingTranscriptRateUsesTheProviderFloorForAnAdvisory() throws {
        var (project, envelope) = try fixture()
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: envelope,
            firstWordId: "w50", lastWordId: "w57")
        let phrase = ClipTakePlan.Phrase(id: 0, indices: [0], text: "to how", window: window)
        let untimedCharacters = (project.transcript?.words ?? []).map { original in
            var word = original; word.text = "."; return word
        }
        project.transcript?.words = untimedCharacters
        let estimate = try ClipTakePlan.validateSpeechAvailability([phrase], project: project, scope: .full)
        #expect(try #require(estimate[0]) < ClipTakePlan.minimumGeneratedSpeechSeconds)
    }

    @Test func sourceEdgeSilenceDoesNotIncreaseTheAdvisory() throws {
        let (project, envelope) = try fixture(duration: 121)
        let phrases = try ClipTakePlan.preparePlan(project: project, scope: .full, envelope: envelope,
            hunks: [hunk(99...99, text: "to how")])
        #expect(phrases[0].window.end - phrases[0].window.start > 70)
        #expect(try #require(phrases[0].estimatedVoicedSeconds) < 1)
    }
}
