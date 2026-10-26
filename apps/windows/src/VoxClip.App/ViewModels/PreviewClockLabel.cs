namespace VoxClip.App.ViewModels;

/// <summary>Label the edited preview clock, including its current clip scope.</summary>
public static class PreviewClockLabel
{
    public static string Format(double editedTime, double duration, bool clip)
    {
        var length = Math.Max(0, duration);
        var elapsed = Math.Clamp(editedTime, 0, length);
        return $"{(clip ? "Clip" : "Edit")} {EditorViewModel.Timecode(elapsed)} / {EditorViewModel.Timecode(length)}";
    }
}
