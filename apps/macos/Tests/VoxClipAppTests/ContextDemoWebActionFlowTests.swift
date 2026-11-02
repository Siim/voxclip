#if DEBUG
import AppKit
import Foundation
import Testing
import WebKit
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

@MainActor private final class ContextDemoWebFlowProbe: ContextDemoRecording, ContextDemoBrowserDriving {
    var prepared: [ContextDemoBrowserReview] = []
    var scriptChoices: [Bool] = []
    var started: [ContextDemoCaptureRequest] = []
    var performed: [ContextDemoWebAction] = []
    var events: [String] = []
    var discarded: [ContextDemoAsset] = []
    var holdPreparation = false
    var onAction: (() -> Void)?
    var actionFailure: ContextDemoBrowserError?
    private var preparationRelease: TestContinuation<Void>?
    private var projectID = ""

    func checkAvailability() { events.append("check-access") }
    func unavailableReason(for kind: ContextDemoTargetKind) -> String? { nil }
    func targets() async throws -> [ContextDemoCaptureTarget] { [] }
    func prepare(target: ContextDemoTarget, window: ContextDemoCaptureTarget?, duration: Double,
                 document: ContextDemoDocument) async throws -> ContextDemoCaptureRequest {
        try await prepare(target: target, window: window, duration: duration, document: document,
            webActions: [], allowsPageScripts: false)
    }
    func prepare(target: ContextDemoTarget, window: ContextDemoCaptureTarget?, duration: Double,
                 document: ContextDemoDocument, webActions: [ContextDemoWebAction],
                 allowsPageScripts: Bool) async throws -> ContextDemoCaptureRequest {
        projectID = document.projectId
        let request = ContextDemoCaptureRequest(id: UUID().uuidString, planId: document.planId,
            revision: document.revision, target: target, durationSeconds: duration)
        let review = try ContextDemoAutomation.prepare(request: request, actions: webActions)
        prepared.append(review)
        scriptChoices.append(allowsPageScripts)
        if holdPreparation { await withTestDeadline { preparationRelease = $0 } }
        return review.request
    }
    func record(_ request: ContextDemoCaptureRequest, isCurrent: @escaping @MainActor () -> Bool) async throws -> (asset: ContextDemoAsset, url: URL) {
        let review = try #require(prepared.last)
        guard request == review.request, isCurrent() else { throw ContextDemoPreparationError.stalePlan }
        started.append(request)
        events.append("capture-started")
        defer { events.append("capture-drained") }
        let automation = ContextDemoAutomation(plan: review.plan, approval: try review.approve(currentRequest: request))
        try await automation.run(driver: self, currentRevision: { isCurrent() ? review.plan.revision : "stale" })
        let id = UUID().uuidString.lowercased()
        let asset = ContextDemoAsset(id: id, requestId: request.id, target: request.target,
            relativePath: try ContextDemoAsset.relativePath(projectId: projectID, assetId: id),
            sha256: String(repeating: "a", count: 64), durationSeconds: 2, pixelWidth: 1280,
            pixelHeight: 720, byteSize: 1024, createdAt: Date(timeIntervalSince1970: 1_000))
        return (asset, try verifiedURL(for: asset))
    }
    func perform(_ action: ContextDemoWebAction, navigationTimeoutSeconds: Int) async throws {
        events.append("action")
        performed.append(action)
        onAction?()
        if let actionFailure { throw actionFailure }
        try Task.checkCancellation()
    }
    func stop() { events.append("browser-stopped") }
    func finish() { events.append("capture-finish") }
    func cancel() { events.append("capture-cancel") }
    func discard(_ asset: ContextDemoAsset) { discarded.append(asset) }
    func verifiedURL(for asset: ContextDemoAsset) throws -> URL { URL(fileURLWithPath: "/tmp/fake-web-flow-\(asset.id).mp4") }
    func releasePreparation() { preparationRelease?.resume(); preparationRelease = nil }
}

