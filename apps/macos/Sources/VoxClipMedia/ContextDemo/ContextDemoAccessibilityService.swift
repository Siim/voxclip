import Foundation
import VoxClipCore

@MainActor public final class ContextDemoAccessibilityService {
    private let driver: any ContextDemoAccessibilityDriving
    private let timing: any ContextDemoAccessibilityTiming
    private var checkedAvailability: ContextDemoAccessibilityAvailability?
    private var inspected: ContextDemoDesktopSnapshot?
    private var inspectedAt: Double = 0
    private var pendingApproval: ContextDemoDesktopApproval?
    private var approvedAt: Double = 0
    private var runID: UUID?
    private var actionTask: Task<Void, Error>?
    private var recording: (any ContextDemoAccessibilityRecording)?
    private var captureActive = false
    private var actionsCompleted = false
    private var recordingStarted = false
    private var actionFailure: Error?
    private var deadline: Double = 0

    public convenience init() {
        self.init(driver: ContextDemoAccessibilityDriver(), timing: ContextDemoAccessibilitySystemTiming())
    }

    init(driver: any ContextDemoAccessibilityDriving, timing: any ContextDemoAccessibilityTiming) {
        self.driver = driver; self.timing = timing
    }

    public func availability() -> ContextDemoAccessibilityAvailability {
        let result = driver.availability()
        checkedAvailability = result
        return result
    }

    public func inspect(target: ContextDemoCaptureTarget) throws -> ContextDemoDesktopSnapshot {
        guard runID == nil else { throw ContextDemoDesktopError.alreadyRunning }
        guard let checkedAvailability else { throw ContextDemoDesktopError.accessCheckRequired }
        guard checkedAvailability == .available else { throw ContextDemoDesktopError.permissionRequired }
        inspected = nil; pendingApproval = nil; driver.release()
        try Task.checkCancellation()
        let identity = ContextDemoDesktopIdentity(window: target.binding, processLaunchDate: target.processLaunchDate)
        let snapshot = try driver.inspect(identity: identity)
        try Task.checkCancellation()
        guard snapshot.identity == identity else { throw ContextDemoDesktopError.targetUnavailable }
        inspected = snapshot; inspectedAt = timing.now
        return snapshot
    }

    public func approve(plan: ContextDemoDesktopPlan, currentRequest: ContextDemoCaptureRequest,
                        sourceContentKey: String) throws -> ContextDemoDesktopApproval {
        guard runID == nil else { throw ContextDemoDesktopError.alreadyRunning }
        pendingApproval = nil
        try Task.checkCancellation()
        guard checkedAvailability == .available else { throw ContextDemoDesktopError.permissionRequired }
        try plan.validate(current: ContextDemoDesktopCurrent(request: currentRequest, sourceContentKey: sourceContentKey))
        guard inspected == plan.snapshot else { throw ContextDemoDesktopError.stalePlan }
        try checkFreshness(since: inspectedAt)
        let approval = ContextDemoDesktopApproval(planDigest: plan.digest, token: UUID())
        pendingApproval = approval; approvedAt = timing.now
        return approval
    }

