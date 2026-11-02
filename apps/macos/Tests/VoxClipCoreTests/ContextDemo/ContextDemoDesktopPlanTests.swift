import Foundation
import Testing
import VoxClipCore

@Suite("Ephemeral reviewed desktop plans")
struct ContextDemoDesktopPlanTests {
    private func identity(window: UInt32 = 42, process: Int32 = 123, bundle: String = "com.example.Demo",
                          launch: Double = 1) -> ContextDemoDesktopIdentity {
        ContextDemoDesktopIdentity(window: ContextDemoWindowBinding(windowID: window, processID: process, bundleID: bundle),
                                   processLaunchDate: Date(timeIntervalSince1970: launch))
    }

    private func control(identifier: String = "show-details", role: String = "AXButton", path: [Int] = [0],
                         capability: ContextDemoDesktopCapability = .press) throws -> ContextDemoDesktopControl {
        try ContextDemoDesktopControl(childPath: path,
            ancestry: [ContextDemoDesktopNodeIdentity(role: "AXWindow")]
                + path.dropLast().map { _ in ContextDemoDesktopNodeIdentity(role: "AXGroup") }
                + [ContextDemoDesktopNodeIdentity(role: role, identifier: identifier)], capabilities: [capability])
    }

    private func request(identity: ContextDemoDesktopIdentity? = nil, revision: Int = 0,
                         duration: Double = 10) -> ContextDemoCaptureRequest {
        let identity = identity ?? self.identity()
        return ContextDemoCaptureRequest(id: "request-one", planId: "plan-one", revision: revision,
            target: ContextDemoTarget(kind: .desktopApp, displayName: "Demo", locator: identity.window.bundleID),
            durationSeconds: duration, window: identity.window)
    }

    @Test func reviewSummariesBindExactImmutablePlanDigest() throws {
        let control = try control(capability: .focus)
        let snapshot = try ContextDemoDesktopSnapshot(identity: identity(), controls: [control])
        let plan = try ContextDemoDesktopPlan.prepare(request: request(), sourceContentKey: "source-one",
            snapshot: snapshot, actions: [.focus(control)])
        #expect(plan.request.actions[0].summary.contains(plan.digest))
        #expect(plan.request.actions[1].summary == plan.actions[0].reviewDescription)
    }

