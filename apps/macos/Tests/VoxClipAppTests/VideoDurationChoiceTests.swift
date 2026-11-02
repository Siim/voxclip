#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private struct VideoDurationTestKeys: KeyProvider {
    func key(for provider: String) async throws -> String? {
        Issue.record("Duration choices must not request credentials or call a provider")
        return nil
    }
}

@Suite("Explicit video duration choice", .serialized, .offlineFixtures)
@MainActor struct VideoDurationChoiceTests {
    private func source() throws -> Project {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.voiceLab.segments = []; project.voiceLab.assets = []
        project.edits = ProjectEdits()
        project.media.source.durationSeconds = 101
        project.media.source.audio?.sampleRate = 24_000
        project.transcript?.durationSeconds = 101
        project.transcript?.words = (0..<100).map { index in
            let start = 0.2 + Double(index)
            return TimedWord(id: "w\(index)", text: "source", start: start, end: start + 0.8)
        }
        return project
    }

    private func plan(current: @escaping @MainActor () -> Bool = { true }) throws -> ClipTakePlan {
        let project = try source()
        let hunks = [20...27, 60...67].map { indices in
            VoiceLabDiffHunk(kind: .voice, sourceWordIds: indices.map { "w\($0)" },
                newTokens: EditingPrimitives.splitWords("This comprehensive demonstration preserves reviewed pronunciation naturally."), correctedTexts: [],
                absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: indices.lowerBound, sourceEndIndex: indices.upperBound + 1, anchorSeconds: nil)
        }
        let plan = try ClipTakePlan(project: project, scope: .full,
            envelope: AudioEnvelope(sampleRate: 24_000, levels: [Float](repeating: 0.01, count: 10_100)), hunks: hunks,
            makeInput: { _ in Issue.record("A video choice must not decode or regenerate speech"); throw ClipTakePlan.Failure.stale }, isCurrent: current)
        plan.showFixture("ready")
        return plan
    }

    @Test func eachPassageRequiresANewExplicitChoiceWithoutChangingTakeOrSpend() throws {
        let plan = try plan()
        let ids = plan.phrases.map(\.selectedID), spend = plan.spent, quote = plan.approvalID
        #expect(plan.phrases.count == 2 && !plan.canAccept)
        #expect(plan.phrases.allSatisfy { $0.videoChoice == nil })
        #expect(plan.chooseVideo(.source, phrase: 0))
        #expect(!plan.canAccept && plan.phrases[1].videoChoice == nil)
        #expect(plan.chooseVideo(.source, phrase: 1) && plan.canAccept)
        #expect(plan.phrases.map(\.selectedID) == ids && plan.spent == spend && plan.approvalID == quote)
        #expect(plan.select(take: try #require(ids[0]), phrase: 0))
        #expect(plan.phrases[0].videoChoice == .source && plan.canAccept)
        let nextReview = try self.plan()
        #expect(nextReview.phrases.allSatisfy { $0.videoChoice == nil } && !nextReview.canAccept)
    }

    @Test func staleChoicesCannotEnableAcceptanceOrChangeReviewedText() throws {
        var current = true
        let plan = try plan(current: { current })
        let texts = plan.phrases.map(\.text), windows = plan.phrases.map(\.window)
        #expect(plan.chooseVideo(.source, phrase: 0) && plan.chooseVideo(.source, phrase: 1))
        current = false
        #expect(!plan.canAccept && !plan.chooseVideo(.source, phrase: 0))
        #expect(!plan.select(take: try #require(plan.phrases[0].selectedID), phrase: 0))
        #expect(plan.phrases.map(\.text) == texts && plan.phrases.map(\.window) == windows)
    }

    @Test func failedOrMissingChoicesCannotPublishAnyPartialAcceptance() async throws {
        let plan = try plan()
        #expect(plan.chooseVideo(.source, phrase: 0))
        await #expect(throws: ClipTakePlan.Failure.noSelection) { try await plan.acceptance() }
        #expect(!plan.canAccept && plan.phrases[1].videoChoice == nil)
        #expect(!plan.chooseVideo(.lipsync, phrase: 1) && !plan.chooseVideo(.zoomCover, phrase: 1))
    }

