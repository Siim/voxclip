using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Replays shared/fixtures/voice-lab/tilt-cases.json (voice-lab.md §8.7 item 2b; Mac <c>VoiceLabTiltReplayTests</c>): the tone match's
/// band measurement, slope, clamped stepped tilt, and its shelf cascade's coefficients, magnitude and outputs, within the file's
/// tolerances. Fails on an unknown kind.</summary>
public sealed class VoiceLabTiltReplayTests
{
    /// <summary>The generator's signals: integer LCG noise, exact in Float32 (tilt-README.md "Signals").</summary>
    internal static float[] Render(JsonElement signal)
    {
        var state = signal.GetProperty("seed").GetUInt32();
        var samples = signal.GetProperty("samples").GetInt32();
        var scale = Math.Pow(2.0, -(signal.TryGetProperty("shift", out var shift) ? shift.GetInt32() : 0));
        var basis = new double[samples + 3];
        for (var index = 0; index < basis.Length; index++)
        {
            state = unchecked(state * 1_664_525u + 1_013_904_223u);
            basis[index] = ((state >> 16) / 32_768.0 - 1) * scale;
        }
        var values = new double[samples];
        var shape = signal.GetProperty("shape").GetString();
        for (var index = 0; index < samples; index++)
            values[index] = shape switch
            {
                "white" => basis[index + 3],
                "bright" => (basis[index + 3] - basis[index + 2]) / 2,
                "warm" => (basis[index + 3] + basis[index + 2] / 2) / 2,
                "dark" => (basis[index] + basis[index + 1] + basis[index + 2] + basis[index + 3]) / 4,
                _ => throw new InvalidDataException("unknown shape " + shape)
            };
        if (signal.TryGetProperty("quiet", out var quiet))
            foreach (var range in quiet.EnumerateArray())
                for (var index = range[0].GetInt32(); index < range[1].GetInt32(); index++) values[index] *= Math.Pow(2.0, -12);
        return values.Select(value => (float)value).ToArray();
    }

    private static bool Close(double? actual, double? expected, double tolerance) =>
        actual is null ? expected is null : expected is { } value && Math.Abs(actual.Value - value) <= tolerance;
    private static double? Number(JsonElement element) => element.ValueKind == JsonValueKind.Null ? null : element.GetDouble();
    private static IEnumerable<double?> Levels(VoiceLabTilt.Bands bands) => Enumerable.Range(0, VoiceLabTilt.BandIndices.Count).Select(band => VoiceLabTilt.Level(bands, band));

