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
        Assert.Equal("voxclip-natural-pacing/2", fixture.GetProperty("schema").GetString());
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

    [Fact]
    public void SharedQuietBoundaryCuts()
    {
        var root = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "fixtures/voice-lab/natural-pacing-cases.json")));
        var fixture = document.RootElement;
        Assert.Equal(13, fixture.GetProperty("cutCaseCount").GetInt32());
        Assert.Equal(13, fixture.GetProperty("cutCases").GetArrayLength());
        foreach (var row in fixture.GetProperty("cutCases").EnumerateArray())
        {
            var quiet = row.GetProperty("quietBlocks").EnumerateArray().Select(range => (Start: range[0].GetInt32(), End: range[1].GetInt32())).ToArray();
            var levels = Enumerable.Range(0, 500).Select(block => quiet.Any(range => block >= range.Start && block < range.End) ? 0.005f : 1f).ToArray();
            foreach (var entry in row.GetProperty("levels").EnumerateArray()) levels[entry[0].GetInt32()] = entry[1].GetSingle();
            var items = row.GetProperty("speech").EnumerateArray().Select((item, index) => new TimedWord("speech-" + index, "speech",
                item.GetProperty("kind").GetString() == "word" ? WordKind.Word : WordKind.UnlabeledSpeech,
                item.GetProperty("start").GetDouble(), item.GetProperty("end").GetDouble(), null, null, null, null, TimingSource.Native)).ToArray();
            var cuts = VoiceLabNaturalPacing.Cuts(row.GetProperty("windowStartSample").GetInt64(), row.GetProperty("windowEndSample").GetInt64(),
                row.GetProperty("outputSamples").GetInt64(), fixture.GetProperty("sourceSampleRate").GetInt32(), new(48000, 0.01, levels), items);
            var expected = row.GetProperty("expected").EnumerateArray().Select(span => new VoiceLabVideoCut(span[0].GetInt64(), span[1].GetInt64())).ToArray();
            Assert.True(expected.SequenceEqual(cuts), row.GetProperty("id").GetString());
        }
    }

    [Fact]
    public void SharedTaggedPauseEdits()
    {
        var root = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "fixtures/voice-lab/natural-pacing-cases.json")));
        using var catalog = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "data/voice-audio-tags.json")));
        var fixture = document.RootElement;
        Assert.Equal(3, fixture.GetProperty("pauseCaseCount").GetInt32());
        VoiceLabWord[] words = [new("hello,", 0, 0.3, true), new("world,", 0.6, 0.9, true), new("again", 1.2, 1.5, true)];
        var levels = Enumerable.Range(0, 150).Select(block => block is >= 30 and < 60 or >= 90 and < 120 ? 0f : 1f).ToArray();
        var take = new VoiceLabFitTake(72000, 48000, 0, 1.5, words, new(48000, 0.01, levels));
        foreach (var row in fixture.GetProperty("pauseCases").EnumerateArray())
            foreach (var tag in catalog.RootElement.GetProperty("tags").EnumerateArray())
            {
                var fit = VoiceLabFitPlanner.Plan(Window(row.GetProperty("windowSeconds").GetDouble()), null, null, take,
                    words.Select(word => word.Text).ToArray(), 48000, false, new(new([0.1, 0.5, 0.7]), new([])),
                    [new(row.GetProperty("beforeToken").GetInt32(), tag.GetProperty("tag").GetString()!)]);
                var edit = Assert.Single(fit.Plan.Edits);
                Assert.Equal(row.GetProperty("kind").GetString() == "insert" ? VoiceLabFitEditKind.Insert : VoiceLabFitEditKind.Remove, edit.Kind);
                Assert.True(row.GetProperty("editedGap").GetInt32() == 1 ? edit.Start < 28800 : edit.Start >= 43200,
                    row.GetProperty("id").GetString() + ": " + tag.GetProperty("tag").GetString());
            }
    }

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
    public void CutReadyFitUsesSpokenTakeWithoutPartialPauseGrowth()
    {
        VoiceLabWord[] words = [new("hello,", 0, 0.3, true), new("world", 0.5, 1, true)];
        var take = new VoiceLabFitTake(48000, 48000, 0, 1, words,
            new(48000, 0.01, Enumerable.Range(0, 100).Select(block => block is >= 30 and < 50 ? 0f : 1f).ToArray()));
        var profile = new VoiceLabPauseProfile(new([0.1, 0.7, 0.8]), new([]));
        var source = new AudioEnvelope(48000, 0.01, Enumerable.Range(0, 240).Select(block =>
            block is >= 50 and < 56 or >= 190 and < 196 ? 0.001f : 1f).ToArray());
        var grown = VoiceLabFitPlanner.Plan(Window(2.4), null, null, take, words.Select(word => word.Text).ToArray(), 48000, false, profile);
        Assert.Equal(28800, Assert.Single(grown.Plan.Edits).Count);
        var fit = VoiceLabNaturalPacing.Fit(Window(2.4), null, null, take, 48000, false, profile, [], source, []);
        Assert.Empty(fit.Plan.Edits);
        Assert.Equal(48000, fit.Plan.OutputFrames);
        Assert.Equal(words, fit.Plan.Words);
        Assert.Equal(new VoiceLabVideoCut(24000, 91200), Assert.Single(fit.Plan.VideoCuts));
        var paidRateTake = take with { AssetSampleRate = 24000, AssetFrames = 24000, Envelope = new(24000, 0.01, take.Envelope.Rms) };
        var paidRateFit = VoiceLabNaturalPacing.Fit(Window(2.4), null, null, paidRateTake, 48000, false, profile, [], source, []);
        Assert.Equal(24000, paidRateFit.Plan.OutputFrames);
        Assert.Equal(fit.Plan.VideoCuts, paidRateFit.Plan.VideoCuts);
        var noCut = VoiceLabNaturalPacing.Fit(Window(2.4), null, null, take, 48000, false, profile, [],
            new(48000, 0.01, Enumerable.Repeat(1f, 240).ToArray()), []);
        Assert.Equal(grown.Plan.OutputFrames, noCut.Plan.OutputFrames);
        Assert.Equal(grown.Plan.Edits, noCut.Plan.Edits);
    }

    [Fact]
    public void PauseTagsRequireACapableModelAndWhitelistedBoundary()
    {
        VoiceLabAudioTag[] tags = [new(1, "long pause"), new(1, "not allowed"), new(3, "laughs")];
        Assert.Empty(VoiceLabNaturalPacing.PauseTags(tags, "eleven_multilingual_v2", 2));
        Assert.Equal(tags.Take(1), VoiceLabNaturalPacing.PauseTags(tags, "eleven_v3", 2));
        var mutable = new List<VoiceLabAudioTag>(tags);
        var input = new VoiceLabTakeInput("hello world", "eleven_v3", "record", "en", 1, "key", new float[48000], 48000,
            [], new HashSet<string>(), Window(1), null, null, false, true) { AudioTags = mutable };
        var snapshot = input.Snapshot();
        mutable.Clear();
        Assert.Equal(tags, snapshot.AudioTags);
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
        Assert.Equal(new VoiceLabVideoCut(24_000, 120_000), Assert.Single(two));
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

    private static JsonDocument Review()
    {
        var root = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR") ?? throw new InvalidOperationException("VOXCLIP_SHARED_DIR required");
        var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "fixtures/voice-lab/natural-pacing-review-cases.json")));
        Assert.Equal("voxclip-natural-pacing-review/1", document.RootElement.GetProperty("schema").GetString());
        Assert.Equal(48000, document.RootElement.GetProperty("sourceSampleRate").GetInt32());
        return document;
    }

    [Fact]
    public void PaidRateCutUsesTheVideoOptionsOutput()
    {
        using var document = Review();
        var fixture = document.RootElement;
        Assert.Equal(1, fixture.GetProperty("paidRateCutCaseCount").GetInt32());
        Assert.Equal(1, fixture.GetProperty("paidRateCutCases").GetArrayLength());
        VoiceLabWord[] words = [new("hello,", 0, 0.3, true), new("world", 0.5, 1, true)];
        foreach (var row in fixture.GetProperty("paidRateCutCases").EnumerateArray())
        {
            var id = row.GetProperty("id").GetString();
            var assetRate = row.GetProperty("assetSampleRate").GetInt32();
            var frames = row.GetProperty("takeFrames").GetInt64();
            var blocks = (int)(frames / VoiceLabGeometry.FrameSize(assetRate));
            var take = new VoiceLabFitTake(frames, assetRate, 0, 1, words,
                new(assetRate, 0.01, Enumerable.Range(0, blocks).Select(block => block is >= 30 and < 50 ? 0f : 1f).ToArray()));
            var quiet = row.GetProperty("sourceQuietBlocks").EnumerateArray().Select(range => (Start: range[0].GetInt32(), End: range[1].GetInt32())).ToArray();
            var source = new AudioEnvelope(48000, 0.01, Enumerable.Range(0, 240).Select(block =>
                quiet.Any(range => block >= range.Start && block < range.End) ? 0.001f : 1f).ToArray());
            var endSample = row.GetProperty("windowEndSample").GetInt64();
            var end = endSample / 48000.0;
            var window = new VoiceLabWindow("first", "last", [], [], 0, end, 0, endSample,
                new(VoiceLabSeamKind.Hard, 0, 0, 240), new(VoiceLabSeamKind.Hard, end, endSample, 240));
            var fit = VoiceLabNaturalPacing.Fit(window, null, null, take, 48000, false,
                new(new([0.1, 0.7, 0.8]), new([])), [], source, []);
            var output = (long)VoxClip.Core.Domain.Editing.EditingMath.Round(VoiceLabRewriteFit.VideoDuration(fit) * 48000);
            Assert.Equal(row.GetProperty("outputSamples").GetInt64(), output);
            var expected = row.GetProperty("expectedCuts").EnumerateArray().Select(span => new VoiceLabVideoCut(span[0].GetInt64(), span[1].GetInt64())).ToArray();
            Assert.True(expected.SequenceEqual(fit.Plan.VideoCuts), id);
            var video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Cut, fit.Plan.WindowStartSample, fit.Plan.WindowEndSample, output,
                null, VoiceLabNaturalPacing.CUT_PUNCH_IN, 0.5, 0.5, null, null, null, null, null, null, null, fit.Plan.VideoCuts);
            Assert.True(VoiceLabNaturalPacing.ValidCuts(video, 48000), id);
        }
    }

    [Fact]
    public void BorrowedWindowReservesWhatRenderValidationRecomputes()
    {
        using var document = Review();
        var fixture = document.RootElement;
        Assert.Equal(1, fixture.GetProperty("borrowedReserveCaseCount").GetInt32());
        Assert.Equal(1, fixture.GetProperty("borrowedReserveCases").GetArrayLength());
        foreach (var row in fixture.GetProperty("borrowedReserveCases").EnumerateArray())
        {
            var id = row.GetProperty("id").GetString();
            var seconds = row.GetProperty("windowSeconds").GetDouble();
            var speech = row.GetProperty("speechSeconds").GetDouble();
            var end = VoiceLabGeometry.Samples(seconds, 48000);
            var window = new VoiceLabWindow("first", "last", [], [], 0, seconds, 0, end,
                new(VoiceLabSeamKind.Hard, 0, 0, 240), new(VoiceLabSeamKind.Gap, seconds, end, 240));
            var frames = VoiceLabGeometry.Samples(speech, 48000);
            var take = new VoiceLabFitTake(frames, 48000, 0, speech, [new("speech", 0, speech, true)],
                new(48000, 0.01, Enumerable.Repeat(1f, (int)(frames / 480)).ToArray()));
            var plan = Assert.IsType<VoiceLabFitResult.Exact>(VoiceLabFitPlanner.Plan(window, null,
                row.GetProperty("outgoingSilenceSeconds").GetDouble(), take, ["speech"], 48000, true)).Plan;
            Assert.Equal(row.GetProperty("reserveFrames").GetInt64(), plan.Incoming.PadFrames);
            Assert.Equal(row.GetProperty("windowEndSample").GetInt64(), plan.WindowEndSample);
            Assert.Equal(plan.WindowEndSample - end, plan.Outgoing.BorrowedSamples);
            var outDuration = plan.OutputFrames / 48000.0;
            var video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Source, plan.WindowStartSample, plan.WindowEndSample,
                plan.WindowEndSample - plan.WindowStartSample, null, null, null, null, null, null, null, null, null, null, null);
            var seams = new VoiceLabSeams(new(VoiceLabSeamKind.Hard, 240, 120, 120, VoiceLabHardJoin.Pause(plan.Words, outDuration, true)),
                new(VoiceLabSeamKind.Gap, 240, 120, 120));
            var error = Record.Exception(() => VoiceLabHardJoin.Validate(seams, null, outDuration, VoiceLabHardJoin.WindowDuration(video, outDuration)));
            Assert.True(error is null, id + ": " + error?.Message);
        }
    }

    [Fact]
    public void UnmeasuredPauseClassKeepsItsLegacyShrinkFloor()
    {
        using var document = Review();
        var fixture = document.RootElement;
        Assert.Equal(2, fixture.GetProperty("emptyClassCaseCount").GetInt32());
        Assert.Equal(2, fixture.GetProperty("emptyClassCases").GetArrayLength());
        static double[] Seconds(JsonElement values) => values.EnumerateArray().Select(value => value.GetDouble()).ToArray();
        foreach (var row in fixture.GetProperty("emptyClassCases").EnumerateArray())
        {
            var id = row.GetProperty("id").GetString();
            var tokens = row.GetProperty("tokens").EnumerateArray().Select(token => token.GetString()!).ToArray();
            VoiceLabWord[] words = [new(tokens[0], 0, 0.3, true), new(tokens[1], 0.6, 1, true)];
            var take = new VoiceLabFitTake(48000, 48000, 0, 1, words,
                new(48000, 0.01, Enumerable.Range(0, 100).Select(block => block is >= 30 and < 60 ? 0f : 1f).ToArray()));
            var profile = new VoiceLabPauseProfile(new(Seconds(row.GetProperty("withinSentence"))), new(Seconds(row.GetProperty("betweenSentences"))));
            Assert.True(profile.Distribution(tokens[0]).IsEmpty, id);
            var fit = VoiceLabFitPlanner.Plan(Window(row.GetProperty("windowSeconds").GetDouble()), null, null, take, tokens, 48000, false, profile);
            var edit = Assert.Single(fit.Plan.Edits);
            Assert.Equal(VoiceLabFitEditKind.Remove, edit.Kind);
            Assert.True(row.GetProperty("removedFrames").GetInt64() == edit.Count, id + ": " + edit.Count);
        }
    }
}
