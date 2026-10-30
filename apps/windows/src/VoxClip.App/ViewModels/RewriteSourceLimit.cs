using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

/// <summary>The longest source Rewrite can generate takes for. A take run reads the whole source track into memory at its own
/// rate (RewriteGenerationBackend.ReadSourceAsync), because the room tone (voice-lab §8.7 item 3) is chosen from the whole take
/// and the render recipe keeps source sample positions. 30,000,000 frames is 10 min 25 s at 48 kHz. A longer source is refused
/// when Rewrite opens, before the paid AI proposal and before any decode, never after the user has paid for new words.</summary>
internal static class RewriteSourceLimit
{
    internal const long MaxFrames = 30_000_000;

    /// <summary>The source track's frame count at its own sample rate, as the take run reads it.</summary>
    internal static long Frames(Project project) =>
        checked((long)Math.Floor(project.Media.Source.DurationSeconds * (project.Media.Source.Audio?.SampleRate ?? 0) + 0.5));

    /// <summary>The refusal for a source too long to generate takes for, or null.</summary>
    internal static string? Refusal(Project project) =>
        project.Media.Source.Audio?.SampleRate is int rate and > 0 && Frames(project) > MaxFrames ? Copy(rate) : null;

    /// <summary>"Rewriting speech works only in videos up to 10 minutes long. Your edits are saved." for 48 kHz audio.</summary>
    internal static string Copy(int sampleRate) =>
        $"Rewriting speech works only in videos up to {MaxFrames / Math.Max(1, sampleRate) / 60} minutes long. Your edits are saved.";
}
