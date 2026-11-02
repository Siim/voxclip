#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

@MainActor private final class ContextDemoBrowserProbe: ContextDemoBrowserDriving {
    var actions: [ContextDemoWebAction] = []
    var stops = 0
    var onAction: (() -> Void)?
    var failure: ContextDemoBrowserError?

    func perform(_ action: ContextDemoWebAction, navigationTimeoutSeconds: Int) async throws {
        actions.append(action)
        onAction?()
        if let failure { throw failure }
        try Task.checkCancellation()
    }

    func stop() { stops += 1 }
}

@MainActor @Suite("Context demo bounded browser automation", .offlineFixtures)
struct ContextDemoAutomationTests {
    private func plan() throws -> ContextDemoWebPlan {
        try .prepare(url: "https://example.test/demo", revision: "r1", actions: [.scroll(verticalPixels: 200), .pause(milliseconds: 100)])
    }

    @Test func initializationAndApprovalDoNotPerformActions() throws {
        let plan = try plan()
        let driver = ContextDemoBrowserProbe()
        _ = ContextDemoAutomation(plan: plan, approval: try .approve(plan: plan, currentRevision: "r1"))
        #expect(driver.actions.isEmpty && driver.stops == 0)
    }

    @Test func startExecutesOnlyReviewedActionsAndCannotReplay() async throws {
        let plan = try plan(), driver = ContextDemoBrowserProbe()
        let automation = ContextDemoAutomation(plan: plan, approval: try .approve(plan: plan, currentRevision: "r1"))
        try await automation.run(driver: driver, currentRevision: { "r1" })
        #expect(driver.actions == plan.actions)
        await #expect(throws: ContextDemoBrowserError.alreadyStarted) {
            try await automation.run(driver: driver, currentRevision: { "r1" })
        }
    }

    @Test func staleApprovalPreventsEvenFirstNavigation() async throws {
        let plan = try plan(), driver = ContextDemoBrowserProbe()
        let automation = ContextDemoAutomation(plan: plan, approval: try .approve(plan: plan, currentRevision: "r1"))
        await #expect(throws: ContextDemoPreparationError.stalePlan) {
            try await automation.run(driver: driver, currentRevision: { "r2" })
        }
        #expect(driver.actions.isEmpty && driver.stops == 1)
    }

    @Test func currentnessIsRecheckedAfterEveryAwait() async throws {
        let plan = try plan(), driver = ContextDemoBrowserProbe()
        var revision = "r1"
        driver.onAction = { revision = "r2" }
        let automation = ContextDemoAutomation(plan: plan, approval: try .approve(plan: plan, currentRevision: "r1"))
        await #expect(throws: ContextDemoPreparationError.stalePlan) {
            try await automation.run(driver: driver, currentRevision: { revision })
        }
        #expect(driver.actions.count == 1 && driver.stops == 1)
    }

    @Test func expiredApprovalStopsBeforeNavigation() async throws {
        let plan = try plan(), driver = ContextDemoBrowserProbe()
        let date = Date(timeIntervalSince1970: 1000)
        let automation = ContextDemoAutomation(plan: plan,
            approval: try .approve(plan: plan, currentRevision: "r1", now: date), now: { date.addingTimeInterval(301) })
        await #expect(throws: ContextDemoPreparationError.approvalExpired) {
            try await automation.run(driver: driver, currentRevision: { "r1" })
        }
        #expect(driver.actions.isEmpty && driver.stops == 1)
    }

    @Test func explicitCancellationStopsBeforeAnyActions() async throws {
        let plan = try plan(), driver = ContextDemoBrowserProbe()
        let automation = ContextDemoAutomation(plan: plan, approval: try .approve(plan: plan, currentRevision: "r1"))
        automation.cancel()
        await #expect(throws: CancellationError.self) {
            try await automation.run(driver: driver, currentRevision: { "r1" })
        }
        #expect(driver.actions.isEmpty && driver.stops == 1)
    }

    @Test func taskCancellationCannotContinueToFollowingActions() async throws {
        let plan = try plan(), driver = ContextDemoBrowserProbe()
        driver.onAction = { withUnsafeCurrentTask { $0?.cancel() } }
        let automation = ContextDemoAutomation(plan: plan, approval: try .approve(plan: plan, currentRevision: "r1"))
        let task = Task { try await automation.run(driver: driver, currentRevision: { "r1" }) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(driver.actions.count == 1 && driver.stops == 1)
    }

    @Test func driverFailureStopsAndDoesNotFallBackToAnotherTarget() async throws {
        let plan = try plan(), driver = ContextDemoBrowserProbe()
        driver.failure = .elementUnavailable
        let automation = ContextDemoAutomation(plan: plan, approval: try .approve(plan: plan, currentRevision: "r1"))
        await #expect(throws: ContextDemoBrowserError.elementUnavailable) {
            try await automation.run(driver: driver, currentRevision: { "r1" })
        }
        #expect(driver.actions.count == 1 && driver.stops == 1)
    }

    @Test func navigationPolicyRejectsEveryUnreviewedTargetOrAction() throws {
        let expected = try #require(URL(string: "https://example.test/demo"))
        #expect(ContextDemoBrowserNavigationPolicy.allows(url: expected, expectedURL: expected,
            mainFrame: true, method: "GET", formSubmission: false, download: false, active: true))
        for proposed in [nil, URL(string: "https://elsewhere.test"), URL(string: "file:///etc/passwd")] {
            #expect(!ContextDemoBrowserNavigationPolicy.allows(url: proposed, expectedURL: expected,
                mainFrame: true, method: "GET", formSubmission: false, download: false, active: true))
        }
        for mainFrame in [nil, false] {
            #expect(!ContextDemoBrowserNavigationPolicy.allows(url: expected, expectedURL: expected,
                mainFrame: mainFrame, method: "GET", formSubmission: false, download: false, active: true))
        }
        #expect(!ContextDemoBrowserNavigationPolicy.allows(url: expected, expectedURL: expected,
            mainFrame: true, method: "POST", formSubmission: true, download: false, active: true))
        #expect(!ContextDemoBrowserNavigationPolicy.allows(url: expected, expectedURL: expected,
            mainFrame: true, method: "GET", formSubmission: false, download: true, active: true))
        #expect(!ContextDemoBrowserNavigationPolicy.allows(url: expected, expectedURL: expected,
            mainFrame: true, method: "GET", formSubmission: false, download: false, active: false))
    }

    @Test func staleStartAndClosedSessionCannotCreateAWindow() throws {
        let request = ContextDemoCaptureRequest(id: "request", planId: "plan", revision: 1,
            target: .init(kind: .webPage, displayName: "Page", locator: "https://example.test"), durationSeconds: 10)
        let review = try ContextDemoAutomation.prepare(request: request)
        let approval = try review.approve(currentRequest: review.request)
        let browser = ContextDemoBrowserSession()
        #expect(throws: ContextDemoPreparationError.stalePlan) {
            try browser.start(review: review, approval: approval, currentRequest: request)
        }
        #expect(browser.captureTarget == nil)
        browser.cancel()
        browser.cancel()
        #expect(throws: ContextDemoBrowserError.alreadyStarted) {
            try browser.start(review: review, approval: approval, currentRequest: review.request)
        }
        #expect(browser.captureTarget == nil)
    }

    @Test func responseFragmentNormalizationNeverAuthorizesAnotherPage() {
        let expected = URL(string: "https://example.test/demo#section")
        #expect(ContextDemoBrowserNavigationPolicy.responseMatches(url: URL(string: "https://example.test/demo"), expectedURL: expected))
        #expect(!ContextDemoBrowserNavigationPolicy.responseMatches(url: URL(string: "https://example.test/other"), expectedURL: expected))
        #expect(!ContextDemoBrowserNavigationPolicy.responseMatches(url: nil, expectedURL: expected))
    }
}
#endif
