#if DEBUG
import AppKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

@MainActor private final class DesktopReviewEvents {
    var values: [String] = []
}

@MainActor private final class DesktopReviewClock: ContextDemoCaptureTiming, ContextDemoAccessibilityTiming {
    var now: Double = 100
    func pause() async throws {
        try Task.checkCancellation()
        await Task.yield()
        now += 0.05
    }
    func pause(seconds: Double) async throws {
        try Task.checkCancellation()
        await Task.yield()
        now += seconds
    }
}

@MainActor private final class DesktopReviewDriver: ContextDemoAccessibilityDriving {
    let events: DesktopReviewEvents
    var access = ContextDemoAccessibilityAvailability.available
    var accessChecks = 0
    var inspections: [ContextDemoDesktopIdentity] = []
    var performed: [ContextDemoDesktopAction] = []
    var targetIsCurrent = true
    var actionError: ContextDemoDesktopError?
    var onAction: (() -> Void)?

    init(events: DesktopReviewEvents) { self.events = events }

    func availability() -> ContextDemoAccessibilityAvailability { accessChecks += 1; return access }
    func inspect(identity: ContextDemoDesktopIdentity) throws -> ContextDemoDesktopSnapshot {
        inspections.append(identity)
        return try ContextDemoDesktopSnapshot(identity: identity, controls: [button(), textField(), scrollBar()])
    }
    func validate(snapshot: ContextDemoDesktopSnapshot) throws {
        guard targetIsCurrent else { throw ContextDemoDesktopError.targetUnavailable }
    }
    func perform(_ action: ContextDemoDesktopAction, snapshot: ContextDemoDesktopSnapshot, deadline: Double) throws {
        try validate(snapshot: snapshot)
        if let actionError { throw actionError }
        events.values.append("action")
        performed.append(action)
        onAction?()
    }
    func release() { events.values.append("ax-release") }

    func button() throws -> ContextDemoDesktopControl {
        try control(index: 0, role: "AXButton", identifier: "demo.expand", capabilities: [.focus, .press])
    }
    func textField() throws -> ContextDemoDesktopControl {
        try control(index: 1, role: "AXTextField", identifier: "demo.caption", capabilities: [.focus, .setNonsecretValue])
    }
    func scrollBar() throws -> ContextDemoDesktopControl {
        try control(index: 2, role: "AXScrollBar", identifier: "demo.scroll", capabilities: [.increment, .decrement])
    }
    private func control(index: Int, role: String, identifier: String,
                         capabilities: [ContextDemoDesktopCapability]) throws -> ContextDemoDesktopControl {
        try ContextDemoDesktopControl(childPath: [index], ancestry: [
            ContextDemoDesktopNodeIdentity(role: "AXWindow"),
            ContextDemoDesktopNodeIdentity(role: role, identifier: identifier)
        ], capabilities: capabilities)
    }
}

@MainActor private final class DesktopReviewCaptureBackend: ContextDemoCaptureBackend {
    let events: DesktopReviewEvents
    var candidates = [ContextDemoCaptureTarget(windowID: 42, processID: 321,
        bundleIdentifier: "test.voxclip.Demo", applicationName: "Demo", windowTitle: "Chosen capture window",
        processLaunchDate: Date(timeIntervalSince1970: 10), widthPoints: 640, heightPoints: 480, pixelScale: 1)]
    var state = ContextDemoCaptureSnapshot()
    var begins = 0
    var enumerations = 0
    var onBegin: (() -> Void)?
    var holdEnumeration = false
    var enumerationRelease: CheckedContinuation<Void, Never>?
    var output: URL?

    init(events: DesktopReviewEvents) { self.events = events }
    func availability() -> ContextDemoCaptureAvailability { .available }
    func windows() async throws -> [ContextDemoCaptureTarget] {
        enumerations += 1
        if holdEnumeration { await withCheckedContinuation { enumerationRelease = $0 } }
        return candidates
    }
    func begin(window: ContextDemoCaptureTarget, output: URL, width: Int, height: Int) async throws {
        begins += 1
        self.output = output
        state = ContextDemoCaptureSnapshot()
        try Data([0, 0, 0, 24] + Array("ftypmp42".utf8) + [0, 0, 0, 0]).write(to: output)
        state.startAcknowledged = true
        state.started = true
        events.values.append("capture-started")
        onBegin?()
    }
    func snapshot() -> ContextDemoCaptureSnapshot { state }
    func stop() { state.stopped = true; state.finished = true; events.values.append("capture-stop") }
    func release() { events.values.append("capture-drained") }
    func releaseEnumeration() { enumerationRelease?.resume(); enumerationRelease = nil; holdEnumeration = false }
}

