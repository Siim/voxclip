#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

@Suite("Explicit Rewrite speech context review", .serialized, .offlineFixtures)
@MainActor struct RewriteSpeechContextReviewTests {
    private struct Fixture {
        let project: Project
        let envelope: AudioEnvelope
        let record: VoiceConsentRecord
    }

    @MainActor private final class Fake {
        var quoted: [[VoiceLabTakeInput]] = []
        var quotedIndices: [[Int]] = []
        var approvals: [UUID] = []
        var executed: [Int] = []
        var published: [VoiceLabTakeInput] = []
        var discarded = 0
        var insufficient: Set<Int> = []
        var current = true
        var beforePrepare: (() -> Void)?
        let record: VoiceConsentRecord

        init(record: VoiceConsentRecord) { self.record = record }

        func backend(projectID: String) -> ClipTakePlan.Backend {
            var backend = ClipTakePlan.Backend(runs: [])
            backend.prepare = { [self] inputs, indices, candidates in
                beforePrepare?()
                quoted.append(inputs); quotedIndices.append(indices)
                return try VoiceLabTakeBatch(windows: inputs.map { input in
                    let takes = (0..<candidates).map { index in
                        VoiceLabTakeQuote(index: index, seed: input.seed &+ UInt32(index),
                            synthesis: Self.quote(.textToSpeech), qa: Self.quote(.speechToText))
                    }
                    return .init(input: input, quote: .init(id: UUID(), takes: takes, preparedAt: Date()))
                })
            }
            backend.approve = { [self] batch, _ in approvals.append(batch.id) }
            backend.execute = { [self] batch, offset, phrase, progress in
                executed.append(phrase)
                let window = batch.windows[offset]
                let quote = try #require(window.quote.takes.first)
                let row: VoiceLabTakeRow
                if insufficient.contains(phrase) {
                    row = .init(id: quote.synthesis.requestID, index: 0, seed: quote.seed,
                        failure: .qa([.insufficientGeneratedSpeech]), quote: quote, accepted: [quote.synthesis.requestID])
                } else { row = Self.row(input: window.input, quote: quote, record: record) }
                await progress([row])
                return .init(rows: [row], end: .completed)
            }
            backend.discard = { [self] in discarded += 1 }
            backend.invalidate = {}
            backend.retire = { _, _ in }
            backend.scratch = { _, _ in nil }
            backend.publish = { [self] _, row, input, date in
                published.append(input)
                let fit = try #require(row.audio?.fit.plan)
                let rate = Double(input.sourceSampleRate)
                let length = Double(fit.outputFrames) / rate
                let assetID = UUID().uuidString.lowercased()
                let asset = VoiceLabAsset(id: assetID, file: try VoiceLabAssetNaming.file(projectId: projectID, assetId: assetID, extension: "wav"),
                    sha256: String(repeating: "a", count: 64), durationSeconds: length + 2,
                    sampleRate: input.sourceSampleRate, createdAt: date)
                let chunk = VoiceLabChunk(sourceStartSample: fit.windowStartSample, sourceEndSample: fit.windowEndSample,
                    requestId: try #require(row.receipt?.requestID.uuidString), seed: row.seed, assetId: asset.id,
                    assetSha256: asset.sha256, assembledStartFrame: Int64(input.sourceSampleRate),
                    assembledEndFrame: Int64(input.sourceSampleRate) + fit.outputFrames)
                return (.init(assets: [asset], audio: .init(assetId: asset.id, trimStart: 1, trimEnd: 1 + length),
                    outDuration: length, words: fit.words, chunks: [chunk]), record)
            }
            return backend
        }

        private static func quote(_ operation: VoiceLabOperation) -> VoiceLabQuote {
            .init(id: UUID(), operation: operation, requestID: UUID(),
                estimate: .init(provider: "elevenlabs", operation: operation.rawValue, units: 1,
                    unit: "fake-only", usd: Decimal(string: "0.01"), basis: "inert test quote"),
                region: .default, endpoint: "v1/text-to-speech/fixtureOwnVoice/with-timestamps", languageMode: .explicit("en"), fingerprint: "fake")
        }

