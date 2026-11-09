using System.Security.Cryptography;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The Windows quad finder and screen scan (ADR-R48 Windows, package W4): every case of
/// shared/fixtures/clip-frames/frame-quad-cases.json, which tools/fixtures/clip-frames/generate_frame_quads.py draws with exact
/// arithmetic. Found quads match the drawn ones within the file's tolerance; scans with listed quads match exactly. No Mac twin:
/// the Mac reads Vision.</summary>
[Trait("Track", "win-ai")]
public sealed class FrameQuadVectorTests
{
    private const string Path = "fixtures/clip-frames/frame-quad-cases.json";
    private static readonly Lazy<JsonObject> Vectors = new(() => JsonNode.Parse(FixtureLoader.ReadText(Path))!.AsObject());
    private static readonly Lazy<Dictionary<string, (byte[] Pixels, int Width, int Height)>> Frames = new(() =>
        Vectors.Value["frames"]!.AsArray().Select(node => node!.AsObject()).ToDictionary(frame => Id(frame), Decode));
    private static IEnumerable<JsonObject> Rows(string key) => Vectors.Value[key]!.AsArray().Select(row => row!.AsObject());
    private static string Id(JsonObject row) => row["id"]!.GetValue<string>();
    private static double Number(JsonNode? node) => node!.GetValue<double>();
    private static double Tolerance => Number(Vectors.Value["tolerance"]);
    private static ClipEffectRect Rect(JsonNode? node) => new(Number(node!["x"]), Number(node["y"]), Number(node["width"]), Number(node["height"]));

    internal static (byte[] Pixels, int Width, int Height) Decode(JsonObject frame)
    {
        var width = frame["width"]!.GetValue<int>();
        var height = frame["height"]!.GetValue<int>();
        var pixels = new byte[width * height];
        var at = 0;
        foreach (var token in frame["runs"]!.GetValue<string>().Split(' '))
        {
            var star = token.IndexOf('*');
            var value = byte.Parse(token.AsSpan(0, star));
            var count = int.Parse(token.AsSpan(star + 1));
            pixels.AsSpan(at, count).Fill(value);
            at += count;
        }
        Assert.Equal(pixels.Length, at);
        Assert.Equal(frame["sha256"]!.GetValue<string>(), Convert.ToHexStringLower(SHA256.HashData(pixels)));
        return (pixels, width, height);
    }

    internal static IReadOnlyList<FrameQuad> Find(string frame)
    {
        var (pixels, width, height) = Frames.Value[frame];
        return new QuadFinder().Find(pixels, width, height);
    }

    private static bool Near(ClipEffectRect expected, ClipEffectRect actual, double tolerance) =>
        Math.Abs(expected.X - actual.X) <= tolerance && Math.Abs(expected.Y - actual.Y) <= tolerance
        && Math.Abs(expected.X + expected.Width - actual.X - actual.Width) <= tolerance
        && Math.Abs(expected.Y + expected.Height - actual.Y - actual.Height) <= tolerance;

    /// <summary>Each drawn corner has a found corner within the tolerance on both axes, and the boxes agree.</summary>
    private static bool Matches(JsonObject drawn, FrameQuad found)
    {
        if (!Near(Rect(drawn["box"]), found.BoundingBox, Tolerance)) return false;
        FramePoint[] corners = [found.TopLeft, found.TopRight, found.BottomRight, found.BottomLeft];
        return drawn["corners"]!.AsArray().All(corner =>
            corners.Any(point => Math.Abs(point.X - Number(corner![0])) <= Tolerance && Math.Abs(point.Y - Number(corner[1])) <= Tolerance));
    }

    private static string Describe(IReadOnlyList<FrameQuad> found) => string.Join("; ", found.Select(quad =>
        $"({quad.TopLeft.X:F4},{quad.TopLeft.Y:F4}) ({quad.TopRight.X:F4},{quad.TopRight.Y:F4}) ({quad.BottomRight.X:F4},{quad.BottomRight.Y:F4}) ({quad.BottomLeft.X:F4},{quad.BottomLeft.Y:F4}) c={quad.Confidence:F3}"));

    [Fact]
    public void KeysCountsAndSettingsAreVisions()
    {
        var vectors = Vectors.Value;
        Assert.Equal("voxclip-frame-quad-cases/1", vectors["schema"]!.GetValue<string>());
        Assert.Equal(["schema", "description", "settings", "tolerance", "coverageTolerance", "caseCount", "counts", "frames", "quads", "scans"],
            vectors.Select(pair => pair.Key).ToArray());
        Assert.Equal(25, vectors["caseCount"]!.GetValue<int>());
        Assert.Equal(10, Rows("quads").Count());
        Assert.Equal(15, Rows("scans").Count());
        Assert.Equal(10, Frames.Value.Count);
        var settings = vectors["settings"]!.AsObject();
        Assert.Equal(QuadFinderSettings.MaximumObservations, settings["maximumObservations"]!.GetValue<int>());
        Assert.Equal(QuadFinderSettings.MinimumAspectRatio, Number(settings["minimumAspectRatio"]));
        Assert.Equal(QuadFinderSettings.MaximumAspectRatio, Number(settings["maximumAspectRatio"]));
        Assert.Equal(QuadFinderSettings.MinimumSize, Number(settings["minimumSize"]));
        Assert.Equal(QuadFinderSettings.MinimumConfidence, Number(settings["minimumConfidence"]));
        Assert.Equal(QuadFinderSettings.QuadratureTolerance, Number(settings["quadratureTolerance"]));
        Assert.Equal(QuadFinderSettings.WorkingLongSide, settings["workingLongSide"]!.GetValue<int>());
    }

