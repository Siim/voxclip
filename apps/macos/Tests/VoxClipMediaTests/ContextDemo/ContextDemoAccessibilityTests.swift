import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite("Desktop automation recording and approval boundary") @MainActor
struct ContextDemoAccessibilityTests {
    @Test func constructionNeverQueriesAccessibilityOrStartsActions() throws {
        let fixture = try DesktopAutomationFixture()
        let driver = DesktopAutomationDriverFake(snapshot: fixture.plan.snapshot, events: fixture.events)
        _ = ContextDemoAccessibilityService(driver: driver, timing: fixture.timing)
        #expect(driver.availabilityCount == 0 && driver.inspectionCount == 0 && driver.performed.isEmpty)
    }

    @Test func callerMustExplicitlyCheckAccessBeforeInspection() throws {
        let fixture = try DesktopAutomationFixture()
        let driver = DesktopAutomationDriverFake(snapshot: fixture.plan.snapshot, events: fixture.events)
        let service = ContextDemoAccessibilityService(driver: driver, timing: fixture.timing)
        #expect(throws: ContextDemoDesktopError.accessCheckRequired) { try service.inspect(target: desktopAutomationTarget()) }
        #expect(driver.availabilityCount == 0 && driver.inspectionCount == 0)
        driver.permission = .accessibilityPermissionRequired
        #expect(service.availability() == .accessibilityPermissionRequired)
        #expect(throws: ContextDemoDesktopError.permissionRequired) { try service.inspect(target: desktopAutomationTarget()) }
        #expect(driver.inspectionCount == 0)
    }

    @Test func reviewAndApprovalDoNotRecordOrInteract() throws {
        let fixture = try DesktopAutomationFixture()
        _ = try fixture.approval()
        #expect(fixture.recording.startCount == 0 && fixture.driver.performed.isEmpty)
    }

    @Test func actionsStartOnlyAfterNativeRecordingAcknowledgement() async throws {
        let fixture = try DesktopAutomationFixture()
        let approval = try fixture.approval()
        let result = try await fixture.record(approval)
        #expect(result.asset.requestId == fixture.plan.request.id)
        #expect(fixture.events.values == ["recording-started", "action", "finish"])
        #expect(fixture.recording.discardCount == 0)
        await #expect(throws: ContextDemoDesktopError.approvalRequired) { try await fixture.record(approval) }
        #expect(fixture.recording.startCount == 1 && fixture.driver.performed.count == 1)
    }

    @Test func startFailureNeverRunsActionsAndConsumesApproval() async throws {
        let fixture = try DesktopAutomationFixture()
        fixture.recording.startFailure = .nativeFailure
        let approval = try fixture.approval()
        await #expect(throws: ContextDemoDesktopError.nativeFailure) { try await fixture.record(approval) }
        #expect(fixture.driver.performed.isEmpty)
        await #expect(throws: ContextDemoDesktopError.approvalRequired) { try await fixture.record(approval) }
    }

    @Test func noAcknowledgementOrEarlyRecordingEndDiscardsResultWithoutActions() async throws {
        for acknowledged in [false, true] {
            let fixture = try DesktopAutomationFixture()
            fixture.recording.acknowledgeStart = acknowledged
            fixture.recording.returnImmediately = true
            let approval = try fixture.approval()
            let expected: ContextDemoDesktopError = acknowledged ? .recordingEnded : .recordingNotStarted
            await #expect(throws: expected) { try await fixture.record(approval) }
            #expect(fixture.driver.performed.isEmpty && fixture.recording.discardCount == 1)
        }
    }

    @Test func repeatedAcknowledgementCannotReplayActions() async throws {
        let fixture = try DesktopAutomationFixture()
        fixture.recording.repeatStartCallback = true
        _ = try await fixture.record(fixture.approval())
        #expect(fixture.driver.performed.count == 1)
    }

    @Test func staleSourceBeforeRecordingNeverStartsCapture() async throws {
        let fixture = try DesktopAutomationFixture()
        let approval = try fixture.approval()
        fixture.current.value = ContextDemoDesktopCurrent(request: fixture.plan.request, sourceContentKey: "different-source")
        await #expect(throws: ContextDemoDesktopError.stalePlan) { try await fixture.record(approval) }
        #expect(fixture.recording.startCount == 0 && fixture.driver.performed.isEmpty)
    }

    @Test func stalenessDuringStartRefusesFirstAction() async throws {
        let fixture = try DesktopAutomationFixture()
        fixture.recording.beforeAcknowledgement = { fixture.current.value = nil }
        await #expect(throws: ContextDemoDesktopError.stalePlan) { try await fixture.record(fixture.approval()) }
        #expect(fixture.driver.performed.isEmpty && fixture.recording.cancelled)
    }

    @Test func nativeRefusalIsInlineNotMisreportedAsUserCancellation() async throws {
        let fixture = try DesktopAutomationFixture()
        fixture.driver.failure = .controlUnavailable
        await #expect(throws: ContextDemoDesktopError.controlUnavailable) { try await fixture.record(fixture.approval()) }
        #expect(fixture.recording.cancelled && fixture.driver.performed.isEmpty)
    }

    @Test func staleCompletionAfterAnActionCancelsCapture() async throws {
        let fixture = try DesktopAutomationFixture()
        fixture.driver.onPerform = { fixture.current.value = nil }
        await #expect(throws: ContextDemoDesktopError.stalePlan) { try await fixture.record(fixture.approval()) }
        #expect(fixture.driver.performed.count == 1 && fixture.recording.cancelled)
    }