@MainActor
@Suite("Context demo reviewed web action flow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
struct ContextDemoWebActionFlowTests {
    private func open() async throws -> (EditorModel, ContextDemoSession, ContextDemoWebFlowProbe) {
        _ = NSApplication.shared
        let app = AppModel()
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        await app.shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .fullTake)
        let model = try #require(app.shell.editor)
        model.mediaResolved = true
        model.refresh()
        let backend = ContextDemoWebFlowProbe()
        let session = ContextDemoSession(model: model, backend: backend)
        model.contextDemoSession = session
        session.setURL("https://example.test/demo?mode=preview#intro")
        session.setCaptureSeconds(30)
        return (model, session, backend)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition())
    }

    @Test func reviewedScrollLinkAndPauseReachCaptureWithoutLosingExactURLs() async throws {
        let (model, session, backend) = try await open()
        defer { model.close() }
        let destination = "https://example.test/detail?mode=demo#details"
        session.appendWebAction(.scroll(verticalPixels: 600))
        session.appendWebLink(elementID: "details-link", destination: destination)
        session.appendWebAction(.pause(milliseconds: 500))
        #expect(backend.prepared.isEmpty && backend.started.isEmpty && backend.performed.isEmpty)
        session.review()
        try await eventually { session.phase == .ready }
        let review = try #require(backend.prepared.last)
        #expect(review.request == session.request)
        #expect(review.request.target.locator == session.urlText)
        #expect(review.plan.actions == [.navigate(try ContextDemoURLPolicy.validate(session.urlText))] + session.webActions)
        #expect(review.plan.actions[2] == .followLink(elementID: "details-link", destination: try ContextDemoURLPolicy.validate(destination)))
        #expect(review.request.actions.map(\.summary) == review.plan.actions.map(\.reviewDescription))
        #expect(backend.started.isEmpty && backend.performed.isEmpty)
        session.start()
        session.start()
        try await eventually { session.phase == .result }
        #expect(backend.started == [review.request])
        #expect(backend.performed == review.plan.actions)
        let start = try #require(backend.events.firstIndex(of: "capture-started"))
        let firstAction = try #require(backend.events.firstIndex(of: "action"))
        let drain = try #require(backend.events.firstIndex(of: "capture-drained"))
        #expect(start < firstAction && firstAction < drain)
        #expect(backend.scriptChoices == [false])
    }

    @Test func explicitScriptChoiceAndEveryActionEditRequireFreshCaptureReview() async throws {
        let (model, session, backend) = try await open()
        defer { model.close() }
        #expect(!session.allowsPageScripts)
        session.appendWebAction(.scroll(verticalPixels: 100))
        session.review()
        try await eventually { session.phase == .ready }
        let firstID = session.request?.id
        session.setAllowsPageScripts(true)
        #expect(session.request == nil && !session.canStart && session.allowsPageScripts)
        #expect(backend.scriptChoices == [false] && backend.started.isEmpty)
        session.review()
        try await eventually { session.phase == .ready }
        #expect(session.request?.id != firstID)
        #expect(backend.scriptChoices == [false, true])
        session.appendWebAction(.pause(milliseconds: 500))
        #expect(session.request == nil && !session.canStart)
        session.review()
        try await eventually { session.phase == .ready }
        session.removeWebAction(at: 0)
        #expect(session.request == nil && !session.canStart)
        session.review()
        try await eventually { session.phase == .ready }
        session.setURL("https://example.test/changed#exact")
        #expect(session.request == nil && !session.canStart && session.urlText.hasSuffix("#exact"))
        #expect(backend.started.isEmpty && backend.performed.isEmpty)
    }

    @Test func invalidActionsURLsAndBudgetsAreNotSilentlyAccepted() async throws {
        let (model, session, backend) = try await open()
        defer { model.close() }
        session.appendWebAction(.scroll(verticalPixels: 0))
        session.appendWebAction(.scroll(verticalPixels: 3001))
        session.appendWebAction(.pause(milliseconds: 5001))
        session.appendWebAction(.navigate(try ContextDemoURLPolicy.validate("https://example.test/not-an-optional-step")))
        session.appendWebLink(elementID: "", destination: "https://example.test/link")
        session.appendWebLink(elementID: "link", destination: "https://example.test/link?token=not-a-secret")
        #expect(session.webActions.isEmpty && session.message != nil)
        #expect(backend.prepared.isEmpty && backend.started.isEmpty)
        for _ in 0..<12 { session.appendWebAction(.pause(milliseconds: 100)) }
        #expect(session.webActions.count == 11)
        session.setCaptureSeconds(1)
        session.review()
        try await eventually { session.phase == .failed }
        #expect(session.message == ContextDemoPreparationError.invalidPlan.userMessage)
        #expect(!session.canStart && backend.started.isEmpty)
    }

    @Test func cancellationFencesLatePrepareAndNewActionChoices() async throws {
        let (model, session, backend) = try await open()
        defer { model.close() }
        backend.holdPreparation = true
        session.appendWebAction(.pause(milliseconds: 100))
        session.review()
        try await eventually { backend.prepared.count == 1 }
        session.cancel()
        session.removeWebAction(at: 0)
        session.appendWebAction(.scroll(verticalPixels: -200))
        backend.releasePreparation()
        for _ in 0..<30 { await Task.yield() }
        #expect(session.request == nil && !session.canStart && session.phase == .choosing)
        backend.holdPreparation = false
        session.review()
        try await eventually { session.phase == .ready }
        #expect(backend.prepared.last?.plan.actions.last == .scroll(verticalPixels: -200))
        #expect(backend.started.isEmpty && backend.performed.isEmpty)
    }

    @Test func changedCurrentnessDuringActionStopsBeforeFollowingActionsOrResult() async throws {
        let (model, session, backend) = try await open()
        defer { model.close() }
        session.appendWebAction(.scroll(verticalPixels: 300))
        session.appendWebAction(.pause(milliseconds: 100))
        session.review()
        try await eventually { session.phase == .ready }
        backend.onAction = { session.cancel() }
        session.start()
        try await eventually { backend.events.contains("capture-drained") }
        #expect(backend.performed.count == 1)
        #expect(backend.events.contains("browser-stopped"))
        #expect(session.phase == .choosing && session.recordedAsset == nil && session.request == nil)
    }

    @Test func actualActionFailureIsInlineAndNeverPublishedAsSuccessfulResult() async throws {
        let (model, session, backend) = try await open()
        defer { model.close() }
        session.appendWebAction(.scroll(verticalPixels: 200))
        session.review()
        try await eventually { session.phase == .ready }
        backend.actionFailure = .elementUnavailable
        session.start()
        try await eventually { session.phase == .failed }
        #expect(session.message == ContextDemoBrowserError.elementUnavailable.userMessage)
        #expect(session.recordedAsset == nil && backend.performed.count == 1)
        #expect(backend.events.contains("browser-stopped") && backend.events.contains("capture-drained"))
    }

    @Test func projectPreviewHandoffKeepsExactURLAndRunsNothing() async throws {
        let (model, session, backend) = try await open()
        defer { model.close() }
        session.chooseKind(.codeProject)
        let preview = "http://localhost:3000/example?mode=demo#preview"
        session.useProjectPreviewURL(preview)
        #expect(session.targetKind == .webPage && session.urlText == preview)
        #expect(session.request == nil && !session.canStart)
        #expect(session.projectLaunch.facts == nil && session.projectLaunch.plan == nil)
        #expect(backend.prepared.isEmpty && backend.started.isEmpty && backend.performed.isEmpty)
        session.useProjectPreviewURL("http://not-loopback.test/unsafe")
        #expect(session.urlText == preview && session.message != nil)
    }

    @Test func productionPrepareIncludesAllReviewedActionsWithoutOpeningABrowser() async throws {
        let (model, session, _) = try await open()
        defer { model.close() }
        let document = try model.contextDemoDraftDocument()
        let recorder = ContextDemoLocalRecorder()
        defer { recorder.cancel() }
        let actions: [ContextDemoWebAction] = [.scroll(verticalPixels: 400),
            .followLink(elementID: "detail", destination: try ContextDemoURLPolicy.validate("https://example.test/detail#preview")),
            .pause(milliseconds: 200)]
        let target = ContextDemoTarget(kind: .webPage, displayName: "Example", locator: session.urlText)
        let request = try await recorder.prepare(target: target, window: nil, duration: 30,
            document: document, webActions: actions, allowsPageScripts: true)
        let review = try ContextDemoAutomation.prepare(request: request, actions: actions)
        #expect(request == review.request)
        #expect(request.actions.count == actions.count + 1)
        #expect(Array(review.plan.actions.dropFirst()) == actions)
        #expect(request.target == target && request.window == nil)
        #expect(request.planId == document.planId && request.revision == document.revision)
    }
}

