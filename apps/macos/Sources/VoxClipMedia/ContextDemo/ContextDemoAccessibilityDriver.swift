import Foundation
import VoxClipCore

@MainActor final class ContextDemoAccessibilityDriver: ContextDemoAccessibilityDriving {
    private let boundary: any ContextDemoAccessibilityAX
    private let now: @MainActor () -> Double
    private var reviewed: ContextDemoDesktopSnapshot?
    private var reviewedWindow: ContextDemoAccessibilityElement?
    private var reviewedElements: [String: ContextDemoAccessibilityElement] = [:]

    init(boundary: any ContextDemoAccessibilityAX = ContextDemoAccessibilityNative(),
         now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.boundary = boundary; self.now = now
    }

    func availability() -> ContextDemoAccessibilityAvailability { boundary.availability() }

    func inspect(identity: ContextDemoDesktopIdentity) throws -> ContextDemoDesktopSnapshot {
        release()
        boundary.deadline = now() + ContextDemoDesktopLimits.inspectionTimeoutSeconds
        do {
            let window = try resolveWindow(identity: identity)
            let tree = try inspectTree(identity: identity, window: window)
            let snapshot = try ContextDemoDesktopSnapshot(identity: identity, controls: tree.controls)
            try check(identity: identity)
            reviewed = snapshot; reviewedWindow = window; reviewedElements = tree.elements
            return snapshot
        } catch { release(); throw error }
    }

    func validate(snapshot: ContextDemoDesktopSnapshot) throws {
        boundary.deadline = now() + ContextDemoDesktopLimits.inspectionTimeoutSeconds
        try validateWindow(snapshot: snapshot)
    }

    func perform(_ action: ContextDemoDesktopAction, snapshot: ContextDemoDesktopSnapshot, deadline: Double) throws {
        boundary.deadline = min(deadline, now() + ContextDemoDesktopLimits.inspectionTimeoutSeconds)
        guard let control = action.control, snapshot.controls.contains(control) else {
            throw ContextDemoDesktopError.controlUnavailable
        }
        try validateWindow(snapshot: snapshot)
        guard let window = reviewedWindow else { throw ContextDemoDesktopError.stalePlan }
        let fresh = try inspectTree(identity: snapshot.identity, window: window)
        guard fresh.controls.contains(control), let element = fresh.elements[control.fingerprint],
              reviewedElements[control.fingerprint] == element else { throw ContextDemoDesktopError.controlUnavailable }
        try check(identity: snapshot.identity)
        guard try boundary.belongsToWindow(element, window: window),
              try boundary.processID(of: element) == snapshot.identity.window.processID else {
            throw ContextDemoDesktopError.controlUnavailable
        }
        try boundary.perform(action, on: element)
        try check(identity: snapshot.identity)
    }

    func release() {
        reviewed = nil; reviewedWindow = nil; reviewedElements = [:]; boundary.release()
    }

    private func validateWindow(snapshot: ContextDemoDesktopSnapshot) throws {
        guard reviewed == snapshot, let expected = reviewedWindow else { throw ContextDemoDesktopError.stalePlan }
        let current = try resolveWindow(identity: snapshot.identity)
        guard current == expected else { throw ContextDemoDesktopError.targetUnavailable }
        try check(identity: snapshot.identity)
    }

    private func resolveWindow(identity: ContextDemoDesktopIdentity) throws -> ContextDemoAccessibilityElement {
        try check(identity: identity)
        let app = try boundary.application(processID: identity.window.processID)
        guard try boundary.processID(of: app) == identity.window.processID else { throw ContextDemoDesktopError.targetUnavailable }
        let windows = try boundary.elements(of: app, windows: true, maximum: ContextDemoDesktopLimits.maximumWindows)
        guard windows.count <= ContextDemoDesktopLimits.maximumWindows else { throw ContextDemoDesktopError.treeLimitExceeded }
        var matches: [ContextDemoAccessibilityElement] = []
        for window in windows {
            try check(identity: identity)
            guard try boundary.processID(of: window) == identity.window.processID else {
                throw ContextDemoDesktopError.targetUnavailable
            }
            if try boundary.windowID(of: window) == identity.window.windowID { matches.append(window) }
        }
        guard matches.count == 1, let selected = matches.first else { throw ContextDemoDesktopError.targetUnavailable }
        return selected
    }

    private func inspectTree(identity: ContextDemoDesktopIdentity, window: ContextDemoAccessibilityElement) throws
        -> (controls: [ContextDemoDesktopControl], elements: [String: ContextDemoAccessibilityElement]) {
        var visited = Set<ContextDemoAccessibilityElement>()
        var controls: [ContextDemoDesktopControl] = []
        var elements: [String: ContextDemoAccessibilityElement] = [:]
        func visit(_ element: ContextDemoAccessibilityElement, path: [Int],
                   ancestors: [ContextDemoDesktopNodeIdentity]) throws {
            try check(identity: identity)
            guard visited.count < ContextDemoDesktopLimits.maximumElements,
                  visited.insert(element).inserted else { throw ContextDemoDesktopError.treeLimitExceeded }
            guard try boundary.processID(of: element) == identity.window.processID else {
                throw ContextDemoDesktopError.targetUnavailable
            }
            if !path.isEmpty {
                guard try boundary.belongsToWindow(element, window: window) else {
                    throw ContextDemoDesktopError.controlUnavailable
                }
            }
            guard let node = try boundary.metadata(of: element), !node.isSensitive else { return }
            guard !path.isEmpty || node.role == "AXWindow" else { throw ContextDemoDesktopError.unsupportedWindow }
            let ancestry = ancestors + [node]
            if !path.isEmpty, !node.identifier.isEmpty,
               ["AXButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXTextField", "AXScrollBar"].contains(node.role) {
                let capabilities = try boundary.capabilities(of: element, node: node)
                if !capabilities.isEmpty {
                    let control = try ContextDemoDesktopControl(childPath: path, ancestry: ancestry, capabilities: capabilities)
                    controls.append(control); elements[control.fingerprint] = element
                }
            }
            let children = try boundary.elements(of: element, windows: false,
                maximum: ContextDemoDesktopLimits.maximumElements - visited.count)
            guard children.count <= ContextDemoDesktopLimits.maximumElements - visited.count else {
                throw ContextDemoDesktopError.treeLimitExceeded
            }
            guard path.count < ContextDemoDesktopLimits.maximumDepth || children.isEmpty else {
                throw ContextDemoDesktopError.treeLimitExceeded
            }
            for (index, child) in children.enumerated() { try visit(child, path: path + [index], ancestors: ancestry) }
        }
        try visit(window, path: [], ancestors: [])
        return (controls, elements)
    }

    private func check(identity: ContextDemoDesktopIdentity) throws {
        try Task.checkCancellation()
        guard now() < boundary.deadline else { throw ContextDemoDesktopError.timedOut }
        guard boundary.processMatches(identity) else { throw ContextDemoDesktopError.targetUnavailable }
    }
}