    @Test func cancellationDuringPausePreventsLaterActionsAndDrains() async throws {
        let fixture = try DesktopAutomationFixture(withPause: true)
        fixture.timing.onPause = { fixture.service.cancel() }
        await #expect(throws: CancellationError.self) { try await fixture.record(fixture.approval()) }
        #expect(fixture.driver.performed.isEmpty && fixture.recording.cancelled)
        #expect(throws: ContextDemoDesktopError.stalePlan) { try fixture.approval() }
    }

    @Test func taskCancellationDuringPausePreventsLaterActions() async throws {
        let fixture = try DesktopAutomationFixture(withPause: true)
        let approval = try fixture.approval()
        var operation: Task<ContextDemoCaptureResult, Error>?
        fixture.timing.onPause = { operation?.cancel() }
        operation = Task { @MainActor in try await fixture.record(approval) }
        defer { fixture.timing.onPause = nil; operation = nil }
        let task = try #require(operation)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.driver.performed.isEmpty && fixture.recording.cancelled)
    }

    @Test func staleOrCancelledLateCaptureResultIsDiscarded() async throws {
        for cancelled in [false, true] {
            let fixture = try DesktopAutomationFixture()
            fixture.recording.beforeReturn = {
                if cancelled { fixture.service.cancel() }
                else { fixture.current.value = nil }
            }
            if cancelled {
                await #expect(throws: CancellationError.self) { try await fixture.record(fixture.approval()) }
            } else {
                await #expect(throws: ContextDemoDesktopError.stalePlan) { try await fixture.record(fixture.approval()) }
            }
            #expect(fixture.recording.discardCount == 1)
        }
    }

    @Test func lateResultAfterCancelledActionsIsDiscarded() async throws {
        let fixture = try DesktopAutomationFixture(withPause: true)
        fixture.recording.returnAfterCancel = true
        fixture.timing.onPause = { fixture.service.cancel() }
        await #expect(throws: CancellationError.self) { try await fixture.record(fixture.approval()) }
        #expect(fixture.recording.discardCount == 1 && fixture.driver.performed.isEmpty)
    }

    @Test func exactWindowIsRevalidatedBeforeAcceptingLateCaptureResult() async throws {
        let fixture = try DesktopAutomationFixture()
        fixture.recording.beforeReturn = { fixture.driver.validationFailure = .targetUnavailable }
        await #expect(throws: ContextDemoDesktopError.targetUnavailable) { try await fixture.record(fixture.approval()) }
        #expect(fixture.recording.discardCount == 1)
    }

    @Test func reviewAndApprovalExpireAndClockRollbackRefuses() async throws {
        for uptime in [99.0, 220.0, 221.0] {
            let fixture = try DesktopAutomationFixture()
            let approval = try fixture.approval()
            fixture.timing.now = uptime
            await #expect(throws: ContextDemoDesktopError.approvalExpired) { try await fixture.record(approval) }
            #expect(fixture.recording.startCount == 0 && fixture.driver.performed.isEmpty)
        }
        let fixture = try DesktopAutomationFixture()
        fixture.timing.now = 220
        #expect(throws: ContextDemoDesktopError.approvalExpired) { try fixture.approval() }
    }

    @Test func captureDeadlineRefusesAnyNextAction() async throws {
        let fixture = try DesktopAutomationFixture(withPause: true)
        fixture.timing.onPause = { fixture.timing.now += 20 }
        await #expect(throws: ContextDemoDesktopError.timedOut) { try await fixture.record(fixture.approval()) }
        #expect(fixture.driver.performed.isEmpty && fixture.recording.cancelled)
    }

    @Test func staleInspectionAndReplacedApprovalsRefuse() async throws {
        let fixture = try DesktopAutomationFixture()
        let old = try fixture.approval()
        let replacement = try fixture.approval()
        await #expect(throws: ContextDemoDesktopError.approvalRequired) { try await fixture.record(old) }
        _ = try await fixture.record(replacement)
        #expect(fixture.recording.startCount == 1)
    }

    @Test func publicCaptureAdapterRejectsDifferentRequestOrProcessLaunchBeforeStart() async throws {
        for changedLaunch in [false, true] {
            let fixture = try DesktopAutomationFixture()
            let backend = DesktopAutomationCaptureBackendFake()
            if changedLaunch {
                let original = backend.target
                backend.target = ContextDemoCaptureTarget(windowID: original.windowID, processID: original.processID,
                    bundleIdentifier: original.bundleIdentifier, applicationName: original.applicationName,
                    windowTitle: original.windowTitle, processLaunchDate: Date(timeIntervalSince1970: 2),
                    widthPoints: original.widthPoints, heightPoints: original.heightPoints, pixelScale: original.pixelScale)
            }
            let capture = ContextDemoCaptureService(backend: backend, inspector: DesktopAutomationRecordingInspectorFake(),
                timing: ContextDemoSystemTiming(), store: ContextDemoAssetStore(rootURL: URL(fileURLWithPath: "/not-created/desktop-adapter-test")))
            let request = changedLaunch ? fixture.plan.request : ContextDemoCaptureRequest(id: "another-request", planId: "plan-one",
                revision: 0, target: fixture.plan.request.target, durationSeconds: 10, window: fixture.plan.request.window)
            let review = try await capture.prepare(request: request, projectId: "11111111-1111-4111-8111-111111111111")
            let approval = try fixture.approval()
            await #expect(throws: ContextDemoDesktopError.stalePlan) {
                try await fixture.service.record(plan: fixture.plan, approval: approval, reviewedCapture: review,
                    capture: capture, current: { fixture.current.value })
            }
            #expect(backend.beginCount == 0 && fixture.driver.performed.isEmpty)
        }
    }
}