@MainActor @Suite("Context demo browser delegate and script contract", .serialized)
struct ContextDemoBrowserDelegateContractTests {
    @Test func optionalPolicyAndPermissionMethodsHaveObjectiveCDelegateSelectors() {
        let session = ContextDemoBrowserSession()
        let selectors = [
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
            "webView:didReceiveAuthenticationChallenge:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"
        ]
        for selector in selectors { #expect(session.responds(to: NSSelectorFromString(selector))) }
        if #available(macOS 27.0, *) {
            #expect(session.responds(to: NSSelectorFromString("webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:")))
        }
    }

    @Test func enablingStandardPageScriptsKeepsPrivateStoreAndPopupRestrictions() {
        let disabled = ContextDemoBrowserSession.configuration(allowsPageScripts: false)
        let enabled = ContextDemoBrowserSession.configuration(allowsPageScripts: true)
        #expect(!disabled.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(enabled.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!disabled.websiteDataStore.isPersistent && !enabled.websiteDataStore.isPersistent)
        #expect(!disabled.preferences.javaScriptCanOpenWindowsAutomatically && !enabled.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(enabled.mediaTypesRequiringUserActionForPlayback == .all)
        #expect(ContextDemoBrowserSession.pageScriptNotice(allowsPageScripts: true).contains("network resources"))
    }