@MainActor private final class DesktopReviewInspector: ContextDemoRecordingInspecting {
    func inspect(_ url: URL) async throws -> ContextDemoRecordingMetadata {
        ContextDemoRecordingMetadata(duration: 1, width: 640, height: 480)
    }
}

@MainActor private final class DesktopReviewServiceProbe: ContextDemoDesktopReviewServing {
    let service: ContextDemoAccessibilityService
    let events: DesktopReviewEvents
    var approvals: [ContextDemoCaptureRequest] = []
    var captures: [ContextDemoCaptureRequest] = []
    var current: (@MainActor () -> ContextDemoDesktopCurrent?)?
    var holdResult = false
    var resultRelease: CheckedContinuation<Void, Never>?
    var result: ContextDemoCaptureResult?

    init(service: ContextDemoAccessibilityService, events: DesktopReviewEvents) {
        self.service = service; self.events = events
    }
    func availability() -> ContextDemoAccessibilityAvailability { service.availability() }
    func inspect(target: ContextDemoCaptureTarget) throws -> ContextDemoDesktopSnapshot { try service.inspect(target: target) }
    func approve(plan: ContextDemoDesktopPlan, currentRequest: ContextDemoCaptureRequest,
                 sourceContentKey: String) throws -> ContextDemoDesktopApproval {
        approvals.append(currentRequest)
        events.values.append("approve")
        return try service.approve(plan: plan, currentRequest: currentRequest, sourceContentKey: sourceContentKey)
    }
    func record(plan: ContextDemoDesktopPlan, approval: ContextDemoDesktopApproval,
                reviewedCapture: ContextDemoReviewedCapture, capture: ContextDemoCaptureService,
                current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws -> ContextDemoCaptureResult {
        captures.append(reviewedCapture.request)
        self.current = current
        let result = try await service.record(plan: plan, approval: approval, reviewedCapture: reviewedCapture,
            capture: capture, current: current)
        self.result = result
        if holdResult { await withCheckedContinuation { resultRelease = $0 } }
        events.values.append("service-drained")
        return result
    }
    func cancel() { events.values.append("cancel-service"); service.cancel() }
    func releaseResult() { resultRelease?.resume(); resultRelease = nil }
}

@MainActor private final class DesktopReviewFixture {
    let model: EditorModel
    let session: ContextDemoSession
    let review: ContextDemoDesktopReviewSession
    let driver: DesktopReviewDriver
    let native: DesktopReviewCaptureBackend
    let service: DesktopReviewServiceProbe
    let capture: ContextDemoCaptureService
    let recorder: ContextDemoLocalRecorder
    let clock: DesktopReviewClock
    let events: DesktopReviewEvents
    let root: URL
    let undo = UndoManager()

    init(model: EditorModel) {
        self.model = model
        events = DesktopReviewEvents()
        clock = DesktopReviewClock()
        driver = DesktopReviewDriver(events: events)
        native = DesktopReviewCaptureBackend(events: events)
        service = DesktopReviewServiceProbe(service: ContextDemoAccessibilityService(driver: driver, timing: clock), events: events)
        review = ContextDemoDesktopReviewSession(service: service)
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("voxclip-desktop-review-\(UUID().uuidString)")
        capture = ContextDemoCaptureService(backend: native, inspector: DesktopReviewInspector(), timing: clock,
            store: ContextDemoAssetStore(rootURL: root))
        recorder = ContextDemoLocalRecorder(capture: capture, desktopReview: review)
        session = ContextDemoSession(model: model, backend: recorder, desktopReview: review)
        model.contextDemoSession = session
        undo.groupsByEvent = false
        model.undoManager = undo
    }
    func close() {
        service.releaseResult()
        native.releaseEnumeration()
        driver.onAction = nil
        native.onBegin = nil
        service.current = nil
        model.close()
        try? FileManager.default.removeItem(at: root)
    }
    func selectWindow() async throws {
        session.chooseKind(.desktopApp)
        session.checkCaptureAccess()
        session.refreshWindows()
        try await eventually { !self.session.loadingWindows }
        session.chooseWindow(42)
    }
    func inspect() {
        session.checkDesktopAccess()
        session.inspectDesktopWindow()
    }
    func ready() async throws {
        try await selectWindow()
        inspect()
        session.appendDesktopAction(.press(try driver.button()))
        session.review()
        try await eventually { self.session.phase == .ready || self.session.phase == .failed }
        try #require(session.phase == .ready)
    }
    func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition())
    }
}

