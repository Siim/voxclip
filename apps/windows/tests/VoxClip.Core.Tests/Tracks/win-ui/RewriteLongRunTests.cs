#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>A long Rewrite run (Mac <c>ClipTakePlan</c> parts): more phrases than one batch holds are priced and approved once
/// and voiced part by part. A later part quoted again at another price stops the run, sending nothing more.</summary>
public sealed class RewriteLongRunTests
{
    [Fact]
    public async Task ALaterPartWhosePriceChangedStopsWithNothingMoreSent()
    {
        var changed = false;
        var runners = RewriteSmokeTests.LongRunWords.Select((_, index) => new Runner((_, _) => (Fit, Passed))
            { Price = _ => index == VoiceLabTakeBatch.MaximumWindows && changed ? .02m : .01m }).ToArray();
        using var session = Session(new(RewriteSmokeTests.LongRunReply, (_, ordinals) => Rows(ordinals, "x")), last: 79);
        RewriteOwnTakeTests.ConfigureWithSource(session, index => runners[index]);
        Assert.True(await ProposeAsync(session));
        await session.WordingFitWork;
        await session.DiscoverWindowsAsync();
        foreach (var window in session.GenerationWindows) await window.PendingUpdate;
        var run = Assert.IsType<VoiceLabTakeRunParts>(session.PreparedBatch);
        Assert.Equal(3, run.Parts.Count);
        Assert.Equal(RewriteSmokeTests.LongRunWords.Length, run.Windows.Count);
        Assert.Equal(run.Parts.Sum(part => part.Estimate.Usd), run.Estimate.Usd);
        session.MarkBatchEstimateShown(run);
        var priced = runners.Select(runner => runner.Prepares).ToArray();
        changed = true;
        var approvals = 0;
        await session.GenerateWindowsAsync((_, _, _, _) => { approvals++; return Task.FromResult(true); }, _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        Assert.Equal(1, approvals);
        Assert.Equal(RewriteSession.PriceChangedCopy, session.Problem);
        Assert.All(runners.Take(VoiceLabTakeBatch.MaximumWindows), runner => Assert.Equal(1, runner.Sends));
        Assert.All(runners.Skip(VoiceLabTakeBatch.MaximumWindows), runner => Assert.Equal(0, runner.Sends));
        Assert.Equal(priced[VoiceLabTakeBatch.MaximumWindows] + 1, runners[VoiceLabTakeBatch.MaximumWindows].Prepares);
    }

    [Fact]
    public void TheRunLimitIsStatedWithWhatToDo()
    {
        Assert.Equal(100, VoiceLabTakeBatch.MaximumRunPhrases);
        Assert.Equal("These changes make 140 phrases to voice. Up to 100 can be voiced in one run: voice the first changes now and rewrite the rest after.",
            RewriteSession.TooManyPhrasesCopy(140));
    }
}
#endif
