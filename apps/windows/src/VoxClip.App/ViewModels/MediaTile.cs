using System.Globalization;
using VoxClip.App.Services;
namespace VoxClip.App.ViewModels;

/// <summary>What a media tile says over its frame or card (design §5.4.4).</summary>
public enum MediaStatus { None, Loading, Missing, Unreadable, Transcribing, Demo, AudioOnly }

/// <summary>Where a transcription is: the design §13 stages, read by Home chips and sidebar meta.</summary>
public enum TranscriptionStep { Reading, Extracting, Transcribing, Aligning }

/// <summary>A running transcription's stage and fraction; null fraction when the engine reports no progress.</summary>
public readonly record struct TranscriptionStatus(TranscriptionStep Step, double? Fraction)
{
    /// <summary>"42%", in the chip's monospaced figures; empty with no fraction or outside the transcribing stage.</summary>
    public string Percent => Step == TranscriptionStep.Transcribing && Fraction is { } fraction
        ? string.Create(CultureInfo.InvariantCulture, $"{Math.Round(Math.Clamp(fraction, 0, 1) * 100):0}%") : "";
    /// <summary>The chip and sidebar copy before <see cref="Percent"/>: "Transcribing · ", "Transcribing" with no fraction, or a §13 stage.</summary>
    public string Label => Step switch
    {
        TranscriptionStep.Reading => "Reading video…",
        TranscriptionStep.Extracting => "Extracting audio…",
        TranscriptionStep.Aligning => "Aligning words…",
        _ => Percent.Length > 0 ? "Transcribing · " : "Transcribing"
    };
    /// <summary>The state in accessible names, with no "·": "transcribing 42 percent".</summary>
    public string Spoken => Step switch
    {
        TranscriptionStep.Reading => "reading video",
        TranscriptionStep.Extracting => "extracting audio",
        TranscriptionStep.Aligning => "aligning words",
        _ => Percent.Length > 0 ? $"transcribing {Percent[..^1]} percent" : "transcribing"
    };
}

/// <summary>One media tile's state (design §5.4.1): its stand-ins and its status, decided here so views never choose
/// precedence. A real frame wins, then the caption card, then stage black. <see cref="Id"/> names the take or clip, so a
/// recycled tile restarts its loading ladder when it shows another one.</summary>
public sealed record MediaTile(string Id, string? FramePath, CaptionCard? Card, MediaStatus Status, TranscriptionStatus? Transcription = null)
{
    /// <summary>A tile with nothing to show yet: the ladder's stage-black hold.</summary>
    public static MediaTile Empty(string id) => new(id, null, null, MediaStatus.None);
    /// <summary>The caption card has words to set; without them the tile shows the style's backdrop or stage black.</summary>
    public bool HasWords => Card is { Text.Words.Count: > 0 };
    /// <summary>Transcribing with no frame yet: the style backdrop with three dots (design §5.4.4 d).</summary>
    public bool ShowsDots => Status == MediaStatus.Transcribing && FramePath is null && !HasWords;
    /// <summary>The state in a tile's accessible name, with no "·" (design §5.4.9); empty in the normal state.</summary>
    public string Spoken => Status switch
    {
        MediaStatus.Loading => "loading",
        MediaStatus.Missing => "video not found",
        MediaStatus.Unreadable => "video can't be read",
        MediaStatus.Transcribing => Transcription?.Spoken ?? "transcribing",
        MediaStatus.Demo => "demo project, no video",
        MediaStatus.AudioOnly => "audio only",
        _ => ""
    };
    /// <summary>"{title}, {state}", or the title alone in the normal state.</summary>
    public string Name(string title) => Spoken.Length == 0 ? title : $"{title}, {Spoken}";
}
