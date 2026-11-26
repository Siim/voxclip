@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

public enum ContextDemoPermission: String, Sendable {
    case screenRecording, accessibility
}

public enum ContextDemoPermissionState: Sendable {
    case granted, notAsked, denied
}

@MainActor public protocol ContextDemoPermissions: AnyObject {
    func status(for permission: ContextDemoPermission) -> ContextDemoPermissionState
    func request(_ permission: ContextDemoPermission) -> ContextDemoPermissionState
    func settingsURL(for permission: ContextDemoPermission) -> URL
}

@MainActor public final class ContextDemoSystemPermissions: ContextDemoPermissions {
    public static let shared = ContextDemoSystemPermissions()

    private init() {}

    public func status(for permission: ContextDemoPermission) -> ContextDemoPermissionState {
        let granted = switch permission {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
        if granted { return .granted }
        return UserDefaults.standard.bool(forKey: attemptKey(for: permission)) ? .denied : .notAsked
    }

    public func request(_ permission: ContextDemoPermission) -> ContextDemoPermissionState {
        let current = status(for: permission)
        guard current == .notAsked else { return current }
        UserDefaults.standard.set(true, forKey: attemptKey(for: permission))
        let granted = switch permission {
        case .screenRecording: CGRequestScreenCaptureAccess()
        case .accessibility: AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        }
        return granted ? .granted : status(for: permission)
    }

    public func settingsURL(for permission: ContextDemoPermission) -> URL {
        let pane = switch permission {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    private func attemptKey(for permission: ContextDemoPermission) -> String {
        "contextDemo.permissionAttempted.\(permission.rawValue)"
    }
}
