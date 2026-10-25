import Foundation

/// Stable wire codes; architecture §10.2. notImplemented is skeleton-only (CONTRACTS.md).
public enum VoxClipErrorCode: String, Codable, Sendable, Hashable, CaseIterable {
    case unsupportedContainer
    case mediaMissing
    case noAudioTrack
    case decodeFailed
    case noSpeech
    case modelMissing
    case modelChecksumMismatch
    case keyMissing
    case keyRejected
    case keyPermissionMissing
    case quotaExceeded
    case rateLimited
    case mediaTooLong
    case transcriptionLanguageUnsupported
    case speechAssetsUnavailable
    case transcriptionFailed
    case offline
    case providerError
    case cliNotInstalled
    case cliNotSignedIn
    case llmInvalidOutput
    case localeUnsupported
    case everythingCut
    case diskFull
    case encoderUnavailable
    case exportFailed
    case projectUnreadable
    case projectTooNew
    case sharedResourcesMissing
    case ffmpegLicenceGate
    case cancelled
    case notImplemented
}

/// Safe service failures; architecture §10.1–10.2. Associated context must already be redacted.
public enum VoxClipError: Error, LocalizedError, Codable, Sendable, Equatable {
    case unsupportedContainer(String)
    case mediaMissing(String)
    case noAudioTrack
    case decodeFailed(String)
    case noSpeech
    case modelMissing(String, size: String = "unknown size")
    case modelChecksumMismatch(String)
    case keyMissing(String)
    case keyRejected(String, status: Int? = nil)
    case keyPermissionMissing
    case quotaExceeded(String)
    case rateLimited(String)
    case mediaTooLong(String)
    case transcriptionLanguageUnsupported(String, language: String = "the selected language")
    case speechAssetsUnavailable(String, reason: String = "unavailable")
    case transcriptionFailed(String)
    case offline
    case providerError(String, provider: String? = nil, status: Int? = nil)
    case cliNotInstalled(String)
    case cliNotSignedIn(String)
    case llmInvalidOutput
    case localeUnsupported(String)
    case everythingCut
    case diskFull(String, size: String? = nil)
    case encoderUnavailable
    case exportFailed(String)
    case projectUnreadable(String)
    case projectTooNew
    case sharedResourcesMissing
    case ffmpegLicenceGate
    case cancelled
    case notImplemented(String)

    public var code: VoxClipErrorCode {
        switch self {
        case .unsupportedContainer: .unsupportedContainer
        case .mediaMissing: .mediaMissing
        case .noAudioTrack: .noAudioTrack
        case .decodeFailed: .decodeFailed
        case .noSpeech: .noSpeech
        case .modelMissing: .modelMissing
        case .modelChecksumMismatch: .modelChecksumMismatch
        case .keyMissing: .keyMissing
        case .keyRejected: .keyRejected
        case .keyPermissionMissing: .keyPermissionMissing
        case .quotaExceeded: .quotaExceeded
        case .rateLimited: .rateLimited
        case .mediaTooLong: .mediaTooLong
        case .transcriptionLanguageUnsupported: .transcriptionLanguageUnsupported
        case .speechAssetsUnavailable: .speechAssetsUnavailable
        case .transcriptionFailed: .transcriptionFailed
        case .offline: .offline
        case .providerError: .providerError
        case .cliNotInstalled: .cliNotInstalled
        case .cliNotSignedIn: .cliNotSignedIn
        case .llmInvalidOutput: .llmInvalidOutput
        case .localeUnsupported: .localeUnsupported
        case .everythingCut: .everythingCut
        case .diskFull: .diskFull
        case .encoderUnavailable: .encoderUnavailable
        case .exportFailed: .exportFailed
        case .projectUnreadable: .projectUnreadable
        case .projectTooNew: .projectTooNew
        case .sharedResourcesMissing: .sharedResourcesMissing
        case .ffmpegLicenceGate: .ffmpegLicenceGate
        case .cancelled: .cancelled
        case .notImplemented: .notImplemented
        }
    }

