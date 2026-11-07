using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>"Did matching help" before the first take with a video's own voice (voice-lab.md §6.13 item 9, ADR-R45 step 4; Mac
/// <c>VoiceLabSession+AnchorBaseline</c>): the anchor's takes already accepted into the owner's projects, scored on this PC as each new take is,
/// so Settings › Voices can show "siim · 0.54 across 8 earlier takes" beside the video's voice. Read only; nothing is sent. Behind the closed
/// parity gate there is no speaker model, so nothing is measured and no line shows.</summary>
internal sealed partial class VoiceLabSession
{
    private Task? anchorBaselineWork;
    /// <summary>The anchor and model a measurement came back empty for (no projects could be read): Settings rebuilds on every change, so it
    /// isn't asked again for them in this session.</summary>
    private (string Anchor, string Model)? anchorBaselineUnread;

    /// <summary>Settings › Voices' quiet line while the baseline measures.</summary>
    internal bool MeasuringAnchorBaseline { get; private set; }

    /// <summary>The projects the baseline reads: by default the same as Learn from my videos. Tests and smokes set it.</summary>
    internal Func<IReadOnlyList<string>>? AnchorBaselineProjects { get; set; }

    /// <summary>Measures the anchor's baseline in the background unless the book already holds the anchor's with the current speaker model; one
    /// whose anchor or model differs is dropped first. One measurement at a time: a second call returns the running one.</summary>
    internal Task MeasureAnchorBaselineAsync()
    {
        if (anchorBaselineWork is { IsCompleted: false } running) return running;
        if (!Enabled || AnchorVoice(null) is not { } anchor) return Task.CompletedTask;
        anchorBaselineWork = RunAnchorBaselineAsync(anchor);
        return anchorBaselineWork;
    }

    private async Task RunAnchorBaselineAsync(VoiceConsentRecord anchor)
    {
        if (Backend.SpeakerModel(anchor.Language) is not { } model) return;
        if (PerVideoBook.Baseline(anchor.RecordId, model) is not null || anchorBaselineUnread == (anchor.RecordId, model)) return;
        // Another model's or another voice's numbers don't compare with this model's: dropped, then measured again.
        if (PerVideoBook.AnchorBaseline is not null) await UpdateBookAsync(book => book with { AnchorBaseline = null });
        var projects = (AnchorBaselineProjects ?? Backend.LearningProjects)();
        await Dispatch(() => { MeasuringAnchorBaseline = true; Notify(); });
        try
        {
            var result = await Backend.MeasureAnchorBaselineAsync(projects, anchor.RecordId, anchor.Language, Lifetime);
            if (Lifetime.IsCancellationRequested) return;
            if (result is null) { anchorBaselineUnread = (anchor.RecordId, model); return; }
            var baseline = new VoicePerVideoBook.AnchorBaselineEntry(anchor.RecordId, model, result.Mean, result.Scores.Count, Timestamp(Clock.GetUtcNow()));
            await UpdateBookAsync(book => book with { AnchorBaseline = baseline });
            var score = result.Mean is { } mean ? mean.ToString("F3", CultureInfo.InvariantCulture) : "none";
            Backend.Log($"per-video anchor baseline takes={result.Scores.Count} score={score} model={model} projects={projects.Count}");
            if (PerVideoBook.Measurements.FirstOrDefault(measurement => measurement.VideoVoice is not null) is { } latest) LogMatchComparison(latest);
        }
        finally { await Dispatch(() => { MeasuringAnchorBaseline = false; Notify(); }); }
    }

    /// <summary>The log line with both numbers: a video's own voice and the anchor's baseline.</summary>
    private void LogMatchComparison(VoicePerVideoBook.Measurement measurement)
    {
        if (measurement.VideoVoice is not { } own || PerVideoBook.AnchorBaseline is not { Score: { } score } baseline) return;
        static string Value(double value) => value.ToString("F3", CultureInfo.InvariantCulture);
        Backend.Log($"per-video match compared video={measurement.ContentKey[..Math.Min(8, measurement.ContentKey.Length)]} own={Value(own)} " +
            $"anchor_baseline={Value(score)} earlier_takes={baseline.Takes}");
    }

    /// <summary>The baseline line Settings › Voices shows in its comparison, for the anchor it names.</summary>
    internal string? AnchorBaselineLine
    {
        get
        {
            var anchor = AnchorVoice(null);
            return BaselineLine(PerVideoBook.AnchorBaseline, MeasuringAnchorBaseline, anchor?.RecordId, anchor is null ? "your voice" : RebuildName(anchor.VoiceName));
        }
    }

    /// <summary>Settings › Voices shows the comparison once a video has its own voice or a take was measured; showing it starts the baseline.</summary>
    internal static bool ShowsComparison(VoicePerVideoBook book) => book.Measurements.Count > 0 || book.Videos.Count > 0;

    /// <summary>"siim · 0.54 across 8 earlier takes", the quiet line while it measures, or null before it was measured for this anchor.</summary>
    internal static string? BaselineLine(VoicePerVideoBook.AnchorBaselineEntry? baseline, bool measuring, string? anchorId, string anchor)
    {
        if (measuring) return $"Measuring {anchor}'s earlier takes…";
        if (baseline is null || baseline.AnchorId != anchorId) return null;
        if (baseline.Score is not { } score || baseline.Takes <= 0) return $"No earlier takes of {anchor} on this PC to compare with.";
        return $"{anchor} · {score.ToString("F2", CultureInfo.InvariantCulture)} across {baseline.Takes} earlier {(baseline.Takes == 1 ? "take" : "takes")}";
    }
}
