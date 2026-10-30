using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class SpeakerAudioTests
{
    [Fact]
    public void EightSharedSpeakerWavsAndAllRecordedCosinePairsReplayWithoutModels()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/voice-lab/speaker/vectors.json");
        var root = fixture.RootElement;
        var vectors = new Dictionary<string, float[]>();
        foreach (var clip in root.GetProperty("clips").EnumerateArray())
        {
            var id = clip.GetProperty("id").GetString()!;
            var wav = File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, "fixtures/voice-lab/speaker/" + id + ".wav"));
            Assert.Equal(clip.GetProperty("sha256").GetString(), VoiceConsentStore.Hash(wav));
            Assert.Equal(clip.GetProperty("sampleRate").GetInt32(), VoiceConsentAudio.ValidateWav(wav).Rate);
            Assert.Equal(96000, VoiceConsentAudio.Pcm16k(wav).Length);
            vectors.Add(id, clip.GetProperty("embedding").EnumerateArray().Select(value => value.GetSingle()).ToArray());
        }
        Assert.Equal(8, vectors.Count);
        foreach (var score in root.GetProperty("scores").EnumerateArray())
            Assert.InRange(Math.Abs(SpeakerAudio.Cosine(vectors[score[0].GetString()!], vectors[score[1].GetString()!]) - score[2].GetDouble()),
                0, root.GetProperty("scoreAbsoluteTolerance").GetDouble());
    }
    [Theory]
    [InlineData(44100, 48000)]
    [InlineData(48000, 16000)]
    public void TargetRateResamplerPreservesSignalAndSixteenKhzContract(int rate, int target)
    {
        var pcm = Enumerable.Range(0, rate).Select(index => (float)(0.2 * Math.Sin(2 * Math.PI * 440 * index / rate))).ToArray();
        var actual = VoiceConsentAudio.Resample(pcm.AsSpan(), rate, target);
        Assert.Equal(target, actual.Length);
        for (var index = 100; index < actual.Length - 100; index++)
            Assert.InRange(Math.Abs(actual[index] - 0.2 * Math.Sin(2 * Math.PI * 440 * index / target)), 0, 0.00001);
        if (target == 16000) Assert.Equal(VoiceConsentAudio.Resample(pcm, rate), actual);
    }
    [Fact]
    public void NinetySecond192KhzCaptureUsesInt64IndexMath()
    {
        var pcm = new float[192000 * 90];
        pcm[192000 * 89] = 1;
        var actual = VoiceConsentAudio.Resample(pcm.AsSpan(), 192000, 48000);
        Assert.Equal(48000 * 90, actual.Length);
        Assert.InRange(actual[48000 * 89], 0.23f, 0.24f);
        Assert.All(actual.Take(48000), sample => Assert.Equal(0, sample));
    }
    [Fact]
    public void WindowsNormalizationCosineAndOrderedRangesMatchReference()
    {
        Assert.Equal(2, SpeakerAudio.Windows(new float[72000]).Count());
        Assert.Single(SpeakerAudio.Windows(new float[71999]));
        Assert.Throws<VoiceConsentException>(() => SpeakerAudio.Windows(new float[47999]).ToArray());
        Assert.Equal(new[] { 1f, 2f, 4f, 5f }, SpeakerAudio.Select([0, 1, 2, 3, 4, 5], [(1, 3), (4, 6)]));
        Assert.Throws<VoiceConsentException>(() => SpeakerAudio.Select([0, 1, 2, 3], [(2, 3), (1, 2)]));
        Assert.Equal(1, SpeakerAudio.Cosine([3, 4], [6, 8]), 6);
        Assert.Equal(0, SpeakerAudio.Cosine([1, 0], [0, 1]), 6);
        Assert.Throws<VoiceConsentException>(() => SpeakerAudio.Normalized([0, 0]));
        Assert.Throws<VoiceConsentException>(() => SpeakerAudio.Cosine([float.NaN], [1]));
        Assert.Throws<VoiceConsentException>(() => SpeakerAudio.Cosine([1], [1, 2]));
    }
    [Fact]
    public void FeaturesReplayIndependentNumpyVectorAndZeroMean()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/voice-lab/speaker/features.json");
        var pcm = Enumerable.Range(0, 48000).Select(index => (float)(Math.Sin(index * 0.071) * 0.2)).ToArray();
        var actual = SpeakerAudio.Features(pcm);
        Assert.Equal(298 * 80, actual.Length);
        var first = fixture.RootElement.GetProperty("first").EnumerateArray().Select(item => item.GetSingle()).ToArray();
        var last = fixture.RootElement.GetProperty("last").EnumerateArray().Select(item => item.GetSingle()).ToArray();
        for (var band = 0; band < 80; band++)
        {
            Assert.InRange(Math.Abs(actual[band] - first[band]), 0, 0.0002);
            Assert.InRange(Math.Abs(actual[297 * 80 + band] - last[band]), 0, 0.0002);
            Assert.InRange(Math.Abs(Enumerable.Range(0, 298).Sum(frame => (double)actual[frame * 80 + band]) / 298), 0, 0.00001);
        }
    }
    [Fact]
    public void BlackmanResamplerRejectsAliasingAndPreservesPhaseAndLength()
    {
        foreach (var rate in new[] { 44100, 48000 })
        {
            var pcm = Enumerable.Range(0, rate).Select(index => (float)Math.Sin(2 * Math.PI * 12000 * index / rate)).ToArray();
            var converted = VoiceConsentAudio.Resample(pcm, rate);
            Assert.Equal(16000, converted.Length);
            var rms = Math.Sqrt(converted.Skip(100).SkipLast(100).Average(value => (double)value * value));
            Assert.True(rms < 0.0001, "12 kHz must not alias into speech features.");
            var impulse = new float[rate];
            impulse[rate / 2] = 1;
            var downsampled = VoiceConsentAudio.Resample(impulse, rate);
            Assert.Equal(8000, Array.IndexOf(downsampled, downsampled.Max()));
        }
        Assert.Equal(new[] { 1f, 2f }, VoiceConsentAudio.Resample([1, 2], 16000));
    }
    [Fact]
    public void CatalogRequiresExactFilesAndEnglishCalibration()
    {
        var catalog = new SpeakerModelCatalog(FixtureLoader.SharedRoot);
        Assert.Equal(256, catalog.Entry.Dimension);
        Assert.Equal(SpeakerAudio.Version, catalog.Entry.Preprocessing);
        Assert.Equal(0.45, catalog.Entry.CalibratedThreshold());
        Assert.Null(catalog.Entry.CalibratedThreshold("et"));
        Assert.Throws<VoiceConsentException>(() => catalog.Entry.VerifiedFiles(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"))));
    }
    [Theory]
    [InlineData("missing-margin")]
    [InlineData("small-margin")]
    [InlineData("threshold")]
    [InlineData("policy")]
    [InlineData("percentile")]
    [InlineData("percentile-method")]
    [InlineData("percentile-score")]
    [InlineData("rounding")]
    [InlineData("drift")]
    [InlineData("outcome")]
    [InlineData("speaker-count")]
    [InlineData("pooled-far")]
    [InlineData("condition-far")]
    [InlineData("condition-own")]
    [InlineData("sample-rate")]
    public void UnsafeCalibrationEvidenceNeverProducesThreshold(string mutation)
    {
        var root = JsonNode.Parse(FixtureLoader.ReadText("catalog/voice-lab-models.json"))!["models"]![0]!;
        var calibration = root["calibration"]!;
        var margin = calibration["margin"]!;
        var language = calibration["languages"]![0]!;
        var conditions = language["conditions"]!.AsArray();
        switch (mutation)
        {
            case "missing-margin": calibration.AsObject().Remove("margin"); break;
            case "small-margin": margin["absoluteFloor"] = 0.0000001; break;
            case "threshold": root["threshold"] = 0.44; margin["candidateThreshold"] = 0.44; break;
            case "policy": margin["policy"] = "clean-max-plus-margin-production-v1"; break;
            case "percentile": margin["percentileProbability"] = 0.99; break;
            case "percentile-method": margin["percentileMethod"] = "nearest-rank"; break;
            case "percentile-score": margin["percentileCalibrationImpostorScore"] = 1; break;
            case "rounding": margin["roundingIncrement"] = 0.001; break;
            case "drift": margin["crossRuntimeDrift"] = 0.02; break;
            case "outcome": calibration["outcome"] = "withheld"; break;
            case "speaker-count": language["calibrationSpeakers"] = 79; break;
            case "pooled-far": language["falseAcceptRate"] = 0.006; break;
            case "condition-far": conditions[0]!["falseAcceptRate"] = 0.006; break;
            case "condition-own": conditions[0]!["sameSpeakerPassRate"] = 0.94; break;
            default: foreach (var condition in conditions) condition!["sampleRate"] = 48000; break;
        }
        using var json = JsonDocument.Parse(root.ToJsonString());
        Assert.Null(new SpeakerModel(json.RootElement).CalibratedThreshold());
    }
    [Theory]
    [InlineData(0.438, 0.002, 0.44)]
    [InlineData(0.4380000001, 0.002, 0.45)]
    [InlineData(0.8, 0.02, 0.82)]
    public void CalibrationUsesDecimalCeiling(double percentile, double drift, double threshold)
    {
        var root = JsonNode.Parse(FixtureLoader.ReadText("catalog/voice-lab-models.json"))!["models"]![0]!;
        var margin = root["calibration"]!["margin"]!;
        root["threshold"] = threshold;
        margin["candidateThreshold"] = threshold;
        margin["percentileCalibrationImpostorScore"] = percentile;
        margin["maximumCalibrationImpostorScore"] = Math.Max(percentile, 0.55);
        margin["crossRuntimeDrift"] = drift;
        using var json = JsonDocument.Parse(root.ToJsonString());
        Assert.Equal(threshold, new SpeakerModel(json.RootElement).CalibratedThreshold());
    }
}