    public static TheoryData<string> QuadCases() => [.. Rows("quads").Select(Id)];

    [Theory]
    [MemberData(nameof(QuadCases))]
    public void FindsTheDrawnQuadsAndOnlyThose(string id)
    {
        var row = Rows("quads").Single(item => Id(item) == id);
        var found = Find(row["frame"]!.GetValue<string>());
        Assert.True(found.Count <= row["maximumCount"]!.GetValue<int>(), $"{id}: {found.Count} quads: {Describe(found)}");
        foreach (var drawn in row["expected"]!.AsArray().Select(node => node!.AsObject()))
            Assert.True(found.Any(quad => Matches(drawn, quad)), $"{id}: missing {drawn["box"]!.ToJsonString()}; found {Describe(found)}");
        foreach (var drawn in row["rejected"]!.AsArray().Select(node => node!.AsObject()))
            Assert.False(found.Any(quad => Near(Rect(drawn["box"]), quad.BoundingBox, Tolerance)), $"{id}: kept {drawn["box"]!.ToJsonString()}");
        for (var index = 1; index < found.Count; index++)
            Assert.True(found[index - 1].Confidence >= found[index].Confidence, $"{id}: not the most confident first");
        Assert.All(found, quad => Assert.InRange(quad.Confidence, QuadFinderSettings.MinimumConfidence, 1));
    }

    public static TheoryData<string> ScanCases() => [.. Rows("scans").Select(Id)];

    [Theory]
    [MemberData(nameof(ScanCases))]
    public void ScansGiveTheSharedScreens(string id)
    {
        var row = Rows("scans").Single(item => Id(item) == id);
        var lines = row["lines"]!.AsArray().Select(Rect).ToArray();
        var expected = row["screens"]!.AsArray().Select(node => node!.AsObject()).ToArray();
        FrameScreenFindings findings;
        double tolerance, coverage;
        if (row["frame"] is { } frame)
        {
            findings = FrameScreenScan.Detect(lines, Find(frame.GetValue<string>()));
            (tolerance, coverage) = (Tolerance, Number(Vectors.Value["coverageTolerance"]));
        }
        else
        {
            var quads = row["quads"]!.AsArray().Select(Rect).Select(box => new FrameQuad(new(box.X, box.Y), new(box.X + box.Width, box.Y),
                new(box.X + box.Width, box.Y + box.Height), new(box.X, box.Y + box.Height), 1)).ToArray();
            findings = FrameScreenScan.Detect(lines, quads);
            (tolerance, coverage) = (1e-12, 1e-12);
        }
        Assert.Equal(lines, findings.TextRects);
        Assert.True(expected.Length == findings.Screens.Count, $"{id}: {findings.Screens.Count} screens");
        for (var index = 0; index < expected.Length; index++)
        {
            var screen = findings.Screens[index];
            Assert.True(Near(Rect(expected[index]["rect"]), screen.Rect, tolerance), $"{id}[{index}]: rect {screen.Rect}");
            Assert.Equal(expected[index]["textBoxes"]!.GetValue<int>(), screen.TextBoxes);
            var share = Number(expected[index]["textCoverage"]);
            Assert.True(Math.Abs(share - screen.TextCoverage) <= coverage * Math.Max(1e-9, share) + 1e-12, $"{id}[{index}]: coverage {screen.TextCoverage} vs {share}");
            Assert.Equal(expected[index]["framed"]!.GetValue<bool>(), screen.Framed);
        }
    }

    /// <summary>The Mac's drawn phone screen (FrameAnalyzerTests.phoneScreen) is a framed screen: the quad finder is the
    /// rectangle source Windows needs, since its six lines are under the 8-box cluster rule.</summary>
    [Fact]
    public void TheDrawnPhoneScreenIsFoundAndFramed()
    {
        var row = Rows("scans").Single(item => Id(item) == "phone-framed");
        var lines = row["lines"]!.AsArray().Select(Rect).ToArray();
        var findings = FrameScreenScan.Detect(lines, Find("phone-upright"));
        var screen = Assert.Single(findings.Screens.Take(1));
        Assert.True(screen.Framed);
        Assert.Equal(6, screen.TextBoxes);
        Assert.InRange(FrameRect.MidX(screen.Rect), 0.5, 0.8);
        Assert.Empty(FrameScreenScan.Detect(lines, []).Screens);
    }
}
