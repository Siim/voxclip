import Foundation

public enum ContextDemoDesktopError: Error, LocalizedError, Sendable, Equatable {
    case accessCheckRequired, permissionRequired, invalidPlan, targetUnavailable, unsupportedWindow
    case treeLimitExceeded, controlUnavailable, unsafeControl, unsupportedAction, stalePlan
    case approvalRequired, approvalExpired, alreadyRunning, recordingNotStarted, recordingEnded
    case nativeFailure, timedOut

    public var errorDescription: String? {
        let reason: String
        switch self {
        case .accessCheckRequired: reason = "Choose Check Accessibility Access before inspecting the selected app."
        case .permissionRequired: reason = "Accessibility access is not granted. No permission prompt was opened."
        case .invalidPlan: reason = "Review a bounded demonstration for the exact selected desktop window."
        case .targetUnavailable: reason = "The exact selected app process or window is no longer available."
        case .unsupportedWindow: reason = "This app does not expose an exact accessible window identity. Automatic demonstration is unavailable; no other window will be used."
        case .treeLimitExceeded: reason = "The selected window exceeds the safe accessibility inspection limits."
        case .controlUnavailable: reason = "A reviewed control is missing, ambiguous or changed. Review the window again."
        case .unsafeControl: reason = "Secure or potentially secret fields cannot be inspected or edited."
        case .unsupportedAction: reason = "The selected control does not support that exact native action."
        case .stalePlan: reason = "The source, request or reviewed window changed. Review a new demonstration."
        case .approvalRequired: reason = "Explicitly approve these exact actions with Start before running them."
        case .approvalExpired: reason = "The desktop review expired. Inspect and approve the window again."
        case .alreadyRunning: reason = "Finish or cancel the current demonstration first."
        case .recordingNotStarted: reason = "Window recording did not acknowledge its start. No actions were run."
        case .recordingEnded: reason = "Recording ended before all approved actions completed. The recording was discarded."
        case .nativeFailure: reason = "The selected app refused an accessibility operation. No substitute action was attempted."
        case .timedOut: reason = "The desktop demonstration exceeded its reviewed time limit."
        }
        return reason + " Your media and edits are safe."
    }
}

public enum ContextDemoDesktopLimits {
    public static let maximumDepth = 8
    public static let maximumElements = 256
    public static let maximumWindows = 32
    public static let maximumActions = 12
    public static let maximumIdentifierBytes = 128
    public static let maximumReplacementBytes = 256
    public static let maximumPauseMilliseconds = 5_000
    public static let reviewLifetimeSeconds: Double = 120
    public static let nativeCallTimeoutSeconds: Float = 0.25
    public static let inspectionTimeoutSeconds: Double = 5
}

public struct ContextDemoDesktopIdentity: Sendable, Equatable {
    public let window: ContextDemoWindowBinding
    public let processLaunchDate: Date

    public init(window: ContextDemoWindowBinding, processLaunchDate: Date) {
        self.window = window; self.processLaunchDate = processLaunchDate
    }
}

public enum ContextDemoDesktopCapability: String, Sendable, Equatable, CaseIterable {
    case focus, press, increment, decrement, setNonsecretValue
}

public struct ContextDemoDesktopNodeIdentity: Sendable, Equatable {
    public let role: String
    public let subrole: String
    public let identifier: String

    public init(role: String, subrole: String = "", identifier: String = "") {
        self.role = role; self.subrole = subrole; self.identifier = identifier
    }

    public var isSensitive: Bool {
        let metadata = (role + " " + subrole + " " + identifier).lowercased()
        return ["secure", "password", "passwd", "secret", "token", "credential", "apikey", "api_key",
                "privatekey", "private_key", "authorization", "one-time", "onetime", "otp"].contains {
            metadata.contains($0)
        }
    }
}

public struct ContextDemoDesktopControl: Sendable, Equatable, Identifiable {
    public var id: String { fingerprint }
    public let childPath: [Int]
    public let ancestry: [ContextDemoDesktopNodeIdentity]
    public let capabilities: [ContextDemoDesktopCapability]
    public let fingerprint: String
    public var node: ContextDemoDesktopNodeIdentity { ancestry[ancestry.count - 1] }

