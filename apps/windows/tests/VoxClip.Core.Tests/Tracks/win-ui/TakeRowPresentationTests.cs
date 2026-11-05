#if WIN_UI_TESTS
using System.Globalization;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class TakeRowPresentationTests
{
    [Fact]
    public void AdvisoryRowIsANoteBesideItsPlayAndIsPreselectedWhenBest()
    {
        var row = Row(1) with { Qa = new(1, 4, -3, .8, [VoiceLabTakeQaFailure.Loudness]) { JoinSeams = [new("left", 4)] } };
        var content = TakeRowPresentation.From(row, row.Id, 3);
        Assert.True(content.Selectable && content.JoinAdvisory);
        Assert.True(content.BestMatch);
        Assert.Equal("Best match · join may sound slightly louder", content.Note);
        Assert.Equal("Play take 2, join advisory", content.PlayName);
        Assert.Equal("Take 2 · 1.2 s · Best match · join may sound slightly louder", content.Copy);
        Assert.Equal("Take 2, 1.2 s, Best match · join may sound slightly louder", content.AutomationName);
        Assert.Equal("Take 2 · 1.2 s · join may sound slightly louder", TakeRowPresentation.From(row, null, 3).Copy);
        // ADR-R39: the best take is chosen with its join advisory; a clean take ranks first when there is one.
        Assert.Equal(row.Id, TakeRowPresentation.Preselect(new([row], VoiceLabTakeRunEnd.Completed)));
        var clean = Row(0);
        Assert.Equal(clean.Id, TakeRowPresentation.Preselect(new([row, clean], VoiceLabTakeRunEnd.Completed)));
    }

    private static VoiceLabTakeRow Row(int index, double score = .5, bool fits = true)
    {
        var plan = new VoiceLabFitPlan([new(VoiceLabFitEditKind.Insert, 0, 19200)], new(0, 0), new(0, 0), 0, 57600, 0, 1.2, 0, 57600, 57600, []);
        VoiceLabFitResult fit = fits ? new VoiceLabFitResult.Exact(plan) : new VoiceLabFitResult.ChangedDuration(plan, 1.4, .2);
        return new(Guid.NewGuid(), index, 1, Audio: new(48000, [], [], 0, 0, [], 0, null, fit), Qa: new(1, 0, -3, .8, []), Score: score);
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
        Assert.Equal("Take 3: The required checks did not complete. No result is available. Left out.", content.FailureText);
        Assert.Equal(content.FailureText, content.AutomationName);
        Assert.Equal("Play phrase 1, take 3", content.PlayName);
        Assert.Equal("Pause phrase 1, take 3", content.PauseName);
        Assert.Empty(content.RejectName);
        Assert.DoesNotContain("Try Another", content.ToString());
        Assert.Null(TakeRowPresentation.Preselect(new([failed], VoiceLabTakeRunEnd.Completed)));
    }
    [Theory]
    [InlineData(false, "Take 2: The recognized words did not pass the word check. Left out.", "Play phrase 1, take 2")]
    [InlineData(true, "Take 2 · not checked: The take's word timing could not be validated. Left out.", "Play phrase 1, take 2, not checked")]
    public void PaidFailuresExposeExactMacCopyAndAccessibleInlinePlayback(bool uncheckedAudio, string copy, string playName)
    {
        var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "fixture", "eleven_multilingual_v2", "voice", Guid.NewGuid(), null, null);
        var row = Row(1) with { Qa = new(.5, 0, -3, .8, [VoiceLabTakeQaFailure.Transcript]) };
        if (uncheckedAudio) row = row with { Audio = null, Qa = null, Generated = new([1, 0], 24000, null, receipt),
            Failure = new VoiceLabException(VoiceLabErrorKind.InvalidAlignment) };
        var content = TakeRowPresentation.From(row, row.Id);
        Assert.Equal(copy, content.FailureText); Assert.Equal(copy, content.AutomationName);
        Assert.Equal(playName, content.PlayName); Assert.Equal(playName.Replace("Play", "Pause"), content.PauseName);
        Assert.False(content.Selectable); Assert.False(content.BestMatch); Assert.Empty(content.RejectName);
        Assert.Null(TakeRowPresentation.Preselect(new([row], VoiceLabTakeRunEnd.Completed)));
    }
    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public void InterruptedRowsSayStoppedAndKeepTheirAcceptedRequests(int kind)
    {
        Exception failure = kind switch
        {
            0 => new OperationCanceledException(),
            1 => new VoiceLabException(VoiceLabErrorKind.Cancelled),
            _ => new VoxClip.Core.Services.VoiceLab.VoiceLabRunInvalidatedException()
        };
        var request = Guid.NewGuid();
        var row = Row(1) with { Failure = failure, Accepted = new HashSet<Guid> { request } };
        var content = TakeRowPresentation.From(row, row.Id);
        Assert.True(row.Stopped); Assert.False(content.Selectable); Assert.False(content.BestMatch);
        Assert.Equal("Take 2 stopped.", content.FailureText); Assert.Equal("Take 2, stopped", content.AutomationName);
        Assert.DoesNotContain("speech check", content.ToString());
        Assert.Empty(content.PlayName); Assert.Empty(content.RejectName);
        Assert.Contains(request, row.AcceptedRequestIds);
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