    @Test func deterministicDigestAndTypedSummaries() throws {
        let control = try control()
        let snapshot = try ContextDemoDesktopSnapshot(identity: identity(), controls: [control])
        let plan = try ContextDemoDesktopPlan.prepare(request: request(), sourceContentKey: "source-one",
            snapshot: snapshot, actions: [.press(control), .pause(milliseconds: 500)])
        let same = try ContextDemoDesktopPlan.prepare(request: request(), sourceContentKey: "source-one",
            snapshot: snapshot, actions: plan.actions)
        #expect(plan == same)
        #expect(plan.digest.count == 64)
        #expect(plan.request.actions.count == 3)
        #expect(plan.request.actions[0].summary.contains(plan.digest))
        #expect(plan.request.actions[1].summary == plan.actions[0].reviewDescription)
        #expect(plan.request.actions[1].summary.contains("show-details"))
        #expect(plan.request.actions[2].summary == "Pause for 500 milliseconds")
        try plan.request.validate()
        try plan.validate(current: ContextDemoDesktopCurrent(request: plan.request, sourceContentKey: "source-one"))
        #expect(throws: ContextDemoDesktopError.stalePlan) {
            try plan.validate(current: ContextDemoDesktopCurrent(request: request(), sourceContentKey: "source-one"))
        }
    }

    @Test func digestChangesForEveryAuthorizationBinding() throws {
        let control = try control()
        let inspectionID = UUID()
        func prepare(identity: ContextDemoDesktopIdentity, source: String = "source-one", revision: Int = 0,
                     duration: Double = 10, actions: [ContextDemoDesktopAction]? = nil,
                     inspection: UUID? = nil) throws -> ContextDemoDesktopPlan {
            try ContextDemoDesktopPlan.prepare(request: request(identity: identity, revision: revision, duration: duration),
                sourceContentKey: source, snapshot: ContextDemoDesktopSnapshot(identity: identity,
                    inspectionID: inspection ?? inspectionID, controls: [control]), actions: actions ?? [.press(control)])
        }
        let original = try prepare(identity: identity())
        let variants = try [prepare(identity: identity(window: 43)), prepare(identity: identity(process: 124)),
            prepare(identity: identity(bundle: "com.example.Other")), prepare(identity: identity(launch: 2)),
            prepare(identity: identity(), source: "source-two"), prepare(identity: identity(), revision: 1),
            prepare(identity: identity(), duration: 11), prepare(identity: identity(), actions: [.press(control), .pause(milliseconds: 1)]),
            prepare(identity: identity(), inspection: UUID())]
        #expect(variants.allSatisfy { $0.digest != original.digest })
    }

    @Test func sourceRequestAndRevisionChangesRefuse() throws {
        let control = try control()
        let plan = try ContextDemoDesktopPlan.prepare(request: request(), sourceContentKey: "source-one",
            snapshot: ContextDemoDesktopSnapshot(identity: identity(), controls: [control]), actions: [.press(control)])
        #expect(throws: ContextDemoDesktopError.stalePlan) { try plan.validate(current: nil) }
        #expect(throws: ContextDemoDesktopError.stalePlan) {
            try plan.validate(current: ContextDemoDesktopCurrent(request: plan.request, sourceContentKey: "source-two"))
        }
        #expect(throws: ContextDemoDesktopError.stalePlan) {
            try plan.validate(current: ContextDemoDesktopCurrent(request: request(revision: 1), sourceContentKey: "source-one"))
        }
    }

    @Test func exactWindowAndNonDesktopTargetsRefuse() throws {
        let control = try control()
        let snapshot = try ContextDemoDesktopSnapshot(identity: identity(), controls: [control])
        #expect(throws: ContextDemoDesktopError.invalidPlan) {
            try ContextDemoDesktopPlan.prepare(request: request(identity: identity(window: 43)),
                sourceContentKey: "source-one", snapshot: snapshot, actions: [.press(control)])
        }
        let web = ContextDemoCaptureRequest(id: "request-one", planId: "plan-one", revision: 0,
            target: ContextDemoTarget(kind: .webPage, displayName: "Web", locator: "https://example.com"),
            durationSeconds: 10, window: identity().window)
        #expect(throws: ContextDemoDesktopError.invalidPlan) {
            try ContextDemoDesktopPlan.prepare(request: web, sourceContentKey: "source-one", snapshot: snapshot, actions: [.press(control)])
        }
    }

    @Test func missingOrChangedControlAndUnsupportedCapabilityRefuse() throws {
        let original = try control(), changed = try control(identifier: "other")
        let snapshot = try ContextDemoDesktopSnapshot(identity: identity(), controls: [original])
        #expect(throws: ContextDemoDesktopError.controlUnavailable) {
            try ContextDemoDesktopPlan.prepare(request: request(), sourceContentKey: "source-one", snapshot: snapshot,
                actions: [.press(changed)])
        }
        #expect(throws: ContextDemoDesktopError.unsupportedAction) {
            try ContextDemoDesktopPlan.prepare(request: request(), sourceContentKey: "source-one", snapshot: snapshot,
                actions: [.focus(original)])
        }
        #expect(try control(path: [1]).fingerprint != original.fingerprint)
    }

    @Test func selectedProjectWindowDoesNotAuthorizeProjectExecution() throws {
        let control = try control()
        let request = ContextDemoCaptureRequest(id: "request-one", planId: "plan-one", revision: 0,
            target: ContextDemoTarget(kind: .codeProject, displayName: "Selected project", locator: "file:///approved/project"),
            durationSeconds: 10, window: identity().window)
        let plan = try ContextDemoDesktopPlan.prepare(request: request, sourceContentKey: "source-one",
            snapshot: ContextDemoDesktopSnapshot(identity: identity(), controls: [control]), actions: [.press(control)])
        #expect(plan.request.target == request.target)
        #expect(plan.request.window == request.window)
        #expect(plan.actions == [.press(control)])
    }

    @Test func sensitiveMetadataAndUnsafeRolesNeverBecomeActionable() throws {
        for identifier in ["password", "access-token", "credential", "api_key", "otp-code"] {
            #expect(throws: ContextDemoDesktopError.unsafeControl) { try control(identifier: identifier) }
        }
        #expect(throws: ContextDemoDesktopError.unsafeControl) {
            try ContextDemoDesktopControl(childPath: [0], ancestry: [ContextDemoDesktopNodeIdentity(role: "AXWindow"),
                ContextDemoDesktopNodeIdentity(role: "AXTextField", subrole: "AXSecureTextField", identifier: "entry")],
                capabilities: [.setNonsecretValue])
        }
        #expect(throws: ContextDemoDesktopError.unsupportedAction) {
            try control(identifier: "terminal", role: "AXTextArea", capability: .setNonsecretValue)
        }
        #expect(throws: ContextDemoDesktopError.unsupportedAction) {
            try control(identifier: "link", role: "AXLink")
        }
    }

    @Test func nonsecretReplacementIsExplicitBoundedAndReviewed() throws {
        let field = try control(identifier: "caption", role: "AXTextField", capability: .setNonsecretValue)
        let snapshot = try ContextDemoDesktopSnapshot(identity: identity(), controls: [field])
        let plan = try ContextDemoDesktopPlan.prepare(request: request(), sourceContentKey: "source-one", snapshot: snapshot,
            actions: [.setNonsecretValue(field, value: "Demo caption")])
        #expect(plan.request.actions[1].summary.contains("Demo caption"))
        for value in ["", "line\nbreak", String(repeating: "x", count: 257), "password=not-a-real-value"] {
            #expect(throws: ContextDemoDesktopError.unsafeControl) {
                try ContextDemoDesktopPlan.prepare(request: request(), sourceContentKey: "source-one", snapshot: snapshot,
                    actions: [.setNonsecretValue(field, value: value)])
            }
        }
    }

    @Test func actionCountPauseAndCaptureBudgetsAreHardBounds() throws {
        let control = try control()
        let snapshot = try ContextDemoDesktopSnapshot(identity: identity(), controls: [control])
        let invalidActions: [[ContextDemoDesktopAction]] = [[], [.pause(milliseconds: 1)], [.press(control), .pause(milliseconds: 5_001)],
            [.press(control), .pause(milliseconds: 0)], Array(repeating: .press(control), count: 13)]
        for actions in invalidActions {
            #expect(throws: ContextDemoDesktopError.invalidPlan) {
                try ContextDemoDesktopPlan.prepare(request: request(duration: 30), sourceContentKey: "source-one",
                    snapshot: snapshot, actions: actions)
            }
        }
        #expect(throws: ContextDemoDesktopError.invalidPlan) {
            try ContextDemoDesktopPlan.prepare(request: request(duration: 1), sourceContentKey: "source-one",
                snapshot: snapshot, actions: [.press(control)])
        }
    }

    @Test func snapshotAndPathLimitsRefuseAmbiguousInputs() throws {
        let control = try control()
        #expect(throws: ContextDemoDesktopError.invalidPlan) {
            try ContextDemoDesktopSnapshot(identity: identity(), controls: [control, control])
        }
        #expect(throws: ContextDemoDesktopError.invalidPlan) {
            try self.control(path: Array(repeating: 0, count: 9))
        }
        #expect(throws: ContextDemoDesktopError.invalidPlan) {
            try ContextDemoDesktopSnapshot(identity: identity(launch: .nan), controls: [control])
        }
    }
}