        private static func row(input: VoiceLabTakeInput, quote: VoiceLabTakeQuote, record: VoiceConsentRecord) -> VoiceLabTakeRow {
            let window = input.window
            let rate = input.sourceSampleRate
            let count = window.endSample - window.startSample
            let duration = Double(count) / Double(rate)
            let tokens = input.text.split(separator: " ").map(String.init)
            let words = tokens.enumerated().map { index, text in
                VoiceLabWord(text: text, start: (Double(index) + 0.1) * duration / Double(tokens.count),
                    end: (Double(index) + 0.9) * duration / Double(tokens.count), synthetic: true)
            }
            let fit = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0),
                outgoing: .init(padFrames: 0, borrowedSamples: 0), trimStartFrame: 0, trimEndFrame: count,
                windowStart: window.start, windowEnd: window.end, windowStartSample: window.startSample,
                windowEndSample: window.endSample, outputFrames: count, words: words)
            let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: quote.synthesis.endpoint, modelID: input.modelID,
                voiceID: record.voiceId, requestID: quote.synthesis.requestID, providerRequestID: nil, spendWarning: nil)
            let audio = VoiceLabTakeAudio(sampleRate: rate, trimmed: [], mixed: [], patchRange: 0..<0, seams: [],
                gainDb: 0, roomTone: .init(sourceStartSample: 0, sourceEndSample: Int64(rate / 2), gainDb: 0), fit: .exact(fit))
            return .init(id: receipt.requestID, index: 0, seed: quote.seed, receipt: receipt, audio: audio,
                qa: .init(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10, speakerScore: 1), failures: []),
                score: 1, quote: quote)
        }
    }

    private func fixture() throws -> Fixture {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.voiceLab.segments = []; project.voiceLab.assets = []; project.edits = ProjectEdits()
        project.media.source.durationSeconds = 113
        project.transcript?.durationSeconds = 113
        project.media.source.audio?.sampleRate = 24_000
        let sentence = ["We", "thoughtfully", "contextualize", "the", "unmodified", "implementation", "with", "comprehensive", "multidisciplinary", "demonstrations."]
        project.transcript?.words = (0..<160).map { index in
            let start = 0.5 + Double(index) * 0.7
            return TimedWord(id: "w\(index)", text: sentence[index % 10], start: start, end: start + 0.5,
                rawStart: start, rawEnd: start + 0.5, conf: 0.97, speaker: "owner")
        }
        let record = try JSONDecoder().decode(VoiceConsentRecord.self,
            from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        return .init(project: project, envelope: .init(sampleRate: 24_000, levels: Array(repeating: 0.001, count: 11_300)), record: record)
    }

    private func hunk(_ range: ClosedRange<Int>, text: [String], kind: VoiceLabDiffHunkKind = .voice) -> VoiceLabDiffHunk {
        .init(kind: kind, sourceWordIds: range.map { "w\($0)" }, newTokens: text,
            correctedTexts: kind == .textOnly ? text : [], absorbedItemIds: [], bridgeWordIds: [],
            sourceStartIndex: range.lowerBound, sourceEndIndex: range.upperBound + 1, anchorSeconds: nil)
    }

    private func request(_ fixture: Fixture, hunks: [VoiceLabDiffHunk], selected: [Int], target: Int,
                         approved: [String]? = nil, scope: VoiceLabOutputScope = .full) throws -> VoiceLabSpeechContextPlan.Request {
        let placed = try RewriteSpeechContextReview.placedPhrases(project: fixture.project, scope: scope,
            envelope: fixture.envelope, hunks: selected.map { hunks[$0] })
        let targetPhrase = try #require(placed.first { $0.indices.map { selected[$0] } == [target] })
        return .init(project: fixture.project, scope: scope,
            approvedSourceWordIDs: approved ?? fixture.project.transcript!.words.map(\.id), reviewHunks: hunks,
            selectedHunkIndices: selected, expandingHunkIndices: [target],
            reservations: placed.filter { $0.id != targetPhrase.id }.map {
                .init(hunkIndices: $0.indices.map { selected[$0] }, text: $0.text, window: $0.window)
            }, revision: "fake-review-7", contentKey: fixture.project.media.source.contentKey, maximumRequestCharacters: 5_000)
    }

    private func review(_ request: VoiceLabSpeechContextPlan.Request, fixture: Fixture) throws -> RewriteSpeechContextReview {
        let placed = try RewriteSpeechContextReview.placedPhrases(project: fixture.project, scope: request.scope,
            envelope: fixture.envelope, hunks: request.selectedHunkIndices.map { request.reviewHunks[$0] })
        let target = try #require(placed.first { $0.indices.map { request.selectedHunkIndices[$0] } == request.expandingHunkIndices })
        return try .propose(request: request, envelope: fixture.envelope, targetPhraseID: target.id,
            selectedOriginalIndices: request.selectedHunkIndices)
    }

    private func input(_ phrase: ClipTakePlan.Phrase, fixture: Fixture,
                       silenceWindow: VoiceLabWindow? = nil) throws -> VoiceLabTakeInput {
        let silence = try VoiceLabWindowPlanner.lendableSilence(project: fixture.project, scope: .full, window: silenceWindow ?? phrase.window)
        return .init(text: phrase.text, modelID: "fake-model", recordID: fixture.record.id, language: "en", seed: 7,
            contentKey: fixture.project.media.source.contentKey, source: .init(whole: []), sourceEnvelope: fixture.envelope,
            sourceSampleRate: 24_000, items: RewriteSession.corrected(fixture.project), window: phrase.window,
            incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, providerConsent: true)
    }

    private func plan(_ fixture: Fixture, hunks: [VoiceLabDiffHunk], fake: Fake,
                      review: RewriteSpeechContextReview? = nil) throws -> ClipTakePlan {
        let made = try ClipTakePlan(project: fixture.project, scope: .full, envelope: fixture.envelope, hunks: hunks,
            makeInput: { phrase in try input(phrase, fixture: fixture) }, isCurrent: { fake.current })
        if let review {
            made.bindSpeechContext({ inputs in
                try review.validateQuotedInputs(inputs, current: review.plan.request, envelope: fixture.envelope)
            }, current: { fake.current })
        }
        made.connect(fake.backend(projectID: fixture.project.id))
        return made
    }

    @Test func reviewAndCancellationBuyNothingAndDoNotChangeUndo() throws {
        let fixture = try fixture(), fake = Fake(record: fixture.record)
        let original = fixture.project
        let request = try request(fixture, hunks: [hunk(4...4, text: ["better"])], selected: [0], target: 0)
        let review = try review(request, fixture: fixture)
        let hunks = try review.replacingHunks(current: request, envelope: fixture.envelope)
        let prepared = try ClipTakePlan.preparePlan(project: fixture.project, scope: .full, envelope: fixture.envelope, hunks: hunks)
        try review.validatePreparedPhrases(prepared, current: request, envelope: fixture.envelope)
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: original, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: fixture.envelope, connector: nil)
        session.takePlan = try plan(fixture, hunks: hunks, fake: fake, review: review)
        session.speechContextReview = review
        session.cancelSpeechContextReview()
        #expect(session.speechContextReview == nil)
        #expect(fake.quoted.isEmpty && fake.approvals.isEmpty && fake.executed.isEmpty && fake.published.isEmpty)
        #expect(editor.project == original && editor.undoSteps == 0 && !undo.canUndo)
    }

    @Test func shortPhraseCanStayShortBeforeAnyQuote() throws {
        let fixture = try fixture(), fake = Fake(record: fixture.record)
        let plan = try plan(fixture, hunks: [hunk(4...4, text: ["better"])], fake: fake)
        #expect(plan.phrases.count == 1 && plan.phrases[0].text == "better")
        #expect(plan.phrases[0].estimatedVoicedSeconds.map { $0 < 3 } == true)
        #expect(fake.quoted.isEmpty && fake.executed.isEmpty)
    }

    @Test func expandedQuoteIsExactOnlyTargetsTheRequestedSlotAndNeedsPaidApproval() async throws {
        let fixture = try fixture(), fake = Fake(record: fixture.record)
        let sibling = hunk(20...29, text: ["We", "thoughtfully", "contextualize", "the", "different", "implementation", "with", "comprehensive", "multidisciplinary", "demonstrations."])
        let all = [hunk(114...114, text: [], kind: .cut), hunk(4...4, text: ["better"]), sibling]
        let request = try request(fixture, hunks: all, selected: [1, 2], target: 1)
        let review = try review(request, fixture: fixture)
        #expect(review.ordinal == 2 && review.targetPhraseID == 0)
        let hunks = try review.replacingHunks(current: request, envelope: fixture.envelope)
        #expect(hunks.count == 2 && hunks[1] == sibling && all[0].kind == .cut)
        let plan = try plan(fixture, hunks: hunks, fake: fake, review: review)
        try review.validatePreparedPhrases(plan.phrases, current: request, envelope: fixture.envelope)
        await plan.prepareSpeechContext(phrase: review.targetPhraseID)
        #expect(fake.quotedIndices == [[0]] && fake.quoted[0].count == 1)
        #expect(fake.quoted[0][0].text.utf8.elementsEqual(review.phrase.text.utf8))
        #expect(fake.quoted[0][0].window == review.phrase.window)
        #expect(fake.approvals.isEmpty && fake.executed.isEmpty)
        let approval = try #require(plan.approvalID)
        await plan.start(approved: false, quoteID: approval)
        await plan.start(approved: true, quoteID: UUID())
        #expect(fake.approvals.isEmpty && fake.executed.isEmpty)
        await plan.start(approved: true, quoteID: approval)
        #expect(fake.approvals == [approval] && fake.executed == [0])
        #expect(plan.phrases[1].takes.isEmpty)
        #expect(plan.chooseVideo(.source, phrase: 0))
        let acceptance = try await plan.acceptance()
        #expect(acceptance.segments.count == 1)
        #expect(acceptance.segments[0].text?.new == review.phrase.text)
        #expect(acceptance.segments[0].replace.firstWordId == review.phrase.window.firstWordId)
        #expect(acceptance.segments[0].replace.lastWordId == review.phrase.window.lastWordId)
        #expect(fake.published.count == 1 && fake.published[0].window == review.phrase.window)
    }

    @Test func excludedChangesClipEdgesAndOverlapsNeverGetSilentlyAbsorbed() throws {
        let fixture = try fixture()
        let target = hunk(4...4, text: ["better"])
        let excluded = hunk(7...7, text: ["precise"], kind: .textOnly)
        let blocked = try request(fixture, hunks: [target, excluded], selected: [0], target: 0)
        #expect(throws: (any Error).self) { try review(blocked, fixture: fixture) }
        var project = fixture.project
        project.edits.clips = [.init(id: "narrow", startWordId: "w2", endWordId: "w8")]
        let clipped = Fixture(project: project, envelope: fixture.envelope, record: fixture.record)
        let clipRequest = try request(clipped, hunks: [target], selected: [0], target: 0,
            approved: (2...8).map { "w\($0)" }, scope: .clip("narrow"))
        #expect(throws: (any Error).self) { try review(clipRequest, fixture: clipped) }
        #expect(project.edits.clips[0].startWordId == "w2" && project.edits.clips[0].endWordId == "w8")
        let neighbor = hunk(7...7, text: ["precise"])
        let overlapping = VoiceLabSpeechContextPlan.Request(project: fixture.project, scope: .full,
            approvedSourceWordIDs: fixture.project.transcript!.words.map(\.id), reviewHunks: [target, neighbor],
            selectedHunkIndices: [0, 1], expandingHunkIndices: [0], reservations: [
                .init(hunkIndices: [1], text: "precise", window: try VoiceLabWindowPlanner.place(project: fixture.project,
                    scope: .full, envelope: fixture.envelope, firstWordId: "w7", lastWordId: "w7"))
            ], revision: "review", contentKey: fixture.project.media.source.contentKey, maximumRequestCharacters: 5_000)
        #expect(throws: (any Error).self) {
            try RewriteSpeechContextReview.propose(request: overlapping, envelope: fixture.envelope,
                targetPhraseID: 0, selectedOriginalIndices: [0, 1])
        }
    }

    @Test func staleReviewAndWrongTextOrWindowAreRejectedBeforeQuotes() async throws {
        let fixture = try fixture(), fake = Fake(record: fixture.record)
        let request = try request(fixture, hunks: [hunk(4...4, text: ["better"])], selected: [0], target: 0)
        let review = try review(request, fixture: fixture)
        let stale = VoiceLabSpeechContextPlan.Request(project: request.project, scope: request.scope,
            approvedSourceWordIDs: request.approvedSourceWordIDs, reviewHunks: request.reviewHunks,
            selectedHunkIndices: [], expandingHunkIndices: request.expandingHunkIndices, reservations: [],
            revision: "changed", contentKey: request.contentKey, maximumRequestCharacters: 5_000)
        #expect(throws: VoiceLabSpeechContextPlan.Failure.staleReview) {
            try review.replacingHunks(current: stale, envelope: fixture.envelope)
        }
        let hunks = try review.replacingHunks(current: request, envelope: fixture.envelope)
        let prepared = try ClipTakePlan.preparePlan(project: fixture.project, scope: .full, envelope: fixture.envelope, hunks: hunks)
        for variant in 0..<2 {
            var window = review.phrase.window
            if variant == 1 { window.endSample += 1 }
            let bad = ClipTakePlan.Phrase(id: 0, indices: [0], text: variant == 0 ? "better" : review.phrase.text, window: window)
            #expect(throws: (any Error).self) { try review.validatePreparedPhrases([bad], current: request, envelope: fixture.envelope) }
            let invalid = try input(bad, fixture: fixture, silenceWindow: review.phrase.window)
            #expect(throws: VoiceLabSpeechContextPlan.Failure.quoteBinding) {
                try review.validateQuotedInputs([invalid], current: request, envelope: fixture.envelope)
            }
        }
        let plan = try ClipTakePlan(project: fixture.project, scope: .full, envelope: fixture.envelope, hunks: hunks,
            makeInput: { _ in try input(.init(id: 0, indices: [0], text: "better", window: prepared[0].window), fixture: fixture) })
        plan.bindSpeechContext({ inputs in try review.validateQuotedInputs(inputs, current: request, envelope: fixture.envelope) }, current: { true })
        plan.connect(fake.backend(projectID: fixture.project.id))
        await plan.prepare()
        #expect(fake.quoted.isEmpty && fake.approvals.isEmpty && fake.executed.isEmpty)
    }

    @Test func replacingFailedSlotDiscardsShortApprovalPreservesOtherTakeAndUndo() async throws {
        let fixture = try fixture(), fake = Fake(record: fixture.record)
        let target = hunk(2...7, text: ["accurately", "contextualize", "this", "significantly", "better", "approach"])
        let sibling = hunk(20...29, text: ["We", "thoughtfully", "contextualize", "the", "different", "implementation", "with", "comprehensive", "multidisciplinary", "demonstrations."])
        let request = try request(fixture, hunks: [target, sibling], selected: [0, 1], target: 0)
        let review = try review(request, fixture: fixture)
        let plan = try plan(fixture, hunks: [target, sibling], fake: fake)
        fake.insufficient = [0]
        await plan.prepare()
        await plan.start(approved: true)
        #expect(plan.phrases[0].selected == nil && plan.phrases[1].selected != nil)
        let retained = try #require(plan.phrases[1].selectedID)
        #expect(plan.chooseVideo(.source, phrase: 1))
        let siblingRows = plan.phrases[1].takes.map(\.row)
        await plan.prepareAnother(phrase: 0)
        let oldApproval = try #require(plan.approvalID)
        let approvalsBeforeReview = fake.approvals.count
        plan.bindSpeechContext({ inputs in try review.validateQuotedInputs(inputs, current: request, envelope: fixture.envelope) },
            current: { fake.current })
        let hunks = try review.replacingHunks(current: request, envelope: fixture.envelope)
        try await plan.replaceSpeechContext(hunks: hunks, envelope: fixture.envelope, phrase: 0)
        let fresh = try #require(plan.approvalID)
        #expect(fresh != oldApproval && fake.quotedIndices.last == [0])
        #expect(fake.approvals.count == approvalsBeforeReview)
        #expect(plan.phrases[1].selectedID == retained && plan.phrases[1].videoChoice == .source)
        #expect(plan.phrases[1].takes.map(\.row) == siblingRows)
        let executionsBefore = fake.executed.count
        await plan.start(approved: true, quoteID: oldApproval)
        #expect(fake.executed.count == executionsBefore)
        fake.insufficient = []
        await plan.start(approved: true, quoteID: fresh)
        #expect(fake.executed.suffix(1) == [0] && fake.executed.filter { $0 == 1 }.count == 1)
        #expect(plan.chooseVideo(.source, phrase: 0))
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: fixture.project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: fixture.envelope, connector: nil)
        editor.rewrite = session; session.takePlan = plan
        let original = editor.project
        undo.beginUndoGrouping()
        let accepted = await session.acceptTakes()
        undo.endUndoGrouping()
        #expect(accepted && editor.project.voiceLab.segments.count == 2)
        #expect(editor.project.voiceLab.segments[0].text?.new == review.phrase.text)
        #expect(editor.project.transcript?.words == original.transcript?.words)
        #expect(undo.canUndo)
        undo.undo()
        #expect(editor.project == original)
    }

    @Test func reviewCurrentnessIsCheckedAgainAfterQuoteAndBeforeApproval() async throws {
        let fixture = try fixture(), fake = Fake(record: fixture.record)
        let request = try request(fixture, hunks: [hunk(4...4, text: ["better"])], selected: [0], target: 0)
        let review = try review(request, fixture: fixture)
        let hunks = try review.replacingHunks(current: request, envelope: fixture.envelope)
        let plan = try plan(fixture, hunks: hunks, fake: fake, review: review)
        await plan.prepareSpeechContext(phrase: 0)
        let approval = try #require(plan.approvalID)
        fake.current = false
        await plan.start(approved: true, quoteID: approval)
        #expect(fake.approvals.isEmpty && fake.executed.isEmpty && fake.published.isEmpty)
        #expect(!plan.stillCurrent)
    }
}
#endif