    private func row(changed: Bool = false, index: Int = 0) -> VoiceLabTakeRow {
        let duration = changed ? 4.4 : 4.0
        let frames = Int64(EditingPrimitives.jsRound(duration * 24_000))
        let fit = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: frames, windowStart: 1, windowEnd: 5, windowStartSample: 24_000, windowEndSample: 120_000,
            outputFrames: frames, words: [.init(text: "Reviewed passage", start: 0.1, end: duration - 0.1, synthetic: true)])
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0, roomTone: nil,
            fit: changed ? .changedDuration(fit, naturalOut: duration, residualSeconds: duration - 4) : .exact(fit))
        return VoiceLabTakeRow(id: UUID(), index: index, seed: UInt32(index), audio: audio,
            qa: .init(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10, speakerScore: 0.9), failures: []), score: 0.9)
    }

    private func input() -> VoiceLabTakeInput {
        VoiceLabTakeInput(text: "Reviewed passage", modelID: "fixture-model", recordID: "fixture-record", language: "en", seed: 7,
            contentKey: "reviewed-source", source: [], sourceSampleRate: 24_000, items: [],
            window: .init(firstWordId: "w1", lastWordId: "w2", leftBridgeWordIds: [], rightBridgeWordIds: [],
                start: 1, end: 5, startSample: 24_000, endSample: 120_000,
                leftSeam: .init(kind: .gap, time: 1, sample: 24_000, fadeSamples: 480),
                rightSeam: .init(kind: .gap, time: 5, sample: 120_000, fadeSamples: 480)),
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
    }

    private func session(current: @escaping @MainActor () -> Bool = { true }) -> RewriteGenerationSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let run = VoiceLabTakeRun(client: ElevenLabsVoiceLab(keys: VideoDurationTestKeys(), region: .default), store: store, speaker: .unavailable,
            storage: VoiceLabTakeStorage(projectId: UUID().uuidString.lowercased(), paidRoot: root.appendingPathComponent("paid"), scratchRoot: root.appendingPathComponent("scratch")),
            dispatchIfCurrent: { _, _ in Issue.record("Duration choices must not dispatch paid work"); throw VoiceLabError.consentRequired }, inputsAreCurrent: { true })
        return RewriteGenerationSession(run: run, inputsAreCurrent: current)
    }

    @Test func changingSelectedTakeClearsChoiceButReselectingSameTakeDoesNot() {
        let session = session(), first = row(), second = row(index: 1)
        let input = input()
        session.review(.init(rows: [first, second], end: .completed), input: input)
        #expect(!session.readyToAccept && session.videoChoice == nil)
        #expect(session.chooseVideo(.source) && session.readyToAccept)
        let quote = session.quote
        #expect(session.select(first.id) && session.videoChoice == .source)
        #expect(session.select(second.id) && session.selectedID == second.id && session.videoChoice == nil && !session.readyToAccept)
        #expect(session.input == input && session.quote == quote)
        #expect(session.chooseVideo(.source) && session.select(first.id) && session.videoChoice == nil)
    }

    @Test func changingReviewInputsClearsAcceptanceWithoutQuotingOrRegenerating() {
        var current = true
        let session = session(current: { current }), row = row()
        session.review(.init(rows: [row], end: .completed), input: input())
        #expect(session.chooseVideo(.source) && session.readyToAccept)
        current = false
        #expect(!session.readyToAccept && !session.chooseVideo(.source))
        current = true
        session.inputsChanged(prepareNewQuote: false)
        #expect(session.videoChoice == nil && !session.readyToAccept && session.selectedID == row.id && session.quote == nil)
    }

    @Test func changedDurationStaysSelectableButCannotBeAcceptedWithoutPreparedRenderer() {
        let session = session(), row = row(changed: true)
        session.review(.init(rows: [row], end: .completed), input: input())
        #expect(row.selectable && session.select(row.id) && session.selectedID == row.id)
        #expect(session.videoAvailability.unchangedReason?.contains("cannot be shortened") == true)
        #expect(!session.chooseVideo(.source) && !session.chooseVideo(.retimed) && !session.readyToAccept)
        #expect(session.videoAvailability.changedReason?.contains("not prepared") == true)
        let structurallyAvailable = VideoDurationChoiceAvailability(row: row, sourceSampleRate: 24_000, rendererReady: true)
        #expect(structurallyAvailable.allows(.retimed) && !structurallyAvailable.allows(.source))
    }

    @Test func missingPreparationHookFailsClosedBeforeAnyMediaWork() async throws {
        let project = try source()
        await #expect(throws: VoiceLabProjectError.videoModeUnsupported) {
            _ = try await VideoDurationRenderReadiness.prepare(project, scope: .full, using: nil)
        }
    }

    @Test(arguments: [false, true])
    func wrongProjectOrMissingInputFactoryCannotReachComposition(missingInput: Bool) async throws {
        let project = try source()
        var other = project
        other.title = "Not the reviewed project"
        let prepared = try VoiceLabRenderContract.prepare(other, scope: .full, labelPosition: .topRight)
        let input = try VoiceLabRenderInput(project: other, scope: .full, labelPosition: .topRight,
            paidRoot: URL(fileURLWithPath: "/unopened-paid-assets"), prepared: prepared)
        let request = RenderRequest(sourceURL: URL(fileURLWithPath: "/unopened-source.mov"),
            plan: EditPlan(sampleRate: 24_000, totalSamples: 2_424_000), output: .init(size: .init(width: 1920, height: 1080), fps: 30, videoBitrate: 4_000_000),
            voiceLab: missingInput ? nil : input)
        var calls = 0
        await #expect(throws: VoiceLabProjectError.staleRenderContract) {
            _ = try await VideoDurationRenderReadiness.prepare(project, scope: .full, using: { _, _ in calls += 1; return request })
        }
        #expect(calls == 1)
    }

    @Test func multiPassageDurationAndFreeChangesRemainOneNativeUndo() throws {
        let shared = try SharedResources.locate()
        var fixture = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/touching-render-v3.voxclip")))
        fixture.voiceLab.voices?[0].status = .active
        var segments = fixture.voiceLab.segments
        #expect(segments.count == 2)
        var recipe = try #require(segments[0].candidates[0].recipe)
        recipe.outDuration = 0.75; recipe.audio.stretch = 1; recipe.audio.trimEnd = 0.85
        recipe.chunks[0].assembledEndFrame = 20_400
        recipe.video.mode = .zoomCover; recipe.video.outputSamples = 750; recipe.video.retimeFactor = 700 / 750.0
        recipe.video.zoom = 1.12; recipe.video.faceX = 0.5; recipe.video.faceY = 0.5
        segments[0].candidates = [segments[0].candidates[0]]
        segments[0].candidates[0].recipe = recipe
        segments[0].outDuration = recipe.outDuration; segments[0].audio = recipe.audio
        var source = fixture
        source.voiceLab.segments = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: source, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let original = editor.project
        undo.beginUndoGrouping()
        try editor.applyVoiceLab(segments, assets: [], voice: try #require(fixture.voiceLab.voices?.first), scope: .fullTake,
            localCommands: [.correct(id: "w1", text: "Reviewed correction")])
        undo.endUndoGrouping()
        let accepted = editor.project
        #expect(accepted.voiceLab.segments.map(\.selectedCandidateIndex) == segments.map(\.selectedCandidateIndex))
        #expect(accepted.edits.corrections["w1"] == "Reviewed correction" && accepted.transcript == original.transcript)
        let prepared = try VoiceLabRenderContract.prepare(accepted, scope: .full, labelPosition: .topRight)
        #expect(prepared.selectedSegmentRecipes.count == 2 && prepared.outputPlan.outputSamples == 7_050)
        #expect(prepared.selectedSegmentRecipes[0].piece.outputEndSample == prepared.selectedSegmentRecipes[1].piece.outputStartSample)
        undo.undo()
        #expect(editor.project == original && !undo.canUndo)
        undo.redo()
        #expect(editor.project == accepted)
    }
}
#endif
