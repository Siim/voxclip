import AppKit
import Foundation
import VoxClipCore
import WebKit

struct ContextDemoBrowserCaptureTarget: Equatable {
    let sessionID: UUID
    let window: VoxClipCore.ContextDemoWindowBinding
    let contentBounds: CGRect
    let pixelScale: Double
}

@MainActor private final class ContextDemoReadOnlyWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

@MainActor private final class ContextDemoClosedBrowserFence: NSObject, WKNavigationDelegate {
    static let shared = ContextDemoClosedBrowserFence()

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) { decisionHandler(.cancel) }
}

@MainActor final class ContextDemoBrowserSession: NSObject, ContextDemoBrowserDriving, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    private(set) var captureTarget: ContextDemoBrowserCaptureTarget?
    var onInvalidated: (@MainActor () -> Void)?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var urlObservation: NSKeyValueObservation?
    private var automation: ContextDemoAutomation?
    private var review: ContextDemoBrowserReview?
    private var active: Task<Void, Error>?
    private var started = false
    private var closed = false
    private var invalidated = false
    private var navigationID: UUID?
    private var expectedURL: URL?
    private var expectedNavigation: WKNavigation?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var scriptID: UUID?
    private var scriptContinuation: CheckedContinuation<Bool, Error>?
    private var scriptTimeout: Task<Void, Never>?

    static func pageScriptNotice(allowsPageScripts: Bool) -> String {
        let policy = allowsPageScripts
            ? "This page’s own JavaScript is enabled by your choice; it may load network resources and execute page code."
            : "This private browser disables the page’s JavaScript. Script-dependent pages may not work; enable it explicitly if needed."
        return policy + " Only reviewed navigation, scrolls and ordinary links are automated. No arbitrary agent scripts, sign-in, forms, downloads, pop-ups or permission bypass."
    }

    static func pageURLMatchesReview(_ url: URL?, expectedURL: URL?) -> Bool {
        url == nil || url == expectedURL
    }

    static func configuration(allowsPageScripts: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsPageScripts
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        return configuration
    }

    func start(review: ContextDemoBrowserReview, approval: ContextDemoWebApproval,
               currentRequest: ContextDemoCaptureRequest,
               allowsPageScripts: Bool = false) throws -> ContextDemoBrowserCaptureTarget {
        guard !started, !closed else { throw ContextDemoBrowserError.alreadyStarted }
        guard currentRequest == review.request else { throw ContextDemoPreparationError.stalePlan }
        try approval.validate(plan: review.plan, currentRevision: review.plan.revision)
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            throw ContextDemoBrowserError.unavailable
        }
        started = true
        let configuration = Self.configuration(allowsPageScripts: allowsPageScripts)
        let webView = ContextDemoReadOnlyWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityLabel("Approved context demonstration page")
        let window = NSWindow(contentRect: webView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Context demonstration"
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        window.center()
        self.window = window
        self.webView = webView
        self.review = review
        self.automation = ContextDemoAutomation(plan: review.plan, approval: approval)
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            let url = change.newValue ?? nil
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if !Self.pageURLMatchesReview(url, expectedURL: self.expectedURL) { self.invalidate() }
            }
        }
        window.makeKeyAndOrderFront(nil)
        guard window.windowNumber > 0, window.isVisible else {
            cancel()
            throw ContextDemoBrowserError.targetUnavailable
        }
        let target = ContextDemoBrowserCaptureTarget(sessionID: id,
            window: VoxClipCore.ContextDemoWindowBinding(windowID: UInt32(window.windowNumber),
                processID: ProcessInfo.processInfo.processIdentifier, bundleID: bundleID),
            contentBounds: webView.bounds, pixelScale: window.backingScaleFactor)
        captureTarget = target
        return target
    }

    func validatedCaptureTarget() throws -> ContextDemoBrowserCaptureTarget {
        guard !closed, !invalidated, let target = captureTarget, let window, let webView,
              window.isVisible, !window.isMiniaturized, window.windowNumber == Int(target.window.windowID),
              webView.bounds == target.contentBounds, window.backingScaleFactor == target.pixelScale else {
            throw ContextDemoBrowserError.targetUnavailable
        }
        guard Self.pageURLMatchesReview(webView.url, expectedURL: expectedURL) else {
            throw ContextDemoBrowserError.navigationBlocked
        }
        return target
    }

    func run(currentRequest: @escaping @MainActor () -> ContextDemoCaptureRequest?) async throws {
        try Task.checkCancellation()
        guard active == nil, let automation, let review, !closed else { throw ContextDemoBrowserError.closed }
        _ = try validatedCaptureTarget()
        let task = Task { @MainActor [self] in
            try await automation.run(driver: self) {
                currentRequest() == review.request ? review.plan.revision : "stale"
            }
        }
        active = task
        defer { active = nil }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            _ = try validatedCaptureTarget()
        } catch {
            stop()
            throw error
        }
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        urlObservation?.invalidate()
        urlObservation = nil
        automation?.cancel()
        active?.cancel()
        stop()
        webView?.navigationDelegate = ContextDemoClosedBrowserFence.shared
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        window?.delegate = nil
        window?.close()
        webView = nil
        window = nil
        captureTarget = nil
        review = nil
        automation = nil
        onInvalidated = nil
    }

    func stop() {
        automation?.cancel()
        active?.cancel()
        webView?.stopLoading()
        completeNavigation(.failure(CancellationError()))
        completeScript(.failure(CancellationError()))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        invalidate()
        if onInvalidated == nil { cancel(); return true }
        return false
    }

    func windowDidResize(_ notification: Notification) { checkGeometry() }
    func windowDidChangeBackingProperties(_ notification: Notification) { checkGeometry() }
    func windowDidMiniaturize(_ notification: Notification) { invalidate() }

    private func checkGeometry() {
        guard captureTarget != nil, !closed else { return }
        if (try? validatedCaptureTarget()) == nil { invalidate() }
    }

    private func invalidate() {
        guard !invalidated, !closed else { return }
        invalidated = true
        stop()
        onInvalidated?()
    }

    func perform(_ action: ContextDemoWebAction, navigationTimeoutSeconds: Int) async throws {
        try Task.checkCancellation()
        _ = try validatedCaptureTarget()
        guard active != nil, review?.plan.actions.contains(action) == true,
              let webView else { throw ContextDemoBrowserError.navigationBlocked }
        switch action {
        case .navigate(let url):
            try await navigate(to: url, timeoutSeconds: navigationTimeoutSeconds) { [weak self, weak webView] in
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: Double(navigationTimeoutSeconds))
                request.httpMethod = "GET"
                self?.expectedNavigation = webView?.load(request)
            }
        case .scroll(let pixels):
            let result = try await scriptBoolean(
                "window.scrollBy({top: pixels, left: 0, behavior: 'instant'}); return true;",
                arguments: ["pixels": pixels])
            guard result else { throw ContextDemoBrowserError.navigationFailed }
        case .followLink(let elementID, let destination):
            let result = try await scriptBoolean("""
                const link = document.getElementById(elementID);
                if (!(link instanceof HTMLAnchorElement) || link.href !== destination ||
                    link.hasAttribute('download') || (link.target && link.target !== '_self') ||
                    link.closest('form') || link.getClientRects().length === 0) return false;
                return true;
                """, arguments: ["elementID": elementID, "destination": destination.absoluteString])
            guard result else { throw ContextDemoBrowserError.elementUnavailable }
            try Task.checkCancellation()
            try await navigate(to: destination, timeoutSeconds: navigationTimeoutSeconds) { [weak self, weak webView] in
                guard let self, let webView, !self.closed, let token = self.navigationID else { return }
                webView.callAsyncJavaScript("""
                            const link = document.getElementById(elementID);
                            if (!(link instanceof HTMLAnchorElement) || link.href !== destination ||
                                link.hasAttribute('download') || (link.target && link.target !== '_self') ||
                                link.closest('form') || link.getClientRects().length === 0) return false;
                            HTMLAnchorElement.prototype.click.call(link); return true;
                            """, arguments: ["elementID": elementID, "destination": destination.absoluteString],
                            in: nil, in: .defaultClient) { [weak self] result in
                    guard self?.navigationID == token, self?.closed == false else { return }
                    guard case .success(let clicked) = result, clicked as? Bool == true else {
                        self?.completeNavigation(.failure(ContextDemoBrowserError.elementUnavailable))
                        return
                    }
                }
            }
        case .pause(let milliseconds):
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
        try Task.checkCancellation()
        _ = try validatedCaptureTarget()
    }

    private func navigate(to url: URL, timeoutSeconds: Int, trigger: @escaping @MainActor () -> Void) async throws {
        guard navigationContinuation == nil, review?.plan.approvedNavigationURLs.contains(url) == true else {
            throw ContextDemoBrowserError.navigationBlocked
        }
        let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                navigationID = token
                expectedURL = url
                navigationContinuation = continuation
                navigationTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                    guard self?.navigationID == token else { return }
                    self?.webView?.stopLoading()
                    self?.completeNavigation(.failure(ContextDemoBrowserError.navigationTimedOut))
                }
                trigger()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.navigationID == token else { return }
                self?.stop()
            }
        }
    }

    private func completeNavigation(_ result: Result<Void, Error>) {
        let continuation = navigationContinuation
        navigationContinuation = nil
        navigationID = nil
        expectedURL = nil
        expectedNavigation = nil
        navigationTimeout?.cancel()
        navigationTimeout = nil
        continuation?.resume(with: result)
    }

    private func scriptBoolean(_ body: String, arguments: [String: Any]) async throws -> Bool {
        try Task.checkCancellation()
        guard let webView, !closed, scriptContinuation == nil else { throw ContextDemoBrowserError.closed }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                scriptID = token
                scriptContinuation = continuation
                scriptTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard self?.scriptID == token else { return }
                    self?.completeScript(.failure(ContextDemoBrowserError.navigationTimedOut))
                }
                webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
                    guard self?.scriptID == token else { return }
                    switch result {
                    case .success(let value): self?.completeScript(.success(value as? Bool == true))
                    case .failure: self?.completeScript(.failure(ContextDemoBrowserError.elementUnavailable))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.scriptID == token else { return }
                self?.completeScript(.failure(CancellationError()))
            }
        }
    }

    private func completeScript(_ result: Result<Bool, Error>) {
        let continuation = scriptContinuation
        scriptContinuation = nil
        scriptID = nil
        scriptTimeout?.cancel()
        scriptTimeout = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = ContextDemoBrowserNavigationPolicy.allows(url: action.request.url, expectedURL: expectedURL,
            mainFrame: action.targetFrame?.isMainFrame, method: action.request.httpMethod,
            formSubmission: action.navigationType == .formSubmitted || action.navigationType == .formResubmitted,
            download: action.shouldPerformDownload, active: !closed && navigationContinuation != nil)
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed, action.targetFrame?.isMainFrame != false, navigationContinuation != nil {
            completeNavigation(.failure(ContextDemoBrowserError.navigationBlocked))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let http = response.response as? HTTPURLResponse
        let allowed = !closed && response.isForMainFrame && response.canShowMIMEType
            && ContextDemoBrowserNavigationPolicy.responseMatches(url: response.response.url, expectedURL: expectedURL)
            && ["text/html", "application/xhtml+xml", "text/plain"].contains(response.response.mimeType ?? "")
            && http.map({ (200...299).contains($0.statusCode) }) == true
            && !(http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") ?? false)
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed, response.isForMainFrame { completeNavigation(.failure(ContextDemoBrowserError.navigationBlocked)) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard navigationContinuation != nil, !closed else { return }
        if expectedNavigation == nil { expectedNavigation = navigation }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === expectedNavigation else { return }
        guard webView.url == expectedURL else { completeNavigation(.failure(ContextDemoBrowserError.navigationBlocked)); return }
        completeNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === expectedNavigation else { return }
        completeNavigation(.failure(ContextDemoBrowserError.navigationFailed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === expectedNavigation else { return }
        completeNavigation(.failure(ContextDemoBrowserError.navigationFailed))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        completeNavigation(.failure(ContextDemoBrowserError.navigationFailed))
        completeScript(.failure(ContextDemoBrowserError.navigationFailed))
        automation?.cancel()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) { completionHandler() }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
