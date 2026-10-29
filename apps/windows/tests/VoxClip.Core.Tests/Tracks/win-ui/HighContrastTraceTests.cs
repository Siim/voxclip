#if WIN_UI_TESTS
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class HighContrastTraceTests
{
    [Fact]
    public void DebugThemeEvidenceIncludesTheSnapshotAndPostRenderPalette()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var ui = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/Ui.cs"));
        var transcript = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TranscriptView.cs"));
        Assert.Contains("[System.Diagnostics.Conditional(\"DEBUG\")]", ui);
        Assert.Contains("TraceEffects(\"settings\")", ui);
        Assert.Contains("Scheme = HighContrastScheme", ui);
        Assert.Contains("Color(\"VcSelectionTranscriptBrush\")", ui);
        Assert.Contains("Color(\"VcWordPlayingBackgroundBrush\")", ui);
        Assert.Contains("Color(\"VcWordPlayingForegroundBrush\")", ui);
        Assert.Contains("Ui.TraceEffects(\"transcript-post-render\", this)", transcript);
        Assert.Contains("CompositionTarget.Rendering -= rendered", transcript);
    }
}
#endif
