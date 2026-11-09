using System.Reflection;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Text lines and the screen scan on Windows (ADR-R48 Windows, W4): OCR words become line boxes (the maths Ask Claude's
/// eyes used, with its numbers), no string reaches a result, and opening-scan frames skip text and quads.</summary>
[Trait("Track", "win-ai")]
public sealed class FrameScreenScanTests
{
    /// <summary>The numbers WindowsAskClaudeVision made before the maths moved to Core: left/top are the words' minimum, right and
    /// bottom their maximum, each divided by the frame's size, then clamped.</summary>
    [Fact]
    public void ALineBoxIsTheMinAndMaxOverItsWordsAsAskClaudeMadeIt()
    {
        var box = FrameTextLines.LineBox([new(100, 200, 50, 20), new(160, 198, 40, 24)], 1280, 720);
        Assert.Equal(new ClipEffectRect(0.078125, 0.275, 0.078125, 0.03333333333333333), box);
        var edge = FrameTextLines.LineBox([new(1200, 700, 100, 40)], 1280, 720);
        Assert.Equal(new ClipEffectRect(0.921875, 0.9444444444444444, 0.078125, 0.05555555555555555), edge);
        var tiny = FrameTextLines.LineBox([new(10, 10, 2, 2)], 1280, 720);
        Assert.Equal(new ClipEffectRect(10.0 / 1280, 10.0 / 720, 0.01, 0.01), tiny);
        Assert.Null(FrameTextLines.LineBox([], 1280, 720));
        Assert.Null(FrameTextLines.LineBox([new(1, 1, 1, 1)], 0, 720));
    }

    /// <summary>Lines, not words: three lines of three words are three boxes, a screen of 3 inside a quad. Their nine word boxes
    /// would be a dense-text cluster of their own (8 or more) and claim the quad's text twice over.</summary>
    [Fact]
    public void WordsBecomeLineBoxesNotWordBoxes()
    {
        OcrWordBox[][] lines = [.. Enumerable.Range(0, 3).Select(line =>
            Enumerable.Range(0, 3).Select(word => new OcrWordBox(820 + word * 60, 200 + line * 60, 50, 24)).ToArray())];
        var boxes = lines.Select(words => FrameTextLines.LineBox(words, 1280, 720)!.Value).ToArray();
        Assert.Equal(3, boxes.Length);
        Assert.All(boxes, box => Assert.Equal(170.0 / 1280, box.Width, 12));
        var quad = new FrameQuad(new(0.6, 0.2), new(0.82, 0.2), new(0.82, 0.8), new(0.6, 0.8), 1);
        var screen = Assert.Single(FrameScreenScan.Detect(boxes, [quad]).Screens);
        Assert.True(screen.Framed);
        Assert.Equal(3, screen.TextBoxes);
        var words = lines.SelectMany(line => line).Select(word => FrameTextLines.LineBox([word], 1280, 720)!.Value).ToArray();
        Assert.Equal(9, FrameScreenScan.Detect(words, [quad]).Screens.Single().TextBoxes);
    }

    /// <summary>Positions only: nothing a scan returns, and nothing the text seam returns, can hold a string.</summary>
    [Fact]
    public void NoStringReachesTheResultTypes()
    {
        var method = typeof(IFrameTextLines).GetMethod(nameof(IFrameTextLines.LinesAsync))!;
        Assert.Equal(typeof(Task<IReadOnlyList<ClipEffectRect>>), method.ReturnType);
        foreach (var type in new[] { typeof(FrameScreenFindings), typeof(FrameQuad), typeof(OcrWordBox), method.ReturnType })
            Assert.False(HoldsText(type, []), $"{type.Name} can hold text");
        Assert.DoesNotContain(typeof(FrameTextLines).GetMethods(BindingFlags.Public | BindingFlags.Static).SelectMany(item => item.GetParameters()),
            parameter => parameter.ParameterType == typeof(string));
    }

    private static bool HoldsText(Type type, HashSet<Type> seen)
    {
        if (type == typeof(string) || type == typeof(char) || type == typeof(object)) return true;
        if (type.IsPrimitive || type.IsEnum || type == typeof(decimal) || !seen.Add(type)) return false;
        if (type.IsArray) return HoldsText(type.GetElementType()!, seen);
        if (type.IsGenericType && type.GetGenericArguments().Any(argument => HoldsText(argument, seen))) return true;
        if (type.Namespace?.StartsWith("VoxClip", StringComparison.Ordinal) != true) return false;
        const BindingFlags members = BindingFlags.Public | BindingFlags.Instance;
        return type.GetProperties(members).Any(property => HoldsText(property.PropertyType, seen))
            || type.GetFields(members).Any(field => HoldsText(field.FieldType, seen));
    }

    /// <summary>The opening scan only feeds the opening frame (faces): its frames never reach the OCR or the quad finder. This
    /// frame's pixels are missing, so the finder would throw if it looked.</summary>
    [Fact]
    public async Task OpeningScanFramesSkipTextAndQuads()
    {
        var text = new CountingText([new(0.62, 0.3, 0.1, 0.03)]);
        var scan = new FrameScreenScan(text, new QuadFinder());
        var missing = new PixelBuffer(Memory<byte>.Empty, 1280, 720, 1280 * 4);
        var opening = await scan.ScanAsync(missing, openingScan: true, CancellationToken.None);
        Assert.Same(FrameScreenFindings.None, opening);
        Assert.Equal(0, text.Calls);
        await Assert.ThrowsAsync<ArgumentException>(() => scan.ScanAsync(missing, openingScan: false, CancellationToken.None));
        Assert.Equal(1, text.Calls);
    }

    /// <summary>A sentence frame through the whole scan: the drawn phone as BGRA (the decoder's layout, padded rows), the six
    /// lines from the text seam, and a framed screen on the observation, faces left as they were.</summary>
    [Fact]
    public async Task ASentenceFrameGetsTextRectsAndAFramedScreen()
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-frames/frame-quad-cases.json"))!.AsObject();
        var (grey, width, height) = FrameQuadVectorTests.Decode(vectors["frames"]!.AsArray().Single(frame => frame!["id"]!.GetValue<string>() == "phone-upright")!.AsObject());
        var stride = width * 4 + 64;
        var bgra = new byte[stride * height];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var at = y * stride + x * 4;
                bgra[at] = bgra[at + 1] = bgra[at + 2] = grey[y * width + x];
                bgra[at + 3] = 255;
            }
        var lines = vectors["scans"]!.AsArray().Single(row => row!["id"]!.GetValue<string>() == "phone-framed")!["lines"]!.AsArray()
            .Select(box => new ClipEffectRect(box!["x"]!.GetValue<double>(), box["y"]!.GetValue<double>(), box["width"]!.GetValue<double>(), box["height"]!.GetValue<double>()))
            .ToArray();
        var text = new CountingText(lines);
        var findings = await new FrameScreenScan(text, new QuadFinder()).ScanAsync(new PixelBuffer(bgra, width, height, stride), openingScan: false, CancellationToken.None);
        Assert.Equal(1, text.Calls);
        Assert.Equal(lines, findings.TextRects);
        Assert.Equal(new QuadFinder().Find(grey, width, height), new QuadFinder().Find(new PixelBuffer(bgra, width, height, stride)));
        var screen = findings.Screens[0];
        Assert.True(screen.Framed);
        Assert.Equal(6, screen.TextBoxes);
        var face = new FrameFace(new ClipEffectRect(0.1, 0.2, 0.2, 0.3), 0.6, 0.3, 0.3);
        var observation = findings.ApplyTo(new FrameObservation(3) { FaceCount = 1, Face = face });
        Assert.Same(face, observation.Face);
        Assert.Equal(lines, observation.TextRects);
        Assert.Equal(findings.Screens, observation.Screens);
    }

    private sealed class CountingText(IReadOnlyList<ClipEffectRect> lines) : IFrameTextLines
    {
        public int Calls { get; private set; }

        public Task<IReadOnlyList<ClipEffectRect>> LinesAsync(PixelBuffer frame, CancellationToken ct)
        {
            Calls++;
            return Task.FromResult(lines);
        }
    }
}
