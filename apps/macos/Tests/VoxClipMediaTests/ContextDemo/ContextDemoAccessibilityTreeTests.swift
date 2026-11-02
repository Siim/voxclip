import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite("Exact-window bounded accessibility traversal") @MainActor
struct ContextDemoAccessibilityTreeTests {
    private func fixture() -> (ContextDemoAccessibilityDriver, DesktopAutomationAXFake) {
        let boundary = DesktopAutomationAXFake()
        return (ContextDemoAccessibilityDriver(boundary: boundary, now: { 100 }), boundary)
    }

    @Test func exactWindowProducesStableFingerprintsAndElementTargetedActions() throws {
        let (driver, boundary) = fixture()
        let snapshot = try driver.inspect(identity: boundary.identity)
        let control = try #require(snapshot.controls.first)
        #expect(control.childPath == [0] && control.node.identifier == "show-details")
        try driver.perform(.press(control), snapshot: snapshot, deadline: 110)
        #expect(boundary.performed == [.press(control)])
        let next = try driver.inspect(identity: boundary.identity)
        #expect(next.controls.first?.fingerprint == control.fingerprint)
        #expect(next.inspectionID != snapshot.inspectionID)
        #expect(throws: ContextDemoDesktopError.stalePlan) { try driver.validate(snapshot: snapshot) }
    }

    @Test func pidBundleAndLaunchIdentityChangesNeverSubstitute() throws {
        let (driver, boundary) = fixture()
        let expected = boundary.identity
        let snapshot = try driver.inspect(identity: expected)
        let changes = [ContextDemoDesktopIdentity(window: ContextDemoWindowBinding(windowID: 42, processID: 124,
                bundleID: expected.window.bundleID), processLaunchDate: expected.processLaunchDate),
            ContextDemoDesktopIdentity(window: ContextDemoWindowBinding(windowID: 42, processID: 123,
                bundleID: "com.example.Other"), processLaunchDate: expected.processLaunchDate),
            ContextDemoDesktopIdentity(window: expected.window, processLaunchDate: Date(timeIntervalSince1970: 2))]
        for identity in changes {
            boundary.identity = identity
            #expect(throws: ContextDemoDesktopError.targetUnavailable) { try driver.validate(snapshot: snapshot) }
        }
        #expect(boundary.performed.isEmpty)
    }

    @Test func missingAmbiguousAndUnsupportedWindowIDsRefuse() throws {
        for variant in 0...2 {
            let (driver, boundary) = fixture()
            if variant == 0 { boundary.windowIDs[1] = 43 }
            if variant == 1 {
                boundary.windows.append(ContextDemoAccessibilityElement(key: 3)); boundary.windowIDs[3] = 42
            }
            if variant == 2 { boundary.mappingUnavailable = true }
            let error: ContextDemoDesktopError = variant == 2 ? .unsupportedWindow : .targetUnavailable
            #expect(throws: error) { try driver.inspect(identity: boundary.identity) }
            #expect(boundary.performed.isEmpty && boundary.metadataReads.isEmpty)
        }
    }

    @Test func replacedWindowWithSameIDRefusesOriginalInspection() throws {
        let (driver, boundary) = fixture()
        let snapshot = try driver.inspect(identity: boundary.identity)
        boundary.windows = [ContextDemoAccessibilityElement(key: 3)]
        boundary.windowIDs[3] = 42
        #expect(throws: ContextDemoDesktopError.targetUnavailable) { try driver.validate(snapshot: snapshot) }
    }

