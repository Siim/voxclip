using System.Text.Json;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Tests.Tracks.WinEditing;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>Replays shared/fixtures/clip-render/clip-grade-cases.json (looks spec 2026-11-28, sections 5, 6 and 11.1), as the
/// Swift ClipGradeRecipeTests do: bytes and integers exactly, floats within 1e-9, curve coefficients within 1e-12.</summary>
public sealed class ClipGradeVectorTests
{
    private const double Floats = 1e-9;
    private const double Coefficients = 1e-12;

    private static JsonElement Cases() => FixtureLoader.ReadJson("fixtures/clip-render/clip-grade-cases.json").RootElement.Clone();

    private static ProjectClipControls Controls(JsonElement value) =>
        JsonSerializer.Deserialize(value.GetRawText(), ProjectJsonContext.Default.ProjectClipControls)!;

    private static double[] Doubles(JsonElement value) => value.EnumerateArray().Select(item => item.GetDouble()).ToArray();
    private static int[] Ints(JsonElement value) => value.EnumerateArray().Select(item => item.GetInt32()).ToArray();
    private static double[] Unit(JsonElement value) => Ints(value).Select(item => item / 255.0).ToArray();
    private static int[] Bytes(IReadOnlyList<double> rgb) => rgb.Select(ClipGradeRecipe.Byte).ToArray();
    private static int Int(JsonElement item, string key) => item.GetProperty(key).GetInt32();

    private static bool Close(IReadOnlyList<double> found, IReadOnlyList<double> expected, double tolerance = Floats) =>
        found.Count == expected.Count && found.Zip(expected).All(pair => Math.Abs(pair.First - pair.Second) <= tolerance);

    private static ClipGradeRecipe Recipe(JsonElement item)
    {
        ClipLook? replacement = item.TryGetProperty("override", out var value) ? value.GetString() switch
        {
            "muted" => ClipLook.Muted, "warm" => ClipLook.Warm, "bw" => ClipLook.Bw, _ => ClipLook.Original
        } : null;
        return ClipGradeRecipe.For(Controls(item.GetProperty("controls")), replacement);
    }

    [Fact]
    public void TheFileHoldsEveryCategoryBothCoresReplay()
    {
        var cases = Cases();
        Assert.Equal("voxclip-clip-grade-cases/1", cases.GetProperty("format").GetString());
        Assert.Equal(["format", "looks", "tolerance", "swatches8", "primary", "controls", "curves", "vignette", "pcg", "frameHash", "frameIndex",
            "grain", "demo", "finish", "chains", "looksOnSwatches", "adjustments", "skinCheck", "measure"], cases.EnumerateObject().Select(property => property.Name));
        Assert.Equal(10, cases.GetProperty("swatches8").EnumerateObject().Count());
    }

    [Fact]
    public void TheFixIsAGainPerChannelWithAShoulder()
    {
        var cases = Cases().GetProperty("primary").EnumerateArray().ToArray();
        Assert.Equal(7, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var fix = item.GetProperty("fix");
            var primary = new ClipGradeRecipe.PrimaryGains(new(Int(fix, "exposure"), Int(fix, "temperature"), Int(fix, "tint")));
            Assert.True(Close(primary.Gains, Doubles(item.GetProperty("gains"))), id);
            var shoulders = item.GetProperty("shoulders").EnumerateArray().ToArray();
            for (var channel = 0; channel < 3; channel++)
            {
                if (shoulders[channel].ValueKind == JsonValueKind.Null) Assert.True(primary.Shoulders[channel] is null, id);
                else Assert.True(primary.Shoulders[channel] is { } shoulder && Close([shoulder.UMax, shoulder.Alpha], Doubles(shoulders[channel])), id);
            }
        }
    }

