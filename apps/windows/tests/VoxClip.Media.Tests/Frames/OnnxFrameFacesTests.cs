using System.Diagnostics;
using System.Xml.Linq;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Frames;
using VoxClip.Media.Frames;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Frames;

/// <summary>The bundled face models on ONNX Runtime (ADR-R48 Windows, W3): <see cref="OnnxFrameFaces"/> on the golden self-portraits
/// in shared/fixtures/frame-faces (each PD-self or CC0 by the person photographed), loading only verified files, unavailable rather
/// than "no face" when a file is missing or altered, off while the catalogue is off unless overridden, the same from concurrent
/// lanes as from one, and bundled in the App's and the CLI's output. Runs on the Mac host and on hosted Windows x64; arm64 is owed
/// to the VM.</summary>
public sealed class OnnxFrameFacesTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;
    private static readonly Lazy<OnnxFrameFaces> Shared = new(() => OnnxFrameFaces.Load(new FrameModelCatalog().Entry, OnnxFrameFaces.BundledDirectory()));

    /// <summary>What a golden must measure: the reference is tools-independent (numpy, onnxruntime 1.19.2 in Python and W2's generator
    /// maths, run on the Mac), and the tolerances leave room for ORT's CPU differences across x64, arm64 and the Mac.</summary>
    public sealed record Golden(string File, int FaceCount, double X, double Y, double Width, double Height, double LeftEye, double RightEye,
        double Yaw, double Pitch, double Quality);

    public static TheoryData<string> GoldenFiles => new(Goldens.Keys);

    private static readonly Dictionary<string, Golden> Goldens = new[]
    {
        new Golden("kaminix.png", 1, 0.34820, 0.19791, 0.28278, 0.47544, 0.32615, 0.29228, 0.16100, 0.44609, 0.26923),
        new Golden("saurabh.png", 1, 0.08746, 0.34599, 0.57775, 0.50103, 0.34256, 0.29615, 0.35766, -0.06165, 0.34681),
        new Golden("amblard.png", 1, 0.42151, 0.37876, 0.37815, 0.35091, 0.32292, 0.39835, -0.51002, -0.12187, 0.24093),
        new Golden("parham.png", 1, 0.43397, 0.16100, 0.42281, 0.40892, 0.30843, 0.43995, -0.61401, 0.29300, 0.17418),
    }.ToDictionary(golden => golden.File);

    // Tolerances: the rect in picture fractions, eye ratios, angles in radians, quality.
    private const double RectTolerance = 0.005, EyeTolerance = 0.01, AngleTolerance = 0.02, QualityTolerance = 0.02;

    [Theory]
    [MemberData(nameof(GoldenFiles))]
    public void AGoldenFaceMeasuresAsPinned(string file)
    {
        var golden = Goldens[file];
        var found = Shared.Value.Faces(Image(file), Ct);
        Assert.Equal(golden.FaceCount, found.FaceCount);
        var face = Assert.IsType<FrameFace>(found.Largest);
        Near(golden.X, face.Rect.X, RectTolerance, "x");
        Near(golden.Y, face.Rect.Y, RectTolerance, "y");
        Near(golden.Width, face.Rect.Width, RectTolerance, "width");
        Near(golden.Height, face.Rect.Height, RectTolerance, "height");
        Near(golden.LeftEye, face.LeftEyeAspect!.Value, EyeTolerance, "left eye");
        Near(golden.RightEye, face.RightEyeAspect!.Value, EyeTolerance, "right eye");
        Near(golden.Yaw, face.Yaw!.Value, AngleTolerance, "yaw");
        Near(golden.Pitch, face.Pitch!.Value, AngleTolerance, "pitch");
        Assert.Equal(Math.Sign(golden.Yaw), Math.Sign(face.Yaw!.Value));
        Assert.Equal(Math.Sign(golden.Pitch), Math.Sign(face.Pitch!.Value));
        Near(golden.Quality, face.CaptureQuality!.Value, QualityTolerance, "quality");
        Assert.Equal(FrameEyes.Open, face.Eyes);
    }

    [Fact]
    public void TheNoFaceImageHasNoFaces()
    {
        var found = Shared.Value.Faces(Image("no-face.png"), Ct);
        Assert.Equal((0, null), (found.FaceCount, found.Largest));
    }

    /// <summary>A box YuNet finds (score 0.83 in the reference) that Face Mesh V2 says is no face (presence logit −7.1) is not counted.</summary>
    [Fact]
    public void ABoxTheMeshRejectsIsNotAFace()
    {
        var found = Shared.Value.Faces(Image("kaminix-blurred.png"), Ct);
        Assert.Equal((0, null), (found.FaceCount, found.Largest));
    }

    /// <summary>Two people side by side: both counted, the larger one measured.</summary>
    [Fact]
    public void TwoFacesAreCountedAndTheLargerIsMeasured()
    {
        using var left = Bitmap("kaminix.png");
        using var right = Bitmap("saurabh.png");
        using var canvas = new SKBitmap(new SKImageInfo(left.Width + right.Width, Math.Max(left.Height, right.Height), SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var draw = new SKCanvas(canvas))
        {
            draw.Clear(SKColors.Black);
            draw.DrawBitmap(left, 0, 0);
            draw.DrawBitmap(right, left.Width, 0);
        }
        var found = Shared.Value.Faces(Pixels(canvas), Ct);
        Assert.Equal(2, found.FaceCount);
        Assert.True(found.Largest!.Rect.X > (double)left.Width / canvas.Width, "the larger face is the right-hand one");
    }

    [Fact]
    public async Task ConcurrentLanesGiveTheSameResultsAsOneLane()
    {
        var frames = Goldens.Keys.Append("no-face.png").Select(Image).ToArray();
        var one = frames.Select(frame => Shared.Value.Faces(frame, Ct)).ToArray();
        using var start = new Barrier(FrameAnalyzer.Lanes);
        var lanes = Enumerable.Range(0, FrameAnalyzer.Lanes).Select(lane => Task.Run(() =>
        {
            Assert.True(start.SignalAndWait(TimeSpan.FromSeconds(30), Ct), "the lanes did not start together");
            return Enumerable.Range(0, frames.Length * 2).Select(step => (step + lane) % frames.Length)
                .Select(index => (index, found: Shared.Value.FacesAsync(frames[index], Ct).GetAwaiter().GetResult())).ToArray();
        }, Ct)).ToArray();
        foreach (var lane in await Task.WhenAll(lanes))
            foreach (var (index, found) in lane)
                Assert.Equal(one[index], found);
    }

    /// <summary>A missing or altered file is faces unavailable (null: no analyzer, never <c>faceCount: 0</c>), never a crash.</summary>
    [Fact]
    public void AMissingOrAlteredFileMakesFacesUnavailable()
    {
        var directory = FrameFixtures.TempRoot("models");
        try
        {
            var catalog = new FrameModelCatalog();
            foreach (var file in catalog.Entry.Files)
                File.Copy(Path.Combine(OnnxFrameFaces.BundledDirectory(), file.Name), Path.Combine(directory, file.Name));
            using (var verified = OnnxFrameFaces.Installed(catalog, directory, overridden: true)) Assert.NotNull(verified);

            var mesh = Path.Combine(directory, catalog.Entry.Landmarks.Name);
            var bytes = File.ReadAllBytes(mesh);
            bytes[bytes.Length / 2] ^= 1;
            File.WriteAllBytes(mesh, bytes);
            Assert.Null(OnnxFrameFaces.Installed(catalog, directory, overridden: true));
            Assert.Throws<InvalidDataException>(() => OnnxFrameFaces.Load(catalog.Entry, directory));

            File.Delete(mesh);
            Assert.Null(OnnxFrameFaces.Installed(catalog, directory, overridden: true));
            Assert.Null(OnnxFrameFaces.Installed(catalog, Path.Combine(directory, "absent"), overridden: true));
            Assert.Throws<FrameFacesUnavailableException>(() =>
                new FrameAnalyzer(OnnxFrameFaces.Installed(catalog, directory, overridden: true), () => throw new InvalidOperationException(),
                    new StubFrameDecoder(), null));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void TheDisabledCatalogueGivesNoFacesWithoutTheOverride()
    {
        var catalog = new FrameModelCatalog();
        Assert.False(catalog.Enabled);
        Assert.Null(OnnxFrameFaces.Installed(catalog, OnnxFrameFaces.BundledDirectory(), overridden: false));
        using var overridden = OnnxFrameFaces.Installed(catalog, OnnxFrameFaces.BundledDirectory(), overridden: true);
        Assert.NotNull(overridden);
        Assert.Equal(Environment.GetEnvironmentVariable(OnnxFrameFaces.OverrideVariable) == "1", OnnxFrameFaces.Overridden());
        Assert.Equal("VOXCLIP_FRAME_FACES", OnnxFrameFaces.OverrideVariable);
    }

    [Fact]
    public void AfterDisposeACallIsRefused()
    {
        var faces = OnnxFrameFaces.Load(new FrameModelCatalog().Entry, OnnxFrameFaces.BundledDirectory());
        faces.Dispose();
        faces.Dispose();
        Assert.Throws<ObjectDisposedException>(() => faces.Faces(Image("no-face.png"), Ct));
    }

    /// <summary>The CLI's output (this test assembly's folder, which gets the CLI project's content) holds both models as catalogued,
    /// and the App's project copies the same folder to its output and its publish folder (the App builds on Windows only).</summary>
    [Fact]
    public void TheBundledFilesAreInTheAppAndCliOutput()
    {
        var catalog = new FrameModelCatalog();
        var directory = OnnxFrameFaces.BundledDirectory();
        Assert.Equal(Path.Combine(AppContext.BaseDirectory, "models", "frames"), directory);
        catalog.Entry.VerifiedFiles(directory);
        foreach (var notice in new[] { "NOTICE.txt", "LICENSE-YuNet.txt", "LICENSE-Apache-2.0.txt" })
            Assert.True(File.Exists(Path.Combine(directory, notice)), notice);
        var repository = Path.GetDirectoryName(FixtureLoader.SharedRoot)!;
        foreach (var project in new[] { "VoxClip.App/VoxClip.App.csproj", "VoxClip.Cli/VoxClip.Cli.csproj" })
        {
            var items = XDocument.Load(Path.Combine(repository, "apps", "windows", "src", project)).Descendants("Content")
                .Where(item => (string?)item.Attribute("Include") == @"$(MSBuildThisFileDirectory)..\..\models\frames\*").ToArray();
            var item = Assert.Single(items);
            Assert.Equal((@"models\frames", "PreserveNewest", "PreserveNewest"),
                ((string?)item.Attribute("LinkBase"), (string?)item.Attribute("CopyToOutputDirectory"), (string?)item.Attribute("CopyToPublishDirectory")));
        }
        foreach (var file in catalog.Entry.Files)
            Assert.Equal(file.Bundled, "apps/windows/models/frames/" + Path.GetFileName(Path.Combine(directory, file.Name)));
    }

    /// <summary>The full face path's speed on a 1,280 × 720 frame (two goldens on it), printed for the CI log; the bound only catches a
    /// pathological slowdown.</summary>
    [Fact]
    public void TheFacePathSpeedIsPrinted()
    {
        using var face = Bitmap("saurabh.png");
        using var canvas = new SKBitmap(new SKImageInfo(1280, 720, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var draw = new SKCanvas(canvas))
        {
            draw.Clear(new SKColor(90, 100, 110));
            draw.DrawBitmap(face, new SKRect(440, 0, 440 + face.Width * 720f / face.Height, 720));
        }
        var frame = Pixels(canvas);
        var faces = Shared.Value;
        for (var warm = 0; warm < 3; warm++) Assert.Equal(1, faces.Faces(frame, Ct).FaceCount);
        const int runs = 20;
        var clock = Stopwatch.StartNew();
        for (var run = 0; run < runs; run++) faces.Faces(frame, Ct);
        var milliseconds = clock.Elapsed.TotalMilliseconds / runs;
        var line = FormattableString.Invariant($"frame-faces-speed: {milliseconds:F1} ms per 1280x720 frame ") +
            $"({System.Runtime.InteropServices.RuntimeInformation.OSDescription}, {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture})";
        Console.WriteLine(line);
        TestContext.Current.SendDiagnosticMessage(line);
        Assert.True(milliseconds < 2000, $"{milliseconds} ms per frame");
    }

    private static void Near(double expected, double actual, double tolerance, string what) =>
        Assert.True(Math.Abs(expected - actual) <= tolerance, $"{what}: expected {expected} ± {tolerance}, got {actual}");

    private static string GoldenPath(string file) => Path.Combine(FixtureLoader.SharedRoot, "fixtures", "frame-faces", file);

    private static SKBitmap Bitmap(string file)
    {
        using var decoded = SKBitmap.Decode(GoldenPath(file)) ?? throw new InvalidDataException(file);
        return decoded.Copy(SKColorType.Bgra8888) ?? throw new InvalidDataException(file);
    }

    private static PixelBuffer Image(string file)
    {
        using var bitmap = Bitmap(file);
        return Pixels(bitmap);
    }

    private static PixelBuffer Pixels(SKBitmap bitmap) => new(bitmap.Bytes, bitmap.Width, bitmap.Height, bitmap.RowBytes);
}
