#if WIN_UI_TESTS
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class HighContrastTraceTests
{
    [Fact]
    public void ThemeChangesReprepareAllInlineTranscriptPaint()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TranscriptView.cs"));
        Assert.Contains("ActualThemeChanged += (_, _) => RebuildThemeVisuals()", source);
        Assert.Contains("DispatcherQueue.TryEnqueue(RebuildThemeVisuals)", source);
        Assert.Contains("repeater.ItemsSource = model?.Paragraphs", source);
    }

    [Fact]
    public void DebugThemeEvidenceIncludesTheSnapshotAndPostRenderPalette()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var ui = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/Ui.cs"));
        var transcript = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TranscriptView.cs"));
        // The trace and every caller compile only in DEBUG, so Release ships neither the writer nor an empty stub.
        Assert.DoesNotContain("Conditional(\"DEBUG\")", ui);
        Assert.True(InsideDebug(ui, "internal static void TraceEffects("));
        Assert.True(InsideDebug(ui, "TraceEffects(\"settings\")"));
        Assert.True(InsideDebug(transcript, "Ui.TraceEffects(\"transcript-post-render\", this)"));
        Assert.Contains("Scheme = HighContrastScheme", ui);
        Assert.Contains("Color(\"VcSelectionTranscriptBrush\")", ui);
        Assert.Contains("Color(\"VcWordPlayingBackgroundBrush\")", ui);
        Assert.Contains("Color(\"VcWordPlayingForegroundBrush\")", ui);
        Assert.Contains("Ui.TraceEffects(\"transcript-post-render\", this)", transcript);
        Assert.Contains("CompositionTarget.Rendering -= rendered", transcript);
    }

    private static bool InsideDebug(string source, string marker)
    {
        var at = source.IndexOf(marker, StringComparison.Ordinal);
        return at >= 0 && source.LastIndexOf("#if DEBUG", at, StringComparison.Ordinal) > source.LastIndexOf("#endif", at, StringComparison.Ordinal);
    }
}
#endif