    [Fact]
    public void EachControlAloneAndTheWholeChainMatchTheReference()
    {
        var corpus = Cases();
        var cases = corpus.GetProperty("controls").EnumerateArray().Concat(corpus.GetProperty("chains").EnumerateArray()).ToArray();
        Assert.Equal(51, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var output = Recipe(item).Apply(Unit(item.GetProperty("input")));
            Assert.True(Close(output, Doubles(item.GetProperty("output"))), id + ": " + string.Join(", ", output));
            Assert.True(Ints(item.GetProperty("bytes")).SequenceEqual(Bytes(output)), id);
        }
    }

    [Fact]
    public void GoldenHourAtSixtyPercentMixesOverTheFix()
    {
        var item = Cases().GetProperty("chains").EnumerateArray().First(entry => entry.GetProperty("id").GetString() == "E8 Golden Hour 60% skin");
        var recipe = Recipe(item);
        double[] skin = [217 / 255.0, 158 / 255.0, 128 / 255.0];
        Assert.Equal([234, 158, 113], Bytes(recipe.Apply(skin)));
        Assert.True(Close(recipe.Fixed(skin), Doubles(item.GetProperty("stages").GetProperty("P"))));
    }

    [Fact]
    public void CurvesAreMonotoneCubicsThroughTheirKnots()
    {
        var cases = Cases().GetProperty("curves").EnumerateArray().ToArray();
        Assert.Equal(8, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var curve = new ClipGradeRecipe.Curve(Doubles(item.GetProperty("knots")));
            Assert.True(Close(curve.Tangents, Doubles(item.GetProperty("tangents")), Coefficients), id);
            Assert.True(Close(curve.Segments.SelectMany(segment => segment).ToArray(),
                item.GetProperty("segments").EnumerateArray().SelectMany(Doubles).ToArray(), Coefficients), id);
            foreach (var sample in item.GetProperty("samples").EnumerateArray())
            {
                var pair = Doubles(sample);
                Assert.True(Math.Abs(curve.Evaluate(pair[0]) - pair[1]) <= Coefficients, $"{id} at {pair[0]}");
            }
        }
        Assert.True(Close(ClipGradeRecipe.Curve.Tone(-60, 40).Knots, Doubles(cases[0].GetProperty("knots")), Coefficients));
        Assert.Equal(Doubles(cases[4].GetProperty("knots")), ClipGradeRecipe.Curve.FromThousandths(new(0, 245, 500, 760, 965)).Knots);
    }

    [Fact]
    public void TheVignetteWeightsAnOutputPixelByItsPlace()
    {
        var cases = Cases().GetProperty("vignette").EnumerateArray().ToArray();
        Assert.Equal(14, cases.Length);
        foreach (var item in cases)
        {
            var (q, s) = ClipGradeRecipe.VignetteWeight(Int(item, "x"), Int(item, "y"), Int(item, "width"), Int(item, "height"));
            Assert.True(Close([q, s], [item.GetProperty("q").GetDouble(), item.GetProperty("s").GetDouble()]), item.GetRawText());
        }
    }

    [Fact]
    public void GrainIsTheSameIntegerFieldOnEveryPlatform()
    {
        var corpus = Cases();
        foreach (var pair in corpus.GetProperty("pcg").EnumerateArray())
            Assert.Equal(pair[1].GetUInt32(), ClipGrain.Pcg(pair[0].GetUInt32()));
        foreach (var pair in corpus.GetProperty("frameHash").EnumerateArray())
            Assert.Equal(pair[1].GetUInt32(), ClipGrain.FrameHash(pair[0].GetUInt32()));
        foreach (var item in corpus.GetProperty("frameIndex").EnumerateArray())
            Assert.Equal(item.GetProperty("n").GetUInt32(), ClipGrain.FrameIndex(item.GetProperty("seconds").GetDouble(), item.GetProperty("fps").GetDouble()));
        var cases = corpus.GetProperty("grain").EnumerateArray().ToArray();
        Assert.Equal(13, cases.Length);
        foreach (var item in cases)
        {
            var (x, y, width, height) = (Int(item, "x"), Int(item, "y"), Int(item, "width"), Int(item, "height"));
            Assert.Equal(Int(item, "cellSize"), ClipGrain.CellSize(width, height));
            Assert.Equal(new ClipGrain.Cell(Int(item, "a"), Int(item, "b"), Int(item, "fx4"), Int(item, "fy4")), ClipGrain.CellAt(x, y, width, height));
            Assert.Equal(Int(item, "total"), ClipGrain.Total(x, y, width, height, ClipGrain.FrameHash(item.GetProperty("n").GetUInt32())));
        }
    }

