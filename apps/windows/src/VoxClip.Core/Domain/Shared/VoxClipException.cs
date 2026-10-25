using System.Text.Json.Serialization;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Stable cross-platform error codes from architecture §10.2, plus the skeleton-only notImplemented sentinel.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<VoxClipErrorCode>))]
public enum VoxClipErrorCode
{
    /// <summary>UnsupportedContainer; architecture §10.2.</summary>
    [JsonStringEnumMemberName("unsupportedContainer")] UnsupportedContainer,
    /// <summary>MediaMissing; architecture §10.2.</summary>
    [JsonStringEnumMemberName("mediaMissing")] MediaMissing,
    /// <summary>NoAudioTrack; architecture §10.2.</summary>
    [JsonStringEnumMemberName("noAudioTrack")] NoAudioTrack,
    /// <summary>DecodeFailed; architecture §10.2.</summary>
    [JsonStringEnumMemberName("decodeFailed")] DecodeFailed,
    /// <summary>NoSpeech; architecture §10.2.</summary>
    [JsonStringEnumMemberName("noSpeech")] NoSpeech,
    /// <summary>ModelMissing; architecture §10.2.</summary>
    [JsonStringEnumMemberName("modelMissing")] ModelMissing,
    /// <summary>ModelChecksumMismatch; architecture §10.2.</summary>
    [JsonStringEnumMemberName("modelChecksumMismatch")] ModelChecksumMismatch,
    /// <summary>KeyMissing; architecture §10.2.</summary>
    [JsonStringEnumMemberName("keyMissing")] KeyMissing,
    /// <summary>KeyRejected; architecture §10.2.</summary>
    [JsonStringEnumMemberName("keyRejected")] KeyRejected,
    /// <summary>KeyPermissionMissing; architecture §10.2.</summary>
    [JsonStringEnumMemberName("keyPermissionMissing")] KeyPermissionMissing,
    /// <summary>QuotaExceeded; architecture §10.2.</summary>
    [JsonStringEnumMemberName("quotaExceeded")] QuotaExceeded,
    /// <summary>RateLimited; architecture §10.2.</summary>
    [JsonStringEnumMemberName("rateLimited")] RateLimited,
    /// <summary>MediaTooLong; architecture §10.2.</summary>
    [JsonStringEnumMemberName("mediaTooLong")] MediaTooLong,
    /// <summary>TranscriptionLanguageUnsupported; architecture §10.2.</summary>
    [JsonStringEnumMemberName("transcriptionLanguageUnsupported")] TranscriptionLanguageUnsupported,
    /// <summary>SpeechAssetsUnavailable; architecture §10.2.</summary>
    [JsonStringEnumMemberName("speechAssetsUnavailable")] SpeechAssetsUnavailable,
    /// <summary>TranscriptionFailed; architecture §10.2.</summary>
    [JsonStringEnumMemberName("transcriptionFailed")] TranscriptionFailed,
    /// <summary>Offline; architecture §10.2.</summary>
    [JsonStringEnumMemberName("offline")] Offline,
    /// <summary>ProviderError; architecture §10.2.</summary>
    [JsonStringEnumMemberName("providerError")] ProviderError,
    /// <summary>CliNotInstalled; architecture §10.2.</summary>
    [JsonStringEnumMemberName("cliNotInstalled")] CliNotInstalled,
    /// <summary>CliNotSignedIn; architecture §10.2.</summary>
    [JsonStringEnumMemberName("cliNotSignedIn")] CliNotSignedIn,
    /// <summary>LlmInvalidOutput; architecture §10.2.</summary>
    [JsonStringEnumMemberName("llmInvalidOutput")] LlmInvalidOutput,
    /// <summary>LocaleUnsupported; architecture §10.2.</summary>
    [JsonStringEnumMemberName("localeUnsupported")] LocaleUnsupported,
    /// <summary>EverythingCut; architecture §10.2.</summary>
    [JsonStringEnumMemberName("everythingCut")] EverythingCut,
    /// <summary>DiskFull; architecture §10.2.</summary>
    [JsonStringEnumMemberName("diskFull")] DiskFull,
    /// <summary>EncoderUnavailable; architecture §10.2.</summary>
    [JsonStringEnumMemberName("encoderUnavailable")] EncoderUnavailable,
    /// <summary>ExportFailed; architecture §10.2.</summary>
    [JsonStringEnumMemberName("exportFailed")] ExportFailed,
    /// <summary>ProjectUnreadable; architecture §10.2.</summary>
    [JsonStringEnumMemberName("projectUnreadable")] ProjectUnreadable,
    /// <summary>ProjectTooNew; architecture §10.2.</summary>
    [JsonStringEnumMemberName("projectTooNew")] ProjectTooNew,
    /// <summary>SharedResourcesMissing; architecture §10.2.</summary>
    [JsonStringEnumMemberName("sharedResourcesMissing")] SharedResourcesMissing,
    /// <summary>FfmpegLicenceGate; architecture §10.2.</summary>
    [JsonStringEnumMemberName("ffmpegLicenceGate")] FfmpegLicenceGate,
    /// <summary>Cancelled; architecture §10.2.</summary>
    [JsonStringEnumMemberName("cancelled")] Cancelled,
    /// <summary>Skeleton-only sentinel requested by the implementation brief; not a shipping architecture §10.2 code.</summary>
    [JsonStringEnumMemberName("notImplemented")] NotImplemented,
}

