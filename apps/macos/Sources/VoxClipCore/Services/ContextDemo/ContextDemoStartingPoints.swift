import Foundation

public struct ContextDemoBrowserReview: Equatable, Sendable {
    public let request: ContextDemoCaptureRequest
    public let plan: ContextDemoWebPlan

    public var capabilityNotice: String {
        "A private, script-disabled browser records only the reviewed URL, scrolls and ordinary links. "
        + "Forms, sign-in, downloads, pop-ups and arbitrary JavaScript are unavailable. "
        + "Pages that require their own scripts may not work; no unattended free-form demonstration is provided."
    }

    public static func prepare(request: ContextDemoCaptureRequest,
                               actions: [ContextDemoWebAction] = []) throws -> Self {
        try request.validate()
        guard request.target.kind == .webPage, request.window == nil, request.durationSeconds >= 1,
              actions.count < 12 else {
            throw ContextDemoPreparationError.invalidPlan
        }
        var navigationCount = 1
        var fixedSeconds = 0
        for action in actions {
            switch action {
            case .navigate: navigationCount += 1
            case .followLink: navigationCount += 1; fixedSeconds += 2
            case .scroll: fixedSeconds += 2
            case .pause(let milliseconds):
                guard (1...5000).contains(milliseconds) else { throw ContextDemoPreparationError.invalidPlan }
                fixedSeconds += (milliseconds + 999) / 1000
            }
        }
        let navigationSeconds = min(15, Int((request.durationSeconds - Double(fixedSeconds)) / Double(navigationCount)))
        guard navigationSeconds >= 1 else { throw ContextDemoPreparationError.invalidPlan }
        let plan = try ContextDemoWebPlan.prepare(url: request.target.locator,
            revision: "\(request.planId):\(request.revision):\(request.id)", actions: actions,
            navigationTimeoutSeconds: navigationSeconds)
        let reviewed = plan.actions.enumerated().map { index, action in
            ContextDemoReviewedAction(id: "web-\(index)", summary: action.reviewDescription)
        }
        guard request.actions.isEmpty || request.actions == reviewed else {
            throw ContextDemoPreparationError.approvalRequired
        }
        let reviewedRequest = ContextDemoCaptureRequest(id: request.id, planId: request.planId,
            revision: request.revision, target: request.target, durationSeconds: request.durationSeconds,
            actions: reviewed)
        try reviewedRequest.validate()
        return Self(request: reviewedRequest, plan: plan)
    }

    public func approve(currentRequest: ContextDemoCaptureRequest, now: Date = Date()) throws -> ContextDemoWebApproval {
        guard currentRequest == request else { throw ContextDemoPreparationError.stalePlan }
        return try .approve(plan: plan, currentRevision: plan.revision, now: now)
    }

    public func captureRequest(window: ContextDemoWindowBinding) throws -> ContextDemoCaptureRequest {
        let bound = ContextDemoCaptureRequest(id: request.id, planId: request.planId,
            revision: request.revision, target: request.target, durationSeconds: request.durationSeconds,
            window: window, actions: request.actions)
        try bound.validate()
        return bound
    }
}

public struct ContextDemoProjectReview: Equatable, Sendable {
    public let request: ContextDemoCaptureRequest
    public let snapshot: ContextDemoProjectSnapshot

    public var unavailableReason: String {
        "Project facts are ready, but no project code has been run. Start the preview yourself, "
        + "then choose its URL or exact desktop window and review a recording plan. "
        + "Unattended project build/start/demonstration is not available."
    }
}

extension ContextDemoProjectInspector {
    public func prepare(request: ContextDemoCaptureRequest,
                        approval: ContextDemoProjectReadApproval) async throws -> ContextDemoProjectReview {
        try request.validate()
        guard request.target.kind == .codeProject,
              let directory = URL(string: request.target.locator),
              directory.standardizedFileURL.path == approval.directory.path else {
            throw ContextDemoPreparationError.invalidDirectory
        }
        let snapshot = try await inspect(approval: approval)
        return ContextDemoProjectReview(request: request, snapshot: snapshot)
    }
}
