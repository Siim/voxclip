#if WIN_UI_TESTS
using System.Runtime.CompilerServices;
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Media;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The stage's preview-failed state (design.md §5.4.4 g; Mac <c>PreviewFailureStageTests</c>): the line on the stage and not over a
/// stand-in, Reload Preview's load clearing it, each compositor reason's line, log entry and one announcement, and the display watch that
/// re-attaches a ready preview the stage isn't showing. The native plate and the presenter's timer are the hosted Windows CI's.</summary>
public sealed class PreviewFailureStageTests
{
    private sealed class Probe
    {
        internal readonly List<(LogLevel Level, string Category, string Message)> Logs = [];
        internal readonly List<string> Announced = [];
        internal int Changes;
        internal PreviewStageState Stage { get; }
        internal Probe()
        {
            Stage = new((level, category, message) => Logs.Add((level, category, message)), Announced.Add);
            Stage.Changed += (_, _) => Changes++;
        }
    }

    [Fact]
    public void TheLineSitsOnTheStageOverThePlayerAndNotOverAStandIn()
    {
        var probe = new Probe();
        probe.Stage.ShowsPlayer = true;
        Assert.Null(probe.Stage.StagePreviewError);
        probe.Stage.CompositorFailed(PreviewFailureReason.CaptionLayout);
        Assert.Equal("Captions couldn't be drawn, so the preview plays without them.", probe.Stage.StagePreviewError);
        Assert.Null(probe.Stage.TranscriptPreviewError);
        // With a stand-in (missing, corrupt, audio only, demo) the transcript's notice carries it instead.
        probe.Stage.ShowsPlayer = false;
        Assert.Null(probe.Stage.StagePreviewError);
        Assert.Equal("Captions couldn't be drawn, so the preview plays without them.", probe.Stage.TranscriptPreviewError);
        Assert.Equal("Reload Preview", PreviewStageState.ReloadPreview);
    }

    [Fact]
    public void ReloadPreviewsLoadClearsTheLineAndALoadFailureSaysWhy()
    {
        var probe = new Probe { Stage = { ShowsPlayer = true } };
        probe.Stage.CompositorFailed(PreviewFailureReason.Disclosure);
        Assert.Equal(1, probe.Changes);
        probe.Stage.Cleared();
        Assert.Null(probe.Stage.PreviewError);
        Assert.Equal(2, probe.Changes);
        probe.Stage.Cleared();
        Assert.Equal(2, probe.Changes);
        // A load that fails with a compositor reason shows that reason's line, once.
        var marked = new IOException("decode failed");
        PreviewFailureReasons.Mark(marked, PreviewFailureReason.SourceFrame);
        probe.Stage.LoadFailed(marked, "unused");
        Assert.Equal("The preview couldn't draw the video.", probe.Stage.StagePreviewError);
        probe.Stage.LoadFailed(marked, "unused");
        Assert.Single(probe.Announced, "The preview couldn't draw the video.");
        // Any other load failure shows its safe line.
        probe.Stage.Cleared();
        probe.Stage.LoadFailed(new IOException("other"), "VoxClip couldn't decode this video. Your edits are saved.");
        Assert.Equal("VoxClip couldn't decode this video. Your edits are saved.", probe.Stage.StagePreviewError);
    }

