using System.Globalization;
using VoxClip.App.Services;
using VoxClip.Core.Domain.Captions;
namespace VoxClip.App.ViewModels;

/// <summary>A running transcription's Core stage and fraction, as TranscriptionActivity reports it; null fraction when the
/// engine reports no progress. It carries the design §13 copy that Home chips and sidebar meta read.</summary>
public readonly record struct TranscriptionStatus(MediaTranscriptionStage Step, double? Fraction)
{
    /// <summary>"42%", in the chip's monospaced figures; empty with no fraction or outside the transcribing stage.</summary>
    public string Percent => Step == MediaTranscriptionStage.Transcribing && Fraction is { } fraction
        ? string.Create(CultureInfo.InvariantCulture, $"{Math.Round(Math.Clamp(fraction, 0, 1) * 100):0}%") : "";
    /// <summary>The chip and sidebar copy before <see cref="Percent"/>: "Transcribing · ", "Transcribing" with no fraction, or a §13 stage.</summary>
    public string Label => Step switch
    {
        MediaTranscriptionStage.ReadingVideo => "Reading video…",
        MediaTranscriptionStage.ExtractingAudio => "Extracting audio…",
        MediaTranscriptionStage.Aligning => "Aligning words…",
        _ => Percent.Length > 0 ? "Transcribing · " : "Transcribing"
    };
    /// <summary>The state in accessible names, with no "·": "transcribing 42 percent".</summary>
    public string Spoken => Step switch
    {
        MediaTranscriptionStage.ReadingVideo => "reading video",
        MediaTranscriptionStage.ExtractingAudio => "extracting audio",
        MediaTranscriptionStage.Aligning => "aligning words",
        _ => Percent.Length > 0 ? $"transcribing {Percent[..^1]} percent" : "transcribing"
    };
    /// <summary>The Core media state of a transcribing take (design §5.4.4 d).</summary>
    public MediaStatus Status => new MediaStatus.Transcribing(Fraction, Step);
}

/// <summary>One media tile's inputs (design §5.4.1): the scope's frame, its caption card and its Core <see cref="MediaStatus"/>.
/// What the tile draws is Core's <see cref="MediaStandIn.Resolve"/>, so views never choose precedence. <see cref="Id"/>
/// names the take or clip, so a recycled tile restarts its loading ladder when it shows another one.</summary>
public sealed record MediaTile(string Id, string? FramePath, CaptionCard? Card, MediaStatus Status)
{
    /// <summary>A tile with nothing to show yet: the ladder's stage-black hold.</summary>
    public static MediaTile Empty(string id) => new(id, null, null, new MediaStatus.None());
    /// <summary>The running transcription for the chip and progress line; null in every other state.</summary>
    public TranscriptionStatus? Transcription => Status is MediaStatus.Transcribing running ? new(running.Stage, running.Fraction) : null;
    /// <summary>What the tile draws now: <paramref name="frameReady"/> is a decoded <see cref="FramePath"/>, and
    /// <paramref name="holding"/> the first 300 ms of the §5.4.5 ladder.</summary>
    public MediaStandIn StandIn(bool frameReady, bool holding) =>
        MediaStandIn.Resolve(Status, frameReady && FramePath is not null, Card?.Text ?? CaptionCardText.None, Card?.StyleId ?? "", holding);
    /// <summary>The state in a tile's accessible name, with no "·" (design §5.4.9); empty in the normal state.</summary>
    public string Spoken => Status switch
    {
        MediaStatus.Loading => "loading",
        MediaStatus.Missing => "video not found",
        MediaStatus.Unreadable => "video can't be read",
        MediaStatus.Transcribing => Transcription!.Value.Spoken,
        MediaStatus.Demo => "demo project, no video",
        MediaStatus.AudioOnly => "audio only",
        _ => ""
    };
    /// <summary>"{title}, {state}", or the title alone in the normal state.</summary>
    public string Name(string title) => Spoken.Length == 0 ? title : $"{title}, {Spoken}";
    /// <summary>Whether a Home tile shows its duration chip (design §7, §5.4.4 a): in the normal state, after the hold, once
    /// the duration has loaded. Every other state has its own chip.</summary>
    public bool ShowsDuration(string duration, bool holding) => Status is MediaStatus.None && !holding && duration.Length > 0;
}
