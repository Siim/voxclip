using System.Globalization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;

namespace VoxClip.Core.Services.Speech;

internal static class SpeechCopy
{
    internal static string Bytes(double bytes) => bytes >= 1_000_000_000
        ? (bytes / 1_000_000_000).ToString("0.##", CultureInfo.InvariantCulture) + " GB"
        : bytes >= 1_000_000 ? (bytes / 1_000_000).ToString("0.##", CultureInfo.InvariantCulture) + " MB"
        : Math.Ceiling(bytes).ToString(CultureInfo.InvariantCulture) + (Math.Ceiling(bytes) == 1 ? " byte" : " bytes");

    internal static VoxClipException ModelMissing(TranscriptionModel? model, string? id, long bytes) => new(
        VoxClipErrorCode.ModelMissing,
        $"Download the {(model is not null && model.RawMetadata.TryGetProperty("displayName", out var name) ? name.GetString() : id ?? "Whisper")} model{(bytes > 0 ? $" ({Bytes(bytes)})" : "")} to transcribe on this PC.");

    internal static VoxClipException ChooseLanguage() => new(VoxClipErrorCode.TranscriptionLanguageUnsupported, "Which language is spoken?");

    internal static VoxClipException Failed(string reason) => new(VoxClipErrorCode.TranscriptionFailed,
        $"Transcription stopped: {reason}. Your video is still here.");

    internal static VoxClipException Unsupported(TranscriptEngine engine, string language) => language.Equals("auto", StringComparison.OrdinalIgnoreCase) ? ChooseLanguage() : new(
        VoxClipErrorCode.TranscriptionLanguageUnsupported,
        $"{(engine == TranscriptEngine.Elevenlabs ? "ElevenLabs" : engine == TranscriptEngine.Whispercpp ? "Whisper" : "Apple")} can't transcribe {language}.");

    internal static VoxClipException Checksum(string file) => new(VoxClipErrorCode.ModelChecksumMismatch,
        $"{file} did not match its checksum. Try the download again.");

    internal static VoxClipException DiskFull(string root, double bytes) => new(VoxClipErrorCode.DiskFull,
        $"There isn't enough free space on {Path.GetPathRoot(root)}. Free up {Bytes(Math.Max(1, bytes))} and try again.");

    internal static string Duration(double seconds) => FormattableString.Invariant(
        $"{Math.Floor(seconds / 3600):0}:{Math.Floor(seconds % 3600 / 60):00}:{Math.Floor(seconds % 60):00}");
}
