using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>A take run reads only regions of a long source (voice-lab.md §8.7); the preflight must read the same level and room
/// tone from them as from the whole track (Mac VoiceLabSourceExcerptTests).</summary>
public sealed class VoiceLabSourceExcerptTests
{
    private const int Rate = 8_000;
    /// <summary>30 s of tone with a quiet stretch at 24.9–26 s; the words leave a gap only at 25.0–25.8 s.</summary>
    private static float[] Source() => Enumerable.Range(0, 30 * Rate).Select(index =>
    {
        var seconds = index / (double)Rate;
        return seconds is >= 24.9 and < 26 ? 0.001f : (float)(0.1 * Math.Sin(2 * Math.PI * 100 * seconds));
    }).ToArray();
    private static TimedWord Word(string id, double start, double end) => new(id, id, WordKind.Word, start, end, null, null, 1, null, TimingSource.Native);
    private static VoiceLabTakeInput Input(VoiceLabSourceExcerpt source, AudioEnvelope envelope)
    {
        TimedWord[] items = [Word("before", 0, 12), Word("old", 12, 13), Word("after", 13, 25), Word("last", 25.8, 30)];
        var window = new VoiceLabWindow("old", "old", [], [], 12, 13, 96_000, 104_000,
            new(VoiceLabSeamKind.Hard, 12, 96_000, 96), new(VoiceLabSeamKind.Hard, 13, 104_000, 96));
        return new("Hello", "eleven_v3", "record", "en", 1, "synthetic-source", source, envelope, Rate, items, new HashSet<string>(),
            window, null, null, false, true);
    }
    private static VoiceLabSourceExcerpt.Region Region(float[] whole, int start, int end) => new(start, whole.AsSpan(start, end - start));

    [Fact]
    public void PreflightReadsTheSameLevelAndRoomToneFromRegions()
    {
        var whole = Source();
        var envelope = VoiceLabTakeProcessing.Envelope(whole, Rate);
        var expected = VoiceLabTakeProcessing.Preflight(Input(VoiceLabSourceExcerpt.Whole(whole), envelope));
        var regions = new VoiceLabSourceExcerpt(whole.Length, [Region(whole, 8 * Rate, 17 * Rate), Region(whole, 24 * Rate, 27 * Rate)]);
        var actual = VoiceLabTakeProcessing.Preflight(Input(regions, envelope));
        Assert.Equal(expected.SourceLevel, actual.SourceLevel);
        Assert.Equal(expected.RoomTone, actual.RoomTone);
        Assert.Equal(200_000, actual.RoomTone!.SourceStartSample);
        // The whole-array input still builds its envelope from the samples, as short sources and tests pass them.
        var legacy = new VoiceLabTakeInput("Hello", "eleven_v3", "record", "en", 1, "synthetic-source", whole, Rate,
            Input(regions, envelope).Items, new HashSet<string>(), Input(regions, envelope).Window, null, null, false, true);
        Assert.Equal(envelope.Rms, legacy.SourceEnvelope.Rms);
        Assert.Equal(expected, VoiceLabTakeProcessing.Preflight(legacy));
    }

    [Fact]
    public void PreflightRefusesRegionsWithoutTheLoudnessNeighbourhood()
    {
        var whole = Source();
        var envelope = VoiceLabTakeProcessing.Envelope(whole, Rate);
        var narrow = new VoiceLabSourceExcerpt(whole.Length, [Region(whole, 11 * Rate, 14 * Rate)]);
        Assert.Equal(VoiceLabAudioMathErrorCode.InvalidInput,
            Assert.Throws<VoiceLabAudioMathException>(() => VoiceLabTakeProcessing.Preflight(Input(narrow, envelope))).Code);
        var nonfinite = whole.ToArray();
        nonfinite[29 * Rate] = float.NaN;
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() =>
            VoiceLabTakeProcessing.Preflight(Input(new VoiceLabSourceExcerpt(whole.Length, [Region(nonfinite, 8 * Rate, 30 * Rate)]), envelope))).Kind);
    }

    [Fact]
    public void NeighbourhoodLevelFromAnExcerptEqualsTheWholeArrayAtTheTrackEdges()
    {
        var whole = Enumerable.Range(0, 10 * Rate).Select(index => (float)((index * 7_919L % 4_001 - 2_000) / 8_000.0)).ToArray();
        foreach (var (start, end) in new[] { (0, Rate), (Rate, 2 * Rate), (4 * Rate, 4 * Rate + 7), (9 * Rate, 10 * Rate), (2 * Rate + 3, 9 * Rate - 5) })
        {
            var expected = VoiceLabLoudness.NeighbourhoodVoicedRmsDb(whole, Rate, start, end);
            var lower = Math.Max(0, start - 3 * Rate);
            var upper = Math.Min(whole.Length, end + 3 * Rate);
            var excerpt = new VoiceLabSourceExcerpt(whole.Length, [Region(whole, lower, upper)]);
            Assert.Equal(expected, VoiceLabLoudness.NeighbourhoodVoicedRmsDb(excerpt, Rate, start, end));
            if (lower > 0)
                Assert.Throws<VoiceLabAudioMathException>(() => VoiceLabLoudness.NeighbourhoodVoicedRmsDb(
                    new VoiceLabSourceExcerpt(whole.Length, [Region(whole, lower + 1, upper)]), Rate, start, end));
        }
        // A track shorter than the neighbourhood is read whole.
        var brief = whole[..(2 * Rate)];
        Assert.Equal(VoiceLabLoudness.NeighbourhoodVoicedRmsDb(brief, Rate, Rate / 2, Rate),
            VoiceLabLoudness.NeighbourhoodVoicedRmsDb(VoiceLabSourceExcerpt.Whole(brief), Rate, Rate / 2, Rate));
    }

    [Fact]
    public void SamplesAreReadAtAbsoluteFramesFromACopy()
    {
        float[] late = [6, 7, 8];
        var excerpt = new VoiceLabSourceExcerpt(100, [new VoiceLabSourceExcerpt.Region(60, late), new VoiceLabSourceExcerpt.Region(10, [1, 2, 3, 4])]);
        Assert.Equal(new long[] { 10, 60 }, excerpt.Regions.Select(region => region.Start));
        Assert.Equal(new float[] { 2, 3 }, excerpt.Samples(11, 13)!.Value.ToArray());
        Assert.Empty(excerpt.Samples(14, 14)!.Value.ToArray());
        Assert.Null(excerpt.Samples(12, 15));
        Assert.Null(excerpt.Samples(0, 1));
        Assert.Null(excerpt.Samples(62, 101));
        Assert.Null(excerpt.Samples(13, 12));
        Assert.Equal(new float[] { 1, 2 }, VoiceLabSourceExcerpt.Whole([1, 2]).Samples(0, 2)!.Value.ToArray());
        late[0] = 9;
        Assert.Equal(6f, excerpt.Samples(60, 61)!.Value.Span[0]);
        Assert.True(excerpt.IsFinite);
        Assert.False(new VoiceLabSourceExcerpt(3, [new VoiceLabSourceExcerpt.Region(0, [0, float.PositiveInfinity])]).IsFinite);
    }
}