    public var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .notImplemented(let track): "Not implemented (\(track)). Your video and edits are unchanged."
        case .everythingCut: "Keep at least one word before exporting."
        case .projectTooNew: "This project was saved by a newer VoxClip. Update VoxClip to open it."
        case .sharedResourcesMissing: "VoxClip is missing some of its files. Reinstall VoxClip."
        case .noAudioTrack: "This video has no audio track, so there is nothing to transcribe."
        case .noSpeech: "We didn't hear any words. Check the audio track or choose the language."
        case .offline: "You're offline. On-device transcription and editing still work."
        case .keyPermissionMissing: "This ElevenLabs key can't use speech to text. Allow the speech_to_text permission for the key on elevenlabs.io."
        case .llmInvalidOutput: "Could not find clips right now: the model's answer wasn't valid."
        case .encoderUnavailable: "No H.264 encoder is available."
        case .ffmpegLicenceGate: "This VoxClip build contains a GPL FFmpeg and can't run."
        case .unsupportedContainer(let context): "unsupportedContainer: \(context). Your video and edits are unchanged."
        case .mediaMissing(let context): "mediaMissing: \(context). Your video and edits are unchanged."
        case .decodeFailed(let context): "decodeFailed: \(context). Your video and edits are unchanged."
        case .modelMissing(let model, let size): "Download the \(model) model (\(size)) to transcribe on this Mac."
        case .modelChecksumMismatch(let file): "\(file) did not match its checksum. Try the download again."
        case .keyMissing(let context): context.lowercased() == "elevenlabs" ? "Add your ElevenLabs key in Settings to use it." : "keyMissing: \(context). Your video and edits are unchanged."
        case .keyRejected(let context, let status): context.lowercased() == "elevenlabs" ? "ElevenLabs rejected the key (\(status ?? 401)). Your video is still here." : "keyRejected: \(context). Your video and edits are unchanged."
        case .quotaExceeded(let context): context.lowercased() == "elevenlabs" ? "Your ElevenLabs credits or key quota are used up." : "quotaExceeded: \(context). Your video and edits are unchanged."
        case .rateLimited(let context): context.lowercased() == "elevenlabs" ? "ElevenLabs is busy. Try again in a minute." : "rateLimited: \(context). Your video and edits are unchanged."
        case .mediaTooLong(let duration): "ElevenLabs accepts up to 10 hours. This take is \(duration)."
        case .transcriptionLanguageUnsupported(let engine, let language): "\(engine) can't transcribe \(language)."
        case .speechAssetsUnavailable(let language, let reason): "macOS couldn't install its \(language) speech model: \(reason)."
        case .transcriptionFailed(let reason): "Transcription stopped: \(reason). Your video is still here."
        case .providerError(let context, let provider, let status):
            if let provider, let status { "\(provider) answered \(status): \(context)" }
            else { "providerError: \(context). Your video and edits are unchanged." }
        case .cliNotInstalled(let context): "cliNotInstalled: \(context). Your video and edits are unchanged."
        case .cliNotSignedIn(let context): "cliNotSignedIn: \(context). Your video and edits are unchanged."
        case .localeUnsupported(let context): "localeUnsupported: \(context). Your video and edits are unchanged."
        case .diskFull(let context, let size): size.map { "There isn't enough free space on \(context). Free up \($0) and try again." } ?? "diskFull: \(context). Your video and edits are unchanged."
        case .exportFailed(let context): requiresExportRecovery ? context : "exportFailed: \(context). Your video and edits are unchanged."
        case .projectUnreadable(let context): "projectUnreadable: \(context). Your video and edits are unchanged."
        }
    }

    package static let exportRecoveryMessagePrefix = "Couldn't put back "

    package var requiresExportRecovery: Bool {
        if case .exportFailed(let context) = self { return context.hasPrefix(Self.exportRecoveryMessagePrefix) }
        return false
    }

    /// CLI mapping shared by both platforms; architecture §9.3.
    public var exitCode: Int32 {
        switch self {
        case .unsupportedContainer, .mediaMissing, .noAudioTrack, .decodeFailed, .projectUnreadable, .projectTooNew, .sharedResourcesMissing, .ffmpegLicenceGate: 3
        case .noSpeech, .keyPermissionMissing, .mediaTooLong, .transcriptionLanguageUnsupported, .speechAssetsUnavailable, .transcriptionFailed: 4
        case .everythingCut, .diskFull, .encoderUnavailable, .exportFailed: 5
        case .cancelled: 6
        case .keyMissing, .modelMissing, .cliNotInstalled, .cliNotSignedIn: 7
        default: 1
        }
    }
}