/// <summary>Safe, typed application failure; architecture §10.1. Messages must not contain provider bodies or keys.</summary>
public class VoxClipException(VoxClipErrorCode code, string message, Exception? innerException = null)
    : Exception(message, innerException)
{
    /// <summary>Machine-readable code, shared with the CLI and other platform.</summary>
    public VoxClipErrorCode Code { get; } = code;

    /// <summary>Stable camel-case wire code; architecture §10.2.</summary>
    public string WireCode => char.ToLowerInvariant(Code.ToString()[0]) + Code.ToString()[1..];

    /// <summary>CLI exit status from architecture §9.3; notImplemented is unexpected failure (1).</summary>
    public int ExitCode => Code switch
    {
        VoxClipErrorCode.Cancelled => 6,
        VoxClipErrorCode.KeyMissing or VoxClipErrorCode.ModelMissing or VoxClipErrorCode.CliNotInstalled or VoxClipErrorCode.CliNotSignedIn => 7,
        VoxClipErrorCode.UnsupportedContainer or VoxClipErrorCode.MediaMissing or VoxClipErrorCode.ProjectUnreadable or VoxClipErrorCode.ProjectTooNew or VoxClipErrorCode.SharedResourcesMissing => 3,
        VoxClipErrorCode.NoAudioTrack or VoxClipErrorCode.NoSpeech or VoxClipErrorCode.TranscriptionFailed or VoxClipErrorCode.TranscriptionLanguageUnsupported or VoxClipErrorCode.SpeechAssetsUnavailable => 4,
        VoxClipErrorCode.EverythingCut or VoxClipErrorCode.EncoderUnavailable or VoxClipErrorCode.ExportFailed or VoxClipErrorCode.DiskFull => 5,
        _ => 1
    };
}

/// <summary>Typed native-media failure carrying safe av_strerror text; architecture §6.1 and §10.1.</summary>
public sealed class MediaException(int nativeError, string operation, string errorText,
    VoxClipErrorCode code = VoxClipErrorCode.DecodeFailed) : VoxClipException(code, operation + ": " + errorText)
{
    /// <summary>Original negative FFmpeg return code, never a native pointer.</summary>
    public int NativeError { get; } = nativeError;
    /// <summary>Operation label without paths, input contents or credentials.</summary>
    public string Operation { get; } = operation;
}
