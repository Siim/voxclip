#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>A failed take is fixed by what failed, never by its length, and the length test counts the matched speed (Mac
/// <c>RewriteAutoFixReasonTests</c>, voice-lab.md §8.2.2); Rewrite never starts with another video's own voice (Mac
/// <c>RewriteGenerationTests</c>' first-voice tests, §6.13). Stub connectors, runners and Voice Lab backend only.</summary>
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

    /// <summary>A take that failed its word check and runs longer than every video duration carries (Mac MVP13's cause a): its wording
    /// is too long, and a take of the same words would run too long again, so it is reworded shorter at once: one wording round and one
    /// more take, never a Try another first.</summary>
    [Fact]
    public async Task AFailedWordCheckTooLongForEveryDurationIsRewordedShorter()
    {
        var connector = new RewriteAutoFixTests.Connector(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "said briefly"));
        var runner = new RewriteAutoFixTests.Runner((run, _) => run == 1 ? (5.8, RewriteAutoFixTests.WordsFailed) : (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed));
        using var session = await RewriteAutoFixTests.PricedAsync(connector, runner);
        await RewriteAutoFixTests.SettleAsync(session);
        var window = session.Generation!;
        var first = window.Rows[0];
        Assert.False(first.Selectable);
        Assert.True(RewriteGeneration.Length(first) > window.Slot(first));
        Assert.False(window.DurationCarries(first));
        Assert.Single(connector.FitRequests);
        Assert.Equal(2, runner.Sends);
        Assert.DoesNotContain(0, session.AutoFix.TriedAnother);
        Assert.Equal(1, session.AutoFix.Rounds[0]);
        Assert.Equal("said briefly", window.InputFor(window.Rows[1].Id)!.Text);
        Assert.Equal(window.Rows[1].Id, window.SelectedTakeId);
        Assert.Null(session.StuckReason(0));
    }

    [Fact]
    public void TheFirstVoiceIsNeverAnotherVideosOwn()
    {
        RewriteVoice other = new("other", "siim · Car"), anchor = new("anchor", "siim");
        var others = new HashSet<string>(StringComparer.Ordinal) { "other" };
        Assert.Equal("anchor", RewriteGeneration.InitialVoice([other, anchor], null, "anchor", others));
        Assert.Equal("anchor", RewriteGeneration.InitialVoice([other, anchor], null, null, others));
        Assert.Equal("anchor", RewriteGeneration.InitialVoice([other, anchor], "other", "anchor", others));
        Assert.Null(RewriteGeneration.InitialVoice([other], null, "anchor", others));
        Assert.Equal("other", RewriteGeneration.InitialVoice([other, anchor], "other", "anchor"));
    }

    private const string OtherVideoVoice = "22222222-2222-4222-8222-222222222222";

    private static VoicePerVideoBook OtherVideoBook(VoiceConsentRecord anchor) => new()
    {
        Videos = [new("car-key", OtherVideoVoice, anchor.RecordId, new string('a', 64), "Car", "2026-11-19T16:39:19Z", 40, false)]
    };

    /// <summary>A Rewrite of the kitchen video on the harness's Voice Lab whose source media isn't found, so the per-video preference
    /// doesn't apply: the newest listed voice is the car video's own.</summary>
    private static async Task<RewriteSession> KitchenAsync(VideoVoiceFlowTests.Harness h)
    {
        var editor = new EditorViewModel(VideoVoiceFlowTests.Video("kitchen"), now: () => new DateTimeOffset(2026, 11, 21, 0, 0, 0, TimeSpan.Zero));
        var session = RewriteAutoFixTests.Session(new(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "x")), editor: editor);
        session.ConfigureVideoVoice(h.Session, () => null);
        var runner = new RewriteAutoFixTests.Runner((_, _) => (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed));
        session.ConfigureGenerationFactory(index => new(runner,
            _ => Task.FromResult(new RewriteGenerationChoices(h.Backend.Records.Where(record => record.Status == VoiceConsentStatus.Active)
                .Select(record => new RewriteVoice(record.RecordId, record.VoiceName)).ToArray(), [new("eleven_v4", "Eleven v4", ["en"], true, false, 5000, 1)])),
            (voice, model, seed, ct) => session.GenerationInputAsync(voice, model, seed, true,
                (request, _) => Task.FromResult((new VoiceLabSourceExcerpt(request.Frames, []), session.Envelope!)), ct, index),
            _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent));
        Assert.True(await RewriteAutoFixTests.ProposeAsync(session));
        await session.DiscoverWindowsAsync();
        foreach (var window in session.GenerationWindows) await window.PendingUpdate;
        return session;
    }

    [Fact]
    public async Task RewriteStartsWithTheAnchorWhenTheNewestVoiceIsAnotherVideos()
    {
        using var h = new VideoVoiceFlowTests.Harness();
        h.Backend.Records = [h.Anchor with { RecordId = OtherVideoVoice, VoiceName = "siim · Car (VoxClip)" }, h.Anchor];
        await h.Backend.PerVideoStore!.SaveAsync(OtherVideoBook(h.Anchor), TestContext.Current.CancellationToken);
        await h.LoadAsync();
        using var session = await KitchenAsync(h);
        Assert.Equal(h.Anchor.RecordId, Assert.Single(session.GenerationWindows).VoiceId);
    }

    /// <summary>Voice Lab assigns its records before the per-video book loads: until then the car video's voice reads as the anchor and
    /// is chosen. Once the book loads the first choice is made again, while nothing is paid.</summary>
    [Fact]
    public async Task TheFirstVoiceIsChosenAgainOnceThePerVideoBookLoads()
    {
        using var h = new VideoVoiceFlowTests.Harness();
        h.Backend.Records = [h.Anchor with { RecordId = OtherVideoVoice, VoiceName = "siim · Car (VoxClip)" }, h.Anchor];
        await h.LoadAsync();
        using var session = await KitchenAsync(h);
        var window = Assert.Single(session.GenerationWindows);
        Assert.Equal(OtherVideoVoice, window.VoiceId);
        await h.Backend.PerVideoStore!.SaveAsync(OtherVideoBook(h.Anchor), TestContext.Current.CancellationToken);
        await h.LoadAsync();
        await window.PendingUpdate;
        Assert.Equal(new[] { OtherVideoVoice }, session.OtherVideoVoices.ToArray());
        Assert.Equal(h.Anchor.RecordId, window.VoiceId);
    }
}
#endif