    public func record(plan: ContextDemoDesktopPlan, approval: ContextDemoDesktopApproval,
                       reviewedCapture: ContextDemoReviewedCapture, capture: ContextDemoCaptureService,
                       current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws -> ContextDemoCaptureResult {
        guard reviewedCapture.request == plan.request,
              reviewedCapture.target.binding == plan.snapshot.identity.window,
              reviewedCapture.target.processLaunchDate == plan.snapshot.identity.processLaunchDate else {
            pendingApproval = nil
            throw ContextDemoDesktopError.stalePlan
        }
        return try await record(plan: plan, approval: approval,
            recording: ContextDemoAccessibilityCapture(service: capture, review: reviewedCapture), current: current)
    }

    func record(plan: ContextDemoDesktopPlan, approval: ContextDemoDesktopApproval,
                recording: any ContextDemoAccessibilityRecording,
                current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws -> ContextDemoCaptureResult {
        guard runID == nil else { throw ContextDemoDesktopError.alreadyRunning }
        guard pendingApproval == approval, approval.planDigest == plan.digest else {
            throw ContextDemoDesktopError.approvalRequired
        }
        pendingApproval = nil
        guard checkedAvailability == .available else { throw ContextDemoDesktopError.permissionRequired }
        try checkFreshness(since: approvedAt)
        try checkFreshness(since: inspectedAt)
        try plan.validate(current: current())
        try Task.checkCancellation()
        guard inspected == plan.snapshot else { throw ContextDemoDesktopError.stalePlan }
        try driver.validate(snapshot: plan.snapshot)
        try plan.validate(current: current())
        let token = UUID()
        runID = token; self.recording = recording
        captureActive = false; recordingStarted = false; actionsCompleted = false; actionFailure = nil
        defer {
            runID = nil; self.recording = nil; actionTask = nil
            inspected = nil; captureActive = false; driver.release()
        }
        return try await withTaskCancellationHandler {
            var result: ContextDemoCaptureResult?
            do {
                let captured = try await recording.start { [weak self] in
                    guard let self, self.runID == token, !self.recordingStarted else { return }
                    self.recordingStarted = true; self.captureActive = true
                    self.deadline = self.timing.now + plan.request.durationSeconds - 0.25
                    self.actionTask = Task { @MainActor [weak self] in
                        guard let self else { throw CancellationError() }
                        do {
                            try await self.runActions(plan: plan, token: token, current: current)
                            self.actionsCompleted = true
                            recording.finish()
                        } catch {
                            self.actionFailure = error
                            recording.cancel()
                            throw error
                        }
                    }
                }
                result = captured
                captureActive = false
                guard recordingStarted else { throw ContextDemoDesktopError.recordingNotStarted }
                guard let actionTask else { throw ContextDemoDesktopError.recordingNotStarted }
                if !actionsCompleted { actionTask.cancel() }
                do { try await actionTask.value }
                catch {
                    if !actionsCompleted, error is CancellationError, runID == token, !Task.isCancelled {
                        throw ContextDemoDesktopError.recordingEnded
                    }
                    throw error
                }
                try check(plan: plan, token: token, current: current, duringCapture: false)
                try driver.validate(snapshot: plan.snapshot)
                try check(plan: plan, token: token, current: current, duringCapture: false)
                guard actionsCompleted, captured.asset.requestId == plan.request.id,
                      captured.asset.target == plan.request.target else { throw ContextDemoDesktopError.recordingEnded }
                return captured
            } catch {
                captureActive = false
                recording.cancel(); actionTask?.cancel()
                if let actionTask { _ = try? await actionTask.value }
                if let result { try recording.discard(result.asset) }
                if Task.isCancelled || runID != token { throw CancellationError() }
                if let actionFailure, !(actionFailure is CancellationError) { throw actionFailure }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.runID == token else { return }
                self.cancel()
            }
        }
    }

    public func cancel() {
        pendingApproval = nil; inspected = nil
        if runID != nil {
            runID = UUID(); captureActive = false
            actionTask?.cancel(); recording?.cancel()
        } else { driver.release() }
    }

    private func runActions(plan: ContextDemoDesktopPlan, token: UUID,
                            current: @escaping @MainActor () -> ContextDemoDesktopCurrent?) async throws {
        for action in plan.actions {
            try check(plan: plan, token: token, current: current)
            if case .pause(let milliseconds) = action {
                let until = timing.now + Double(milliseconds) / 1_000
                while timing.now < until {
                    try check(plan: plan, token: token, current: current)
                    try await timing.pause(seconds: min(0.05, until - timing.now))
                }
                try driver.validate(snapshot: plan.snapshot)
            } else {
                try driver.perform(action, snapshot: plan.snapshot, deadline: deadline)
            }
            try check(plan: plan, token: token, current: current)
        }
    }

    private func check(plan: ContextDemoDesktopPlan, token: UUID,
                       current: @MainActor () -> ContextDemoDesktopCurrent?, duringCapture: Bool = true) throws {
        try Task.checkCancellation()
        guard runID == token else { throw CancellationError() }
        try plan.validate(current: current())
        if duringCapture {
            guard captureActive else { throw ContextDemoDesktopError.recordingEnded }
            guard timing.now < deadline else { throw ContextDemoDesktopError.timedOut }
        }
    }

    private func checkFreshness(since uptime: Double) throws {
        guard timing.now.isFinite, uptime.isFinite, timing.now >= uptime,
              timing.now - uptime < ContextDemoDesktopLimits.reviewLifetimeSeconds else {
            throw ContextDemoDesktopError.approvalExpired
        }
    }
}
