using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.Core.Domain.Shared;

/// <summary>Immutable source-timeline item; editing §2.2 and timed-word.schema.json. Never rewrite timings during edits.</summary>
public sealed record TimedWord(
    string Id, string Text, WordKind Kind, double Start, double End,
    double? RawStart, double? RawEnd, double? Conf, string? Speaker, TimingSource Timing);

/// <summary>Stored item kind, not derived filler status; editing §2.2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<WordKind>))]
public enum WordKind
{
    /// <summary>Transcribed speech, including fillers.</summary>
    [JsonStringEnumMemberName("word")] Word,
    /// <summary>Explicit non-speech sound.</summary>
    [JsonStringEnumMemberName("event")] Event,
    /// <summary>Audible speech omitted by a non-verbatim engine.</summary>
    [JsonStringEnumMemberName("unlabeledSpeech")] UnlabeledSpeech
}

/// <summary>Pixel dimensions; architecture §4.1.</summary>
public readonly record struct PixelSize(int Width, int Height);

/// <summary>Normalized caption anchor; project schema $defs/position.</summary>
public readonly record struct CaptionPosition(double X, double Y);

/// <summary>Double-precision geometry independent of native graphics; captions §7.</summary>
public readonly record struct RectD(double X, double Y, double Width, double Height);

/// <summary>Double-precision point; captions §7.</summary>
public readonly record struct PointD(double X, double Y);

/// <summary>Source-timeline half-open interval in seconds; editing §2.1.</summary>
public readonly record struct TimeRange(double Start, double End);
