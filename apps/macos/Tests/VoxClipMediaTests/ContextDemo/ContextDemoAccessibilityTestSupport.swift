import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@MainActor final class DesktopAutomationEvents {
    var values: [String] = []
}

func desktopAutomationTarget() -> ContextDemoCaptureTarget {
    ContextDemoCaptureTarget(windowID: 42, processID: 123, bundleIdentifier: "com.example.Demo",
        applicationName: "Demo", windowTitle: "Reviewed window", processLaunchDate: Date(timeIntervalSince1970: 1),
        widthPoints: 640, heightPoints: 480, pixelScale: 1)
}

func desktopAutomationControl(role: String = "AXButton", identifier: String = "show-details", path: [Int] = [0],
                              capabilities: [ContextDemoDesktopCapability] = [.focus, .press]) throws -> ContextDemoDesktopControl {
    try ContextDemoDesktopControl(childPath: path,
        ancestry: [ContextDemoDesktopNodeIdentity(role: "AXWindow", identifier: "main-window")]
            + path.dropLast().map { _ in ContextDemoDesktopNodeIdentity(role: "AXGroup") }
            + [ContextDemoDesktopNodeIdentity(role: role, identifier: identifier)], capabilities: capabilities)
}

@MainActor final class DesktopAutomationClock: ContextDemoAccessibilityTiming {
    var now: Double = 100
    var onPause: (() -> Void)?
    func pause(seconds: Double) async throws {
        try Task.checkCancellation()
        now += seconds
        onPause?()
        await Task.yield()
        try Task.checkCancellation()
    }
}

@MainActor final class DesktopAutomationDriverFake: ContextDemoAccessibilityDriving {
    let snapshot: ContextDemoDesktopSnapshot
    let events: DesktopAutomationEvents
    var permission: ContextDemoAccessibilityAvailability = .available
    var availabilityCount = 0
    var inspectionCount = 0
    var validationCount = 0
    var performed: [ContextDemoDesktopAction] = []
    var failure: ContextDemoDesktopError?
    var validationFailure: ContextDemoDesktopError?
    var onPerform: (() -> Void)?

    init(snapshot: ContextDemoDesktopSnapshot, events: DesktopAutomationEvents) {
        self.snapshot = snapshot; self.events = events
    }
    func availability() -> ContextDemoAccessibilityAvailability { availabilityCount += 1; return permission }
    func inspect(identity: ContextDemoDesktopIdentity) throws -> ContextDemoDesktopSnapshot {
        inspectionCount += 1
        guard identity == snapshot.identity else { throw ContextDemoDesktopError.targetUnavailable }
        return snapshot
    }
    func validate(snapshot: ContextDemoDesktopSnapshot) throws {
        validationCount += 1
        if let validationFailure { throw validationFailure }
        guard snapshot == self.snapshot else { throw ContextDemoDesktopError.stalePlan }
    }
    func perform(_ action: ContextDemoDesktopAction, snapshot: ContextDemoDesktopSnapshot, deadline: Double) throws {
        try validate(snapshot: snapshot)
        if let failure { throw failure }
        performed.append(action); events.values.append("action")
        onPerform?()
    }
    func release() {}
}

@MainActor final class DesktopAutomationRecordingFake: ContextDemoAccessibilityRecording {
    let events: DesktopAutomationEvents
    var result: ContextDemoCaptureResult
    var startCount = 0
    var discardCount = 0
    var finished = false
    var cancelled = false
    var acknowledgeStart = true
    var returnImmediately = false
    var returnAfterCancel = false
    var repeatStartCallback = false
    var beforeAcknowledgement: (() -> Void)?
    var beforeReturn: (() -> Void)?
    var startFailure: ContextDemoDesktopError?

