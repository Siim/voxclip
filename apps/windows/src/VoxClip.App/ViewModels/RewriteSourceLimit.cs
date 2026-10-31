using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

/// <summary>The longest source Windows can generate new takes for. A take run reads the whole source track into memory at its
/// own rate (RewriteGenerationBackend.ReadSourceAsync), so 30,000,000 frames (10 min 25 s at 48 kHz) bounds that memory. Only
/// take generation is limited: the AI proposal, Apply Cuts and Apply Correction never read the source audio and work at any
/// length. A longer source is refused when takes are prepared, before any decode or ElevenLabs call. The Mac has no cap
/// (streamed envelope plus VoiceLabSourceExcerpt regions); porting that to Windows removes this limit.</summary>
internal static class RewriteSourceLimit
{
    internal const long MaxFrames = 30_000_000;

    /// <summary>The source track's frame count at its own sample rate, as the take run reads it.</summary>
    internal static long Frames(Project project) =>
        checked((long)Math.Floor(project.Media.Source.DurationSeconds * (project.Media.Source.Audio?.SampleRate ?? 0) + 0.5));

    /// <summary>The refusal for a source too long to generate takes for, or null.</summary>
    internal static string? Refusal(Project project) =>
        project.Media.Source.Audio?.SampleRate is int rate and > 0 && Frames(project) > MaxFrames ? Copy(rate) : null;

    /// <summary>"New takes work only in videos up to 10 minutes long. Cuts and corrections still work. Your edits are saved."
    /// for 48 kHz audio.</summary>
    internal static string Copy(int sampleRate) =>
        $"New takes work only in videos up to {MaxFrames / Math.Max(1, sampleRate) / 60} minutes long. Cuts and corrections still work. Your edits are saved.";
}