    @Test func javascriptChoiceDoesNotRelaxExactNavigationFormsOrDownloads() throws {
        let exact = try ContextDemoURLPolicy.validate("https://example.test/page#one")
        let changed = try ContextDemoURLPolicy.validate("https://example.test/page#two")
        func allows(url: URL, mainFrame: Bool = true, method: String = "GET", form: Bool = false, download: Bool = false, active: Bool = true) -> Bool {
            ContextDemoBrowserNavigationPolicy.allows(url: url, expectedURL: exact,
                mainFrame: mainFrame, method: method, formSubmission: form, download: download, active: active)
        }
        #expect(allows(url: exact))
        #expect(!allows(url: changed))
        #expect(!allows(url: exact, mainFrame: false))
        #expect(!allows(url: exact, method: "POST"))
        #expect(!allows(url: exact, form: true))
        #expect(!allows(url: exact, download: true))
        #expect(!allows(url: exact, active: false))
    }

    @Test func scriptDrivenHistoryChangesMustMatchTheCurrentlyExpectedExactURL() throws {
        let exact = try ContextDemoURLPolicy.validate("https://example.test/page?mode=preview#one")
        let fragment = try ContextDemoURLPolicy.validate("https://example.test/page?mode=preview#two")
        let next = try ContextDemoURLPolicy.validate("https://example.test/next")
        #expect(ContextDemoBrowserSession.pageURLMatchesReview(nil, expectedURL: nil))
        #expect(ContextDemoBrowserSession.pageURLMatchesReview(exact, expectedURL: exact))
        #expect(!ContextDemoBrowserSession.pageURLMatchesReview(fragment, expectedURL: exact))
        #expect(!ContextDemoBrowserSession.pageURLMatchesReview(next, expectedURL: exact))
        #expect(!ContextDemoBrowserSession.pageURLMatchesReview(exact, expectedURL: nil))
        #expect(ContextDemoBrowserSession.pageURLMatchesReview(next, expectedURL: next))
    }
}
#endif