    @Test func missingChangedOrReplacedControlCannotBeRetargeted() throws {
        for variant in 0...3 {
            let (driver, boundary) = fixture()
            let snapshot = try driver.inspect(identity: boundary.identity)
            let control = try #require(snapshot.controls.first)
            switch variant {
            case 0: boundary.children[1] = []
            case 1: boundary.nodes[2] = ContextDemoDesktopNodeIdentity(role: "AXButton", identifier: "other")
            case 2:
                boundary.nodes[3] = boundary.nodes[2]; boundary.supported[3] = boundary.supported[2]
                boundary.children[1] = [ContextDemoAccessibilityElement(key: 3)]
            default: boundary.supported[2] = [.focus]
            }
            #expect(throws: ContextDemoDesktopError.controlUnavailable) {
                try driver.perform(.press(control), snapshot: snapshot, deadline: 110)
            }
            #expect(boundary.performed.isEmpty)
        }
    }

    @Test func reorderedControlsRefuseInsteadOfMatchingByLabel() throws {
        let (driver, boundary) = fixture()
        let snapshot = try driver.inspect(identity: boundary.identity)
        let control = try #require(snapshot.controls.first)
        boundary.nodes[3] = ContextDemoDesktopNodeIdentity(role: "AXButton", identifier: "other")
        boundary.supported[3] = [.press]
        boundary.children[1] = [ContextDemoAccessibilityElement(key: 3), boundary.buttonElement]
        #expect(throws: ContextDemoDesktopError.controlUnavailable) {
            try driver.perform(.press(control), snapshot: snapshot, deadline: 110)
        }
        #expect(boundary.performed.isEmpty)
    }

    @Test func secureSubtreesAreNotTraversedOrExposed() throws {
        let (driver, boundary) = fixture()
        boundary.nodes[2] = ContextDemoDesktopNodeIdentity(role: "AXTextField", subrole: "AXSecureTextField", identifier: "hidden")
        boundary.children[2] = [ContextDemoAccessibilityElement(key: 3)]
        boundary.nodes[3] = ContextDemoDesktopNodeIdentity(role: "AXButton", identifier: "not-inspected")
        boundary.supported[3] = [.press]
        let snapshot = try driver.inspect(identity: boundary.identity)
        #expect(snapshot.controls.isEmpty)
        #expect(!boundary.metadataReads.contains(3) && !boundary.childReads.contains(2))
    }

    @Test func missingStableIdentifierIsNotActionable() throws {
        let (driver, boundary) = fixture()
        boundary.nodes[2] = ContextDemoDesktopNodeIdentity(role: "AXButton")
        let snapshot = try driver.inspect(identity: boundary.identity)
        #expect(snapshot.controls.isEmpty && boundary.performed.isEmpty)
    }

    @Test func crossProcessAndCrossWindowChildrenRefuse() throws {
        for crossProcess in [true, false] {
            let (driver, boundary) = fixture()
            if crossProcess { boundary.processes[2] = 999 }
            else { boundary.owners[2] = 999 }
            let error: ContextDemoDesktopError = crossProcess ? .targetUnavailable : .controlUnavailable
            #expect(throws: error) { try driver.inspect(identity: boundary.identity) }
            #expect(boundary.performed.isEmpty)
        }
    }

    @Test func elementWindowDepthAndCycleLimitsRefuseWithoutPartialSuccess() throws {
        for variant in 0...3 {
            let (driver, boundary) = fixture()
            switch variant {
            case 0:
                boundary.children[1] = (2...257).map { ContextDemoAccessibilityElement(key: $0) }
            case 1:
                boundary.windows = (1...33).map { ContextDemoAccessibilityElement(key: $0) }
            case 2:
                for key in 2...10 {
                    boundary.nodes[key] = ContextDemoDesktopNodeIdentity(role: "AXGroup")
                    boundary.children[key - 1] = [ContextDemoAccessibilityElement(key: key)]
                }
            default: boundary.children[2] = [boundary.windowElement]
            }
            #expect(throws: ContextDemoDesktopError.treeLimitExceeded) { try driver.inspect(identity: boundary.identity) }
            #expect(boundary.performed.isEmpty)
        }
    }

    @Test func deadlineDuringInspectionRefusesNoLateAction() throws {
        let boundary = DesktopAutomationAXFake(), timing = DesktopAutomationClock()
        let driver = ContextDemoAccessibilityDriver(boundary: boundary, now: { timing.now })
        boundary.onMetadata = { timing.now += 6 }
        #expect(throws: ContextDemoDesktopError.timedOut) { try driver.inspect(identity: boundary.identity) }
        #expect(boundary.performed.isEmpty)
    }

    @Test func exactNativeScrollbarAndNonsecretFieldActionsReachBoundary() throws {
        let (driver, boundary) = fixture()
        boundary.nodes[2] = ContextDemoDesktopNodeIdentity(role: "AXScrollBar", identifier: "document-scroll")
        boundary.supported[2] = [.increment, .decrement]
        boundary.nodes[3] = ContextDemoDesktopNodeIdentity(role: "AXTextField", identifier: "caption")
        boundary.supported[3] = [.focus, .setNonsecretValue]
        boundary.children[1] = [boundary.buttonElement, ContextDemoAccessibilityElement(key: 3)]
        let snapshot = try driver.inspect(identity: boundary.identity)
        let scroll = try #require(snapshot.controls.first { $0.node.role == "AXScrollBar" })
        let field = try #require(snapshot.controls.first { $0.node.role == "AXTextField" })
        let actions: [ContextDemoDesktopAction] = [.scroll(scroll, direction: .increment), .scroll(scroll, direction: .decrement),
            .focus(field), .setNonsecretValue(field, value: "Demo caption")]
        for action in actions { try driver.perform(action, snapshot: snapshot, deadline: 110) }
        #expect(boundary.performed == actions)
    }
}