    init(request: ContextDemoCaptureRequest, events: DesktopAutomationEvents) {
        self.events = events
        self.result = ContextDemoCaptureResult(asset: ContextDemoAsset(id: "test-asset", requestId: request.id,
            target: request.target, relativePath: "context-demo/test-project/test-asset.mp4",
            sha256: String(repeating: "a", count: 64), durationSeconds: 1, pixelWidth: 640, pixelHeight: 480,
            byteSize: 128, createdAt: Date(timeIntervalSince1970: 1)),
            url: URL(fileURLWithPath: "/not-created/context-demo/test-project/test-asset.mp4"))
    }

    func start(onStarted: @escaping @MainActor () -> Void) async throws -> ContextDemoCaptureResult {
        startCount += 1
        if let startFailure { throw startFailure }
        beforeAcknowledgement?()
        if acknowledgeStart {
            events.values.append("recording-started")
            onStarted()
            if repeatStartCallback { onStarted() }
        }
        if !returnImmediately {
            await TestDeadline.until { finished || cancelled || Task.isCancelled }
            try Task.checkCancellation()
        }
        if cancelled && !returnAfterCancel { throw CancellationError() }
        beforeReturn?()
        return result
    }
    func finish() { finished = true; events.values.append("finish") }
    func cancel() { cancelled = true; events.values.append("cancel") }
    func discard(_ asset: ContextDemoAsset) throws { discardCount += 1; events.values.append("discard") }
}

@MainActor final class DesktopAutomationCurrent {
    var value: ContextDemoDesktopCurrent?
    init(_ value: ContextDemoDesktopCurrent?) { self.value = value }
}

@MainActor struct DesktopAutomationFixture {
    let service: ContextDemoAccessibilityService
    let driver: DesktopAutomationDriverFake
    let timing: DesktopAutomationClock
    let recording: DesktopAutomationRecordingFake
    let plan: ContextDemoDesktopPlan
    let current: DesktopAutomationCurrent
    let events: DesktopAutomationEvents

    init(withPause: Bool = false) throws {
        let target = desktopAutomationTarget()
        let control = try desktopAutomationControl()
        let snapshot = try ContextDemoDesktopSnapshot(identity: ContextDemoDesktopIdentity(window: target.binding,
            processLaunchDate: target.processLaunchDate), controls: [control])
        let events = DesktopAutomationEvents(), timing = DesktopAutomationClock()
        let driver = DesktopAutomationDriverFake(snapshot: snapshot, events: events)
        let service = ContextDemoAccessibilityService(driver: driver, timing: timing)
        _ = service.availability()
        let inspected = try service.inspect(target: target)
        let request = ContextDemoCaptureRequest(id: "request-one", planId: "plan-one", revision: 0,
            target: ContextDemoTarget(kind: .desktopApp, displayName: "Demo", locator: target.bundleIdentifier),
            durationSeconds: 10, window: target.binding)
        let actions: [ContextDemoDesktopAction] = withPause ? [.pause(milliseconds: 500), .press(control)] : [.press(control)]
        let plan = try ContextDemoDesktopPlan.prepare(request: request, sourceContentKey: "source-one",
            snapshot: inspected, actions: actions)
        self.service = service; self.driver = driver; self.timing = timing; self.plan = plan; self.events = events
        self.recording = DesktopAutomationRecordingFake(request: plan.request, events: events)
        self.current = DesktopAutomationCurrent(ContextDemoDesktopCurrent(request: plan.request, sourceContentKey: "source-one"))
    }

    func approval() throws -> ContextDemoDesktopApproval {
        try service.approve(plan: plan, currentRequest: plan.request, sourceContentKey: "source-one")
    }

    func record(_ approval: ContextDemoDesktopApproval) async throws -> ContextDemoCaptureResult {
        try await service.record(plan: plan, approval: approval, recording: recording, current: { current.value })
    }
}

