using VoxClip.Core.Domain.Captions;

namespace VoxClip.App.ViewModels;

internal readonly record struct AccessibilityEffects(bool Animations, bool AdvancedEffects, bool HighContrast)
{
    internal bool OpaqueTransientSurfaces => HighContrast || !AdvancedEffects;
}

internal sealed class TranscriptionAnnouncements
{
    private MediaTranscriptionStage? stage;
    private int decile = -1;
    internal string? Update(MediaTranscriptionStage next, double? fraction, bool cloud)
    {
        var changed = stage != next;
        if (changed) { stage = next; decile = -1; }
        if (next != MediaTranscriptionStage.Transcribing)
            return !changed ? null : next == MediaTranscriptionStage.ReadingVideo ? "Reading video…" : next == MediaTranscriptionStage.ExtractingAudio ? "Extracting audio…" : "Aligning words…";
        var prefix = cloud ? "Transcribing with ElevenLabs" : "Transcribing on this PC";
        if (fraction is not { } value || !double.IsFinite(value)) return changed ? prefix : null;
        var bucket = Math.Clamp((int)Math.Floor(value * 10), 0, 10);
        if (bucket <= decile) return null;
        decile = bucket;
        return $"{prefix} · {Math.Clamp((int)Math.Round(value * 100), 0, 100)}%";
    }
}

internal static class ClipAnnouncements
{
    internal const string NoResults = "No clips matched. Try another style or describe what you want.";
    internal static string Found(int count, string? noResults = null) => count == 0 ? noResults ?? NoResults
        : count == 1 ? "Found 1 clip." : $"Found {count} clips.";
}

internal static class PlaybackPresentation
{
    internal static string Name(bool playing) => playing ? "Pause" : "Play";
    internal static string Hint(bool playing) => playing ? "Pause (Space)" : "Play (Space)";
}
