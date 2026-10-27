using System.Text.Json;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Measures the graph called by TempoTrack.Create; output timing is not inferred from PTS.</summary>
[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class VoiceLabNativeTempoTests(ITestOutputHelper output) : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync(windows: true);
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    [Theory]
    [InlineData(24_000, 1, 0.92, false)]
    [InlineData(24_000, 1, 1.08, false)]
    [InlineData(48_000, 2, 0.92, false)]
    [InlineData(48_000, 2, 1.08, false)]
    [InlineData(24_000, 2, 0.92, true)]
    [InlineData(24_000, 2, 1.08, true)]
    [InlineData(48_000, 1, 0.92, true)]
    [InlineData(48_000, 1, 1.08, true)]
    public async Task GraphReportsRealBodyAndTailMarkerPositionsAndCompositionRefusesUnprovenFit(
        int rate, int channels, double stretch, bool overdeclaredHandles)
    {
        NativeTest.RequireFilter("atempo");
        await ShippingRuntimeIdentityTests.MatchShippingReportWhenEvidencePresentAsync();
        var ct = TestContext.Current.CancellationToken;
        var folder = Directory.CreateTempSubdirectory("voxclip-tempo-native-").FullName;
        try
        {
            var source = Path.Combine(folder, "markers.wav");
            var stage = Path.Combine(folder, "fitted.f32");
            var total = (int)(rate * 0.30);
            var trimStart = (long)(rate * 0.05);
            var trimEnd = (long)(rate * 0.25);
            var firstMarker = (int)(rate * 0.085);
            var tailMarker = (int)(rate * 0.215);
            WriteWave(source, rate, channels, total, firstMarker, tailMarker);
            using var asset = new PreparedVoiceLabAsset("segment", "asset", source, folder, rate, channels, total,
                trimStart, trimEnd, stretch, 0);
            // Match Core's 20 ms seam policy: each outside half needs enough raw
            // frames after pitch-preserving stretch, rounded up on the asset grid.
            var fadeSamples = (long)Math.Round(0.020 * rate, MidpointRounding.AwayFromZero);
            var incomingOutside = fadeSamples / 2;
            var outgoingOutside = fadeSamples - incomingOutside;
            var minimumBefore = (long)Math.Ceiling(incomingOutside * (double)rate / (rate * stretch));
            var minimumAfter = (long)Math.Ceiling(outgoingOutside * (double)rate / (rate * stretch));
            var beforeHandle = overdeclaredHandles ? trimStart : minimumBefore;
            var afterHandle = overdeclaredHandles ? total - trimEnd : minimumAfter;
            Assert.True(beforeHandle >= minimumBefore && beforeHandle <= trimStart);
            Assert.True(afterHandle >= minimumAfter && afterHandle <= total - trimEnd);
            var inputStart = trimStart - beforeHandle;
            var inputEnd = trimEnd + afterHandle;
            var nominal = (long)Math.Round((inputEnd - inputStart) * stretch, MidpointRounding.AwayFromZero);
            var (frames, firstPts) = VoiceLabTempoTrack.Render(asset, inputStart, inputEnd, 1 / stretch,
                nominal, stage, ct);
            Assert.InRange(frames, nominal - 1024, nominal + 1024);
            Assert.Equal(frames * 2 * sizeof(float), new FileInfo(stage).Length);
            var markers = FindMarkers(stage, frames);
            Assert.True(markers.first >= 0 && markers.tail > markers.first,
                $"Missing marker in real atempo output: first={markers.first}, tail={markers.tail}");
            var pitchHz = MeasurePitchBetweenMarkers(stage, markers, rate);
            Assert.InRange(pitchHz, 410, 470);
            Assert.InRange(firstPts, 0, 4096);
            var bodyOriginAssumed = (long)Math.Round(beforeHandle * stretch, MidpointRounding.AwayFromZero) - firstPts;
            var observedFirstRelative = markers.first - bodyOriginAssumed;
            var expectedFirstRelative = (long)Math.Round((firstMarker - trimStart) * stretch,
                MidpointRounding.AwayFromZero);
            var evidence = new
            {
                rate, channels, stretch, overdeclaredHandles, minimumBefore, minimumAfter,
                beforeHandle, afterHandle, inputStart, inputEnd, frames, nominal,
                firstPts, markers.first, markers.tail, pitchHz, bodyOriginAssumed, observedFirstRelative,
                expectedFirstRelative, firstError = observedFirstRelative - expectedFirstRelative
            };
            var json = JsonSerializer.Serialize(evidence);
            output.WriteLine(json);
            if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } evidenceDir)
            {
                Directory.CreateDirectory(evidenceDir);
                File.WriteAllText(Path.Combine(evidenceDir,
                    $"tempo-{rate}-{channels}-{stretch:0.00}-{overdeclaredHandles}.json"), json);
            }
            var refusal = Assert.Throws<VoiceLabTempoException>(() => VoiceLabTempoTrack.Create(asset,
                (long)Math.Round((trimEnd - trimStart) * stretch, MidpointRounding.AwayFromZero), rate,
                beforeHandle, afterHandle, fadeSamples - incomingOutside,
                fadeSamples - outgoingOutside, ct));
            Assert.Contains("unverified body and seam timing", refusal.Message, StringComparison.Ordinal);
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }

    private static void WriteWave(string path, int rate, int channels, int frames, int first, int tail)
    {
        using var file = File.Create(path);
        using var writer = new BinaryWriter(file);
        writer.Write("RIFF"u8); writer.Write(36 + frames * channels * 2); writer.Write("WAVEfmt "u8);
        writer.Write(16); writer.Write((short)1); writer.Write((short)channels); writer.Write(rate);
        writer.Write(rate * channels * 2); writer.Write((short)(channels * 2)); writer.Write((short)16);
        writer.Write("data"u8); writer.Write(frames * channels * 2);
        for (var i = 0; i < frames; i++)
        {
            var marker = i >= first && i < first + rate / 200 || i >= tail && i < tail + rate / 200;
            var value = marker ? (short)30_000 : (short)Math.Round(1000 * Math.Sin(2 * Math.PI * 440 * i / rate));
            for (var channel = 0; channel < channels; channel++) writer.Write(value);
        }
    }

    private static (long first, long tail) FindMarkers(string path, long frames)
    {
        using var file = File.OpenRead(path);
        using var reader = new BinaryReader(file);
        long first = -1, tail = -1;
        for (long i = 0; i < frames; i++)
        {
            var left = reader.ReadSingle();
            var right = reader.ReadSingle();
            Assert.True(float.IsFinite(left) && float.IsFinite(right));
            if (Math.Max(Math.Abs(left), Math.Abs(right)) < 0.65f) continue;
            if (i < frames / 2 && first < 0) first = i;
            if (i >= frames / 2 && tail < 0) tail = i;
        }
        return (first, tail);
    }

    private static double MeasurePitchBetweenMarkers(string path, (long first, long tail) markers, int rate)
    {
        // Stay clear of both deliberately loud, non-tonal marker bursts.
        var start = markers.first + rate / 50;
        var end = markers.tail - rate / 50;
        Assert.True(end - start >= rate / 25, "The fitted body lacks a marker-free pitch window.");
        using var file = File.OpenRead(path);
        using var reader = new BinaryReader(file);
        file.Position = start * 2 * sizeof(float);
        var previous = reader.ReadSingle(); reader.ReadSingle();
        var crossings = 0;
        for (var frame = start + 1; frame < end; frame++)
        {
            var sample = reader.ReadSingle(); reader.ReadSingle();
            if (previous <= 0 && sample > 0) crossings++;
            previous = sample;
        }
        return crossings * (double)rate / (end - start);
    }
}
