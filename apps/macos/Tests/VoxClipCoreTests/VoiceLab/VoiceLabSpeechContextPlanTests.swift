import Foundation
import Testing
@testable import VoxClipCore

@Suite("Generated speech context proposals")
struct VoiceLabSpeechContextPlanTests {
    private func fixture() throws -> Project {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        project.voiceLab.segments = []
        project.voiceLab.assets = []
        project.edits = ProjectEdits()
        let sentence = ["We", "carefully", "explain", "the", "original", "idea", "with", "clear", "useful", "examples."]
        project.transcript?.words = (0..<120).map { index in
            let start = 0.5 + Double(index) * 0.7
            return TimedWord(id: "w\(index)", text: sentence[index % sentence.count], start: start, end: start + 0.5,
                             rawStart: start, rawEnd: start + 0.5, conf: 0.97, speaker: "owner")
        }
        project.media.source.durationSeconds = 85
        return project
    }

    private func hunk(_ index: Int, text: String = "better", kind: VoiceLabDiffHunkKind = .voice) -> VoiceLabDiffHunk {
        VoiceLabDiffHunk(kind: kind, sourceWordIds: ["w\(index)"], newTokens: kind == .cut ? [] : [text],
                         correctedTexts: kind == .textOnly ? [text] : [], absorbedItemIds: [], bridgeWordIds: [],
                         sourceStartIndex: index, sourceEndIndex: index + 1, anchorSeconds: nil)
    }

    private func envelope(_ project: Project) -> AudioEnvelope {
        AudioEnvelope(sampleRate: Double(project.media.source.audio!.sampleRate),
                      levels: Array(repeating: 0.001, count: Int(project.media.source.durationSeconds * 100)))
    }

    private func request(_ project: Project, hunks: [VoiceLabDiffHunk]? = nil,
                         selected: [Int] = [0], expanding: [Int] = [0], approved: [String]? = nil,
                         scope: VoiceLabOutputScope = .full, revision: String = "review-7", cap: Int = 5_000,
                         reservations: [VoiceLabSpeechContextPlan.Reservation] = []) -> VoiceLabSpeechContextPlan.Request {
        .init(project: project, scope: scope, approvedSourceWordIDs: approved ?? project.transcript!.words.map(\.id),
              reviewHunks: hunks ?? [hunk(4)], selectedHunkIndices: selected, expandingHunkIndices: expanding,
              reservations: reservations, revision: revision, contentKey: project.media.source.contentKey, maximumRequestCharacters: cap)
    }

    private func proposal(_ request: VoiceLabSpeechContextPlan.Request) throws -> VoiceLabSpeechContextPlan {
        let outcome = VoiceLabSpeechContextPlan.propose(request, envelope: envelope(request.project))
        guard case .reviewRequired(let plan) = outcome else {
            Issue.record("Expected a review proposal, got \(outcome)")
            throw VoiceLabError.invalidInput
        }
        return plan
    }

    @Test func shortEditRegeneratesTheCompleteSentenceAndPreservesSourceTimings() throws {
        let project = try fixture(), snapshot = project
        let plan = try proposal(request(project))
        let phrase = try #require(plan.phrases.first)
        #expect(phrase.text == "We carefully explain the better idea with clear useful examples.")
        #expect(phrase.sourceWords == Array(project.transcript!.words[0...9]))
        #expect(phrase.hunk.sourceWordIds == (0...9).map { "w\($0)" })
        #expect(phrase.hunk.newTokens.joined(separator: " ") == phrase.text)
        #expect(phrase.hunk.sourceStartIndex == 0 && phrase.hunk.sourceEndIndex == 10)
        #expect(phrase.window.firstWordId == "w0" && phrase.window.lastWordId == "w9")
        #expect(phrase.window.leftBridgeWordIds.isEmpty && phrase.window.rightBridgeWordIds.isEmpty)
        #expect(phrase.estimatedSpeechSeconds >= VoiceLabSpeechContextPlan.minimumGeneratedSpeechSeconds + phrase.marginSeconds)
        #expect(abs(phrase.marginSeconds - 0.5) < 0.000_001)
        #expect(plan.totalVoiceTokenCount == 10)
        #expect(project == snapshot)
        #expect(try proposal(request(project)) == plan)
    }

