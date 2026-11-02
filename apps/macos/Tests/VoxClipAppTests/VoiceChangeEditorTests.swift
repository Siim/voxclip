#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

@Suite("Voice change scope and atomic editor acceptance", .serialized, .offlineFixtures)
@MainActor struct VoiceChangeEditorTests {
    private func fixture() throws -> Project {
        let shared = try SharedResources.locate()
        return try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
    }
    private func envelope(_ project: Project) -> AudioEnvelope {
        let rate = Double(project.media.source.audio?.sampleRate ?? 1_000)
        let total = Int(EditingPrimitives.jsRound(project.media.source.durationSeconds * rate))
        let frame = Int(EditingPrimitives.jsRound(rate * 0.01))
        return AudioEnvelope(sampleRate: rate, levels: Array(repeating: 0.1, count: total / frame))
    }
    private func sourceProject() throws -> Project {
        var project = try fixture()
        project.voiceLab.segments = []
        return project
    }
    @Test func passagePinsOnlySelectedWordsWithClampedPointOneSecondMargins() throws {
        let project = try sourceProject(), words = try #require(project.transcript?.words)
        let first = try #require(words.firstIndex { $0.id == "w4" })
        let last = try #require(words.firstIndex { $0.id == "w5" })
        let snapshot = try VoiceChangeSession.makeSnapshot(project: project, scope: .selection(first...last), envelope: envelope(project))
        #expect(snapshot.window.firstWordId == "w4" && snapshot.window.lastWordId == "w5")
        #expect(snapshot.window.start >= words[first - 1].end && snapshot.window.start >= words[first].start - 0.1)
        #expect(snapshot.window.end <= words[last + 1].start && snapshot.window.end <= words[last].end + 0.1)
        #expect(snapshot.outputScope == .clip("clip-main") && snapshot.project == project)
        #expect(snapshot.window.leftSeam.fadeSamples == 12 && snapshot.window.rightSeam.fadeSamples == 12)
    }
    @Test func fullTakeCoversTheSourceEdgesAndNeverSilentlyUsesTheClip() throws {
        var project = try sourceProject()
        #expect(throws: (any Error).self) {
            try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: envelope(project))
        }
        project.edits.activeClipId = nil
        let snapshot = try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: envelope(project))
        #expect(snapshot.outputScope == .full && snapshot.window.startSample == 0 && snapshot.window.endSample == 7_000)
        #expect(snapshot.window.leftSeam.kind == .none && snapshot.window.rightSeam.kind == .none)
    }
    @Test func partialTailUsesOnlyCompleteSourceEnvelopeBuckets() throws {
        var project = try sourceProject()
        project.edits.activeClipId = nil
        project.media.source.durationSeconds = 10.005
        project.media.source.audio = MediaAudio(sampleRate: 48_000, channels: 1)
        let complete = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.1, count: 1_000))
        let snapshot = try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: complete)
        #expect(snapshot.window.endSample == 480_240 && snapshot.envelope.levels.count == 1_000)
        let displayTail = AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.1, count: 1_001))
        #expect(throws: VoiceLabError.invalidInput) {
            _ = try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: displayTail)
        }
    }

    @Test func cutsCleanAudioAndExistingReplacementsRefuseBeforeAnyQuote() throws {
        var project = try sourceProject(); project.edits.activeClipId = nil; project.edits.cutWordIds = ["w4"]
        #expect(throws: (any Error).self) {
            try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: envelope(project))
        }
        project.edits.cutWordIds = []; project.voiceLab.cleanAudio = VoiceLabCleanAudio(mode: .on, assetId: "asset-one", mix: 1)
        #expect(throws: (any Error).self) {
            try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: envelope(project))
        }
        project = try fixture(); project.edits.activeClipId = nil
        #expect(throws: (any Error).self) {
            try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: envelope(project))
        }
    }
    @Test(arguments: [48_000, 88_200, 96_000, 192_000])
    func chunksRespectBothNativeRateByteAndDurationLimits(rate: Int) throws {
        var project = try sourceProject()
        project.edits.activeClipId = nil; project.media.source.durationSeconds = 610
        project.media.source.audio = MediaAudio(sampleRate: rate, channels: 1)
        project.transcript?.durationSeconds = 610
        project.transcript?.words = (0..<610).map { index in
            TimedWord(id: "chunk-word-\(index)", text: "word", start: Double(index) + 0.1, end: Double(index) + 0.5)
        }
        let snapshot = try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: envelope(project))
        let ranges = try VoiceChangeSession.chunkRanges(snapshot)
        #expect(ranges.count >= 3 && ranges.first?.lowerBound == 0 && ranges.last?.upperBound == 610 * Int64(rate))
        for (index, range) in ranges.enumerated() {
            let upload = try VoiceChangeSession.uploadRange(body: range, index: index, count: ranges.count, snapshot: snapshot)
            #expect(upload.count <= 290 * rate)
            #expect(44 + 2 * upload.count < 50_000_000)
            #expect(upload.lowerBound <= range.lowerBound && upload.upperBound >= range.upperBound)
            let halfFade = Int64(EditingPrimitives.jsRound(0.020 * Double(rate))) / 2
            #expect(upload.lowerBound == (index == 0 ? range.lowerBound : range.lowerBound - halfFade))
            #expect(upload.upperBound == (index + 1 == ranges.count ? range.upperBound : range.upperBound + halfFade))
        }
        for (left, right) in zip(ranges, ranges.dropFirst()) { #expect(left.upperBound == right.lowerBound) }
    }
    @Test func passageUploadContainsRealOuterHandlesWhileBodyCoverageIsUnchanged() throws {
        let project = try sourceProject(), words = try #require(project.transcript?.words)
        let first = try #require(words.firstIndex { $0.id == "w4" }), last = try #require(words.firstIndex { $0.id == "w5" })
        let snapshot = try VoiceChangeSession.makeSnapshot(project: project, scope: .selection(first...last), envelope: envelope(project))
        let body = snapshot.window.startSample..<snapshot.window.endSample
        let upload = try VoiceChangeSession.uploadRange(body: body, index: 0, count: 1, snapshot: snapshot)
        #expect(upload == (body.lowerBound - 6)..<(body.upperBound + 6))
        #expect(body == snapshot.window.startSample..<snapshot.window.endSample)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
    func passageEntryNeverSilentlyIncludesUnselectedWordsOrSelectedPauses() throws {
        let project = try sourceProject(), model = editor(project)
        defer { model.close() }
        model.selectedWordIDs = ["w4", "w6"]
        #expect(model.voiceChangeSelection == nil)
        model.selectedWordIDs = ["w4", "w5"]
        #expect(model.voiceChangeSelection != nil)
        model.selectedPauseIDs = ["inert-selected-pause"]
        #expect(model.voiceChangeSelection == nil)
    }
    @Test func noPauseForALongChunkRefusesInsteadOfInventingAWordCut() throws {
        var project = try sourceProject()
        project.edits.activeClipId = nil; project.media.source.durationSeconds = 610
        project.transcript?.durationSeconds = 610
        project.transcript?.words = [TimedWord(id: "long-word", text: "word", start: 0, end: 610)]
        let snapshot = try VoiceChangeSession.makeSnapshot(project: project, scope: .fullTake, envelope: envelope(project))
        #expect(throws: (any Error).self) { try VoiceChangeSession.chunkRanges(snapshot) }
    }

    private func reviewPair() throws -> (VoiceChangeSession.Snapshot, VoiceChangeSession.Review) {
        var reviewed = try fixture()
        var segment = reviewed.voiceLab.segments[0], candidate = reviewed.voiceLab.segments[0].candidates[0]
        var recipe = try #require(candidate.recipe)
        recipe.words = nil; recipe.roomTone = nil; recipe.audio.stretch = 1
        recipe.provenance.endpoint = "v1/voice-changer/fixture-voice"
        candidate.recipe = recipe
        segment.kind = .voiceChanger; segment.text = nil; segment.words = nil
        segment.audio = recipe.audio; segment.provenance = recipe.provenance; segment.candidates = [candidate]
        reviewed.voiceLab.segments = [segment]
        var original = reviewed; original.voiceLab.segments = []
        let words = try #require(original.transcript?.words)
        let first = try #require(words.firstIndex { $0.id == segment.replace.firstWordId })
        let last = try #require(words.firstIndex { $0.id == segment.replace.lastWordId })
        let snapshot = try VoiceChangeSession.makeSnapshot(project: original, scope: .selection(first...last), envelope: envelope(original))
        let contract = try VoiceLabRenderContract.prepare(reviewed, scope: snapshot.outputScope, labelPosition: .topRight)
        return (snapshot, VoiceChangeSession.Review(project: reviewed, contract: contract, media: nil, play: {}, stop: {}, verify: {}))
    }
    private func editor(_ project: Project) -> EditorModel {
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        model.editTimestampForTests = Date(timeIntervalSince1970: 1_800_000_000)
        return model
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
    func acceptanceIsOneNativeUndoAndRedoAndRoundTripsTheRecipe() throws {
        let (snapshot, review) = try reviewPair(), model = editor(snapshot.project)
        defer { model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let previous = model.project, steps = model.undoSteps
        undo.beginUndoGrouping(); try model.commitVoiceChange(review, snapshot: snapshot); undo.endUndoGrouping()
        let changed = model.project
        #expect(model.undoSteps == steps + 1 && changed.voiceLab == review.project.voiceLab)
        #expect(changed.transcript == previous.transcript && changed.edits == previous.edits && changed.media == previous.media)
        undo.undo(); #expect(model.project == previous)
        undo.redo(); #expect(model.project == changed)
        #expect(try JSONProjectStore.decode(ProjectJSON.encode(changed)) == changed)
        undo.removeAllActions()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
    func staleProjectOrRevokedProviderConsentCreatesNoUndoEntry() throws {
        let (snapshot, review) = try reviewPair(), model = editor(snapshot.project)
        defer { model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(false)
        #expect(throws: (any Error).self) { try model.commitVoiceChange(review, snapshot: snapshot) }
        #expect(!undo.canUndo && model.project == snapshot.project)
        model.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        var changed = model.project; changed.title = "Changed during review"
        model.document.replaceProject(changed)
        #expect(throws: (any Error).self) { try model.commitVoiceChange(review, snapshot: snapshot) }
        #expect(!undo.canUndo && model.project == changed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
    func v4MotionSurvivesAcceptanceUndoAndProjectReopen() throws {
        let (base, baseReview) = try reviewPair()
        var original = try ContextDemoProject.upgradeToV4(base.project)
        original.motionCues = [MotionCue(id: "motion-voice-test", clipID: "clip-main", sourceStart: 2.5, sourceEnd: 3.2,
            keyframes: [MotionKeyframe(progress: 0), MotionKeyframe(progress: 1, scale: 1.08)])]
        var changed = original; changed.voiceLab = baseReview.project.voiceLab
        let snapshot = try VoiceChangeSession.makeSnapshot(project: original, scope: base.scope, envelope: envelope(original))
        let contract = try VoiceLabRenderContract.prepare(changed, scope: snapshot.outputScope, labelPosition: .topRight)
        let review = VoiceChangeSession.Review(project: changed, contract: contract, media: nil, play: {}, stop: {}, verify: {})
        let model = editor(original); defer { model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        undo.beginUndoGrouping(); try model.commitVoiceChange(review, snapshot: snapshot); undo.endUndoGrouping()
        #expect(model.project.schemaVersion == 4 && model.project.motionCues == original.motionCues)
        #expect(model.project.contextDemo == original.contextDemo)
        let reopened = try JSONProjectStore.decode(ProjectJSON.encode(model.project))
        #expect(reopened.schemaVersion == 4 && reopened.motionCues == original.motionCues && reopened.voiceLab == changed.voiceLab)
        undo.undo(); #expect(model.project == original)
        undo.removeAllActions()
    }
}
#endif