    [Fact]
    public void GrainSkipsTheContextDemosRenderedRectangle()
    {
        var cases = Cases().GetProperty("demo").EnumerateArray().ToArray();
        Assert.Equal(4, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var motion = item.GetProperty("motion");
            var placement = item.GetProperty("placement");
            var hole = ClipGrain.DemoHole(Int(item, "width"), Int(item, "height"),
                new MotionCropTransform(motion.GetProperty("scale").GetDouble(), motion.GetProperty("anchorX").GetDouble(), motion.GetProperty("anchorY").GetDouble()),
                new ClipEffectRect(placement.GetProperty("x").GetDouble(), placement.GetProperty("y").GetDouble(), placement.GetProperty("width").GetDouble(),
                    placement.GetProperty("height").GetDouble()));
            Assert.True(Close([hole.MinX, hole.MinY, hole.MaxX, hole.MaxY], Doubles(item.GetProperty("rect"))), id);
            foreach (var probe in item.GetProperty("probes").EnumerateArray())
                Assert.True(hole.Contains(probe[0].GetInt32(), probe[1].GetInt32()) == probe[2].GetBoolean(), $"{id} {probe.GetRawText()}");
        }
    }

    [Fact]
    public void TheFinishDarkensCornersAndAddsGrainOnBytes()
    {
        var cases = Cases().GetProperty("finish").EnumerateArray().ToArray();
        Assert.Equal(20, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var recipe = new ClipGradeRecipe(ClipLook.Original, null,
                new ClipColorGrade { Amount = Int(item, "amount"), Vignette = Int(item, "vignette"), Grain = Int(item, "grain") });
            ClipGrain.Hole? hole = null;
            if (item.TryGetProperty("hole", out var rect))
            {
                var edges = Doubles(rect);
                hole = new(edges[0], edges[1], edges[2], edges[3]);
            }
            var output = recipe.Finish(Unit(item.GetProperty("input")), Int(item, "x"), Int(item, "y"), Int(item, "width"), Int(item, "height"),
                ClipGrain.FrameHash(item.GetProperty("n").GetUInt32()), hole);
            Assert.True(Close(output, Doubles(item.GetProperty("output"))), id + ": " + string.Join(", ", output));
            Assert.True(Ints(item.GetProperty("bytes")).SequenceEqual(Bytes(output)), id);
        }
    }

    [Fact]
    public void EveryLookRendersEverySwatchAtFullAndSeventyPercent()
    {
        var corpus = Cases();
        var swatches = corpus.GetProperty("swatches8");
        var looks = ClipLookLibraryTests.Library();
        Assert.Equal(2 * looks.Looks.Count, corpus.GetProperty("looksOnSwatches").GetArrayLength());
        var cases = corpus.GetProperty("looksOnSwatches").EnumerateArray().Concat(corpus.GetProperty("adjustments").EnumerateArray()).ToArray();
        Assert.Equal(56, cases.Length);
        foreach (var item in cases)
        {
            var id = (item.TryGetProperty("look", out var look) ? look.GetString() : item.GetProperty("id").GetString()) +
                (item.TryGetProperty("amount", out var amount) ? " " + amount.GetInt32() : "");
            var recipe = Recipe(item);
            foreach (var expected in item.GetProperty("bytes").EnumerateObject())
                Assert.True(Ints(expected.Value).SequenceEqual(Bytes(recipe.Apply(Unit(swatches.GetProperty(expected.Name))))), $"{id} on {expected.Name}");
        }
    }