    [Fact]
    public void ReplaysEveryToneMatchVector()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/tilt-cases.json");
        var root = document.RootElement;
        Assert.Equal("voxclip-voice-lab-tilt/1", root.GetProperty("schema").GetString());
        var cases = root.GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(root.GetProperty("caseCount").GetInt32(), cases.Length);
        var constants = root.GetProperty("constants");
        Assert.Equal(VoiceLabTilt.MaximumDbPerOctave, constants.GetProperty("maximumDbPerOctave").GetDouble());
        Assert.Equal(VoiceLabTilt.StepDbPerOctave, constants.GetProperty("stepDbPerOctave").GetDouble());
        Assert.Equal(VoiceLabTilt.PivotHz, constants.GetProperty("pivotHz").GetDouble());
        Assert.Equal(VoiceLabTilt.ShelfHz, constants.GetProperty("shelfHz").EnumerateArray().Select(value => value.GetDouble()));
        Assert.Equal(VoiceLabTilt.BandIndices, constants.GetProperty("bandIndices").EnumerateArray().Select(value => value.GetInt32()));
        Assert.True(Math.Abs(Math.Pow(10, constants.GetProperty("voicedRmsDb").GetDouble() / 20) - VoiceLabTilt.VoicedRms) < 1e-15);
        Assert.Equal(VoiceLabTilt.MinimumBands, constants.GetProperty("minimumBands").GetInt32());
        Assert.Equal(3.0, constants.GetProperty("neighbourhoodSeconds").GetDouble());
        var tolerances = root.GetProperty("tolerances");
        double coefficient = tolerances.GetProperty("coefficient").GetDouble(), magnitudeDb = tolerances.GetProperty("magnitudeDb").GetDouble(),
            output = tolerances.GetProperty("output").GetDouble(), levelDb = tolerances.GetProperty("levelDb").GetDouble(),
            slope = tolerances.GetProperty("slope").GetDouble();
        Dictionary<string, VoiceLabTilt.Bands> measured = [];
        HashSet<string> kinds = [];
        foreach (var item in cases)
        {
            var kind = item.GetProperty("kind").GetString()!;
            var name = item.GetProperty("name").GetString()!;
            var expected = item.GetProperty("expected");
            kinds.Add(kind);
            switch (kind)
            {
                case "frameSize":
                {
                    var rate = item.GetProperty("sampleRate").GetInt32();
                    var size = VoiceLabTilt.FrameSize(rate);
                    Assert.True(expected.GetProperty("frameSize").GetInt32() == size, name);
                    var bins = VoiceLabTilt.BandIndices.Select(band => VoiceLabTilt.Bins(band, rate, size))
                        .Select(range => range.End > range.First ? $"{range.First}-{range.End}" : "null");
                    var pinned = expected.GetProperty("bins").EnumerateArray()
                        .Select(range => range.ValueKind == JsonValueKind.Null ? "null" : $"{range[0].GetInt32()}-{range[1].GetInt32()}");
                    Assert.True(pinned.SequenceEqual(bins), name);
                    break;
                }
                case "sections":
                {
                    var rate = item.GetProperty("sampleRate").GetInt32();
                    var sections = VoiceLabTilt.Sections(item.GetProperty("tiltDbPerOctave").GetDouble(), rate);
                    var pinned = expected.GetProperty("sections").EnumerateArray().ToArray();
                    Assert.True(pinned.Length == sections.Count, name);
                    for (var index = 0; index < pinned.Length; index++)
                        Assert.True(Close(sections[index].B0, pinned[index][0].GetDouble(), coefficient) && Close(sections[index].B1, pinned[index][1].GetDouble(), coefficient) &&
                            Close(sections[index].A1, pinned[index][2].GetDouble(), coefficient), $"{name} section {index}");
                    foreach (var pair in expected.GetProperty("magnitudeDb").EnumerateArray())
                        Assert.True(Close(20 * Math.Log10(VoiceLabTilt.Magnitude(sections, pair[0].GetDouble(), rate)), pair[1].GetDouble(), magnitudeDb),
                            $"{name} at {pair[0].GetDouble()} Hz");
                    break;
                }
                case "filter":
                {
                    var rate = item.GetProperty("sampleRate").GetInt32();
                    var input = item.GetProperty("input");
                    var samples = input.TryGetProperty("impulse", out var impulse)
                        ? Enumerable.Range(0, impulse.GetInt32()).Select(index => index == 0 ? 1f : 0f).ToArray()
                        : Render(input.GetProperty("signal"));
                    var sections = VoiceLabTilt.Sections(item.GetProperty("tiltDbPerOctave").GetDouble(), rate);
                    var filter = new VoiceLabTilt.Filter(sections);
                    var actual = samples.Select(sample => filter.Step(sample)).ToArray();
                    var pinned = expected.GetProperty("output").EnumerateArray().Select(value => value.GetDouble()).ToArray();
                    Assert.True(actual.Length == pinned.Length && actual.Zip(pinned).All(pair => Close(pair.First, pair.Second, output)), name);
                    // The binary32 path rounds the same values once.
                    Assert.Equal(actual.Select(value => (float)value), VoiceLabTilt.Apply(samples, sections));
                    break;
                }
                case "bands":
                {
                    var rate = item.GetProperty("sampleRate").GetInt32();
                    var bands = VoiceLabTilt.Measure([Render(item.GetProperty("input").GetProperty("signal"))], rate);
                    measured[name] = bands;
                    Assert.True(expected.GetProperty("frames").GetInt32() == bands.Frames, name);
                    Assert.True(Levels(bands).Zip(expected.GetProperty("levelsDb").EnumerateArray().Select(Number)).All(pair => Close(pair.First, pair.Second, levelDb)), name);
                    Assert.True(Close(VoiceLabTilt.Slope(bands, bands), Number(expected.GetProperty("slopeDbPerOctave")), slope), name);
                    break;
                }
                case "match":
                {
                    var source = measured[item.GetProperty("source").GetString()!];
                    var take = measured[item.GetProperty("take").GetString()!];
                    Assert.True(Number(expected.GetProperty("tiltDbPerOctave")) == VoiceLabTilt.Match(source, take), name);
                    Assert.True(Close(VoiceLabTilt.Slope(source, take), Number(expected.GetProperty("sourceSlope")), slope), name);
                    Assert.True(Close(VoiceLabTilt.Slope(take, source), Number(expected.GetProperty("takeSlope")), slope), name);
                    break;
                }
                case "neighbourhood":
                {
                    var rate = item.GetProperty("sampleRate").GetInt32();
                    var input = item.GetProperty("input");
                    var window = input.GetProperty("window");
                    var bands = VoiceLabTilt.NeighbourhoodBands(VoiceLabSourceExcerpt.Whole(Render(input.GetProperty("signal"))), rate,
                        window[0].GetInt64(), window[1].GetInt64());
                    Assert.NotNull(bands);
                    Assert.True(expected.GetProperty("frames").GetInt32() == bands.Frames, name);
                    Assert.True(Levels(bands).Zip(expected.GetProperty("levelsDb").EnumerateArray().Select(Number)).All(pair => Close(pair.First, pair.Second, levelDb)), name);
                    break;
                }
                default:
                    Assert.Fail($"unknown kind {kind} in {name}");
                    break;
            }
        }
        Assert.Equal(["bands", "filter", "frameSize", "match", "neighbourhood", "sections"], kinds.Order(StringComparer.Ordinal));
    }

    [Fact]
    public void TheTiltIsGentleClampedAndPivotsAtOneKilohertz()
    {
        // ±2 dB/octave is the most either way; a larger request is clamped, not refused.
        Assert.Equal(VoiceLabTilt.Sections(2, 24_000), VoiceLabTilt.Sections(5, 24_000));
        Assert.Empty(VoiceLabTilt.Sections(0, 24_000));
        Assert.Empty(VoiceLabTilt.Sections(double.NaN, 24_000));
        foreach (var tilt in new[] { -2.0, -0.5, 0.5, 2.0 })
        {
            var sections = VoiceLabTilt.Sections(tilt, 24_000);
            Assert.True(Math.Abs(20 * Math.Log10(VoiceLabTilt.Magnitude(sections, 1_000, 24_000))) < 1e-9);
            // About the tilt per octave across the speech band: within half of it from 250 Hz to 4 kHz (four octaves).
            var low = 20 * Math.Log10(VoiceLabTilt.Magnitude(sections, 250, 24_000));
            var high = 20 * Math.Log10(VoiceLabTilt.Magnitude(sections, 4_000, 24_000));
            var perOctave = (high - low) / 4;
            Assert.True(perOctave * tilt > 0 && Math.Abs(perOctave - tilt) <= Math.Abs(tilt) / 2, $"tilt {tilt}: {perOctave} dB/octave");
        }
        // Takes already like the speech beside them are left alone.
        using var signal = JsonDocument.Parse("""{"seed":1,"samples":24000,"shape":"white","shift":2}""");
        var bands = VoiceLabTilt.Measure([Render(signal.RootElement)], 48_000);
        Assert.Null(VoiceLabTilt.Match(bands, bands));
    }
}
