import AppKit
import ApplicationServices
import Darwin
import Foundation
import VoxClipCore

struct ContextDemoAccessibilityElement: Hashable {
    let key: Int
}

@MainActor protocol ContextDemoAccessibilityAX: AnyObject {
    var deadline: Double { get set }
    func availability() -> ContextDemoAccessibilityAvailability
    func processMatches(_ identity: ContextDemoDesktopIdentity) -> Bool
    func application(processID: Int32) throws -> ContextDemoAccessibilityElement
    func processID(of element: ContextDemoAccessibilityElement) throws -> Int32
    func windowID(of element: ContextDemoAccessibilityElement) throws -> UInt32
    func elements(of element: ContextDemoAccessibilityElement, windows: Bool, maximum: Int) throws -> [ContextDemoAccessibilityElement]
    func belongsToWindow(_ element: ContextDemoAccessibilityElement, window: ContextDemoAccessibilityElement) throws -> Bool
    func metadata(of element: ContextDemoAccessibilityElement) throws -> ContextDemoDesktopNodeIdentity?
    func capabilities(of element: ContextDemoAccessibilityElement, node: ContextDemoDesktopNodeIdentity) throws -> [ContextDemoDesktopCapability]
    func perform(_ action: ContextDemoDesktopAction, on element: ContextDemoAccessibilityElement) throws
    func release()
}

@MainActor final class ContextDemoAccessibilityNative: ContextDemoAccessibilityAX {
    var deadline: Double = 0
    private var retained: [AXUIElement] = []

    func availability() -> ContextDemoAccessibilityAvailability {
        AXIsProcessTrusted() ? .available : .accessibilityPermissionRequired
    }

