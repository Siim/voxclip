namespace VoxClip.App.ViewModels;

internal readonly record struct TranscriptWordHighlight(string BackgroundBrush, string ForegroundBrush)
{
    internal static TranscriptWordHighlight? For(bool selected, bool playing, bool highContrast) => playing
        ? new("VcWordPlayingBackgroundBrush", "VcWordPlayingForegroundBrush")
        : selected ? new("VcSelectionTranscriptBrush", highContrast ? "SystemColorHighlightTextColor" : "VcTextPrimaryBrush")
        : null;
}