@MainActor final class DesktopAutomationAXFake: ContextDemoAccessibilityAX {
    var deadline: Double = 0
    var identity = ContextDemoDesktopIdentity(window: desktopAutomationTarget().binding,
        processLaunchDate: desktopAutomationTarget().processLaunchDate)
    let applicationElement = ContextDemoAccessibilityElement(key: 0)
    let windowElement = ContextDemoAccessibilityElement(key: 1)
    let buttonElement = ContextDemoAccessibilityElement(key: 2)
    var windows = [ContextDemoAccessibilityElement(key: 1)]
    var windowIDs: [Int: UInt32] = [1: 42]
    var nodes: [Int: ContextDemoDesktopNodeIdentity] = [
        1: ContextDemoDesktopNodeIdentity(role: "AXWindow", identifier: "main-window"),
        2: ContextDemoDesktopNodeIdentity(role: "AXButton", identifier: "show-details")]
    var children: [Int: [ContextDemoAccessibilityElement]] = [1: [ContextDemoAccessibilityElement(key: 2)]]
    var owners: [Int: Int] = [:]
    var processes: [Int: Int32] = [:]
    var supported: [Int: [ContextDemoDesktopCapability]] = [2: [.focus, .press]]
    var metadataReads: [Int] = []
    var childReads: [Int] = []
    var performed: [ContextDemoDesktopAction] = []
    var onMetadata: (() -> Void)?
    var mappingUnavailable = false

    func availability() -> ContextDemoAccessibilityAvailability { .available }
    func processMatches(_ identity: ContextDemoDesktopIdentity) -> Bool { self.identity == identity }
    func application(processID: Int32) throws -> ContextDemoAccessibilityElement { applicationElement }
    func processID(of element: ContextDemoAccessibilityElement) throws -> Int32 { processes[element.key] ?? identity.window.processID }
    func windowID(of element: ContextDemoAccessibilityElement) throws -> UInt32 {
        if mappingUnavailable { throw ContextDemoDesktopError.unsupportedWindow }
        return windowIDs[element.key] ?? 0
    }
    func elements(of element: ContextDemoAccessibilityElement, windows: Bool,
                  maximum: Int) throws -> [ContextDemoAccessibilityElement] {
        childReads.append(element.key)
        let result = windows ? self.windows : children[element.key] ?? []
        guard result.count <= maximum else { throw ContextDemoDesktopError.treeLimitExceeded }
        return result
    }
    func belongsToWindow(_ element: ContextDemoAccessibilityElement, window: ContextDemoAccessibilityElement) throws -> Bool {
        (owners[element.key] ?? 1) == window.key
    }
    func metadata(of element: ContextDemoAccessibilityElement) throws -> ContextDemoDesktopNodeIdentity? {
        metadataReads.append(element.key); onMetadata?()
        return nodes[element.key]
    }
    func capabilities(of element: ContextDemoAccessibilityElement,
                      node: ContextDemoDesktopNodeIdentity) throws -> [ContextDemoDesktopCapability] { supported[element.key] ?? [] }
    func perform(_ action: ContextDemoDesktopAction, on element: ContextDemoAccessibilityElement) throws { performed.append(action) }
    func release() {}
}

@MainActor final class DesktopAutomationCaptureBackendFake: ContextDemoCaptureBackend {
    var target = desktopAutomationTarget()
    var beginCount = 0
    func availability() -> ContextDemoCaptureAvailability { .available }
    func windows() async throws -> [ContextDemoCaptureTarget] { [target] }
    func begin(window: ContextDemoCaptureTarget, output: URL, width: Int, height: Int) async throws {
        beginCount += 1
        throw ContextDemoCaptureError.failedToStart
    }
    func snapshot() -> ContextDemoCaptureSnapshot { ContextDemoCaptureSnapshot(stopped: true) }
    func stop() {}
    func release() {}
}

@MainActor struct DesktopAutomationRecordingInspectorFake: ContextDemoRecordingInspecting {
    func inspect(_ url: URL) async throws -> ContextDemoRecordingMetadata { throw ContextDemoCaptureError.invalidRecording }
}
