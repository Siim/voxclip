import Foundation
import VoxClipCore

public enum ContextDemoAccessibilityAvailability: Sendable, Equatable {
    case available, accessibilityPermissionRequired
}

public struct ContextDemoDesktopApproval: Sendable, Equatable {
    public let planDigest: String
    fileprivate let token: UUID

    init(planDigest: String, token: UUID) {
        self.planDigest = planDigest; self.token = token
    }
}

@MainActor protocol ContextDemoAccessibilityDriving: AnyObject {
    func availability() -> ContextDemoAccessibilityAvailability
    func inspect(identity: ContextDemoDesktopIdentity) throws -> ContextDemoDesktopSnapshot
    func validate(snapshot: ContextDemoDesktopSnapshot) throws
    func perform(_ action: ContextDemoDesktopAction, snapshot: ContextDemoDesktopSnapshot, deadline: Double) throws
    func release()
}

@MainActor protocol ContextDemoAccessibilityTiming: AnyObject {
    var now: Double { get }
    func pause(seconds: Double) async throws
}

@MainActor final class ContextDemoAccessibilitySystemTiming: ContextDemoAccessibilityTiming {
    var now: Double { ProcessInfo.processInfo.systemUptime }
    func pause(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor protocol ContextDemoAccessibilityRecording: AnyObject {
    func start(onStarted: @escaping @MainActor () -> Void) async throws -> ContextDemoCaptureResult
    func finish()
    func cancel()
    func discard(_ asset: ContextDemoAsset) throws
}

@MainActor final class ContextDemoAccessibilityCapture: ContextDemoAccessibilityRecording {
    private let service: ContextDemoCaptureService
    private let review: ContextDemoReviewedCapture

    init(service: ContextDemoCaptureService, review: ContextDemoReviewedCapture) {
        self.service = service; self.review = review
    }

    func start(onStarted: @escaping @MainActor () -> Void) async throws -> ContextDemoCaptureResult {
        try await service.start(reviewedPlan: review, currentRequest: review.request, onStarted: onStarted)
    }
    func finish() { service.finish() }
    func cancel() { service.cancel() }
    func discard(_ asset: ContextDemoAsset) throws { try service.discard(asset) }
}