    @Test func realDiffUsesExclusiveTokenIndicesRatherThanInventedWordOffsets() throws {
        let project = try fixture()
        let source = project.transcript!.words
        let text = source.enumerated().map { index, word in index == 4 ? "better" : word.text }.joined(separator: " ")
        let diff = try VoiceLabWordDiff.diff(source: source, newText: text)
        let index = try #require(diff.hunks.firstIndex(where: { $0.kind == .voice }))
        #expect(diff.hunks[index].sourceStartIndex == 4 && diff.hunks[index].sourceEndIndex == 5)
        let plan = try proposal(request(project, hunks: diff.hunks, selected: [index], expanding: [index]))
        #expect(plan.phrases[0].hunk.sourceStartIndex == 0 && plan.phrases[0].hunk.sourceEndIndex == 10)
    }

    @Test func approvedCorrectionsAreExactButExcludedCorrectionsBlockExpansion() throws {
        var project = try fixture()
        project.edits.corrections["w1"] = "accurately"
        let correction = hunk(7, text: "precise", kind: .textOnly)
        let included = try proposal(request(project, hunks: [hunk(4), correction], selected: [0, 1]))
        #expect(included.phrases[0].text == "We accurately explain the better idea with precise useful examples.")
        #expect(included.phrases[0].sourceWords[1].text == "carefully")
        #expect(VoiceLabSpeechContextPlan.propose(request(project, hunks: [hunk(4), correction]), envelope: envelope(project))
                == .refused(.insufficientSpeech(hunkIndex: 0)))
    }

    @Test func cutsEventsAndPauseCutsCannotBeResurrectedAsContext() throws {
        for variant in 0..<5 {
            var project = try fixture()
            var hunks = [hunk(4)]
            var selected = [0]
            switch variant {
            case 0: project.edits.cutWordIds = ["w7"]
            case 1: hunks.append(hunk(7, kind: .cut)); selected.append(1)
            case 2: hunks.append(hunk(7, kind: .cut))
            case 3: project.transcript?.words[7].kind = .event
            default:
                project.edits.pauseThresholdSeconds = 0.15
                project.edits.cutPauseIds = ["pause-after-w6"]
            }
            #expect(VoiceLabSpeechContextPlan.propose(request(project, hunks: hunks, selected: selected), envelope: envelope(project))
                    == .refused(.insufficientSpeech(hunkIndex: 0)))
        }
    }

    @Test func unrelatedCutChoiceStaysOutsideTheProposedReplacement() throws {
        let project = try fixture()
        for selected in [[0], [0, 1]] {
            let plan = try proposal(request(project, hunks: [hunk(4), hunk(34, kind: .cut)], selected: selected))
            #expect(plan.phrases.count == 1)
            #expect(!plan.phrases[0].hunk.sourceWordIds.contains("w34"))
            #expect(plan.request.selectedHunkIndices == selected)
            #expect(plan.request.project.edits.cutWordIds.isEmpty)
        }
    }

    @Test func incompleteSentenceAtPassageOrClipBoundaryNeverBorrowsOutsideApproval() throws {
        var project = try fixture()
        let approved = (3...9).map { "w\($0)" }
        #expect(VoiceLabSpeechContextPlan.propose(request(project, approved: approved), envelope: envelope(project))
                == .refused(.insufficientSpeech(hunkIndex: 0)))
        project.edits.clips = [ClipRange(id: "short", startWordId: "w3", endWordId: "w9")]
        #expect(VoiceLabSpeechContextPlan.propose(request(project, scope: .clip("short")), envelope: envelope(project))
                == .refused(.insufficientSpeech(hunkIndex: 0)))
        project.edits.clips = [ClipRange(id: "sentence", startWordId: "w0", endWordId: "w9")]
        let plan = try proposal(request(project, scope: .clip("sentence")))
        let bounds = try clipTimes(project.transcript!.words, startIndex: 0, endIndex: 9)
        #expect(plan.phrases[0].window.start >= bounds.start)
        #expect(plan.phrases[0].window.end <= bounds.end)
        #expect(project.edits.clips[0].endWordId == "w9")
    }

    @Test func shortSentenceCanGrowByWholeAdjacentSentencesOnly() throws {
        var project = try fixture()
        project.transcript?.words[1].text = "carefully."
        let plan = try proposal(request(project, hunks: [hunk(0, text: "They")]))
        #expect(plan.phrases[0].sourceWords.map(\.id) == (0...9).map { "w\($0)" })
        #expect(plan.phrases[0].text.hasPrefix("They carefully. explain"))
        #expect(plan.phrases[0].text.hasSuffix("examples."))
    }

    @Test func overlapReturnsMergeReviewInsteadOfDoubleApplying() throws {
        let project = try fixture()
        let input = request(project, hunks: [hunk(3), hunk(6)], selected: [0, 1], expanding: [0, 1])
        #expect(VoiceLabSpeechContextPlan.propose(input, envelope: envelope(project)) == .mergeRequired(hunkIndices: [0, 1]))
        #expect(VoiceLabSpeechContextPlan.propose(request(project, hunks: input.reviewHunks), envelope: envelope(project))
                == .refused(.insufficientSpeech(hunkIndex: 0)))
    }

    @Test func otherPreparedPhraseIsPreservedAndItsEntireTextCountsTowardBudget() throws {
        let project = try fixture()
        let otherWindow = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: envelope(project),
                                                          firstWordId: "w34", lastWordId: "w34")
        let other = VoiceLabSpeechContextPlan.Reservation(hunkIndices: [1], text: "different", window: otherWindow)
        let input = request(project, hunks: [hunk(4), hunk(34, text: "different")], selected: [0, 1], reservations: [other])
        let plan = try proposal(input)
        #expect(plan.phrases.count == 1)
        #expect(plan.request.reservations == [other])
        #expect(plan.totalVoiceTokenCount == 11)
        let collision = VoiceLabSpeechContextPlan.Reservation(hunkIndices: [1], text: "different", window: plan.phrases[0].window)
        #expect(VoiceLabSpeechContextPlan.propose(request(project, hunks: input.reviewHunks, selected: [0, 1], reservations: [collision]),
                                                envelope: envelope(project)) == .mergeRequired(hunkIndices: [0, 1]))
    }

    @Test func requestCapAndExpandedTotalBudgetRemainHardLimits() throws {
        let project = try fixture()
        #expect(VoiceLabSpeechContextPlan.propose(request(project, cap: 20), envelope: envelope(project))
                == .refused(.insufficientSpeech(hunkIndex: 0)))
        var small = project
        small.transcript?.words = Array(project.transcript!.words.prefix(20))
        #expect(VoiceLabSpeechContextPlan.propose(request(small), envelope: envelope(small)) == .refused(.budget))
        let hunks = [hunk(4), hunk(34)]
        #expect(VoiceLabSpeechContextPlan.propose(request(project, hunks: hunks, selected: [0, 1], expanding: [0, 1]),
                                                envelope: envelope(project)) == .refused(.budget))
    }

    @Test func silenceDoesNotCountAsSpeechAndMissingTimingDoesNotGetGuessed() throws {
        var project = try fixture()
        let originals = try #require(project.transcript).words
        project.transcript?.words = originals.map { original in
            var word = original
            word.end = word.start + 0.04
            return word
        }
        let approved = (0...9).map { "w\($0)" }
        #expect(VoiceLabSpeechContextPlan.propose(request(project, approved: approved), envelope: envelope(project))
                == .refused(.insufficientSpeech(hunkIndex: 0)))
        project.transcript?.words[4].start = .nan
        #expect(VoiceLabSpeechContextPlan.propose(request(project), envelope: envelope(project)) == .refused(.invalidInput))
    }

    @Test func calibratedMinimumRequiresAnActualSourceWordOfMargin() throws {
        for duration in [0.5, 0.49] {
            var project = try fixture()
            project.media.source.durationSeconds = 121
            let originals = try #require(project.transcript).words
            project.transcript?.words = originals.enumerated().map { index, original in
                var word = original
                word.text = index == 6 || index % 10 == 9 ? "word." : "word"
                word.start = Double(index)
                word.end = word.start + duration
                word.rawStart = word.start; word.rawEnd = word.end
                return word
            }
            let input = request(project, hunks: [hunk(4, text: "term")], approved: (0...6).map { "w\($0)" })
            let outcome = VoiceLabSpeechContextPlan.propose(input, envelope: envelope(project))
            if duration == 0.5 {
                guard case .reviewRequired(let plan) = outcome else { Issue.record("Expected exact 3.5-second boundary"); continue }
                #expect(plan.phrases[0].estimatedSpeechSeconds == 3.5)
                #expect(plan.phrases[0].marginSeconds == 0.5)
            } else {
                #expect(outcome == .refused(.insufficientSpeech(hunkIndex: 0)))
            }
        }
    }

    @Test func speakerChangesAndUntimedInsertionsAreNotSafeContext() throws {
        var project = try fixture()
        project.transcript?.words[7].speaker = "guest"
        #expect(VoiceLabSpeechContextPlan.propose(request(project), envelope: envelope(project))
                == .refused(.insufficientSpeech(hunkIndex: 0)))
        let insertion = VoiceLabDiffHunk(kind: .voice, sourceWordIds: [], newTokens: ["extra"], correctedTexts: [],
            absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 4, sourceEndIndex: 4, anchorSeconds: 3)
        #expect(VoiceLabSpeechContextPlan.propose(request(project, hunks: [insertion]), envelope: envelope(project))
                == .refused(.invalidInput))
    }

    @Test func byteExactCorrectionsInvalidateEvenCanonicallyEquivalentReviewText() throws {
        var project = try fixture()
        project.edits.corrections["w1"] = "caf\u{e9}"
        let plan = try proposal(request(project))
        var differentBytes = project
        differentBytes.edits.corrections["w1"] = "cafe\u{301}"
        #expect(project == differentBytes)
        #expect(throws: VoiceLabSpeechContextPlan.Failure.staleReview) {
            try plan.validateCurrent(request(differentBytes), envelope: envelope(project))
        }
    }

    @Test func freshReviewAndExactLongerQuoteBindingAreMandatory() throws {
        let project = try fixture(), original = request(project), plan = try proposal(request(project))
        try plan.validateCurrent(original, envelope: envelope(project))
        #expect(throws: VoiceLabSpeechContextPlan.Failure.staleReview) {
            try plan.validateCurrent(request(project, revision: "review-8"), envelope: envelope(project))
        }
        var changed = project
        changed.edits.corrections["w90"] = "changed"
        #expect(throws: VoiceLabSpeechContextPlan.Failure.staleReview) {
            try plan.validateCurrent(request(changed), envelope: envelope(project))
        }
        #expect(throws: VoiceLabSpeechContextPlan.Failure.staleReview) {
            try plan.validateCurrent(request(project, hunks: [hunk(4, text: "different")]), envelope: envelope(project))
        }
        #expect(throws: VoiceLabSpeechContextPlan.Failure.staleReview) {
            try plan.validateCurrent(request(project, approved: (0...9).map { "w\($0)" }), envelope: envelope(project))
        }
        var wrongSource = project
        wrongSource.media.source.contentKey = String(repeating: "f", count: 64)
        #expect(throws: VoiceLabSpeechContextPlan.Failure.staleReview) {
            try plan.validateCurrent(request(wrongSource), envelope: envelope(project))
        }
        let phrase = plan.phrases[0]
        let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: original.scope, window: phrase.window)
        let input = VoiceLabTakeInput(text: phrase.text, modelID: "eleven_v3", recordID: "consent", language: "en", seed: 7,
            contentKey: original.contentKey, source: VoiceLabSourceExcerpt(whole: []), sourceEnvelope: envelope(project),
            sourceSampleRate: project.media.source.audio!.sampleRate, items: project.transcript!.words, window: phrase.window,
            incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, providerConsent: true)
        try plan.validateQuotedInputs([input], current: original, envelope: envelope(project))
        let short = VoiceLabTakeInput(text: "better", modelID: input.modelID, recordID: input.recordID, language: input.language,
            seed: input.seed, contentKey: input.contentKey, source: [], sourceSampleRate: input.sourceSampleRate, items: input.items,
            window: input.window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        #expect(throws: VoiceLabSpeechContextPlan.Failure.quoteBinding) {
            try plan.validateQuotedInputs([short], current: original, envelope: envelope(project))
        }
        var shifted = input.window
        shifted.startSample += 1
        let wrongWindow = VoiceLabTakeInput(text: input.text, modelID: input.modelID, recordID: input.recordID,
            language: input.language, seed: input.seed, contentKey: input.contentKey, source: VoiceLabSourceExcerpt(whole: []),
            sourceEnvelope: envelope(project), sourceSampleRate: input.sourceSampleRate, items: input.items, window: shifted,
            incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, providerConsent: true)
        #expect(throws: VoiceLabSpeechContextPlan.Failure.quoteBinding) {
            try plan.validateQuotedInputs([wrongWindow], current: original, envelope: envelope(project))
        }
    }
}
