import Foundation

extension LLMError {
    var caseName: String {
        switch self {
        case .noConnector: "noConnector"
        case .missingKey: "missingKey"
        case .unauthorized: "unauthorized"
        case .quotaExceeded: "quotaExceeded"
        case .rateLimited: "rateLimited"
        case .planLimit: "planLimit"
        case .overloaded: "overloaded"
        case .server: "server"
        case .network: "network"
        case .timeout: "timeout"
        case .modelNotFound: "modelNotFound"
        case .contextTooLong: "contextTooLong"
        case .badRequest: "badRequest"
        case .refused: "refused"
        case .truncated: "truncated"
        case .invalidOutput: "invalidOutput"
        case .unsupportedLanguage: "unsupportedLanguage"
        case .notRunning: "notRunning"
        case .noModels: "noModels"
        case .unavailable: "unavailable"
        case .cliMissing: "cliMissing"
        case .cliTooOld: "cliTooOld"
        case .cliSignedOut: "cliSignedOut"
        case .cliFailed: "cliFailed"
        case .cancelled: "cancelled"
        }
    }

    public var code: VoxClipErrorCode {
        switch self {
        case .noConnector, .missingKey: .keyMissing
        case .unauthorized: .keyRejected
        case .rateLimited, .planLimit, .overloaded: .rateLimited
        case .network: .offline
        case .noModels: .modelMissing
        case .cliMissing, .cliTooOld: .cliNotInstalled
        case .cliSignedOut: .cliNotSignedIn
        case .unsupportedLanguage: .localeUnsupported
        case .invalidOutput, .truncated: .llmInvalidOutput
        case .cancelled: .cancelled
        default: .providerError
        }
    }

    public func userMessage(label: String, model: String = "", feature: LLMFeature = .clipFinder, redactor: Redactor = Redactor(), installHint: String = "", signInHint: String = "", cli: String? = nil, includeEditsSaved: Bool = true) -> String? {
        let cli = cli ?? label.replacingOccurrences(of: " (installed CLI)", with: "")
        let message: String
        switch self {
        case .noConnector: message = "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI."
        case .missingKey: message = "Add your \(label) API key in Settings › AI."
        case .unauthorized: message = "\(label) rejected the API key. Check it in Settings › AI."
        case .quotaExceeded: message = "\(label) says this account is out of credit or over its quota."
        case .rateLimited(let after):
            message = "\(label) is rate limiting this key. " + (after.map { "Try again in \(Int(min(86400, max(0, ceil($0))))) s." } ?? "Try again in a minute.")
        case .planLimit(let detail): message = "Your \(cli) plan's usage limit is reached. " + AIText.prefix(redactor.redact(detail ?? ""), utf16: 200)
        case .overloaded: message = "\(label) is overloaded right now. Try again shortly or pick another model."
        case .server(let status): message = "\(label) had a server error (\(status)). Try again."
        case .network: message = "Couldn't reach \(label). Check your internet connection."
        case .timeout: message = "\(label) took too long to answer. Try again, or pick a faster model."
        case .modelNotFound(let name): message = "\(label) doesn't offer the model \"\(name)\" to this account. Pick another model or refresh the list."
        case .contextTooLong: message = "This transcript is too long for \(model). Pick a model with a larger context."
        case .badRequest(let status, let detail): message = "\(label) rejected the request (\(status)): " + AIText.prefix(redactor.redact(detail), utf16: 200)
        case .refused:
            message = feature == .clipFinder ? "Clips could not be suggested for this recording." : feature == .aiTighten ? "The model declined to tighten this recording." : feature == .voiceRewrite ? "The model declined to rewrite this recording." : "The model declined the test request."
        case .truncated: message = feature == .aiTighten ? "The tighten suggestions were incomplete. Please try again." : feature == .voiceRewrite ? "The rewrite was incomplete. Please try again." : "The clip suggestions were incomplete. Please try again."
        case .invalidOutput: message = "The model's answer wasn't in the expected format. Try again or pick another model."
        case .unsupportedLanguage(let language): message = "Apple's on-device model doesn't support \(Locale(identifier: "en").localizedString(forIdentifier: language) ?? language). Use an API key, a CLI or a local model for this project."
        case .notRunning(let url):
            message = label == "Ollama" ? "Ollama isn't running at \(url). Start Ollama and try again." : "LM Studio's server isn't running at \(url). Start it from LM Studio's Developer tab."
        case .noModels: message = label == "Ollama" ? "Ollama has no chat models. Run `ollama pull <model>`, then refresh." : "Load or download a model in LM Studio, then refresh."
        case .unavailable(let reason): message = reason
        case .cliMissing: message = "\(cli) isn't installed. \(installHint)"
        case .cliTooOld(let version, _):
            let version = AIText.trim(version)
            let suffix = version.isEmpty || version == "unknown" ? "" : " \(version)"
            message = "Your \(cli)\(suffix) is too old for VoxClip. Update it, then try again."
        case .cliSignedOut: message = "\(cli) isn't signed in. \(signInHint.isEmpty ? "Open Terminal and sign in through the CLI itself." : signInHint)"
        case .cliFailed(let detail): message = "\(cli) stopped with an error: " + AIText.prefix(redactor.redact(detail), utf16: 200)
        case .cancelled: return nil
        }
        return redactor.redact(AIText.trim(message)) + (includeEditsSaved ? " Your edits are saved." : "")
    }
}
