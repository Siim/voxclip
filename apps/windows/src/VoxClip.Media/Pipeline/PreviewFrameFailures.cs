using VoxClip.Core.Services.Media;

namespace VoxClip.Media.Pipeline;

/// <summary>A loaded preview's compositor failures (design.md §5.4.4 g; Mac <c>PreviewFrameFailures</c>): the compositor reports each
/// failed or degraded preview frame with its fixed reason, and the preview's owner hears about the first one only. Exports never get one.</summary>
public sealed class PreviewFrameFailures(Action<PreviewFailureReason> onFirst)
{
    private readonly object gate = new();
    private readonly List<PreviewFailureReason> reported = [];

    /// <summary>The reasons reported so far, first first; each reason once.</summary>
    public IReadOnlyList<PreviewFailureReason> Reasons { get { lock (gate) return reported.ToArray(); } }

    /// <summary>Records <paramref name="reason"/>; the first reason of this preview calls the owner once.</summary>
    public void Report(PreviewFailureReason reason)
    {
        bool first;
        lock (gate)
        {
            if (reported.Contains(reason)) return;
            reported.Add(reason);
            first = reported.Count == 1;
        }
        if (first) onFirst(reason);
    }

    /// <summary>A frame that can't be finished: reports <paramref name="reason"/> and marks <paramref name="exception"/> with it, in preview
    /// only. An export's exception stays as it was.</summary>
    internal static void Failed(PreviewFrameFailures? failures, bool forPreview, PreviewFailureReason reason, Exception exception)
    {
        if (!forPreview || exception is OperationCanceledException) return;
        PreviewFailureReasons.Mark(exception, reason);
        failures?.Report(reason);
    }
}