    [Fact]
    public void TheSkinTableMatchesTheSpec()
    {
        var corpus = Cases();
        var swatches = corpus.GetProperty("swatches8");
        var cases = corpus.GetProperty("skinCheck").EnumerateArray().ToArray();
        Assert.Equal(16, cases.Length);
        foreach (var item in cases)
        {
            var recipe = Recipe(item);
            foreach (var (key, swatch) in new[] { ("mid", "skin"), ("deep", "deepSkin"), ("veryDeep", "veryDeepSkin") })
                Assert.True(Ints(item.GetProperty(key)).SequenceEqual(Bytes(recipe.Apply(Unit(swatches.GetProperty(swatch))))),
                    item.GetProperty("look").GetString() + " " + key);
        }
    }

    [Fact]
    public void AnUnchangedClipLeavesThePictureAlone()
    {
        var recipe = ClipGradeRecipe.For(new ProjectClipControls("clip", 1, null, ClipLook.Original, 0, 0, 0, false, false, 0));
        Assert.False(recipe.ChangesColor || recipe.HasFinish);
        Assert.Equal([0.2, 0.4, 0.8], recipe.Apply([0.2, 0.4, 0.8]));
        var atZero = new ClipGradeRecipe(ClipLook.Bw, new ClipColorAdjustments(0, 30, 0, 0), new ClipColorGrade { Amount = 0, Grain = 40 });
        Assert.False(atZero.ChangesColor || atZero.HasFinish);
        var fixOnly = new ClipGradeRecipe(ClipLook.Original, null, new ClipColorGrade { Amount = 0, Exposure = 10 });
        Assert.True(fixOnly.ChangesColor && !fixOnly.HasFinish);
    }

    [Fact]
    public void AutoAndTheLightFactsReadSyntheticFrames()
    {
        var measure = ClipLookLibraryTests.Library().Measure;
        var cases = Cases().GetProperty("measure").EnumerateArray().ToArray();
        Assert.Equal(12, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var frames = item.GetProperty("frames").EnumerateArray().Select(frame => new ClipFrameSample(Int(frame, "width"), Int(frame, "height"),
                Ints(frame.GetProperty("rgb")).Select(value => (byte)value).ToArray(),
                frame.TryGetProperty("face", out var face) ? new ClipEffectRect(face.GetProperty("x").GetDouble(), face.GetProperty("y").GetDouble(),
                    face.GetProperty("width").GetDouble(), face.GetProperty("height").GetDouble()) : null)).ToArray();
            var fix = item.GetProperty("fix");
            Assert.Equal(new ClipColorFix(Int(fix, "exposure"), Int(fix, "temperature"), Int(fix, "tint")), ClipColorFix.Measure(frames, measure.Auto));
            var facts = item.GetProperty("facts").EnumerateArray().ToArray();
            Assert.Equal(frames.Length, facts.Length);
            foreach (var (frame, wanted) in frames.Zip(facts))
            {
                var found = new ClipLightFacts(frame, measure);
                bool Optional(double? value, string key) => value is { } number
                    ? Math.Abs(number - wanted.GetProperty(key).GetDouble()) <= Floats : wanted.GetProperty(key).ValueKind == JsonValueKind.Null;
                Assert.True(Close([found.MedianLuma, found.P95Luma, found.MeanChroma],
                    [wanted.GetProperty("medianLuma").GetDouble(), wanted.GetProperty("p95Luma").GetDouble(), wanted.GetProperty("meanChroma").GetDouble()]), id);
                Assert.True(Optional(found.FaceMeanLuma, "faceMeanLuma") && Optional(found.FaceMedianLuma, "faceMedianLuma") &&
                    Optional(found.FaceClippedShare, "faceClippedShare"), id);
                var means = wanted.GetProperty("neutralMeans");
                Assert.True(means.ValueKind == JsonValueKind.Null ? found.NeutralMeans is null : Close(found.NeutralMeans ?? [], Doubles(means)), id);
                Assert.Equal(wanted.GetProperty("notes").EnumerateArray().Select(note => note.GetString()), found.Notes.Select(note => note.Text));
                Assert.Equal(wanted.GetProperty("line").GetString(), found.Line);
            }
        }
    }
}
