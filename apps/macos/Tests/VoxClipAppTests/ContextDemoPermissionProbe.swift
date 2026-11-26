import Foundation
import VoxClipMedia

@MainActor final class ContextDemoPermissionProbe: ContextDemoPermissions {
    var states: [ContextDemoPermission: ContextDemoPermissionState] = [:]
    var requests: [ContextDemoPermission] = []

    func status(for permission: ContextDemoPermission) -> ContextDemoPermissionState {
        states[permission] ?? .granted
    }

    func request(_ permission: ContextDemoPermission) -> ContextDemoPermissionState {
        requests.append(permission)
        states[permission] = .denied
        return .denied
    }

    func settingsURL(for permission: ContextDemoPermission) -> URL {
        URL(string: "https://example.test/settings/\(permission.rawValue)")!
    }
}
