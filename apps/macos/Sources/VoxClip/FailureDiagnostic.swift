import AVFoundation
import Foundation
import VoxClipCore
import VoxClipMedia

enum FailureContext: String, CaseIterable {
    case importMedia = "import"
    case projectOpen = "project-open"
    case projectSave = "project-save"
    case relink, preview, transcribe, export, share, rewrite, llm
    case askClaude = "ask-claude"
    case clipStyle = "clip-style"
    case makeIt = "make-it"
    case voiceLab = "voice-lab"
    case contextDemo = "context-demo"
    case settings, models, music, editing, startup, update
}

enum FailureDiagnostic {
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || error as? VoxClipError == .cancelled || error as? LLMError == .cancelled
            || error as? VoiceLabError == .cancelled || error as? VoiceConsentError == .cancelled
            || (error as? URLError)?.code == .cancelled || (error as? CocoaError)?.code == .userCancelled
    }

    static func describe(_ error: any Error) -> String {
        if let check = error as? LipsyncResultCheck { return "type=LipsyncResultCheck case=\(check.name.rawValue)" }
        let components = String(reflecting: Swift.type(of: error)).split(separator: ".")
        let type = components.dropFirst(components.count > 1 ? 1 : 0)
            .filter { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }.joined(separator: ".")
        let kind = "type=\(type.isEmpty ? "unknown" : type)"
        if let name = caseName(error, depth: 0) { return "\(kind) case=\(name)" }
        let ns = error as NSError
        switch ns.domain {
        case NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, AVFoundationErrorDomain:
            return "\(kind) domain=\(ns.domain) code=\(ns.code)"
        default:
            return kind
        }
    }

    private static func caseName(_ value: Any, depth: Int) -> String? {
        guard !(value is any CustomReflectable) else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .enum else { return nil }
        guard let child = mirror.children.first else {
            guard !(value is any CustomStringConvertible), !(value is any CustomDebugStringConvertible),
                  !(value is any TextOutputStreamable) else { return nil }
            let name = String(describing: value)
            return name.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil ? name : nil
        }
        guard let label = child.label else { return nil }
        guard depth < 3, !(child.value is any CustomReflectable) else { return label }
        let payload = Mirror(reflecting: child.value)
        let first: Any? = payload.displayStyle == .tuple ? payload.children.first?.value : child.value
        guard let inner = first, let name = caseName(inner, depth: depth + 1) else { return label }
        return label + "." + name
    }
}
