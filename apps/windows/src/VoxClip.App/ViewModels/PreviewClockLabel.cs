namespace VoxClip.App.ViewModels;

/// <summary>The viewer's edited clock, "1:37.7 / 2:26.0" (design §5): the elapsed time, then the scope's length, which the
/// views set in text.secondary. The selected sidebar row names the scope, so the clock carries no "Edit" or "Clip".</summary>
public static class PreviewClockLabel
{
    public static (string Elapsed, string Total) Parts(double editedTime, double duration)
    {
        var length = Math.Max(0, duration);
        return (EditorViewModel.Timecode(Math.Clamp(editedTime, 0, length)), EditorViewModel.Timecode(length));
    }

    public static string Format(double editedTime, double duration)
    {
        var (elapsed, total) = Parts(editedTime, duration);
        return $"{elapsed} / {total}";
    }
}