    [Theory]
    [InlineData(PreviewFailureReason.CaptionRaster)]
    [InlineData(PreviewFailureReason.CaptionLayout)]
    [InlineData(PreviewFailureReason.Title)]
    [InlineData(PreviewFailureReason.Disclosure)]
    [InlineData(PreviewFailureReason.SourceFrame)]
    public void ACompositorFailureSetsTheLineAnnouncesItOnceAndLogsItsTag(PreviewFailureReason reason)
    {
        var probe = new Probe { Stage = { ShowsPlayer = true } };
        probe.Stage.CompositorFailed(reason);
        var line = PreviewStageState.Message(reason);
        Assert.Equal(line, probe.Stage.StagePreviewError);
        Assert.Equal([line], probe.Announced);
        var entry = Assert.Single(probe.Logs);
        Assert.Equal((LogLevel.Error, "preview", "compositor reason=" + reason.Tag()), entry);
        Assert.DoesNotContain(".mp4", entry.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("/", entry.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void EveryReasonHasALine()
    {
        Assert.All(PreviewFailureReasons.All, reason => Assert.False(string.IsNullOrWhiteSpace(PreviewStageState.Message(reason))));
        Assert.Equal("The title couldn't be drawn, so the preview plays without it.", PreviewStageState.Message(PreviewFailureReason.Title));
        Assert.Equal("The AI voice label couldn't be drawn, so the preview stopped.", PreviewStageState.Message(PreviewFailureReason.Disclosure));
        foreach (var frames in new[] { PreviewFailureReason.SourceFrame, PreviewFailureReason.LipsyncFrame, PreviewFailureReason.DemoFrame, PreviewFailureReason.FrameBuffer })
            Assert.Equal("The preview couldn't draw the video.", PreviewStageState.Message(frames));
        foreach (var captions in new[] { PreviewFailureReason.CaptionLayout, PreviewFailureReason.CaptionRaster, PreviewFailureReason.Resources })
            Assert.Equal("Captions couldn't be drawn, so the preview plays without them.", PreviewStageState.Message(captions));
    }

    [Fact]
    public void ADisplayStallIsLoggedWithItsFixedLine()
    {
        var probe = new Probe();
        probe.Stage.DisplayStalled();
        Assert.Equal([(LogLevel.Error, "preview", "display stalled, layer reattached")], probe.Logs);
        Assert.Empty(probe.Announced);
        Assert.Null(probe.Stage.PreviewError);
    }

    private sealed class Item;

    [Fact]
    public void AReadyItemWhoseImageShowsNothingIsReattachedOncePerItem()
    {
        var watch = new PlayerDisplayWatch();
        Item first = new(), second = new();
        bool Tick(Item? item, bool ready = true, bool layer = false, bool window = true) => watch.Tick(item, ready, layer, window);
        Assert.Equal([false, false, false, true], Enumerable.Range(0, 4).Select(_ => Tick(first)).ToArray());
        // Once per item: the same item never asks again.
        Assert.DoesNotContain(true, Enumerable.Range(0, 8).Select(_ => Tick(first)).ToArray());
        // A new item gets its own chance.
        Assert.Equal([false, false, false, true], Enumerable.Range(0, 4).Select(_ => Tick(second)).ToArray());
        Assert.Equal(PlayerDisplayWatch.Limit, 4);
        // The handled item is held weakly: once it is gone, a new item is never mistaken for it.
        var fresh = HandledThenGone();
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        Assert.False(fresh.HandledIsAlive);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static PlayerDisplayWatch HandledThenGone()
    {
        var watch = new PlayerDisplayWatch();
        var gone = new Item();
        var asked = false;
        for (var tick = 0; tick < 4; tick++) asked |= watch.Tick(gone, true, false, true);
        Assert.True(asked);
        return watch;
    }

    [Fact]
    public void AShownFrameAnItemNotReadyOrNoWindowResetsTheCount()
    {
        var item = new Item();
        foreach (var (ready, layer, window) in new[] { (true, true, true), (false, false, true), (true, false, false) })
        {
            var watch = new PlayerDisplayWatch();
            for (var tick = 0; tick < 3; tick++) watch.Tick(item, true, false, true);
            Assert.False(watch.Tick(item, ready, layer, window));
            Assert.Equal(0, watch.StalledTicks);
            Assert.False(watch.Tick(item, true, false, true));
        }
        var empty = new PlayerDisplayWatch();
        Assert.DoesNotContain(true, Enumerable.Range(0, 6).Select(_ => empty.Tick(null, true, false, true)).ToArray());
    }
}
#endif
