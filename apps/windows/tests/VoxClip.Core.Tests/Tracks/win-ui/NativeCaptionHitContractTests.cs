#if WIN_UI_TESTS
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class NativeCaptionHitContractTests
{
    [Fact]
    public void RecordTheNativePointWithoutRemovingTheDragAssertion()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.NativeProbe.cs"));
        var observer = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/observe-caption-hits.ps1"));
        Assert.Contains("caption-hits.jsonl", probe);
        Assert.Contains("FindElementsInHostCoordinates", probe);
        Assert.Contains("CaptionDrag.IsDragging", probe);
        Assert.Contains("Native left-down did not begin caption drag.", probe);
        Assert.Contains("inputElapsed.Elapsed < TimeSpan.FromSeconds(2)", probe);
        Assert.Contains("Native left-up did not finish caption drag.", probe);
        Assert.Contains("caption-input-ack.jsonl", probe);
        Assert.Contains("AutomationElement]::FromPoint", observer);
        Assert.Contains("BoundingRectangle", observer);
    }
}
#endif