    public init(childPath: [Int], ancestry: [ContextDemoDesktopNodeIdentity],
                capabilities: [ContextDemoDesktopCapability]) throws {
        guard !childPath.isEmpty, childPath.count <= ContextDemoDesktopLimits.maximumDepth,
              childPath.allSatisfy({ (0..<ContextDemoDesktopLimits.maximumElements).contains($0) }),
              ancestry.count == childPath.count + 1, ancestry.first?.role == "AXWindow",
              let node = ancestry.last, !node.identifier.isEmpty, !capabilities.isEmpty,
              Set(capabilities.map(\.rawValue)).count == capabilities.count else {
            throw ContextDemoDesktopError.invalidPlan
        }
        for ancestor in ancestry {
            guard Self.safeMetadata(ancestor.role, empty: false), Self.safeMetadata(ancestor.subrole),
                  Self.safeMetadata(ancestor.identifier), !ancestor.isSensitive else {
                throw ContextDemoDesktopError.unsafeControl
            }
        }
        let allowed: [String] = ["AXButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXTextField", "AXScrollBar"]
        guard allowed.contains(node.role), capabilities.allSatisfy({ capability in
            switch capability {
            case .focus: return true
            case .press: return ["AXButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"].contains(node.role)
            case .increment, .decrement: return node.role == "AXScrollBar"
            case .setNonsecretValue: return node.role == "AXTextField"
            }
        }) else { throw ContextDemoDesktopError.unsupportedAction }
        self.childPath = childPath; self.ancestry = ancestry
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.fingerprint = ContextDemoDesktopDigest.hash(childPath.map(String.init)
            + ancestry.flatMap { [$0.role, $0.subrole, $0.identifier] }
            + self.capabilities.map(\.rawValue))
    }

