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
    case modelMissing(String)
    case modelChecksumMismatch(String)
    case keyMissing(String)
    case keyRejected(String)
    case keyPermissionMissing
    case quotaExceeded(String)
    case rateLimited(String)
    case mediaTooLong(String)
    case transcriptionLanguageUnsupported(String)
    case speechAssetsUnavailable(String)
    case transcriptionFailed(String)
    case offline
    case providerError(String)
    case cliNotInstalled(String)
    case cliNotSignedIn(String)
    case llmInvalidOutput
    case localeUnsupported(String)
    case everythingCut
    case diskFull(String)
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
        case .keyPermissionMissing: "This ElevenLabs key can't use speech to text. Allow speech_to_text permission."
        case .llmInvalidOutput: "Could not find clips right now: the model's answer wasn't valid."
        case .encoderUnavailable: "No H.264 encoder is available."
        case .ffmpegLicenceGate: "This VoxClip build contains a GPL FFmpeg and can't run."
        case .unsupportedContainer(let context): "unsupportedContainer: \(context). Your video and edits are unchanged."
        case .mediaMissing(let context): "mediaMissing: \(context). Your video and edits are unchanged."
        case .decodeFailed(let context): "decodeFailed: \(context). Your video and edits are unchanged."
        case .modelMissing(let context): "modelMissing: \(context). Your video and edits are unchanged."
        case .modelChecksumMismatch(let context): "modelChecksumMismatch: \(context). Your video and edits are unchanged."
        case .keyMissing(let context): "keyMissing: \(context). Your video and edits are unchanged."
        case .keyRejected(let context): "keyRejected: \(context). Your video and edits are unchanged."
        case .quotaExceeded(let context): "quotaExceeded: \(context). Your video and edits are unchanged."
        case .rateLimited(let context): "rateLimited: \(context). Your video and edits are unchanged."
        case .mediaTooLong(let context): "mediaTooLong: \(context). Your video and edits are unchanged."
        case .transcriptionLanguageUnsupported(let context): "transcriptionLanguageUnsupported: \(context). Your video and edits are unchanged."
        case .speechAssetsUnavailable(let context): "speechAssetsUnavailable: \(context). Your video and edits are unchanged."
        case .transcriptionFailed(let context): "transcriptionFailed: \(context). Your video and edits are unchanged."
        case .providerError(let context): "providerError: \(context). Your video and edits are unchanged."
        case .cliNotInstalled(let context): "cliNotInstalled: \(context). Your video and edits are unchanged."
        case .cliNotSignedIn(let context): "cliNotSignedIn: \(context). Your video and edits are unchanged."
        case .localeUnsupported(let context): "localeUnsupported: \(context). Your video and edits are unchanged."
        case .diskFull(let context): "diskFull: \(context). Your video and edits are unchanged."
        case .exportFailed(let context): "exportFailed: \(context). Your video and edits are unchanged."
        case .projectUnreadable(let context): "projectUnreadable: \(context). Your video and edits are unchanged."
        }
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
