#if WIN_UI_TESTS
using System.Globalization;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class TakeRowPresentationTests
{
    private static VoiceLabTakeRow Row(int index, double score = .5, bool fits = true)
    {
        var plan = new VoiceLabFitPlan([new(VoiceLabFitEditKind.Insert, 0, 19200)], new(0, 0), new(0, 0), 0, 57600, 0, 1.2, 0, 57600, 57600, []);
        VoiceLabFitResult fit = fits ? new VoiceLabFitResult.Exact(plan) : new VoiceLabFitResult.ChangedDuration(plan, 1.4, .2);
        return new(Guid.NewGuid(), index, 1, Audio: new(48000, [], [], 0, 0, [], 0, null, fit), Qa: new(1, 0, -3, null, []), Score: score);
    }
    [Fact]
    public void RowsUseInvariantMonoDurationCorePauseNotesAndQualifiedActions()
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new("et-EE"); var row = Row(1);
            var content = TakeRowPresentation.From(row, null);
            Assert.Equal("Take 2", content.Title); Assert.Equal("1.2 s", content.Duration);
            Assert.Equal("pauses +0.4 s", content.Note); Assert.Equal("Play take 2", content.PlayName);
            Assert.Equal("Reject take 2", content.RejectName); Assert.Equal("Take 2, 1.2 s, pauses +0.4 s", content.AutomationName);
            Assert.Equal("Pause take 2", content.PauseName);
            var best = TakeRowPresentation.From(row, row.Id);
            Assert.Equal("Best match", best.Note); Assert.True(best.BestMatch);
            Assert.Equal("Take 2, 1.2 s, Best match", best.AutomationName);
        }
        finally { CultureInfo.CurrentCulture = previous; }
    }
    [Fact]
    public void FailedRowsStayInIndexOrderWithNoSingleTakeRetryOrSelection()
    {
        var failed = Row(2) with { Failure = new IOException("synthetic") };
        var content = TakeRowPresentation.From(failed, failed.Id);
        Assert.False(content.Selectable); Assert.False(content.BestMatch);
        Assert.Equal("Take 3 didn't pass the speech check.", content.FailureText);
        Assert.Equal("Take 3, didn't pass the speech check", content.AutomationName);
        Assert.Empty(content.PlayName); Assert.Empty(content.RejectName);
        Assert.DoesNotContain("Try Another", content.ToString());
        Assert.Null(TakeRowPresentation.Preselect(new([failed], VoiceLabTakeRunEnd.Completed)));
    }
    [Fact]
    public void PreselectionUsesTheExactRankedBestNeverRejectedOrUnfinishedRows()
    {
        var first = Row(0, .4); var best = Row(2, .9, false); var failed = Row(1, 1) with { Failure = new IOException("synthetic") };
        var result = new VoiceLabTakeRunResult([first, failed, best], VoiceLabTakeRunEnd.Completed);
        Assert.Equal(best.Id, TakeRowPresentation.Preselect(result));
        Assert.Equal(first.Id, TakeRowPresentation.Preselect(result, new HashSet<Guid> { best.Id }));
        Assert.Null(TakeRowPresentation.Preselect(result, new HashSet<Guid> { best.Id, first.Id }));
        foreach (var end in new[] { VoiceLabTakeRunEnd.Cancelled, VoiceLabTakeRunEnd.Invalidated, VoiceLabTakeRunEnd.Fatal })
            Assert.Null(TakeRowPresentation.Preselect(result with { End = end }));
        Assert.Equal(best.Id, TakeRowPresentation.Preselect(result with { End = VoiceLabTakeRunEnd.EarlyStop }));
    }
    [Theory]
    [InlineData(1, null, 0, "One take ready.")]
    [InlineData(2, null, 0, "Two takes ready.")]
    [InlineData(3, null, 0, "Three takes ready.")]
    [InlineData(3, null, 1, "Three takes ready, one failed the speech check.")]
    [InlineData(3, null, 2, "Three takes ready, two failed the speech check.")]
    [InlineData(3, 2, 0, "Take 2 fits.")]
    [InlineData(3, 1, 1, "Take 1 fits. One failed the speech check.")]
    [InlineData(3, 3, 2, "Take 3 fits. Two failed the speech check.")]
    public void AnnouncementsMatchMacNumberWords(int count, int? fitted, int failed, string expected)
    {
        Assert.Equal(expected, TakeRowPresentation.Completion(count, fitted, failed));
        Assert.Equal("Take 1 ready.", TakeRowPresentation.Ready(0)); Assert.Equal("Take 2 fits.", TakeRowPresentation.Fits(1));
    }
}
#endif
