#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

@MainActor private final class ContextDemoRecordingProbe: ContextDemoRecording {
    var reason: String?
    var prepareFailure: ContextDemoCaptureError?
    var holdPreparation = false
    var holdRecording = false
    var prepared: [ContextDemoCaptureRequest] = []
    var started: [ContextDemoCaptureRequest] = []
    var discarded: [ContextDemoAsset] = []
    var finishes = 0
    var cancels = 0
    var accessChecks = 0
    var currentness: (@MainActor () -> Bool)?
    var preparationRelease: TestContinuation<Void>?
    var recordingRelease: TestContinuation<Void>?
    private var projectID = ""
    private var captureIndex = 0

    func unavailableReason(for kind: ContextDemoTargetKind) -> String? { reason }
    func checkAvailability() { accessChecks += 1; reason = nil }
    func targets() async throws -> [ContextDemoCaptureTarget] { [] }
    func prepare(target: ContextDemoTarget, window: ContextDemoCaptureTarget?, duration: Double,
                 document: ContextDemoDocument) async throws -> ContextDemoCaptureRequest {
        projectID = document.projectId
        let request = ContextDemoCaptureRequest(id: "request-\(prepared.count)", planId: document.planId,
            revision: document.revision, target: target, durationSeconds: duration,
            actions: [ContextDemoReviewedAction(id: "open", summary: "Open only the reviewed page.")])
        prepared.append(request)
        if holdPreparation { await withTestDeadline { preparationRelease = $0 } }
        if let prepareFailure { throw prepareFailure }
        return request
    }
    func record(_ request: ContextDemoCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> (asset: ContextDemoAsset, url: URL) {
        currentness = isCurrent
        started.append(request)
        if holdRecording { await withTestDeadline { recordingRelease = $0 } }
        captureIndex += 1
        let id = "capture-\(captureIndex)"
        let asset = ContextDemoAsset(id: id, requestId: request.id, target: request.target,
            relativePath: try ContextDemoAsset.relativePath(projectId: projectID, assetId: id),
            sha256: String(repeating: "a", count: 64), durationSeconds: 2, pixelWidth: 1280,
            pixelHeight: 720, byteSize: 1024, createdAt: Date(timeIntervalSince1970: 1_000))
        return (asset, try verifiedURL(for: asset))
    }
    func finish() { finishes += 1 }
    func cancel() { cancels += 1 }
    func discard(_ asset: ContextDemoAsset) { discarded.append(asset) }
    func verifiedURL(for asset: ContextDemoAsset) throws -> URL {
        URL(fileURLWithPath: "/tmp/voxclip-context-demo-test-assets", isDirectory: true).appendingPathComponent(asset.relativePath)
    }
    func releasePreparation() { preparationRelease?.resume(); preparationRelease = nil }
    func releaseRecording() { recordingRelease?.resume(); recordingRelease = nil }
}

@MainActor
@Suite("Context demo session and undo", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil), .offlineFixtures)
struct ContextDemoSessionTests {
    private func open() async throws -> (EditorModel, ContextDemoSession, ContextDemoRecordingProbe, UndoManager) {
        _ = NSApplication.shared
        let app = AppModel()
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        await app.shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let model = try #require(app.shell.editor)
        model.mediaResolved = true
        model.refresh()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let backend = ContextDemoRecordingProbe()
        let session = ContextDemoSession(model: model, backend: backend)
        session.setURL("https://example.test/demo")
        model.contextDemoSession = session
        return (model, session, backend, undo)
    }
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition())
    }
    private func result(_ session: ContextDemoSession) async throws {
        session.review()
        try await eventually { session.phase == .ready }
        session.start()
        try await eventually { session.phase == .result }
    }
    private func transaction(_ undo: UndoManager, _ body: () -> Bool) -> Bool {
        undo.beginUndoGrouping()
        let result = body()
        undo.endUndoGrouping()
        return result
    }

    @Test func clipReviewUsesFullNarrationAndMapsTheLocalPlayhead() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        var project = model.project
        project.edits.clips.append(ClipRange(id: "context-scope", startWordId: "w4", endWordId: "w5", origin: .manual))
        model.document.replaceProject(project)
        model.refresh()
        model.app.shell.choose(.clip("context-scope"), byClick: false)
        let scoped = try #require(model.renderTimeline)
        let full = try RenderCallerInputs.timeline(project: model.project)
        model.playhead = min(0.1, scoped.duration / 2)
        let expectedPosition = full.mapTime(scoped.sourceTime(model.playhead))
        #expect(expectedPosition > model.playhead)
        let draft = try model.contextDemoDraftDocument()
        #expect(draft.narration == (try ContextDemoNarrationSnapshot(timeline: full)))
        #expect(draft.isCurrent(project: model.project, timeline: full))
        session.review()
        try await eventually { session.phase == .ready }
        #expect(abs(session.editedStart - expectedPosition) <= 1 / draft.narration.sampleRate)
        #expect(session.document?.narration == draft.narration)
        #expect(backend.started.isEmpty && !undo.canUndo)
        do {
            undo.beginUndoGrouping()
            defer { undo.endUndoGrouping() }
            #expect(try model.commitContextDemoDocument(draft, expected: model.contextDemoSnapshot(), name: "Add demonstration"))
        }
        #expect(model.project.contextDemo?.isCurrent(project: model.project, timeline: full) == true)
    }

    @Test func openingAndReviewNeverRecordOrChangeTheProject() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        let original = model.project
        #expect(backend.prepared.isEmpty && backend.started.isEmpty && !undo.canUndo)
        session.review()
        try await eventually { session.phase == .ready }
        #expect(backend.prepared.count == 1 && backend.started.isEmpty)
        #expect(session.request?.target.kind == .webPage && session.request?.window == nil)
        #expect(session.request?.actions.first?.summary == "Open only the reviewed page.")
        #expect(model.project == original && !undo.canUndo && session.canStart)
    }

    @Test func unavailableCapabilityHasAReasonAndCannotStart() async throws {
        let (model, session, backend, _) = try await open()
        defer { model.close() }
        backend.reason = "Screen Recording permission has not been granted."
        #expect(session.unavailableReason == backend.reason)
        session.review()
        session.start()
        #expect(!session.canReview && !session.canStart && backend.prepared.isEmpty && backend.started.isEmpty)
    }

    @Test func firstUseChecksAccessOnlyAfterTheExplicitClickAndDoesNotRecord() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        backend.reason = "Screen Recording access has not been checked."
        #expect(!session.canReview && backend.accessChecks == 0)
        session.checkCaptureAccess()
        #expect(backend.accessChecks == 1 && session.canReview)
        #expect(backend.prepared.isEmpty && backend.started.isEmpty && !undo.canUndo)
        #expect(session.message?.contains("Nothing has started") == true)
    }

    @Test func sourceKindURLAndDurationChangesInvalidateTheReviewedStart() async throws {
        let (model, session, backend, _) = try await open()
        defer { model.close() }
        session.review()
        try await eventually { session.phase == .ready }
        session.setURL("https://example.test/other")
        session.start()
        #expect(session.request == nil && !session.canStart && backend.started.isEmpty)
        session.review()
        try await eventually { session.phase == .ready }
        session.setCaptureSeconds(12)
        #expect(session.phase == .choosing && !session.canStart)
        session.chooseKind(.desktopApp)
        #expect(!session.canReview && session.inputReason?.contains("exact running app window") == true)
    }

    @Test func explicitStartCannotBeRepeatedAndResultRemainsUnplaced() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        let original = model.project
        session.review()
        try await eventually { session.phase == .ready }
        session.start()
        session.start()
        try await eventually { session.phase == .result }
        #expect(backend.started.count == 1 && session.recordedAsset != nil && session.previewURL?.isFileURL == true)
        #expect(model.project == original && !undo.canUndo && session.canApply)
    }

    @Test func cancelDuringPreparationRejectsLateReviewSilently() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        backend.holdPreparation = true
        session.review()
        try await eventually { backend.preparationRelease != nil }
        session.cancel()
        backend.releasePreparation()
        for _ in 0..<20 { await Task.yield() }
        #expect(session.phase == .choosing && session.request == nil && session.message == nil)
        #expect(backend.started.isEmpty && !undo.canUndo && model.project.contextDemo == nil)
    }

    @Test func cancelDuringRecordingDiscardsLateAssetAndNeverPlacesIt() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        backend.holdRecording = true
        session.review()
        try await eventually { session.phase == .ready }
        session.start()
        try await eventually { backend.recordingRelease != nil }
        session.cancel()
        backend.releaseRecording()
        try await eventually { backend.discarded.count == 1 }
        #expect(session.phase == .choosing && session.recordedAsset == nil && session.message == nil)
        #expect(model.project.contextDemo == nil && !undo.canUndo)
    }

    @Test func selectionChangeRejectsStartAndLateCapture() async throws {
        let (model, session, backend, _) = try await open()
        defer { model.close() }
        backend.holdRecording = true
        session.review()
        try await eventually { session.phase == .ready }
        session.start()
        try await eventually { backend.recordingRelease != nil }
        model.selectedWordIDs = [try #require(model.words.first?.id)]
        #expect(backend.currentness?() == false)
        session.followEditor()
        backend.releaseRecording()
        try await eventually { backend.discarded.count == 1 }
        #expect(session.phase == .stale && session.request == nil && model.project.contextDemo == nil)
        #expect(session.message?.contains("source narration") == true)
    }

    @Test func changingProjectThenUndoStillRequiresNewReview() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        session.review()
        try await eventually { session.phase == .ready }
        let snapshot = model.contextDemoSnapshot()
        let id = try #require(model.words.first?.id)
        undo.beginUndoGrouping()
        model.apply(.cutSelection(ids: [id]), name: "Cut narration")
        undo.endUndoGrouping()
        undo.undo()
        #expect(!model.contextDemoIsCurrent(snapshot))
        session.start()
        #expect(backend.started.isEmpty)
        session.followEditor()
        #expect(session.phase == .stale)
    }

    @Test func placementIsOneUndoStepAndPreservesSourceNarration() async throws {
        let (model, session, _, undo) = try await open()
        defer { model.close() }
        let original = model.project
        let steps = model.undoSteps
        try await result(session)
        #expect(transaction(undo, session.apply))
        let placed = try #require(model.project.contextDemo)
        #expect(placed.placements.count == 1 && placed.assets.count == 1 && placed.revision == 1)
        #expect(model.undoSteps == steps + 1 && undo.undoActionName == "Place context demonstration")
        #expect(model.project.media == original.media && model.project.transcript == original.transcript && model.project.edits == original.edits)
        #expect(model.project.schemaVersion == 4)
        undo.undo()
        #expect(model.project.contextDemo == nil && !undo.canUndo && undo.canRedo)
        #expect(model.project.media == original.media && model.project.transcript == original.transcript)
        undo.redo()
        #expect(model.project.contextDemo == placed && !undo.canRedo)
    }

    @Test func trimRemoveAndReplacementAreEachAtomicAndUndoable() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        try await result(session)
        #expect(transaction(undo, session.apply))
        let first = try #require(model.project.contextDemo)
        let id = try #require(first.placements.first?.id)
        session.selectPlacement(id)
        session.setTrim(start: 0.25, end: 1.5, editedStart: 0.5)
        #expect(model.project.contextDemo == first)
        #expect(transaction(undo, session.apply))
        let trimmed = try #require(model.project.contextDemo)
        #expect(trimmed.placements.first?.source == TimeRange(start: 0.25, end: 1.5))
        undo.undo()
        #expect(model.project.contextDemo == first)
        session.followEditor()
        session.selectPlacement(id)
        session.replaceSelected()
        try await result(session)
        #expect(model.project.contextDemo == first)
        #expect(transaction(undo, session.apply))
        let replacement = try #require(model.project.contextDemo)
        #expect(replacement.placements.first?.id == id)
        #expect(replacement.placements.first?.assetId != first.placements.first?.assetId)
        #expect(backend.discarded.isEmpty)
        undo.undo()
        #expect(model.project.contextDemo == first)
        session.followEditor()
        session.selectPlacement(id)
        #expect(transaction(undo, session.removeSelected))
        #expect(model.project.contextDemo?.placements.isEmpty == true)
        undo.undo()
        #expect(model.project.contextDemo == first)
    }

    @Test func invalidTrimNeverMutatesOrCreatesUndoAndCanBeCorrected() async throws {
        let (model, session, _, undo) = try await open()
        defer { model.close() }
        let original = model.project
        try await result(session)
        session.setTrim(start: 1.5, end: 1, editedStart: 0)
        #expect(!session.canApply && !session.apply() && model.project == original && !undo.canUndo)
        session.setTrim(start: 0, end: 1, editedStart: .nan)
        #expect(!session.canApply && !session.apply() && !undo.canUndo)
        session.setTrim(start: 0.25, end: 1.5, editedStart: 0)
        #expect(session.canApply && transaction(undo, session.apply))
    }

    @Test func switchingPanelsPreservesUnplacedDraftButUnchangedTrimHasNoUndo() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        try await result(session)
        let asset = try #require(session.recordedAsset)
        session.cancel()
        #expect(session.phase == .result && session.recordedAsset == asset && session.canApply)
        #expect(transaction(undo, session.apply))
        let document = model.project.contextDemo
        let steps = model.undoSteps
        #expect(!session.canApply && !session.apply())
        #expect(model.project.contextDemo == document && model.undoSteps == steps)
        session.close()
        #expect(backend.discarded.isEmpty)
    }

    @Test func closingDiscardsOnlyUnplacedAssetsAndStopsPendingWork() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        try await result(session)
        let asset = try #require(session.recordedAsset)
        session.close()
        session.close()
        #expect(session.phase == .closed && backend.discarded == [asset] && !undo.canUndo)
        session.start()
        session.review()
        #expect(backend.started.count == 1 && backend.prepared.count == 1)
    }

    @Test func finishIsExplicitAndRecordingFailureIsNotSuccess() async throws {
        let (model, session, backend, undo) = try await open()
        defer { model.close() }
        backend.prepareFailure = .encoderUnavailable
        session.review()
        try await eventually { session.phase == .failed }
        session.start()
        session.finishRecording()
        #expect(backend.started.isEmpty && backend.finishes == 0 && model.project.contextDemo == nil && !undo.canUndo)
        #expect(session.message?.contains("encoder") == true)
        backend.prepareFailure = nil
        backend.holdRecording = true
        session.review()
        try await eventually { session.phase == .ready }
        session.start()
        try await eventually { backend.recordingRelease != nil }
        session.finishRecording()
        #expect(backend.finishes == 1)
        session.cancel()
        backend.releaseRecording()
        try await eventually { backend.discarded.count == 1 }
    }
}
@MainActor
@Suite("Context demo browser/capture lifetime", .serialized, .offlineFixtures)
struct ContextDemoWebCaptureLifetimeTests {
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition())
    }

    @Test func invalidatedBrowserCancelsCaptureBeforeStoppingAndCannotBecomeSuccess() {
        var events: [String] = []
        let lifetime = ContextDemoWebCaptureLifetime(cancelCapture: { events.append("capture-cancel") },
            stopBrowser: { events.append("browser-stop") }, closeBrowser: { events.append("browser-close") })
        lifetime.actionsFinished()
        lifetime.invalidate()
        lifetime.cancel()
        lifetime.actionsFinished()
        #expect(lifetime.isCancelled && (lifetime.browserFailure as? ContextDemoBrowserError) == .targetUnavailable)
        #expect(events == ["capture-cancel", "browser-stop"])
        lifetime.closeAfterCaptureDrained()
        lifetime.closeAfterCaptureDrained()
        #expect(events == ["capture-cancel", "browser-stop", "browser-close"])
    }

    @Test func cancellationKeepsWindowUntilCaptureAndActionsDrain() async throws {
        var events: [String] = []
        var releaseCapture: TestContinuation<Void>?
        var releaseActions: TestContinuation<Void>?
        defer { releaseCapture?.resume(); releaseActions?.resume() }
        let lifetime = ContextDemoWebCaptureLifetime(cancelCapture: { events.append("capture-cancel") },
            stopBrowser: { events.append("browser-stop") }, closeBrowser: { events.append("browser-close") })
        let action = Task { @MainActor in
            await withTestDeadline { releaseActions = $0 }
            events.append("actions-drained")
        }
        lifetime.retainAction(action)
        let operation = Task { @MainActor in
            await withTestDeadline { releaseCapture = $0 }
            events.append("capture-drained")
            await lifetime.drainActions()
            lifetime.closeAfterCaptureDrained()
        }
        try await eventually { releaseCapture != nil && releaseActions != nil }
        lifetime.cancel()
        #expect(action.isCancelled)
        #expect(events == ["capture-cancel", "browser-stop"])
        releaseCapture?.resume()
        releaseCapture = nil
        try await eventually { events.contains("capture-drained") }
        #expect(!events.contains("browser-close"))
        releaseActions?.resume()
        releaseActions = nil
        await operation.value
        #expect(events.first == "capture-cancel" && events.last == "browser-close")
        let closed = try #require(events.firstIndex(of: "browser-close"))
        #expect(try #require(events.firstIndex(of: "capture-drained")) < closed)
        #expect(try #require(events.firstIndex(of: "actions-drained")) < closed)
    }

    @Test func oldLifetimeCleanupNeverClosesTheNextBrowser() async {
        var events: [String] = []
        let old = ContextDemoWebCaptureLifetime(cancelCapture: { events.append("old-capture-cancel") },
            stopBrowser: { events.append("old-browser-stop") }, closeBrowser: { events.append("old-browser-close") })
        let next = ContextDemoWebCaptureLifetime(cancelCapture: { events.append("next-capture-cancel") },
            stopBrowser: { events.append("next-browser-stop") }, closeBrowser: { events.append("next-browser-close") })
        old.cancel()
        await old.drainActions()
        old.closeAfterCaptureDrained()
        old.invalidate()
        #expect(events == ["old-capture-cancel", "old-browser-stop", "old-browser-stop", "old-browser-close"])
        #expect(!next.isCancelled && next.browserFailure == nil)
        next.closeAfterCaptureDrained()
        #expect(events.last == "next-browser-close")
    }
}
#endif
