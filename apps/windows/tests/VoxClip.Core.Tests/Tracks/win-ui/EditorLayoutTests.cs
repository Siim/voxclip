#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The editor layout rules of implementation step 7: delta §3.3, §3.5, §3.7 and §5.1.</summary>
public sealed class EditorLayoutTests
{
    // Tokens.xaml: VcSizeRightColumnMin, VcSizeRightColumnMax; Workspace.xaml: VcLayoutTranscriptMinWidth; the splitter is 12.
    private const double Min = 300, Max = 560, TranscriptMin = 588, Splitter = 12, Pane = 264;

    [Theory]
    [InlineData(1440, 388)]
    [InlineData(1280, 348)]
    [InlineData(1024, 300)]
    [InlineData(2400, 560)]
    public void RightColumnFollowsTheWindowWidth(double window, double expected) => Assert.Equal(expected, EditorLayout.RightColumnWidth(window, Min, Max));

    [Theory]
    [InlineData(1440, true)]
    [InlineData(1280, true)]
    [InlineData(1150, false)]
    [InlineData(1024, false)]
    public void TheViewerCollapsesWhenTheTranscriptWouldDropBelowItsMinimum(double window, bool fits)
    {
        var right = EditorLayout.RightColumnWidth(window, Min, Max);
        Assert.Equal(fits, EditorLayout.TranscriptFits(window - Pane, Splitter, right, TranscriptMin));
    }

    [Fact]
    public void AtTheDefaultWidthsTheMeasuresMatchTheBoard()
    {
        // editor-light.png: the right column is 388 at 1440; editor-1280-light.png: 348, leaving the transcript 1280 − 264 − 12 − 348.
        Assert.Equal(656, 1280 - Pane - Splitter - EditorLayout.RightColumnWidth(1280, Min, Max));
        Assert.Equal(776, 1440 - Pane - Splitter - EditorLayout.RightColumnWidth(1440, Min, Max));
    }

    [Theory]
    [InlineData(ExportAspect.Landscape, 1920, 1080, 355, 199.6875)]
    [InlineData(ExportAspect.Portrait, 1920, 1080, 180, 320)]
    [InlineData(ExportAspect.Square, 1920, 1080, 320, 320)]
    [InlineData(ExportAspect.Source, 1920, 1080, 355, 199.6875)]
    [InlineData(ExportAspect.Source, 1080, 1920, 180, 320)]
    public void TheStageFillsTheColumnOrCentresAtMost320High(ExportAspect aspect, int width, int height, double stageWidth, double stageHeight)
    {
        // A 388 column has 355 inside 16 of padding on each side and the 1 px hairline.
        var stage = EditorLayout.Stage(355, aspect, new PixelSize(width, height));
        Assert.Equal(stageWidth, stage.Width, 3);
        Assert.Equal(stageHeight, stage.Height, 3);
    }

    [Fact]
    public void TheStageNeverGrowsPastANarrowColumn()
    {
        Assert.Equal((150.0, 150.0), EditorLayout.Stage(150, ExportAspect.Square, new PixelSize(1920, 1080)));
        Assert.Equal((0.0, 0.0), EditorLayout.Stage(-20, ExportAspect.Landscape, new PixelSize(1920, 1080)));
    }

    [Fact]
    public void TheFrameRowListsPortraitFirstAndKeepsThePersistedValues()
    {
        Assert.Equal([ExportAspect.Portrait, ExportAspect.Square, ExportAspect.Landscape, ExportAspect.Source], EditorLayout.Frames);
        Assert.Equal(4, EditorLayout.Frames.Distinct().Count());
    }

    [Fact]
    public void ExportNamesWhyItIsUnavailable()
    {
        Assert.Equal("Demo projects have no video to export.", EditorLayout.ExportBlocked(true, true, true, false));
        Assert.Equal("Locate the video to export.", EditorLayout.ExportBlocked(false, true, true, false));
        Assert.Equal("Keep at least one word before exporting.", EditorLayout.ExportBlocked(false, false, false, true));
        Assert.Equal("Keep this clip to export it.", EditorLayout.ExportBlocked(false, false, true, true));
        Assert.Null(EditorLayout.ExportBlocked(false, false, true, false));
    }
}
#endif
