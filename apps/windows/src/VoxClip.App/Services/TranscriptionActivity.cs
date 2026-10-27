using VoxClip.App.ViewModels;

namespace VoxClip.App.Services;

/// <summary>Projects transcribing in any window, read on the UI thread so a Home tile can show "Transcribing · 42%" with
/// Cancel (design §5.4.4 d). The transcription dialog reports; cancelling here is the same as its own "Not now".</summary>
internal static class TranscriptionActivity
{
    private static readonly Dictionary<string, (TranscriptionStatus Status, Action Cancel)> Running = new(StringComparer.OrdinalIgnoreCase);
    internal static event EventHandler? Changed;

    internal static void Report(string projectPath, TranscriptionStep step, double? fraction, Action cancel)
    {
        Running[projectPath] = (new(step, fraction is { } value && double.IsFinite(value) ? Math.Clamp(value, 0, 1) : null), cancel);
        Changed?.Invoke(null, EventArgs.Empty);
    }

    internal static void End(string projectPath)
    {
        if (Running.Remove(projectPath)) Changed?.Invoke(null, EventArgs.Empty);
    }

    internal static TranscriptionStatus? Status(string projectPath) => Running.TryGetValue(projectPath, out var entry) ? entry.Status : null;

    internal static void Cancel(string projectPath)
    {
        if (Running.TryGetValue(projectPath, out var entry)) entry.Cancel();
    }
}
