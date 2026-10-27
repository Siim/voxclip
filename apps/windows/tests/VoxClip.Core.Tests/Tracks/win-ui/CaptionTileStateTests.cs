#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class CaptionTileStateTests
{
    [Theory]
    [InlineData(true, true, CaptionTileBackdrop.Stage)]
    [InlineData(true, false, CaptionTileBackdrop.Stage)]
    [InlineData(false, true, CaptionTileBackdrop.FrameBand)]
    [InlineData(false, false, CaptionTileBackdrop.Card)]
    public void FailedTileKeepsItsBackdrop(bool loading, bool frame, CaptionTileBackdrop expected) =>
        Assert.Equal(expected, CaptionTileState.Backdrop(loading, frame));

    [Fact]
    public async Task CancelledOlderRenderCannotReplaceTheNewImage()
    {
        using var tile = new LatestTileRender();
        var old = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var image = "";
        var older = tile.RunAsync(_ => old.Task, result => image = result, TestContext.Current.CancellationToken);
        await tile.RunAsync(_ => Task.FromResult("new"), result => image = result, TestContext.Current.CancellationToken);
        old.SetResult("old");
        await older;
        Assert.Equal("new", image);
    }
}
#endif
