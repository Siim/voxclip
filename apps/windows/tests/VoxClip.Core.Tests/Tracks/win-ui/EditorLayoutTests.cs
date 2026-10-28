#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The editor layout rules of implementation step 7: delta §3.3, §3.5, §3.7 and §5.1.</summary>
public sealed class EditorLayoutTests
{
    [Theory]
    [InlineData(268, 40, 216, 12, false)]
    [InlineData(267.9, 40, 216, 12, true)]
    [InlineData(356, 40, 320, 12, true)]
    [InlineData(356, 40, 280, 12, false)]
    [InlineData(268, 76, 252, 4, true)]
    [InlineData(528, 76, 252, 4, false)]
    [InlineData(268, 0, 252, 4, false)]
    public void RowFallbackUsesMeasuredContentNotAWindowBreakpoint(double available, double leading, double trailing, double gap, bool stacked) =>
        Assert.Equal(stacked, EditorLayout.StackMeasuredRow(available, leading, trailing, gap));

    [Fact]
    public void FitProbeRetainsBothBoundsAndAllRequiredWidthsAndStates()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var page = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.NativeProbe.cs"));
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.FitProbe.cs"));
        Assert.Contains("(1280, 800, 348", page);
        Assert.Contains("(1440, 900, 300", page);
        Assert.Contains("(1440, 900, 560", page);
        Assert.Contains("(760, 600, 300", page);
        Assert.Contains("9:59:59.9", page);
        Assert.Contains("Fits(column) && Fits(client)", probe);
        Assert.Contains("peer.GetChildren()", probe);
        Assert.Contains("!text.IsTextTrimmed", probe);
        Assert.Contains("-right-column.png", probe);
    }

    // Tokens.xaml: VcSizeRightColumnMin, VcSizeRightColumnMax; Workspace.xaml: VcLayoutTranscriptMinWidth; the splitter is 12.
    private const double Min = 300, Max = 560, TranscriptMin = 588, Splitter = 12, Pane = 264;

    [Theory]
    [InlineData(1440, 388)]
    [InlineData(1280, 348)]
    [InlineData(1024, 300)]
    [InlineData(2400, 560)]
    public void RightColumnFollowsTheWindowWidth(double window, double expected) => Assert.Equal(expected, EditorLayout.RightColumnWidth(window, Min, Max));

    /// <summary>ui.rightColumnWidth: null until the user moves the splitter; the schema allows 240–720 and the column keeps
    /// its own 300–560.</summary>
    [Theory]
    [InlineData(null, null)]
    [InlineData(420.0, 420.0)]
    [InlineData(240.0, 300.0)]
    [InlineData(720.0, 560.0)]
    [InlineData(double.NaN, null)]
    public void AStoredRightColumnWidthKeepsTheColumnsRange(double? stored, double? expected) => Assert.Equal(expected, EditorLayout.StoredRightColumnWidth(stored, Min, Max));

    [Theory]
    [InlineData(347.6, 348.0)]
    [InlineData(300.0, 300.0)]
    [InlineData(120.0, 300.0)]
    [InlineData(900.0, 560.0)]
    [InlineData(double.PositiveInfinity, null)]
    public void MovingTheSplitterStoresAWholeWidthInTheColumnsRange(double width, double? expected)
    {
        var stored = EditorLayout.RightColumnWidthToStore(width, Min, Max);
        Assert.Equal(expected, stored);
        // What the splitter stores is a width the schema accepts and reads back unchanged.
        if (stored is { } value)
        {
            Assert.InRange(value, 240, 720);
            Assert.Equal(value, EditorLayout.StoredRightColumnWidth(value, Min, Max));
        }
    }

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
        Assert.Equal("Demo projects have no video to export.", EditorLayout.ExportBlocked(true, true, true, true, false));
        Assert.Equal("Locate the video to export.", EditorLayout.ExportBlocked(false, true, true, true, false));
        Assert.Equal("Finish the current task first.", EditorLayout.ExportBlocked(false, false, true, false, true));
        Assert.Equal("Keep at least one word before exporting.", EditorLayout.ExportBlocked(false, false, false, false, true));
        Assert.Equal("Keep this clip to export it.", EditorLayout.ExportBlocked(false, false, false, true, true));
        Assert.Null(EditorLayout.ExportBlocked(false, false, false, true, false));
    }
}
#endif
