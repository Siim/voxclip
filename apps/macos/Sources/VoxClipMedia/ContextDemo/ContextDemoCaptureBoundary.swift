import Foundation
import VoxClipCore

public enum ContextDemoCaptureAvailability: String, Sendable, Equatable {
    case available, screenRecordingPermissionRequired
}

public enum ContextDemoCaptureError: Error, LocalizedError, Sendable, Equatable {
    case permissionRequired, permissionDenied, targetUnavailable, ambiguousTarget, staleReview
    case invalidRequest, alreadyRecording, encoderUnavailable, failedToStart, interrupted
    case startTimedOut, finalizationTimedOut, fileBudgetExceeded, invalidRecording, unsafeStorage

    public var errorDescription: String? {
        switch self {
        case .permissionRequired, .permissionDenied:
            "Screen Recording permission is required. Approve access in System Settings, then explicitly start again. No demonstration was kept. Your media and edits are safe."
        case .targetUnavailable:
            "The approved window is unavailable. Select an open window and review a new plan. Your media and edits are safe."
        case .ambiguousTarget:
            "This app has more than one window. Select the exact window to record. Your media and edits are safe."
        case .staleReview:
            "The reviewed target or actions changed, or the review expired. Review a new plan before recording. Your media and edits are safe."
        case .invalidRequest:
            "Choose a demonstration between 1 and 30 seconds and review its exact window. Your media and edits are safe."
        case .alreadyRecording:
            "Finish or cancel the current demonstration before starting another. Your media and edits are safe."
        case .encoderUnavailable, .failedToStart, .startTimedOut:
            "The window recording could not start. No demonstration was kept. Your media and edits are safe."
        case .interrupted, .finalizationTimedOut:
            "The window recording stopped before it could be verified. No demonstration was kept. Your media and edits are safe."
        case .fileBudgetExceeded:
            "The demonstration exceeded its 64 MiB file limit and was discarded. Your media and edits are safe."
        case .invalidRecording:
            "The demonstration failed local video or integrity checks and was not accepted. Your media and edits are safe."
        case .unsafeStorage:
            "The private demonstration folder could not be accessed safely. No demonstration was accepted. Your media and edits are safe."
        }
    }
}

public struct ContextDemoCaptureTarget: Sendable, Equatable, Identifiable {
    public var id: UInt32 { windowID }
    public let windowID: UInt32
    public let processID: Int32
    public let bundleIdentifier: String
    public let applicationName: String
    public let windowTitle: String
    public let processLaunchDate: Date
    public let widthPoints: Double
    public let heightPoints: Double
    public let pixelScale: Double
    public var binding: ContextDemoWindowBinding {
        ContextDemoWindowBinding(windowID: windowID, processID: processID, bundleID: bundleIdentifier)
    }

    public init(windowID: UInt32, processID: Int32, bundleIdentifier: String, applicationName: String,
                windowTitle: String, processLaunchDate: Date, widthPoints: Double,
                heightPoints: Double, pixelScale: Double) {
        self.windowID = windowID; self.processID = processID; self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName; self.windowTitle = windowTitle
        self.processLaunchDate = processLaunchDate; self.widthPoints = widthPoints
        self.heightPoints = heightPoints; self.pixelScale = pixelScale
    }
}

enum ContextDemoCaptureLimits {
    static let maximumSeconds: Double = 30
    static let maximumWidth = 1_920
    static let maximumHeight = 1_080
    static let maximumBytes = 64 * 1_024 * 1_024
    static let framesPerSecond = 30
    static let startTimeout: Double = 10
    static let finishTimeout: Double = 10

    static func geometry(_ binding: ContextDemoCaptureTarget) throws -> (width: Int, height: Int) {
        let width = binding.widthPoints * binding.pixelScale
        let height = binding.heightPoints * binding.pixelScale
        guard width.isFinite, height.isFinite, width >= 2, height >= 2,
              width <= 32_768, height <= 32_768 else { throw ContextDemoCaptureError.invalidRequest }
        let ratio = min(1, Double(maximumWidth) / width, Double(maximumHeight) / height)
        return (max(2, Int(width * ratio) / 2 * 2), max(2, Int(height * ratio) / 2 * 2))
    }
}

struct ContextDemoCaptureSnapshot: Sendable {
    var startAcknowledged = false
    var started = false
    var finished = false
    var stopped = false
    var bytes = 0
    var error: ContextDemoCaptureError?
}

@MainActor protocol ContextDemoCaptureBackend: AnyObject {
    func availability() -> ContextDemoCaptureAvailability
    func windows() async throws -> [ContextDemoCaptureTarget]
    func begin(window: ContextDemoCaptureTarget, output: URL, width: Int, height: Int) async throws
    func snapshot() -> ContextDemoCaptureSnapshot
    func stop()
    func release()
}

struct ContextDemoRecordingMetadata: Sendable, Equatable {
    let duration: Double
    let width: Int
    let height: Int
}

@MainActor protocol ContextDemoRecordingInspecting {
    func inspect(_ url: URL) async throws -> ContextDemoRecordingMetadata
}

@MainActor protocol ContextDemoCaptureTiming {
    var now: Double { get }
    func pause() async throws
}

struct ContextDemoSystemTiming: ContextDemoCaptureTiming {
    var now: Double { ProcessInfo.processInfo.systemUptime }
    func pause() async throws { try await Task.sleep(for: .milliseconds(50)) }
}