    func processMatches(_ identity: ContextDemoDesktopIdentity) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: identity.window.processID),
              !app.isTerminated, app.processIdentifier == identity.window.processID,
              app.bundleIdentifier == identity.window.bundleID,
              app.launchDate == identity.processLaunchDate else { return false }
        return true
    }

    func application(processID: Int32) throws -> ContextDemoAccessibilityElement {
        try gate()
        return try retain(AXUIElementCreateApplication(processID))
    }

    func processID(of element: ContextDemoAccessibilityElement) throws -> Int32 {
        try gate()
        var processID: pid_t = 0
        try success(AXUIElementGetPid(try native(element), &processID))
        return processID
    }

    func windowID(of element: ContextDemoAccessibilityElement) throws -> UInt32 {
        if let number = try attribute(element, "AXWindowNumber") as? NSNumber {
            let raw = number.int64Value
            guard raw > 0, raw <= Int64(UInt32.max), number.doubleValue == Double(raw) else {
                throw ContextDemoDesktopError.unsupportedWindow
            }
            return UInt32(raw)
        }
        try gate()
        guard let handle = dlopen(nil, RTLD_LAZY) else { throw ContextDemoDesktopError.unsupportedWindow }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            throw ContextDemoDesktopError.unsupportedWindow
        }
        typealias WindowLookup = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let lookup = unsafeBitCast(symbol, to: WindowLookup.self)
        var windowID: CGWindowID = 0
        guard lookup(try native(element), &windowID) == .success, windowID > 0 else {
            throw ContextDemoDesktopError.unsupportedWindow
        }
        try gate()
        return windowID
    }

    func elements(of element: ContextDemoAccessibilityElement, windows: Bool,
                  maximum: Int) throws -> [ContextDemoAccessibilityElement] {
        try gate()
        let name = (windows ? kAXWindowsAttribute : kAXChildrenAttribute) as CFString
        var count: CFIndex = 0
        let target = try native(element)
        let status = AXUIElementGetAttributeValueCount(target, name, &count)
        if status == .attributeUnsupported || status == .noValue { return [] }
        try success(status)
        guard count >= 0, count <= maximum else { throw ContextDemoDesktopError.treeLimitExceeded }
        guard count > 0 else { return [] }
        try gate()
        var result: CFArray?
        try success(AXUIElementCopyAttributeValues(target, name, 0, count, &result))
        guard let children = result as? [AXUIElement], children.count == count else {
            throw ContextDemoDesktopError.nativeFailure
        }
        return try children.map { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { throw ContextDemoDesktopError.nativeFailure }
            return try retain(child)
        }
    }

    func belongsToWindow(_ element: ContextDemoAccessibilityElement,
                         window: ContextDemoAccessibilityElement) throws -> Bool {
        guard let value = try attribute(element, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return false
        }
        return CFEqual(value, try native(window))
    }

    func metadata(of element: ContextDemoAccessibilityElement) throws -> ContextDemoDesktopNodeIdentity? {
        let role = try text(element, kAXRoleAttribute)
        let subrole = try text(element, kAXSubroleAttribute)
        guard !role.isEmpty else { throw ContextDemoDesktopError.nativeFailure }
        let partial = ContextDemoDesktopNodeIdentity(role: role, subrole: subrole)
        if partial.isSensitive { return nil }
        if let protected = try attribute(element, "AXProtectedContent") {
            guard CFGetTypeID(protected) == CFBooleanGetTypeID() else { throw ContextDemoDesktopError.unsafeControl }
            if CFEqual(protected, kCFBooleanTrue) { return nil }
        }
        let node = ContextDemoDesktopNodeIdentity(role: role, subrole: subrole,
            identifier: try text(element, kAXIdentifierAttribute))
        return node.isSensitive ? nil : node
    }

    func capabilities(of element: ContextDemoAccessibilityElement,
                      node: ContextDemoDesktopNodeIdentity) throws -> [ContextDemoDesktopCapability] {
        guard !node.identifier.isEmpty, !node.isSensitive,
              let enabled = try attribute(element, kAXEnabledAttribute),
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), CFEqual(enabled, kCFBooleanTrue) else { return [] }
        let target = try native(element)
        var result: [ContextDemoDesktopCapability] = []
        if try settable(element, kAXFocusedAttribute) { result.append(.focus) }
        var names: CFArray?
        try gate()
        let status = AXUIElementCopyActionNames(target, &names)
        if status != .notImplemented && status != .actionUnsupported { try success(status) }
        let actions = names as? [String] ?? []
        guard actions.count <= 32 else { throw ContextDemoDesktopError.treeLimitExceeded }
        if ["AXButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"].contains(node.role),
           actions.contains(kAXPressAction) { result.append(.press) }
        if node.role == "AXScrollBar" {
            if actions.contains(kAXIncrementAction) { result.append(.increment) }
            if actions.contains(kAXDecrementAction) { result.append(.decrement) }
        }
        if node.role == "AXTextField", try settable(element, kAXValueAttribute) { result.append(.setNonsecretValue) }
        return result
    }

    func perform(_ action: ContextDemoDesktopAction, on element: ContextDemoAccessibilityElement) throws {
        guard let control = action.control, let node = try metadata(of: element), node == control.node,
              !node.isSensitive else { throw ContextDemoDesktopError.unsafeControl }
        let supported = try capabilities(of: element, node: node)
        let capability: ContextDemoDesktopCapability
        switch action {
        case .focus: capability = .focus
        case .press: capability = .press
        case .scroll(_, let direction): capability = direction == .increment ? .increment : .decrement
        case .setNonsecretValue: capability = .setNonsecretValue
        case .pause: throw ContextDemoDesktopError.unsupportedAction
        }
        guard supported.contains(capability) else { throw ContextDemoDesktopError.unsupportedAction }
        try gate()
        let target = try native(element)
        let status: AXError
        switch action {
        case .focus: status = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case .press: status = AXUIElementPerformAction(target, kAXPressAction as CFString)
        case .scroll(_, let direction):
            status = AXUIElementPerformAction(target, (direction == .increment ? kAXIncrementAction : kAXDecrementAction) as CFString)
        case .setNonsecretValue(_, let value):
            status = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value as CFString)
        case .pause: throw ContextDemoDesktopError.unsupportedAction
        }
        try success(status)
        try gate()
    }

    func release() { retained.removeAll() }

    private func attribute(_ element: ContextDemoAccessibilityElement, _ name: String) throws -> CFTypeRef? {
        try gate()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(try native(element), name as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        try success(status)
        return value
    }

    private func text(_ element: ContextDemoAccessibilityElement, _ name: String) throws -> String {
        guard let value = try attribute(element, name) else { return "" }
        guard CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String,
              text.utf8.count <= ContextDemoDesktopLimits.maximumIdentifierBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ContextDemoDesktopError.unsafeControl
        }
        return text
    }

    private func settable(_ element: ContextDemoAccessibilityElement, _ name: String) throws -> Bool {
        try gate()
        var result = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(try native(element), name as CFString, &result)
        if status == .attributeUnsupported || status == .noValue { return false }
        try success(status)
        return result.boolValue
    }

    private func retain(_ element: AXUIElement) throws -> ContextDemoAccessibilityElement {
        try gate()
        if let index = retained.firstIndex(where: { CFEqual($0, element) }) {
            return ContextDemoAccessibilityElement(key: index)
        }
        guard retained.count < 2 * ContextDemoDesktopLimits.maximumElements + ContextDemoDesktopLimits.maximumWindows + 1 else {
            throw ContextDemoDesktopError.treeLimitExceeded
        }
        try success(AXUIElementSetMessagingTimeout(element, ContextDemoDesktopLimits.nativeCallTimeoutSeconds))
        retained.append(element)
        return ContextDemoAccessibilityElement(key: retained.count - 1)
    }

    private func native(_ element: ContextDemoAccessibilityElement) throws -> AXUIElement {
        guard retained.indices.contains(element.key) else { throw ContextDemoDesktopError.controlUnavailable }
        return retained[element.key]
    }

    private func gate() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ContextDemoDesktopError.timedOut }
    }

    private func success(_ status: AXError) throws {
        switch status {
        case .success: return
        case .apiDisabled: throw ContextDemoDesktopError.permissionRequired
        case .invalidUIElement: throw ContextDemoDesktopError.controlUnavailable
        case .actionUnsupported, .notImplemented, .attributeUnsupported: throw ContextDemoDesktopError.unsupportedAction
        default: throw ContextDemoDesktopError.nativeFailure
        }
    }
}
