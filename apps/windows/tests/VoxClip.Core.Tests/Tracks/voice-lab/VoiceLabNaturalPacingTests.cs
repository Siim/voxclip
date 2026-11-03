using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabNaturalPacingTests
{
    [Fact]
    public void SharedHardWindowReservesAgreeBeforeAndAfterPayment()
    {
        var root = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR") ?? throw new InvalidOperationException("VOXCLIP_SHARED_DIR required");
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "fixtures/voice-lab/natural-pacing-cases.json")));
        var fixture = document.RootElement;
        Assert.Equal("voxclip-natural-pacing/1", fixture.GetProperty("schema").GetString());
        Assert.Equal(2, fixture.GetProperty("caseCount").GetInt32());
        var sampleRate = fixture.GetProperty("sourceSampleRate").GetInt32();
        foreach (var row in fixture.GetProperty("cases").EnumerateArray())
        {
            var seconds = row.GetProperty("speechSeconds").GetDouble();
            var duration = row.GetProperty("windowSeconds").GetDouble();
            var reserve = row.GetProperty("reserveSeconds").GetDouble();
            Assert.Equal(reserve, VoiceLabHardJoin.PauseForWindow(duration), 9);
            var source = Window(duration);
            var plan = Assert.IsType<VoiceLabFitResult.Exact>(VoiceLabRewriteFit.Hypothetical(source, null, null, seconds, sampleRate, true)).Plan;
            Assert.Equal((long)(reserve * sampleRate), plan.Incoming.PadFrames);
            Assert.Equal(plan.Incoming.PadFrames, plan.Outgoing.PadFrames);
            var timing = VoiceLabPaceMatching.Match(seconds, source, null, null, sampleRate, true, supportsPace: false);
            Assert.True(timing.Fits);
            Assert.Equal(1, timing.Pace);
            var rate = 6 / ((seconds - 0.09) * VoiceLabRewriteFit.ProviderSpeechRateMultiplier);
            var measured = VoiceLabPaceMatching.Measure("speech", rate, source, null, null, sampleRate, true, supportsPace: false);
            Assert.True(measured.Fits);
            Assert.Equal(seconds, measured.EstimateSeconds, 9);
        }
    }
    private static VoiceLabWindow Window(double seconds) => new("first", "last", [], [], 0, seconds, 0, (long)(seconds * 48_000),
        new(VoiceLabSeamKind.Hard, 0, 0, 240), new(VoiceLabSeamKind.Hard, seconds, (long)(seconds * 48_000), 240));

    [Theory]
    [InlineData(4.1, 5.4)]
    [InlineData(1.3, 2.2)]
    [InlineData(2.7, 5.5)]
    public void PauseHeavyPhrasesNeverChooseProviderMinimum(double seconds, double slot)
    {
        var timing = VoiceLabPaceMatching.Match(seconds, Window(slot), null, null, 48_000, hardJoinSmoothing: true);
        Assert.Equal(1, timing.Pace);
        Assert.DoesNotContain("pace", timing.Copy);
    }

    [Fact]
    public void SourceQuantilesBoundRoomToneGrowthWithoutTouchingWords()
    {
        var profile = new VoiceLabPauseProfile(new([0.2, 0.3, 0.7, 1.2]), new([0.4, 0.6, 1.0, 1.5]));
        Assert.Equal(0.2, profile.WithinSentence.P25);
        Assert.Equal(0.7, profile.WithinSentence.P75);
        Assert.Equal(1.2, profile.WithinSentence.P90);
        Assert.Equal(1, profile.Distribution("finished.").P75);
        VoiceLabWord[] words = [new("hello,", 0, 0.3, true), new("world", 0.5, 1, true)];
        var envelope = new AudioEnvelope(48_000, 0.01, Enumerable.Range(0, 100).Select(block => block is >= 30 and < 50 ? 0f : 1f).ToArray());
        var take = new VoiceLabFitTake(48_000, 48_000, 0, 1, words, envelope);
        var fit = VoiceLabFitPlanner.Plan(Window(1.5), null, null, take, words.Select(word => word.Text).ToArray(), 48_000, pauseProfile: profile, hardJoinSmoothing: false);
        var plan = Assert.IsType<VoiceLabFitResult.Exact>(fit).Plan;
        Assert.True(Assert.Single(plan.Edits).RoomTone);
        Assert.Equal(24_000, plan.Edits[0].Count);
        Assert.Equal(words[0], plan.Words[0]);
        Assert.Equal(1, plan.Words[1].Start);
        Assert.Equal(1.5, plan.Words[1].End);
        var bounded = VoiceLabFitPlanner.Plan(Window(3), null, null, take, words.Select(word => word.Text).ToArray(), 48_000, pauseProfile: profile, hardJoinSmoothing: false);
        Assert.Equal(24_000, Assert.Single(bounded.Plan.Edits).Count);
        Assert.True(bounded.Plan.OutputFrames < 144_000);
        var shorter = VoiceLabFitPlanner.Plan(Window(0.9), null, null, take, words.Select(word => word.Text).ToArray(), 48_000, false,
            new(new([0.1, 0.2, 0.7]), new([])));
        var shrunk = Assert.IsType<VoiceLabFitResult.Exact>(shorter).Plan;
        Assert.Equal(VoiceLabFitEditKind.Remove, Assert.Single(shrunk.Edits).Kind);
        Assert.Equal(4_800, shrunk.Edits[0].Count);
        Assert.Equal(words[0], shrunk.Words[0]);
        Assert.Equal(0.4, shrunk.Words[1].Start, 9);
    }

    [Fact]
    public void ExistingAlignedPausesGrowBeforeNewConjunctionPauses()
    {
        VoiceLabWord[] words = [new("one", 0, 0.3, true), new("two", 0.5, 0.7, true),
            new("and", 0.76, 0.9, true), new("three", 0.9, 1, true)];
        var envelope = new AudioEnvelope(48_000, 0.01,
            Enumerable.Range(0, 100).Select(block => block is >= 30 and < 50 or >= 70 and < 76 ? 0f : 1f).ToArray());
        var take = new VoiceLabFitTake(48_000, 48_000, 0, 1, words, envelope);
        var fit = VoiceLabFitPlanner.Plan(Window(1.08), null, null, take, words.Select(word => word.Text).ToArray(), 48_000,
            false, new(new([0.7]), new([])));
        Assert.Equal(3_840, Assert.Single(fit.Plan.Edits).Count);
        Assert.Equal(0.58, fit.Plan.Words[1].Start, 9);
    }

    [Fact]
    public void AutomaticPaceMovesOnlyForAnExactNaturalFit()
    {
        var exact = VoiceLabPaceMatching.Match(5.1, Window(5), null, null, 48_000, hardJoinSmoothing: false);
        Assert.Equal(1.02, exact.Pace);
        Assert.True(exact.Fits);
        var tooLong = VoiceLabPaceMatching.Match(7, Window(5), null, null, 48_000, hardJoinSmoothing: true);
        Assert.Equal(1, tooLong.Pace);
        Assert.False(tooLong.Fits);
        Assert.True(tooLong.TooLong);
        var dialogue = VoiceLabPaceMatching.Match(5.1, Window(5), null, null, 48_000, supportsPace: false, hardJoinSmoothing: true);
        Assert.Equal(1, dialogue.Pace);
        Assert.True(VoiceLabPace.IsValid(0.7) && VoiceLabPace.IsValid(1.2));
    }

    [Fact]
    public void CutsPreferOneQuietSpanThenTwoAndNeverEdges()
    {
        static AudioEnvelope Envelope(params (int Start, int End)[] ranges) => new(48_000, 0.01,
            Enumerable.Range(0, 500).Select(block => ranges.Any(range => block >= range.Start && block < range.End) ? 0.001f : 1f).ToArray());
        var one = VoiceLabNaturalPacing.Cuts(0, 240_000, 144_000, 48_000, Envelope((100, 400)), []);
        Assert.Equal(new VoiceLabVideoCut(48_000, 144_000), Assert.Single(one));
        var spoken = new[] { new TimedWord("spoken", "speech", WordKind.Word, 0.5, 4, null, null, null, null, TimingSource.Native) };
        Assert.Empty(VoiceLabNaturalPacing.Cuts(0, 240_000, 144_000, 48_000, Envelope((100, 400)), spoken));
        Assert.Empty(VoiceLabNaturalPacing.Cuts(0, 240_000, 144_000, 48_000, Envelope((100, 400)),
            [spoken[0] with { Kind = WordKind.UnlabeledSpeech }]));
        var piece = new VoiceLabOutputPiece(VoiceLabOutputPieceKind.Synth, 0, 240_000, 0, 144_000, "cut", null, null);
        var timeline = new VoiceLabOutputPlan(48_000, 240_000, [piece], [], VoiceLabOutputScope.Full)
            { VideoCuts = new Dictionary<string, IReadOnlyList<VoiceLabVideoCut>> { ["cut"] = one } };
        Assert.Equal(1, timeline.MapTime(2));
        Assert.Equal(3, timeline.SourceTime(1));
        Assert.Equal(4, timeline.SourceTime(2));
        var two = VoiceLabNaturalPacing.Cuts(0, 240_000, 144_000, 48_000, Envelope((50, 150), (250, 350)), []);
        Assert.Equal(2, two.Count);
        Assert.Equal(96_000, two.Sum(cut => cut.EndSample - cut.StartSample));
        Assert.Empty(VoiceLabNaturalPacing.Cuts(0, 240_000, 24_000, 48_000, Envelope((0, 500)), []));
        var video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Cut, 0, 240_000, 144_000, null, 1.06, 0.5, 0.5,
            null, null, null, null, null, null, null, one);
        Assert.True(VoiceLabNaturalPacing.ValidCuts(video, 48_000));
        var decoded = JsonSerializer.Deserialize<VoiceLabVideoRecipe>(JsonSerializer.Serialize(video))!;
        Assert.Equal(one, decoded.Cuts);
        Assert.False(VoiceLabNaturalPacing.ValidCuts(video with { Cuts = [new(0, 96_000)] }, 48_000));
        Assert.False(VoiceLabNaturalPacing.ValidCuts(video with { Zoom = 1.12 }, 48_000));
    }
}
