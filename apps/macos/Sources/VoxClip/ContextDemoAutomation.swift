import Foundation
import VoxClipCore

enum ContextDemoBrowserError: Error, Equatable {
    case alreadyStarted, unavailable, targetUnavailable, navigationBlocked, navigationFailed
    case navigationTimedOut, elementUnavailable, closed

    var userMessage: String {
        switch self {
        case .alreadyStarted: "This browser session has already started. Prepare a new demonstration."
        case .unavailable: "The private demonstration browser could not be created. No page was opened."
        case .targetUnavailable: "The demonstration window is no longer visible or its capture geometry changed."
        case .navigationBlocked: "The page requested an unapproved navigation, form submission, frame or download. Review a new exact URL."
        case .navigationFailed: "The approved page could not be loaded. No other destination was opened."
        case .navigationTimedOut: "The approved page did not finish loading within the reviewed time limit."
        case .elementUnavailable: "The reviewed link is missing or its destination changed. Review the page again."
        case .closed: "The demonstration browser was closed. Prepare a new session."
        }
    }
}

enum ContextDemoBrowserNavigationPolicy {
    static func responseMatches(url: URL?, expectedURL: URL?) -> Bool {
        guard let url, let expectedURL,
              var proposed = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var expected = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false) else { return false }
        proposed.fragment = nil
        expected.fragment = nil
        return proposed.url == expected.url
    }

    static func allows(url: URL?, expectedURL: URL?, mainFrame: Bool?, method: String?,
                       formSubmission: Bool, download: Bool, active: Bool) -> Bool {
        active && expectedURL != nil && url == expectedURL && mainFrame == true
            && method == "GET" && !formSubmission && !download
    }
}

@MainActor protocol ContextDemoBrowserDriving: AnyObject {
    func perform(_ action: ContextDemoWebAction, navigationTimeoutSeconds: Int) async throws
    func stop()
}

@MainActor final class ContextDemoAutomation {
    private let plan: ContextDemoWebPlan
    private let approval: ContextDemoWebApproval
    private let now: () -> Date
    private var cancelled = false
    private var started = false

    init(plan: ContextDemoWebPlan, approval: ContextDemoWebApproval, now: @escaping () -> Date = { Date() }) {
        self.plan = plan
        self.approval = approval
        self.now = now
    }

    static func prepare(request: ContextDemoCaptureRequest,
                        actions: [ContextDemoWebAction] = []) throws -> ContextDemoBrowserReview {
        try .prepare(request: request, actions: actions)
    }

    func run(driver: any ContextDemoBrowserDriving,
             currentRevision: @escaping @MainActor () -> String) async throws {
        guard !started else { throw ContextDemoBrowserError.alreadyStarted }
        started = true
        do {
            for action in plan.actions {
                try check(currentRevision: currentRevision())
                try await driver.perform(action, navigationTimeoutSeconds: plan.navigationTimeoutSeconds)
                try check(currentRevision: currentRevision())
            }
        } catch {
            driver.stop()
            throw error
        }
    }

    func cancel() { cancelled = true }

    private func check(currentRevision: String) throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        try approval.validate(plan: plan, currentRevision: currentRevision, now: now())
    }
}