    private static func safeMetadata(_ value: String, empty: Bool = true) -> Bool {
        (empty || !value.isEmpty) && value.utf8.count <= ContextDemoDesktopLimits.maximumIdentifierBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct ContextDemoDesktopSnapshot: Sendable, Equatable {
    public let identity: ContextDemoDesktopIdentity
    public let inspectionID: UUID
    public let controls: [ContextDemoDesktopControl]

    public init(identity: ContextDemoDesktopIdentity, inspectionID: UUID = UUID(),
                controls: [ContextDemoDesktopControl]) throws {
        guard identity.window.windowID > 0, identity.window.processID > 0,
              !identity.window.bundleID.isEmpty, identity.window.bundleID.utf8.count <= 256,
              identity.processLaunchDate.timeIntervalSince1970.isFinite,
              identity.processLaunchDate.timeIntervalSince1970 > 0,
              controls.count < ContextDemoDesktopLimits.maximumElements,
              Set(controls.map(\.childPath)).count == controls.count,
              Set(controls.map(\.fingerprint)).count == controls.count else {
            throw ContextDemoDesktopError.invalidPlan
        }
        self.identity = identity; self.inspectionID = inspectionID; self.controls = controls
    }
}

public enum ContextDemoDesktopScrollDirection: String, Sendable, Equatable {
    case increment, decrement
}

public enum ContextDemoDesktopAction: Sendable, Equatable {
    case focus(ContextDemoDesktopControl)
    case press(ContextDemoDesktopControl)
    case scroll(ContextDemoDesktopControl, direction: ContextDemoDesktopScrollDirection)
    case setNonsecretValue(ContextDemoDesktopControl, value: String)
    case pause(milliseconds: Int)

    public var control: ContextDemoDesktopControl? {
        switch self {
        case .focus(let control), .press(let control), .scroll(let control, _), .setNonsecretValue(let control, _): control
        case .pause: nil
        }
    }

    public var reviewDescription: String {
        let label = control.map { "\($0.node.role) ID ‘\($0.node.identifier)’ [\($0.fingerprint.prefix(12))]" } ?? ""
        switch self {
        case .focus: return "Focus \(label)"
        case .press: return "Press \(label) once"
        case .scroll(_, let direction): return "Scroll \(label) one native \(direction.rawValue) step"
        case .setNonsecretValue(_, let value): return "Replace nonsecret text in \(label) with ‘\(value)’; do not submit"
        case .pause(let milliseconds): return "Pause for \(milliseconds) milliseconds"
        }
    }

    fileprivate var digestFields: [String] {
        switch self {
        case .focus(let control): ["focus", control.fingerprint]
        case .press(let control): ["press", control.fingerprint]
        case .scroll(let control, let direction): ["scroll", control.fingerprint, direction.rawValue]
        case .setNonsecretValue(let control, let value): ["setNonsecretValue", control.fingerprint, value]
        case .pause(let milliseconds): ["pause", String(milliseconds)]
        }
    }
}

public struct ContextDemoDesktopCurrent: Sendable, Equatable {
    public let request: ContextDemoCaptureRequest
    public let sourceContentKey: String

    public init(request: ContextDemoCaptureRequest, sourceContentKey: String) {
        self.request = request; self.sourceContentKey = sourceContentKey
    }
}

public struct ContextDemoDesktopPlan: Sendable, Equatable {
    public let request: ContextDemoCaptureRequest
    public let sourceContentKey: String
    public let snapshot: ContextDemoDesktopSnapshot
    public let actions: [ContextDemoDesktopAction]
    public let digest: String

    public static let reviewWarning = "These exact actions change the chosen app's state. Discarding the recording does not undo them. Never enter secrets. No other window is authorized."

    public static func prepare(request: ContextDemoCaptureRequest, sourceContentKey: String,
                               snapshot: ContextDemoDesktopSnapshot,
                               actions: [ContextDemoDesktopAction]) throws -> Self {
        try request.validate()
        guard request.target.kind == .desktopApp || request.target.kind == .codeProject,
              request.window == snapshot.identity.window,
              request.target.kind != .desktopApp || request.target.locator == snapshot.identity.window.bundleID,
              request.durationSeconds >= 1, !sourceContentKey.isEmpty, sourceContentKey.utf8.count <= 512,
              !actions.isEmpty, actions.count <= ContextDemoDesktopLimits.maximumActions,
              !sourceContentKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ContextDemoDesktopError.invalidPlan
        }
        var budgetMilliseconds = 0
        var hasInteraction = false
        for action in actions {
            if let control = action.control {
                guard snapshot.controls.contains(control) else { throw ContextDemoDesktopError.controlUnavailable }
                hasInteraction = true
                budgetMilliseconds += 1_000
                let capability: ContextDemoDesktopCapability
                switch action {
                case .focus: capability = .focus
                case .press: capability = .press
                case .scroll(_, let direction): capability = direction == .increment ? .increment : .decrement
                case .setNonsecretValue(_, let value):
                    guard !value.isEmpty, value.utf8.count <= ContextDemoDesktopLimits.maximumReplacementBytes,
                          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                          !ContextDemoDesktopNodeIdentity(role: "", identifier: value).isSensitive else {
                        throw ContextDemoDesktopError.unsafeControl
                    }
                    capability = .setNonsecretValue
                case .pause: throw ContextDemoDesktopError.invalidPlan
                }
                guard control.capabilities.contains(capability) else { throw ContextDemoDesktopError.unsupportedAction }
            } else if case .pause(let milliseconds) = action {
                guard (1...ContextDemoDesktopLimits.maximumPauseMilliseconds).contains(milliseconds) else {
                    throw ContextDemoDesktopError.invalidPlan
                }
                budgetMilliseconds += milliseconds
            }
        }
        guard hasInteraction, Double(budgetMilliseconds) + 500 <= request.durationSeconds * 1_000 else {
            throw ContextDemoDesktopError.invalidPlan
        }
        let binding = snapshot.identity.window
        let fields = ["desktop-plan-v1", request.id, request.planId, String(request.revision),
                      request.target.kind.rawValue, request.target.displayName, request.target.locator,
                      String(request.durationSeconds.bitPattern), sourceContentKey,
                      String(binding.windowID), String(binding.processID), binding.bundleID,
                      String(snapshot.identity.processLaunchDate.timeIntervalSince1970.bitPattern),
                      snapshot.inspectionID.uuidString]
        let digest = ContextDemoDesktopDigest.hash(fields + [String(snapshot.controls.count)]
            + snapshot.controls.map(\.fingerprint) + [String(actions.count)] + actions.flatMap(\.digestFields))
        let reviewedActions = [ContextDemoReviewedAction(id: "desktop-plan", summary:
            "Automate only window \(binding.windowID), process \(binding.processID), \(binding.bundleID), launched at Unix time \(snapshot.identity.processLaunchDate.timeIntervalSince1970), for up to \(request.durationSeconds) seconds. Plan SHA-256 \(digest). \(reviewWarning)")]
            + actions.enumerated().map { index, action in
                ContextDemoReviewedAction(id: "desktop-step-\(index + 1)", summary: action.reviewDescription)
            }
        let reviewedRequest = ContextDemoCaptureRequest(id: request.id, planId: request.planId,
            revision: request.revision, target: request.target, durationSeconds: request.durationSeconds,
            window: request.window, actions: reviewedActions)
        try reviewedRequest.validate()
        return Self(request: reviewedRequest, sourceContentKey: sourceContentKey,
                    snapshot: snapshot, actions: actions, digest: digest)
    }

    public func validate(current: ContextDemoDesktopCurrent?) throws {
        guard let current, current.request == request, current.sourceContentKey == sourceContentKey else {
            throw ContextDemoDesktopError.stalePlan
        }
    }
}

private enum ContextDemoDesktopDigest {
    static func hash(_ fields: [String]) -> String {
        SpeechSHA256.hex(Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }
}
