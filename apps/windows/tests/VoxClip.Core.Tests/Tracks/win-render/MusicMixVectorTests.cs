using System.Text.Json;
using VoxClip.Core.Domain.Music;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>The music bed's arithmetic (doc/spec/music.md §4) replayed from shared/fixtures/music/music-mix-cases.json, the port of
/// Mac Core MusicMix.swift that tools/fixtures/music/generate_music_mix.py writes. Media MusicBedTests replays its whole beds.</summary>
public sealed class MusicMixVectorTests
{
    private static JsonElement Cases() => FixtureLoader.ReadJson("fixtures/music/music-mix-cases.json").RootElement.Clone();
    private static double[] Doubles(JsonElement array) => array.EnumerateArray().Select(value => value.GetDouble()).ToArray();
    private static double? Optional(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetDouble();
    private static void Near(double expected, double actual, string where) => Assert.True(Math.Abs(expected - actual) < 1e-9, $"{where}: {expected} vs {actual}");

    [Fact]
    public void TheFileHasItsKeysCountAndTheMacsConstants()
    {
        var cases = Cases();
        Assert.Equal(["format", "description", "constants", "levels", "activity", "bedGain", "musicLevel", "fades", "loops", "beds", "caseCount"],
            cases.EnumerateObject().Select(property => property.Name));
        Assert.Equal("voxclip-music-mix-cases/1", cases.GetProperty("format").GetString());
        Assert.Equal(35, cases.GetProperty("caseCount").GetInt32());
        var constants = cases.GetProperty("constants");
        Assert.Equal((MusicMix.FrameSeconds, MusicMix.DuckDb, MusicMix.AttackSeconds, MusicMix.ReleaseSeconds, MusicMix.LoopCrossfadeSeconds),
            (constants.GetProperty("frameSeconds").GetDouble(), constants.GetProperty("duckDb").GetDouble(), constants.GetProperty("attackSeconds").GetDouble(),
             constants.GetProperty("releaseSeconds").GetDouble(), constants.GetProperty("loopCrossfadeSeconds").GetDouble()));
        Assert.Equal((MusicMix.FallbackSpeechDb, MusicMix.SilenceFloorDb, MusicMix.MaximumBoostDb, MusicMix.MinimumBedDb, MusicMix.BridgeGapSeconds, MusicMix.MinimumSpeechSeconds),
            (constants.GetProperty("fallbackSpeechDb").GetDouble(), constants.GetProperty("silenceFloorDb").GetDouble(), constants.GetProperty("maximumBoostDb").GetDouble(),
             constants.GetProperty("minimumBedDb").GetDouble(), constants.GetProperty("bridgeGapSeconds").GetDouble(), constants.GetProperty("minimumSpeechSeconds").GetDouble()));
    }

    [Fact]
    public void LevelsActivityDuckingAndGainsReplay()
    {
        var cases = Cases();
        foreach (var item in cases.GetProperty("levels").EnumerateArray())
        {
            var mono = Doubles(item.GetProperty("mono")).Select(value => (float)value).ToArray();
            var levels = MusicMix.FrameLevels(mono, item.GetProperty("sampleRate").GetDouble());
            var expected = Doubles(item.GetProperty("levels"));
            Assert.Equal(expected.Length, levels.Length);
            for (var index = 0; index < levels.Length; index++) Assert.True(Math.Abs(expected[index] - levels[index]) < 1e-5, $"level {index}");
        }
        foreach (var item in cases.GetProperty("activity").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            var levels = Doubles(item.GetProperty("levels"));
            var activity = MusicMix.SpeechActivity(levels);
            Assert.Equal(item.GetProperty("activity").EnumerateArray().Select(value => value.GetBoolean()), activity);
            var speech = MusicMix.SpeechLevelDb(levels, activity);
            if (Optional(item.GetProperty("speechDb")) is { } expectedSpeech) Near(expectedSpeech, speech!.Value, id);
            else Assert.Null(speech);
            var gains = MusicMix.DuckingGainsDb(activity);
            var expected = Doubles(item.GetProperty("duckingDb"));
            for (var index = 0; index < gains.Length; index++) Near(expected[index], gains[index], $"{id} ducking {index}");
            Assert.All(MusicMix.DuckingGainsDb(activity, ducking: false), gain => Assert.Equal(0, gain));
            foreach (var factor in item.GetProperty("duckFactors").EnumerateArray())
                Near(factor.GetProperty("factor").GetDouble(), MusicMix.DuckFactor(gains, factor.GetProperty("seconds").GetDouble()), $"{id} factor");
        }
        foreach (var item in cases.GetProperty("bedGain").EnumerateArray())
            Near(item.GetProperty("bedGainDb").GetDouble(),
                MusicMix.BedGainDb(Optional(item.GetProperty("speechDb")), Optional(item.GetProperty("musicDb")), item.GetProperty("gainDb").GetDouble()), "bed gain");
        foreach (var item in cases.GetProperty("musicLevel").EnumerateArray())
        {
            var level = MusicMix.MusicLevelDb(Doubles(item.GetProperty("levels")));
            if (Optional(item.GetProperty("musicDb")) is { } expected) Near(expected, level!.Value, "music level");
            else Assert.Null(level);
        }
        foreach (var item in cases.GetProperty("fades").EnumerateArray())
            Near(item.GetProperty("factor").GetDouble(), MusicMix.FadeFactor(item.GetProperty("seconds").GetDouble(), item.GetProperty("duration").GetDouble(),
                item.GetProperty("fadeIn").GetDouble(), item.GetProperty("fadeOut").GetDouble()), "fade");
    }

    [Fact]
    public void TrimsLoopsAndCrossfadeWeightsReplay()
    {
        foreach (var item in Cases().GetProperty("loops").EnumerateArray())
        {
            var pieces = MusicMix.LoopPieces(item.GetProperty("trackFrames").GetInt64(), item.GetProperty("offsetFrames").GetInt64(),
                item.GetProperty("outputFrames").GetInt64(), item.GetProperty("crossfadeFrames").GetInt64());
            var expected = item.GetProperty("pieces").EnumerateArray().Select(piece => new MusicMix.LoopPiece(piece.GetProperty("sourceStart").GetInt64(),
                piece.GetProperty("outputStart").GetInt64(), piece.GetProperty("count").GetInt64(), piece.GetProperty("fadeIn").GetInt64(),
                piece.GetProperty("fadeOut").GetInt64())).ToArray();
            Assert.Equal(expected, pieces);
            var at = item.GetProperty("weightAt").EnumerateArray().ToArray();
            var weights = item.GetProperty("weights").EnumerateArray().ToArray();
            for (var piece = 0; piece < pieces.Count; piece++)
            {
                var indices = at[piece].EnumerateArray().Select(value => value.GetInt64()).ToArray();
                var values = Doubles(weights[piece]);
                for (var index = 0; index < indices.Length; index++) Near(values[index], MusicMix.PieceWeight(pieces[piece], indices[index]), $"weight {piece}/{indices[index]}");
            }
        }
    }
}
