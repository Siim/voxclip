using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>The text-to-voice length estimator (ADR-R43; Mac <c>VoiceLabTTSEstimatorTests</c>): the calibrated prior, the calibration's
/// robust median and spread, the cross-project voice store and the p80 word budget, replayed from <c>tts-estimator-cases.json</c>.</summary>
public sealed class VoiceLabTTSEstimatorTests
{
    private static JsonObject Vectors() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/tts-estimator-cases.json"))!.AsObject();
    private static double[] Doubles(JsonNode? node) => node!.AsArray().Select(value => value!.GetValue<double>()).ToArray();
    private static VoiceLabRateSample[] Samples(IEnumerable<double> ratios, string prefix) =>
        ratios.Select((ratio, index) => new VoiceLabRateSample(prefix + index, ratio)).ToArray();

    [Fact]
    public void ThePriorMatchesTheSharedConstants()
    {
        var vectors = Vectors();
        Assert.Equal("voxclip-tts-estimator/1", vectors["schema"]!.GetValue<string>());
        Assert.Equal(["schema", "caseCount", "prior", "observed", "estimates", "real", "calibration", "wordTargets"], vectors.Select(pair => pair.Key).ToArray());
        Assert.Equal(new[] { "estimates", "real", "calibration", "wordTargets" }.Sum(key => vectors[key]!.AsArray().Count), vectors["caseCount"]!.GetValue<int>());
        Assert.Equal(31, vectors["caseCount"]!.GetValue<int>());
        var prior = vectors["prior"]!;
        Assert.Equal(VoiceLabRewriteFit.PriorVersion, prior["version"]!.GetValue<int>());
        Assert.Equal(VoiceLabRewriteFit.ProviderSpeechRateMultiplier, prior["providerSpeechRateMultiplier"]!.GetValue<double>());
        Assert.Equal(VoiceLabRewriteFit.OnsetSeconds, prior["onsetSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabRewriteFit.SentencePauseSeconds, prior["sentencePauseSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabRewriteFit.ClausePauseSeconds, prior["clausePauseSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabPatchConstants.TTS_TRIM_LEAD, prior["trimLeadSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabPatchConstants.TTS_TRIM_TAIL, prior["trimTailSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabRateCalibration.PriorSpread, prior["priorSpread"]!.GetValue<double>());
        Assert.Equal([VoiceLabRateCalibration.MinimumRatio, VoiceLabRateCalibration.MaximumRatio], Doubles(prior["ratioBounds"]));
        Assert.Equal([VoiceLabRateCalibration.MinimumSpread, VoiceLabRateCalibration.MaximumSpread], Doubles(prior["spreadBounds"]));
        Assert.Equal(VoiceLabRateCalibration.VoiceSampleLimit, prior["voiceSampleLimit"]!.GetValue<int>());
        Assert.Equal(VoiceLabWordingFit.ProjectSampleLimit, prior["projectSampleLimit"]!.GetValue<int>());
        Assert.Equal(VoiceLabRateCalibration.VoiceWeight, prior["voiceWeight"]!.GetValue<int>());
    }

    [Fact]
    public void EstimatesAndPausesReplayTheSharedVectors()
    {
        foreach (var row in Vectors()["estimates"]!.AsArray())
        {
            var text = row!["text"]!.GetValue<string>();
            Assert.Equal(row["letters"]!.GetValue<int>(), VoiceLabTextLength.Length(text));
            Assert.True(Math.Abs(VoiceLabRewriteFit.PauseSeconds(text) - row["pauseSeconds"]!.GetValue<double>()) < 1e-12, row["id"]!.GetValue<string>());
            var estimate = VoiceLabRewriteFit.Estimate(text, row["rate"]!.GetValue<double>());
            Assert.True(Math.Abs(estimate - row["expectedSeconds"]!.GetValue<double>()) < 1e-12, row["id"]!.GetValue<string>());
        }
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabRewriteFit.Estimate("words", 0));
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabRewriteFit.Estimate("words", double.NaN));
    }

    /// <summary>The regression the user hit: the 1.8 prior planned real Eleven v4 takes at about half their length. On the bin medians of
    /// measured takes it misses by more than 40%; the calibrated prior is within 15%.</summary>
    [Fact]
    public void TheOldPriorMissesRealTakesAndTheNewOneFits()
    {
        var rows = Vectors()["real"]!.AsArray();
        Assert.Equal(4, rows.Count);
        foreach (var row in rows)
        {
            var observed = row!["observedSeconds"]!.GetValue<double>();
            Assert.True(observed / row["oldEstimateSeconds"]!.GetValue<double>() - 1 > 0.4);
            var estimate = VoiceLabRewriteFit.Estimate(row["text"]!.GetValue<string>(), row["rate"]!.GetValue<double>());
            Assert.True(Math.Abs(estimate - row["expectedSeconds"]!.GetValue<double>()) < 1e-12);
            Assert.InRange(estimate / observed, 0.85, 1.15);
        }
    }

    [Fact]
    public void CalibrationIsRobustBoundedAndStartsFromTheVoice()
    {
        foreach (var row in Vectors()["calibration"]!.AsArray())
        {
            var id = row!["id"]!.GetValue<string>();
            var project = Samples(Doubles(row["project"]), "p");
            var voice = Samples(Doubles(row["voice"]), "v");
            Assert.Equal(Doubles(row["robustProject"]), VoiceLabRateCalibration.RobustRatios(project, VoiceLabWordingFit.ProjectSampleLimit));
            var merged = VoiceLabRateCalibration.Samples(project, voice);
            Assert.Equal(Doubles(row["merged"]), merged.Select(sample => sample.Ratio).ToArray());
            Assert.True(Math.Abs(VoiceLabWordingFit.Multiplier(merged) - row["multiplier"]!.GetValue<double>()) < 1e-12, id);
            Assert.True(Math.Abs(VoiceLabRateCalibration.Spread(project, voice) - row["spread"]!.GetValue<double>()) < 1e-12, id);
        }
    }

    [Fact]
    public void WordTargetsAimAtTheP80()
    {
        foreach (var row in Vectors()["wordTargets"]!.AsArray())
        {
            var target = VoiceLabWordingFit.WordTarget(row!["wordsPerSecond"]!.GetValue<double>(), row["multiplier"]!.GetValue<double>(),
                row["minimumSeconds"]!.GetValue<double>(), row["maximumSeconds"]!.GetValue<double>(), row["overheadSeconds"]!.GetValue<double>(),
                row["bridgeWords"]!.GetValue<int>(), row["spread"]!.GetValue<double>());
            Assert.Equal(new VoiceLabWordTarget(row["expected"]!["minimum"]!.GetValue<int>(), row["expected"]!["maximum"]!.GetValue<int>()), target);
        }
        // The default budget is the prior's p80: fewer words than a median budget, and a phrase at its maximum is estimated at or
        // under the slot divided by the spread.
        var median = VoiceLabWordingFit.WordTarget(2.5, 1, 2, 6, 0.49, spread: 1);
        var p80 = VoiceLabWordingFit.WordTarget(2.5, 1, 2, 6, 0.49);
        Assert.True(p80.Maximum < median.Maximum);
        var speechPerWord = 1 / (2.5 * VoiceLabRewriteFit.ProviderSpeechRateMultiplier);
        Assert.True(VoiceLabRateCalibration.P80(p80.Maximum * speechPerWord + 0.49) <= 6);
        Assert.True(VoiceLabRateCalibration.P80(median.Maximum * speechPerWord + 0.49) > 6);
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabWordingFit.WordTarget(2, 1, 1, 2, 0, spread: 0.9));
    }

    [Fact]
    public void VoiceCalibrationWireBoundsAndModels()
    {
        var calibration = new VoiceLabVoiceCalibration("73fcf5fb-5e39-463e-9268-104cecb231f2")
            .Recording("eleven_v4", "a", 2, 2).Recording("eleven_v4", "a", 3, 2).Recording("eleven_v4", "far", 9, 2)
            .Recording("eleven_v4", "nan", double.NaN, 2).Recording("", "b", 2, 2).Recording("eleven_v3", "b", 3, 2);
        Assert.Equal([new VoiceLabRateSample("a", 1)], calibration.Samples("eleven_v4"));
        Assert.Equal([new VoiceLabRateSample("b", 1.5)], calibration.Samples("eleven_v3"));
        for (var index = 0; index < 40; index++) calibration = calibration.Recording("eleven_v4", "t" + index, 1 + index / 100.0, 1);
        Assert.Equal(30, calibration.Samples("eleven_v4").Count);
        Assert.Equal("t10", calibration.Samples("eleven_v4")[0].Id);
        // The wire: schema, record, prior and per-model samples, sorted keys.
        var data = calibration.Encoded();
        var root = JsonNode.Parse(data)!.AsObject();
        Assert.Equal(["models", "prior", "recordId", "schema", "seeded"], root.Select(pair => pair.Key).ToArray());
        Assert.Equal("voxclip-voice-rate-calibration/1", root["schema"]!.GetValue<string>());
        Assert.Equal(2, root["prior"]!.GetValue<int>());
        Assert.Equal(calibration, VoiceLabVoiceCalibration.Decode(data, calibration.RecordId));
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabVoiceCalibration.Decode(data, "someone-else"));
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabVoiceCalibration.Decode("{", calibration.RecordId));
        // Ratios against another prior are dropped, out-of-bounds ratios too.
        root["prior"] = 1;
        var stale = VoiceLabVoiceCalibration.Decode(root.ToJsonString(), calibration.RecordId);
        Assert.Empty(stale.Models);
        Assert.False(stale.Seeded);
        root["prior"] = 2;
        root["models"] = new JsonObject
        {
            ["eleven_v4"] = new JsonArray(new JsonObject { ["id"] = "x", ["ratio"] = 9.0 }, new JsonObject { ["id"] = "y", ["ratio"] = 1.1 }),
            [""] = new JsonArray(new JsonObject { ["id"] = "z", ["ratio"] = 1.0 })
        };
        var cleaned = VoiceLabVoiceCalibration.Decode(root.ToJsonString(), calibration.RecordId);
        Assert.Equal(["eleven_v4"], cleaned.Models.Keys.ToArray());
        Assert.Equal([new VoiceLabRateSample("y", 1.1)], cleaned.Samples("eleven_v4"));
    }

    [Fact]
    public async Task StoreKeepsEachVoiceBesideTheConsentRecords()
    {
        var ct = TestContext.Current.CancellationToken;
        var root = Path.Combine(Path.GetTempPath(), "voxclip-rate-store-" + Guid.NewGuid().ToString("N"));
        try
        {
            var locations = DataLocations.Resolve(root, Path.GetTempPath(), true);
            var store = new VoiceLabRateCalibrationStore(locations);
            Assert.Equal(Path.Combine(Path.GetFullPath(root), "VoiceLab", "calibration"), store.Root);
            Assert.Equal(new VoiceLabVoiceCalibration("voice-a"), await store.LoadAsync("voice-a", ct));
            await store.RecordAsync("voice-a", "eleven_v4", "t1", 2.2, 2, ct);
            await store.RecordAsync("voice-a", "eleven_v4", "t2", 1.8, 2, ct);
            await store.RecordAsync("voice-b", "eleven_v4", "t1", 3, 2, ct);
            var all = await store.AllAsync(ct);
            Assert.Equal(["voice-a", "voice-b"], all.Keys.Order(StringComparer.Ordinal).ToArray());
            Assert.Equal(["t1", "t2"], all["voice-a"].Samples("eleven_v4").Select(sample => sample.Id).ToArray());
            Assert.True(VoiceLabRateCalibrationStore.IsValid("73fcf5fb-5e39-463e-9268-104cecb231f2"));
            foreach (var bad in new[] { "", "../x", "a/b", "a.json", new string('a', 129) }) Assert.False(VoiceLabRateCalibrationStore.IsValid(bad));
            await Assert.ThrowsAsync<VoiceLabLengthBudgetException>(() => store.SaveAsync(new VoiceLabVoiceCalibration("../escape"), ct));
            // A corrupt file reads as empty and the next take writes a clean one.
            await File.WriteAllTextAsync(Path.Combine(store.Root, "voice-a.json"), "{", ct);
            Assert.Empty((await store.LoadAsync("voice-a", ct)).Models);
            await store.RecordAsync("voice-a", "eleven_v4", "t3", 2, 2, ct);
            Assert.Equal(["t3"], (await store.LoadAsync("voice-a", ct)).Samples("eleven_v4").Select(sample => sample.Id).ToArray());
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    /// <summary>A new project starts from its voice's calibration: its first estimate already carries the voice's ratio.</summary>
    [Fact]
    public void ANewProjectsEstimateUsesTheStoredVoiceCalibration()
    {
        var voice = new VoiceLabVoiceCalibration("voice");
        foreach (var (ratio, index) in new[] { 1.3, 1.25, 1.35, 1.28, 1.32 }.Select((ratio, index) => (ratio, index)))
            voice = voice.Recording("eleven_v4", "take" + index, ratio * 2, 2);
        var fresh = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/music/music-project.voxclip"));
        fresh = fresh with { VoiceLab = fresh.VoiceLab with { SpeakingRateSamples = null } };
        var samples = VoiceLabRateCalibration.Samples(fresh, "eleven_v4", voice);
        Assert.True(Math.Abs(VoiceLabWordingFit.Multiplier(samples) - 1.3) < 1e-12);
        Assert.Equal(1, VoiceLabWordingFit.Multiplier(VoiceLabRateCalibration.Samples(fresh, "eleven_v4", null)));
        Assert.Equal(1, VoiceLabWordingFit.Multiplier(VoiceLabRateCalibration.Samples(fresh, "eleven_v3", voice)));
        // Samples under the bare model ID are the 1.8 prior's and are not read; the current prior's key is.
        var old = fresh with { VoiceLab = fresh.VoiceLab with { SpeakingRateSamples = new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>
            { ["eleven_v4"] = Samples([2.59, 1.75, 2.17, 2.38, 1.69], "old") } } };
        Assert.True(Math.Abs(VoiceLabWordingFit.Multiplier(VoiceLabRateCalibration.Samples(old, "eleven_v4", voice)) - 1.3) < 1e-12);
        Assert.Equal("eleven_v4@prior2", VoiceLabRateCalibration.ProjectKey("eleven_v4"));
        old = old with { VoiceLab = old.VoiceLab with { SpeakingRateSamples = new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>(old.VoiceLab.SpeakingRateSamples!)
            { [VoiceLabRateCalibration.ProjectKey("eleven_v4")] = Samples([1.0, 1.02, 0.98, 1.01], "new") } } };
        // The key survives a save and an open.
        var reopened = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(old));
        Assert.Equal(4, reopened.VoiceLab.SpeakingRateSamples![VoiceLabRateCalibration.ProjectKey("eleven_v4")].Count);
        // Four consistent takes of this project outweigh the voice: its entries are trimmed as outliers.
        Assert.True(Math.Abs(VoiceLabWordingFit.Multiplier(VoiceLabRateCalibration.Samples(old, "eleven_v4", voice)) - 1.005) < 1e-12);
        // The estimate the plan shows: the median, times the calibration.
        const double rate = 11.5;
        const string text = "Then we ride on the coast";
        var window = new VoiceLabWindow("w0", "w0", [], [], 10, 14, 480_000, 672_000,
            new(VoiceLabSeamKind.Hard, 10, 480_000, 240), new(VoiceLabSeamKind.Hard, 14, 672_000, 240));
        var timing = VoiceLabPaceMatching.Measure(text, rate, window, null, null, 48_000, false, supportsPace: false,
            rateMultiplier: VoiceLabWordingFit.Multiplier(samples));
        Assert.True(Math.Abs(timing.EstimateSeconds - VoiceLabRewriteFit.Estimate(text, rate) * 1.3) < 1e-9);
        var spread = VoiceLabRateCalibration.Spread(fresh, "eleven_v4", voice);
        Assert.InRange(spread, VoiceLabRateCalibration.MinimumSpread, VoiceLabRateCalibration.MaximumSpread);
    }
}
