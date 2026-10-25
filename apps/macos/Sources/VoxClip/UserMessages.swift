import Foundation
import VoxClipCore

enum UserMessages {
    static func message(_ error: any Error, context: String = "", model: String = "the selected model", installHint: String? = nil, signInHint: String? = nil, connectorID: String? = nil) -> String {
        if error is CancellationError || error as? VoxClipError == .cancelled || error as? LLMError == .cancelled { return "" }
        if error as? VoiceLabProjectError == .unsupportedRendering {
            return "This build cannot preview or export generated voice segments yet. Your video and edits are still here."
        }
        if context == "Settings could not be saved." || context == "Settings could not be loaded." { return context + " Your video and edits are still here." }
        let isAI = context.hasPrefix("ai:") || context.hasPrefix("ai-test:")
        let label = isAI ? String(context.split(separator: ":", maxSplits: 1).last ?? "The provider") : "The provider"
        let cli = connectorID == "claude-code" ? "Claude Code" : connectorID == "codex" ? "Codex" : label
        if let error = error as? LLMError { return ai(error, label: label, cli: cli, model: model, testing: context.hasPrefix("ai-test:"), installHint: installHint, signInHint: signInHint) + " Your edits are saved." }
        if isAI {
            let text: String
            switch error as? VoxClipError {
            case .keyMissing: text = "Add your \(label) API key in Settings › AI."
            case .keyRejected: text = "\(label) rejected the API key. Check it in Settings › AI."
            case .quotaExceeded: text = "\(label) says this account is out of credit or over its quota."
            case .rateLimited: text = "\(label) is rate limiting this key. Try again in a minute."
            case .offline: text = "Couldn't reach \(label). Check your internet connection."
            case .llmInvalidOutput: text = "The model's answer wasn't in the expected format. Try again or pick another model."
            case .notImplemented: text = "This feature is not available in this build."
            default: text = "Could not find clips right now. Try again later."
            }
            return text + " Your edits are saved."
        }
        if context == "export", error as? VoxClipError != .everythingCut {
            let reason: String
            if case .exportFailed(let detail) = error as? VoxClipError { reason = clean(detail) }
            else if case .notImplemented = error as? VoxClipError { reason = "this feature is not available in this build" }
            else { reason = "the operation could not finish" }
            return "Export stopped: \(reason). Your edits are saved."
        }
        guard let error = error as? VoxClipError else {
            if let secret = error as? SecretError { return (secret.errorDescription ?? "Keychain access failed.") + " Your video and edits are still here." }
            return "The operation could not finish. Your video and edits are still here."
        }
        switch error {
        case .unsupportedContainer(let detail): return "VoxClip can't open \(clean(detail).uppercased()) files on Mac yet. Export the video as MP4 or MOV and try again."
        case .mediaMissing(let detail): return "Can't find \(URL(fileURLWithPath: detail).lastPathComponent). Edits are saved."
        case .noAudioTrack: return "This video has no audio track, so there is nothing to transcribe."
        case .decodeFailed(let detail): return "VoxClip couldn't decode this video: \(clean(detail)). Your edits are saved."
        case .noSpeech: return "We didn't hear any words. Check the audio track or choose the language."
        case .modelMissing(let detail, let size): return "Download the \(clean(detail)) model (\(clean(size))) to transcribe on this Mac."
        case .modelChecksumMismatch(let detail): return "\(clean(detail)) did not match its checksum. Try the download again."
        case .keyMissing(let detail): return "Add your \(provider(detail)) key in Settings to use it."
        case .keyRejected(let detail, let status): return "\(provider(detail)) rejected the key (\(status ?? Int(httpStatus(detail)) ?? 401)). Your video is still here."
        case .keyPermissionMissing: return "This ElevenLabs key can't use speech to text. Allow the speech_to_text permission for the key on elevenlabs.io."
        case .quotaExceeded(let detail): return "Your \(provider(detail)) credits or key quota are used up."
        case .rateLimited(let detail): return "\(provider(detail)) is busy. Try again in a minute."
        case .mediaTooLong(let detail): return "ElevenLabs accepts up to 10 hours. This take is \(clean(detail))."
        case .transcriptionLanguageUnsupported(let engine, let language): return "\(clean(engine)) can't transcribe \(clean(language))."
        case .speechAssetsUnavailable(let language, let reason): return "macOS couldn't install its \(clean(language)) speech model: \(clean(reason))."
        case .transcriptionFailed(let detail): return "Transcription stopped: \(clean(detail)). Your video is still here."
        case .offline: return "You're offline. On-device transcription and editing still work."
        case .providerError(let detail, let provider, let status): return "\(provider ?? "The provider") answered \(status.map(String.init) ?? httpStatus(detail)): the request could not finish. Your edits are saved."
        case .cliNotInstalled(let detail): return "\(provider(detail)) isn't installed. Install it, sign in once in a terminal, then try again."
        case .cliNotSignedIn(let detail): return "\(provider(detail)) isn't signed in. Sign in once in a terminal, then try again."
        case .llmInvalidOutput: return "Could not find clips right now: the model's answer wasn't valid. Your edits are saved."
        case .localeUnsupported(let detail): return "Apple's on-device model doesn't support \(clean(detail)). Use an API key, a CLI or a local model for this project."
        case .everythingCut: return "Keep at least one word before exporting."
        case .diskFull(let detail, let size): return "There isn't enough free space on \(clean(detail)). Free up \(size ?? "space") and try again."
        case .encoderUnavailable: return "No H.264 encoder is available on this PC. Install the Media Feature Pack or update your graphics driver."
        case .exportFailed(let detail): return "Export stopped: \(clean(detail)). Your edits are saved."
        case .projectUnreadable(let detail): return "This project file can't be read: \(clean(detail))."
        case .projectTooNew: return "This project was saved by a newer VoxClip. Update VoxClip to open it."
        case .sharedResourcesMissing: return "VoxClip is missing some of its files. Reinstall VoxClip."
        case .ffmpegLicenceGate: return "This VoxClip build contains a GPL FFmpeg and can't run."
        case .cancelled: return ""
        case .notImplemented: return "This feature is not available in this build. Your video and edits are still here."
        }
    }
    private static func clean(_ text: String) -> String {
        let suffixes = ["Your edits are saved.", "Your video is still here.", "Your video and edits are still here."]
        let text = suffixes.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
        return String(text.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }
    private static func provider(_ detail: String) -> String {
        for name in ["ElevenLabs", "Anthropic", "OpenAI", "xAI", "Google Gemini", "Claude Code", "Codex", "Ollama", "LM Studio"] where detail.localizedCaseInsensitiveContains(name) { return name }
        return "The provider"
    }
    private static func httpStatus(_ detail: String) -> String {
        guard let range = detail.range(of: "\\b[1-5][0-9]{2}\\b", options: .regularExpression) else { return "unknown status" }
        return String(detail[range])
    }
    private static func ai(_ error: LLMError, label: String, cli: String, model: String, testing: Bool, installHint: String?, signInHint: String?) -> String {
        switch error {
        case .noConnector: return "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI."
        case .missingKey: return "Add your \(label) API key in Settings › AI."
        case .unauthorized: return "\(label) rejected the API key. Check it in Settings › AI."
        case .quotaExceeded: return "\(label) says this account is out of credit or over its quota."
        case .rateLimited(let delay): return "\(label) is rate limiting this key. " + (delay.map { "Try again in \(Int($0)) s." } ?? "Try again in a minute.")
        case .planLimit(let message): return "Your \(cli) plan's usage limit is reached." + (message.map { " \(clean($0))" }.flatMap { $0 == " " ? nil : $0 } ?? "")
        case .overloaded: return "\(label) is overloaded right now. Try again shortly or pick another model."
        case .server(let status): return "\(label) had a server error (\(status)). Try again."
        case .network: return "Couldn't reach \(label). Check your internet connection."
        case .timeout: return "\(label) took too long to answer. Try again, or pick a faster model."
        case .modelNotFound(let model): return "\(label) doesn't offer the model \"\(clean(model))\" to this account. Pick another model or refresh the list."
        case .contextTooLong: return "This transcript is too long for \(model). Pick a model with a larger context."
        case .badRequest(let status, let message): return "\(label) rejected the request (\(status)): \(clean(message))"
        case .refused: return testing ? "The model declined the test request." : "Clips could not be suggested for this recording."
        case .truncated: return "The clip suggestions were incomplete. Please try again."
        case .invalidOutput: return "The model's answer wasn't in the expected format. Try again or pick another model."
        case .unsupportedLanguage(let language): return "Apple's on-device model doesn't support \(clean(language)). Use an API key, a CLI or a local model for this project."
        case .notRunning(let url): return label == "LM Studio" ? "LM Studio's server isn't running at \(clean(url)). Start it from LM Studio's Developer tab." : "Ollama isn't running at \(clean(url)). Start Ollama and try again."
        case .noModels: return label == "LM Studio" ? "Load or download a model in LM Studio, then refresh." : "Ollama has no chat models. Run `ollama pull <model>`, then refresh."
        case .unavailable(let reason):
            if reason == "appleIntelligenceNotEnabled" { return "Turn on Apple Intelligence in System Settings to use the on-device model." }
            if reason == "modelNotReady" { return "Apple's on-device model is still downloading. Try again later." }
            return reason.isEmpty ? "This Mac can't run Apple Intelligence." : reason
        case .cliMissing: return "\(cli) isn't installed. \(installHint ?? "Install it, sign in once in a terminal, then try again.")"
        case .cliTooOld(let version, _): return "Your \(cli) \(clean(version)) is too old for VoxClip. Update it, then try again."
        case .cliSignedOut: return "\(cli) isn't signed in. \(signInHint ?? "Sign in once in a terminal, then try again.")"
        case .cliFailed(let message): return "\(cli) stopped with an error: \(clean(message))"
        case .cancelled: return ""
        }
    }
}
