#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>A failed take is fixed by what failed, never by its length, and the length test counts the matched speed (Mac
/// <c>RewriteAutoFixReasonTests</c>, voice-lab.md §8.2.2). Stub connectors and runners only.</summary>
public sealed class RewriteAutoFixReasonTests
{
    private static readonly VoiceLabTakeQaResult SpeakerFailed = new(1, 0, -3, .2, [VoiceLabTakeQaFailure.Speaker]);
    private static double Slot(VoiceLabTakeInput input) => input.Window.End - input.Window.Start;

    /// <summary>The finding (2026-11-21): eleven_v4 skipped words, so the phrase's only take failed its word check and ran short with no
    /// cut. The resolver asked for a longer wording and paid for a take of the padded text; one more take of the same words was the fix.</summary>
    [Fact]
    public async Task ATakeThatSkippedWordsIsRetakenNeverRewordedLonger()
    {
        var connector = new RewriteAutoFixTests.Connector(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "said at much greater length"));
        var texts = new List<string>();
        var runner = new RewriteAutoFixTests.Runner((run, input) =>
        {
            texts.Add(input.Text);
            return run == 1 ? (Slot(input) * .3, RewriteAutoFixTests.WordsFailed) : (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed);
        });
        using var session = await RewriteAutoFixTests.PricedAsync(connector, runner);
        await RewriteAutoFixTests.SettleAsync(session);
        var window = session.Generation!;
        var first = window.Rows[0];
        Assert.False(first.Selectable);
        // Neither keep source nor a cut carries it (the matched speed would, at 1.11×): it read as too short.
        Assert.True(RewriteGeneration.Length(first) < window.Slot(first));
        Assert.False(window.LengthFits(first));
        Assert.Empty(connector.FitRequests);
        Assert.Equal(2, runner.Sends);
        Assert.Single(texts.Distinct());
        Assert.Contains(0, session.AutoFix.TriedAnother);
        Assert.Equal(1, session.AutoFix.Rounds[0]);
        Assert.Equal(window.Rows[1].Id, window.SelectedTakeId);
        Assert.Null(session.StuckReason(0));
    }

    /// <summary>A failed voice check is retaken at any length. The length test counts the matched speed: a take 1.4× its slot is
    /// carried by slowing the widened window's picture to 0.93×, which <see cref="RewriteGeneration.LengthFits"/> (keep source or a cut)
    /// left out; at 1.8× nothing carries it.</summary>
    [Theory]
    [InlineData(1.4, true)]
    [InlineData(1.8, false)]
    public async Task AFailedVoiceIsRetakenAndTheMatchedSpeedCountsForLength(double ratio, bool carried)
    {
        var connector = new RewriteAutoFixTests.Connector(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "said briefly"));
        var runner = new RewriteAutoFixTests.Runner((run, input) => run == 1 ? (Slot(input) * ratio, SpeakerFailed) : (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed));
        using var session = await RewriteAutoFixTests.PricedAsync(connector, runner);
        await RewriteAutoFixTests.SettleAsync(session);
        var window = session.Generation!;
        var first = window.Rows[0];
        Assert.False(window.LengthFits(first));
        Assert.Equal(carried, window.DurationCarries(first));
        Assert.Empty(connector.FitRequests);
        Assert.Equal(2, runner.Sends);
        Assert.Equal(window.Rows[1].Id, window.SelectedTakeId);
    }
}
#endif
