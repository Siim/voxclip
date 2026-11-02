import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor protocol ContextDemoDesktopReviewServing: AnyObject {
    func availability() -> ContextDemoAccessibilityAvailability
    func inspect(target: ContextDemoCaptureTarget) throws -> ContextDemoDesktopSnapshot
    func approve(plan: ContextDemoDesktopPlan, currentRequest: ContextDemoCaptureRequest,
                 sourceContentKey: String) throws -> ContextDemoDesktopApproval
    func record(plan: ContextDemoDesktopPlan, approval: ContextDemoDesktopApproval,
                reviewedCapture: ContextDemoReviewedCapture, capture: ContextDemoCaptureService,
                current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws -> ContextDemoCaptureResult
    func cancel()
}

extension ContextDemoAccessibilityService: ContextDemoDesktopReviewServing {}

@MainActor @Observable final class ContextDemoDesktopReviewSession {
    private(set) var availability: ContextDemoAccessibilityAvailability?
    private(set) var snapshot: ContextDemoDesktopSnapshot?
    private(set) var actions: [ContextDemoDesktopAction] = []
    private(set) var plan: ContextDemoDesktopPlan?
    private(set) var message: String?
    private(set) var isDraining = false
    @ObservationIgnored private let service: any ContextDemoDesktopReviewServing
    @ObservationIgnored private var reviewedCapture: ContextDemoReviewedCapture?
    @ObservationIgnored private var recording: Task<ContextDemoCaptureResult, Error>?
    @ObservationIgnored private var capture: ContextDemoCaptureService?
    @ObservationIgnored private var generation = UUID()

    init(service: (any ContextDemoDesktopReviewServing)? = nil) {
        self.service = service ?? ContextDemoAccessibilityService()
    }

    var usesActions: Bool { !actions.isEmpty }
    var canInspect: Bool { availability == .available && !isDraining }

    func checkAccess() {
        guard !isDraining else { return }
        invalidateInspection()
        availability = service.availability()
        message = availability == .available
            ? "Accessibility access is available. Choose Inspect Selected Window to read only stable control identifiers and capabilities. Nothing has run."
            : "Accessibility access is not granted. Enable VoxClip in System Settings → Privacy & Security → Accessibility, then explicitly check again. No prompt or Settings window was opened. Manual window recording remains available."
    }

    func inspect(window: ContextDemoCaptureTarget) {
        guard canInspect else {
            message = ContextDemoDesktopError.accessCheckRequired.errorDescription
            return
        }
        invalidateInspection()
        do {
            let result = try service.inspect(target: window)
            guard result.identity == ContextDemoDesktopIdentity(window: window.binding,
                processLaunchDate: window.processLaunchDate) else { throw ContextDemoDesktopError.targetUnavailable }
            snapshot = result
            message = result.controls.isEmpty
                ? "This exact window exposes no supported controls with stable AXIdentifiers. Manual window recording remains available."
                : "Only stable AXIdentifiers, roles and supported capabilities were inspected. Field values and titles were not read. No action has run."
        } catch { message = Self.message(for: error) }
    }

    func matches(window: ContextDemoCaptureTarget?) -> Bool {
        guard let snapshot, let window else { return false }
        return snapshot.identity == ContextDemoDesktopIdentity(window: window.binding,
            processLaunchDate: window.processLaunchDate)
    }

    func append(_ action: ContextDemoDesktopAction, duration: Double) {
        guard !isDraining, let snapshot else { return }
        do {
            let draft = ContextDemoCaptureRequest(id: "desktop-draft", planId: "desktop-draft", revision: 0,
                target: ContextDemoTarget(kind: .desktopApp, displayName: "Selected window",
                    locator: snapshot.identity.window.bundleID), durationSeconds: duration, window: snapshot.identity.window)
            _ = try ContextDemoDesktopPlan.prepare(request: draft, sourceContentKey: "draft",
                snapshot: snapshot, actions: actions + [action])
            cancelCapture()
            actions.append(action)
            message = nil
        } catch { message = Self.message(for: error) }
    }

    func removeAction(at index: Int) {
        guard !isDraining, actions.indices.contains(index) else { return }
        cancelCapture()
        actions.remove(at: index)
        message = nil
    }

    func prepare(request: ContextDemoCaptureRequest, sourceContentKey: String) throws -> ContextDemoDesktopPlan? {
        guard !isDraining else { throw ContextDemoDesktopError.alreadyRunning }
        guard usesActions else { return nil }
        guard let snapshot else { throw ContextDemoDesktopError.controlUnavailable }
        return try ContextDemoDesktopPlan.prepare(request: request, sourceContentKey: sourceContentKey,
            snapshot: snapshot, actions: actions)
    }

    func prepareCapture(plan: ContextDemoDesktopPlan, document: ContextDemoDocument,
                        capture: ContextDemoCaptureService) async throws -> ContextDemoCaptureRequest {
        guard !isDraining else { throw ContextDemoDesktopError.alreadyRunning }
        guard snapshot == plan.snapshot, actions == plan.actions,
              document.planId == plan.request.planId, document.revision == plan.request.revision,
              document.sourceContentKey == plan.sourceContentKey else {
            throw ContextDemoDesktopError.stalePlan
        }
        let token = generation
        let review = try await capture.prepare(request: plan.request, projectId: document.projectId)
        try Task.checkCancellation()
        guard token == generation, snapshot == plan.snapshot, actions == plan.actions,
              review.request == plan.request, review.target.binding == plan.snapshot.identity.window,
              review.target.processLaunchDate == plan.snapshot.identity.processLaunchDate else {
            throw ContextDemoDesktopError.stalePlan
        }
        self.plan = plan
        reviewedCapture = review
        return plan.request
    }

    func record(request: ContextDemoCaptureRequest, capture: ContextDemoCaptureService,
                current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws -> ContextDemoCaptureResult {
        guard !isDraining else { throw ContextDemoDesktopError.alreadyRunning }
        guard let plan, let reviewedCapture, plan.request == request else { throw ContextDemoDesktopError.stalePlan }
        try plan.validate(current: current())
        let approval = try service.approve(plan: plan, currentRequest: request, sourceContentKey: plan.sourceContentKey)
        self.reviewedCapture = nil
        self.capture = capture
        isDraining = true
        let token = generation
        let job = Task { @MainActor [self, service] in
            defer {
                recording = nil
                self.capture = nil
                self.plan = nil
                snapshot = nil
                actions = []
                isDraining = false
            }
            let result = try await service.record(plan: plan, approval: approval, reviewedCapture: reviewedCapture,
                capture: capture, current: current)
            do {
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                try plan.validate(current: current())
                return result
            } catch {
                try capture.discard(result.asset)
                throw error
            }
        }
        recording = job
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.cancelCapture()
            }
        }
    }

    func cancelCapture() {
        generation = UUID()
        plan = nil
        reviewedCapture = nil
        if let recording {
            service.cancel()
            capture?.cancel()
            recording.cancel()
        }
    }

    func invalidateInspection() {
        cancelCapture()
        service.cancel()
        snapshot = nil
        actions = []
        message = nil
    }

    func drain() async {
        if let recording { _ = try? await recording.value }
    }

    static func message(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let error = error as? ContextDemoDesktopError { return error.errorDescription }
        return ContextDemoSession.message(for: error)
    }
}