@MainActor
@Suite("Desktop review App bridge", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
struct ContextDemoDesktopReviewTests {
    private func open() async throws -> DesktopReviewFixture {
        _ = NSApplication.shared
        let app = AppModel()
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        await app.shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let model = try #require(app.shell.editor)
        model.mediaResolved = true
        model.refresh()
        return DesktopReviewFixture(model: model)
    }

    @Test func openingSelectingAndRefreshingNeverQueryAccessibility() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        #expect(fixture.driver.accessChecks == 0 && fixture.driver.inspections.isEmpty)
        try await fixture.selectWindow()
        fixture.session.inspectDesktopWindow()
        #expect(fixture.driver.accessChecks == 0 && fixture.driver.inspections.isEmpty)
        fixture.session.checkDesktopAccess()
        #expect(fixture.driver.accessChecks == 1 && fixture.driver.inspections.isEmpty)
        fixture.session.inspectDesktopWindow()
        let target = try #require(fixture.session.selectedWindow)
        #expect(fixture.driver.inspections == [ContextDemoDesktopIdentity(window: target.binding, processLaunchDate: target.processLaunchDate)])
        #expect(fixture.driver.performed.isEmpty && fixture.native.begins == 0 && fixture.service.approvals.isEmpty)
    }

    @Test func deniedAccessNeverInspectsOrBlocksManualReview() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.selectWindow()
        fixture.driver.access = .accessibilityPermissionRequired
        fixture.inspect()
        #expect(!fixture.review.canInspect && fixture.driver.inspections.isEmpty)
        #expect(fixture.review.message?.contains("No prompt") == true)
        fixture.session.review()
        try await fixture.eventually { fixture.session.phase == .ready }
        #expect(fixture.service.approvals.isEmpty && fixture.native.begins == 0)
        #expect(fixture.session.request?.actions.contains(where: { $0.id == "manual-interactions" }) == true)
    }

    @Test func actualCaptureReviewGetsExactDigestBoundRequestAndNeverApprovesEarly() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        let plan = try #require(fixture.review.plan)
        #expect(fixture.session.request == plan.request)
        #expect(plan.request.actions.first?.summary.contains(plan.digest) == true)
        #expect(plan.request.actions.first?.summary.contains(ContextDemoDesktopPlan.reviewWarning) == true)
        #expect(plan.request.actions.dropFirst().map(\.summary) == plan.actions.map(\.reviewDescription))
        #expect(fixture.native.enumerations >= 2 && fixture.native.begins == 0)
        #expect(fixture.service.approvals.isEmpty && fixture.driver.performed.isEmpty)
        let stripped = ContextDemoCaptureRequest(id: plan.request.id, planId: plan.request.planId,
            revision: plan.request.revision, target: plan.request.target, durationSeconds: plan.request.durationSeconds,
            window: plan.request.window)
        await #expect(throws: ContextDemoDesktopError.stalePlan) {
            try await fixture.recorder.recordDesktop(stripped) {
                ContextDemoDesktopCurrent(request: stripped, sourceContentKey: fixture.model.project.media.source.contentKey)
            }
        }
        await #expect(throws: ContextDemoDesktopError.stalePlan) {
            try await fixture.recorder.recordDesktop(plan.request) {
                ContextDemoDesktopCurrent(request: plan.request, sourceContentKey: "changed-source")
            }
        }
        #expect(fixture.service.approvals.isEmpty && fixture.native.begins == 0)
    }

    @Test func explicitStartCapturesBeforeActionsThenPlacesOneUndoableVerifiedResult() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        let original = fixture.model.project
        try await fixture.ready()
        let request = try #require(fixture.session.request)
        fixture.session.start()
        try await fixture.eventually { fixture.session.phase == .result || fixture.session.phase == .failed }
        try #require(fixture.session.phase == .result)
        #expect(fixture.service.approvals == [request] && fixture.service.captures == [request])
        let started = try #require(fixture.events.values.firstIndex(of: "capture-started"))
        let acted = try #require(fixture.events.values.firstIndex(of: "action"))
        let drained = try #require(fixture.events.values.firstIndex(of: "capture-drained"))
        #expect(started < acted && acted < drained && fixture.driver.performed.count == 1)
        #expect(!fixture.review.isDraining && fixture.native.begins == 1)
        let asset = try #require(fixture.session.recordedAsset)
        #expect(asset.requestId == request.id && asset.target == request.target)
        #expect(try fixture.capture.verifiedURL(for: asset) == fixture.session.previewURL)
        fixture.undo.beginUndoGrouping()
        let applied = fixture.session.apply()
        fixture.undo.endUndoGrouping()
        #expect(applied && fixture.model.project.contextDemo?.placements.count == 1)
        #expect(fixture.model.project.media == original.media && fixture.model.project.transcript == original.transcript)
        #expect(fixture.undo.undoActionName == "Place context demonstration")
        fixture.undo.undo()
        #expect(fixture.model.project.contextDemo == nil && fixture.undo.canRedo)
    }

    @Test func manualSelectedWindowStillRecordsWithoutAnActionPlan() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.selectWindow()
        fixture.session.review()
        try await fixture.eventually { fixture.session.phase == .ready }
        #expect(fixture.review.plan == nil && fixture.session.canStart)
        fixture.session.start()
        try await fixture.eventually { fixture.native.begins == 1 }
        fixture.session.finishRecording()
        try await fixture.eventually { fixture.session.phase == .result }
        #expect(fixture.service.approvals.isEmpty && fixture.driver.inspections.isEmpty && fixture.driver.performed.isEmpty)
        #expect(fixture.session.recordedAsset != nil)
    }

    @Test func changedSelectedWindowRevokesPlanWithoutInspectingTheReplacement() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        fixture.session.chooseWindow(nil)
        fixture.session.start()
        #expect(fixture.review.plan == nil && fixture.review.snapshot == nil && !fixture.review.usesActions)
        #expect(fixture.session.request == nil && fixture.driver.inspections.count == 1)
        #expect(fixture.native.begins == 0 && fixture.service.approvals.isEmpty)
    }

    @Test func reusedWindowIDWithChangedLaunchIdentityInvalidatesOnRefresh() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        let old = try #require(fixture.native.candidates.first)
        fixture.native.candidates = [ContextDemoCaptureTarget(windowID: old.windowID, processID: old.processID,
            bundleIdentifier: old.bundleIdentifier, applicationName: old.applicationName, windowTitle: old.windowTitle,
            processLaunchDate: Date(timeIntervalSince1970: 20), widthPoints: 640, heightPoints: 480, pixelScale: 1)]
        fixture.session.refreshWindows()
        try await fixture.eventually { !fixture.session.loadingWindows }
        #expect(fixture.review.snapshot == nil && fixture.session.request == nil && !fixture.session.canStart)
        #expect(fixture.driver.inspections.count == 1 && fixture.native.begins == 0)
    }

    @Test func editorChangeThenUndoStillRejectsStartAndInspectionAuthority() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        let snapshot = fixture.model.contextDemoSnapshot()
        let word = try #require(fixture.model.words.first?.id)
        fixture.undo.beginUndoGrouping()
        fixture.model.apply(.cutSelection(ids: [word]), name: "Cut narration")
        fixture.undo.endUndoGrouping()
        fixture.undo.undo()
        #expect(!fixture.model.contextDemoIsCurrent(snapshot))
        fixture.session.start()
        fixture.session.followEditor()
        #expect(fixture.session.phase == .stale && fixture.review.snapshot == nil)
        #expect(fixture.native.begins == 0 && fixture.service.approvals.isEmpty)
    }

    @Test func staleExactTargetAtStartNeverBeginsCapture() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        fixture.driver.targetIsCurrent = false
        fixture.session.start()
        try await fixture.eventually { fixture.session.phase == .failed }
        #expect(fixture.native.begins == 0 && fixture.driver.performed.isEmpty)
        #expect(fixture.session.message == ContextDemoDesktopError.targetUnavailable.errorDescription)
        #expect(fixture.model.project.contextDemo == nil)
    }

    @Test func changedSelectionDuringCaptureStartPreventsFirstActionAndDrains() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        let word = try #require(fixture.model.words.first?.id)
        fixture.native.onBegin = { fixture.model.selectedWordIDs = [word] }
        fixture.session.start()
        try await fixture.eventually { !fixture.review.isDraining && (fixture.session.phase == .failed || fixture.session.phase == .stale) }
        #expect(fixture.service.current?() == nil && fixture.driver.performed.isEmpty)
        #expect(fixture.session.recordedAsset == nil && fixture.model.project.contextDemo == nil)
        #expect(fixture.events.values.contains("capture-drained"))
        let partial = try #require(fixture.native.output)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func changedEditorBetweenActionsStopsRemainingStepsWithoutPlacingAnything() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.selectWindow()
        fixture.inspect()
        fixture.session.appendDesktopAction(.focus(try fixture.driver.button()))
        fixture.session.appendDesktopAction(.press(try fixture.driver.button()))
        let word = try #require(fixture.model.words.first?.id)
        fixture.driver.onAction = { fixture.model.selectedWordIDs = [word] }
        fixture.session.review()
        try await fixture.eventually { fixture.session.phase == .ready }
        fixture.session.start()
        try await fixture.eventually { fixture.session.phase == .failed || fixture.session.phase == .stale }
        #expect(fixture.driver.performed.count == 1 && !fixture.review.isDraining)
        #expect(fixture.session.recordedAsset == nil && fixture.model.project.contextDemo == nil)
    }

    @Test func actualActionErrorIsInlineAndFailedCaptureIsDiscarded() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        fixture.driver.actionError = .controlUnavailable
        fixture.session.start()
        try await fixture.eventually { fixture.session.phase == .failed }
        #expect(fixture.session.message == ContextDemoDesktopError.controlUnavailable.errorDescription)
        #expect(fixture.session.previewURL == nil && fixture.session.recordedAsset == nil && fixture.model.project.contextDemo == nil)
        #expect(!fixture.review.isDraining && fixture.events.values.contains("capture-drained"))
        let partial = try #require(fixture.native.output)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test(arguments: [false, true]) func lateCancelledOrClosedSuccessIsDiscardedBeforeLifetimeEnds(close: Bool) async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        fixture.service.holdResult = true
        fixture.session.start()
        try await fixture.eventually { fixture.service.resultRelease != nil }
        let result = try #require(fixture.service.result)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(fixture.service.current?()?.request == fixture.session.request)
        #expect(fixture.service.current?()?.sourceContentKey == fixture.model.project.media.source.contentKey)
        if close { fixture.session.close() } else { fixture.session.cancel() }
        #expect(fixture.review.isDraining && !fixture.session.canReview && fixture.service.current?() == nil)
        #expect(!fixture.events.values.contains("service-drained"))
        let drain = Task { @MainActor in
            await fixture.review.drain()
            fixture.events.values.append("app-drained")
        }
        await Task.yield()
        #expect(!fixture.events.values.contains("app-drained"))
        fixture.service.releaseResult()
        await drain.value
        #expect(!fixture.review.isDraining)
        #expect(!FileManager.default.fileExists(atPath: result.url.path))
        #expect(fixture.session.recordedAsset == nil && fixture.model.project.contextDemo == nil)
        #expect(fixture.session.phase == (close ? .closed : .choosing) && fixture.session.message == nil)
        #expect(fixture.events.values.contains("service-drained"))
    }

    @Test func lateCancelledPreparationCannotPublishAReviewOrApprove() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.selectWindow()
        fixture.inspect()
        fixture.session.appendDesktopAction(.press(try fixture.driver.button()))
        fixture.native.holdEnumeration = true
        fixture.session.review()
        try await fixture.eventually { fixture.native.enumerationRelease != nil }
        fixture.session.cancel()
        fixture.native.releaseEnumeration()
        for _ in 0..<50 { await Task.yield() }
        #expect(fixture.session.phase == .choosing && fixture.session.request == nil && fixture.review.plan == nil)
        #expect(fixture.service.approvals.isEmpty && fixture.native.begins == 0 && fixture.session.message == nil)
    }

    @Test func typedDraftLimitsAndEditsRevokeApprovalWithoutReinspection() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        fixture.session.appendDesktopAction(.setNonsecretValue(try fixture.driver.textField(), value: "line\nbreak"))
        #expect(fixture.review.actions.count == 1 && fixture.review.message != nil)
        #expect(fixture.session.request == nil && !fixture.session.canStart)
        fixture.session.appendDesktopAction(.scroll(try fixture.driver.scrollBar(), direction: .increment))
        fixture.session.appendDesktopAction(.setNonsecretValue(try fixture.driver.textField(), value: "Example caption"))
        fixture.session.appendDesktopAction(.pause(milliseconds: 500))
        #expect(fixture.review.actions.count == 4 && fixture.driver.inspections.count == 1)
        fixture.session.setCaptureSeconds(2)
        #expect(fixture.review.actions.count == 4 && fixture.driver.inspections.count == 1)
        fixture.session.review()
        #expect(fixture.session.phase == .failed && fixture.native.begins == 0)
        #expect(fixture.service.approvals.isEmpty)
    }

    @Test func projectBoundDesktopPlanUsesChosenWindowWithoutProjectReadsOrLaunch() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.selectWindow()
        fixture.inspect()
        fixture.session.appendDesktopAction(.press(try fixture.driver.button()))
        let document = try fixture.model.contextDemoDraftDocument()
        let target = ContextDemoTarget(kind: .codeProject, displayName: "Missing project",
            locator: fixture.root.appendingPathComponent("does-not-exist").absoluteString)
        let request = ContextDemoCaptureRequest(id: "project-desktop-request", planId: document.planId,
            revision: document.revision, target: target, durationSeconds: 10, window: fixture.session.selectedWindow?.binding)
        let prepared = try fixture.review.prepare(request: request, sourceContentKey: fixture.model.project.media.source.contentKey)
        let plan = try #require(prepared)
        let actual = try await fixture.recorder.prepare(desktopPlan: plan, document: document)
        #expect(actual == plan.request && actual.target.kind == .codeProject)
        #expect(fixture.native.begins == 0 && fixture.service.approvals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        #expect(fixture.session.projectLaunch.phase == .choosing)
    }

    @Test func unsupportedAndOversizedDraftsNeverActOrExceedTwelveSteps() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.selectWindow()
        fixture.session.setCaptureSeconds(30)
        fixture.inspect()
        fixture.session.appendDesktopAction(.press(try fixture.driver.textField()))
        #expect(fixture.review.actions.isEmpty && fixture.review.message != nil)
        fixture.session.appendDesktopAction(.setNonsecretValue(try fixture.driver.textField(), value: String(repeating: "x", count: 257)))
        #expect(fixture.review.actions.isEmpty)
        fixture.session.appendDesktopAction(.press(try fixture.driver.button()))
        fixture.session.appendDesktopAction(.pause(milliseconds: 5_001))
        #expect(fixture.review.actions.count == 1)
        for _ in 1..<ContextDemoDesktopLimits.maximumActions {
            fixture.session.appendDesktopAction(.press(try fixture.driver.button()))
        }
        fixture.session.appendDesktopAction(.press(try fixture.driver.button()))
        #expect(fixture.review.actions.count == 12 && fixture.review.message != nil)
        #expect(fixture.driver.performed.isEmpty && fixture.native.begins == 0 && fixture.service.approvals.isEmpty)
    }

    @Test func expiredInspectionRequiresExplicitReinspectionAndNeverStartsCapture() async throws {
        let fixture = try await open()
        defer { fixture.close() }
        try await fixture.ready()
        fixture.clock.now += 121
        fixture.session.start()
        try await fixture.eventually { fixture.session.phase == .failed }
        #expect(fixture.session.message == ContextDemoDesktopError.approvalExpired.errorDescription)
        #expect(fixture.native.begins == 0 && fixture.driver.performed.isEmpty && fixture.driver.inspections.count == 1)
    }
}
#endif
