using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Share;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>A clip export's cover (ADR-R48, doc/publishing.md §7), twin of the Mac's: <c>&lt;name&gt;-cover.jpg</c> beside the MP4, and the
/// same JPEG as the MP4's <c>covr</c> art, written by the ported writer onto the export's partial before it is moved into place.</summary>
public sealed class ExportCoverTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("voxclip-w6-cover-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(directory, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static string CoverArt(string file) => Path.Combine(FixtureLoader.SharedRoot, "fixtures", "cover-art", file);

    /// <summary>Every shared cover-art vector through the streamed embed on a file: the same bytes as Core's in-memory writer (and the
    /// vector's SHA-256), or, for a refusal, the file as it was and no staged copy left beside it.</summary>
    [Fact]
    public void TheStreamedEmbedWritesTheVectorsBytesOrLeavesTheFileAsItWas()
    {
        using var vectors = FixtureLoader.ReadJson("fixtures/cover-art/cover-art-cases.json");
        var cases = vectors.RootElement.GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(17, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var image = File.ReadAllBytes(CoverArt(item.GetProperty("image").GetString()!));
            var original = File.ReadAllBytes(CoverArt(item.GetProperty("input").GetString()!));
            var file = Path.Combine(directory, id + ".mp4");
            File.WriteAllBytes(file, original);
            if (item.TryGetProperty("refusal", out _))
            {
                Assert.ThrowsAny<Exception>(() => Mp4CoverEmbed.Embed(image, file, TestContext.Current.CancellationToken));
                Assert.Equal(original, File.ReadAllBytes(file));
                Assert.False(File.Exists(file + ".cover"), id);
                Assert.False(Exporter.EmbedCover(image, file, TestContext.Current.CancellationToken), id);
                Assert.Equal(original, File.ReadAllBytes(file));
                continue;
            }
            Mp4CoverEmbed.Embed(image, file, TestContext.Current.CancellationToken);
            var written = File.ReadAllBytes(file);
            Assert.Equal(Mp4CoverArt.Embed(image, original), written);
            Assert.Equal(item.GetProperty("outputSha256").GetString(), Convert.ToHexStringLower(SHA256.HashData(written)));
            Assert.False(File.Exists(file + ".cover"), id);
        }
    }

    [Fact]
    public void TheCoverIsTheComposedFrameAsAFullSizeJpeg()
    {
        var pixels = new byte[64 * 36 * 4];
        for (var index = 0; index < pixels.Length; index += 4) (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]) = (40, 160, 220, 255);
        var jpeg = Exporter.CoverImage(new PixelBuffer(pixels, 64, 36, 64 * 4))!;
        Assert.Equal([0xFF, 0xD8], jpeg[..2]);
        Assert.Equal(new PixelSize(64, 36), VoxClip.Media.Frames.FrameJpeg.Size(jpeg));
        Assert.Null(Exporter.CoverImage(new PixelBuffer(Array.Empty<byte>(), 0, 0, 0)));
    }

    /// <summary>The CLI's export (and so <c>autopilot --out-dir</c>) hands the exporter the clip's cover: the snapshot it prepares has
    /// the clip's <c>coverSeconds</c>, at its place in the render.</summary>
    [Fact]
    public async Task TheCliExportCarriesTheClipsCoverToTheExporter()
    {
        var ct = TestContext.Current.CancellationToken;
        var source = Path.Combine(directory, "source.mp4");
        await File.WriteAllTextAsync(source, "offline injected probe input", ct);
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/five-questions.voxclip"));
        var key = await new ProjectStore().ComputeContentKeyAsync(source, null, ct);
        project = project with { Media = new(project.Media.Source with { AbsolutePath = source, SizeBytes = new FileInfo(source).Length, ContentKey = key }) };
        project = VoxClip.Core.Domain.Frames.ClipPicture.SettingControls("fq-clip-1", project, controls => controls with { CoverSeconds = 2.0 })!;
        var path = Path.Combine(directory, "five-questions.voxclip");
        await File.WriteAllTextAsync(path, ProjectSerialization.Serialize(project), ct);
        var media = new MediaInfo(source, project.Media.Source.DurationSeconds, project.Media.Source.Video, project.Media.Source.Audio, new(1920, 1080),
            "h264", "aac", false, 0, 1, 0);
        ExportInputReader open = async (file, token) => ((await new ProjectStore().LoadAsync(file, token)).Project, media);
        var parsed = CliApplication.Parse(["--open", path, "--export", Path.Combine(directory, "clip.mp4"), "--clip", "fq-clip-1", "--aspect", "9:16", "--quiet"]);
        Assert.Empty(parsed.Errors);
        var prepared = await CliOperations.PrepareExportAsync(parsed, ct, open, checkingOutputs: false);
        Assert.Equal(2.0, prepared.Snapshot.Clip?.Controls?.CoverSeconds);
        var fps = prepared.Snapshot.Output.FrameRate;
        Assert.Equal(prepared.Snapshot.Speed.Rendered(prepared.Snapshot.Timeline.MapTime(2.0)), ExportCover.Seconds(prepared.Snapshot, fps)!.Value, 9);
        Assert.Equal(Path.Combine(Path.GetDirectoryName(prepared.Destination)!, "clip-cover.jpg"), ExportCover.PathFor(prepared.Destination));
        // Without a cover nothing extra is written.
        var plain = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/five-questions.voxclip"));
        Assert.Null(ClipRenderInput.Resolve(plain, "fq-clip-1", directory, FixtureLoader.SharedRoot)?.Controls?.CoverSeconds);
    }
}

/// <summary>The cover through the real exporter (the shipped FFmpeg and a Windows encoder): the JPEG beside the MP4 and inside it.</summary>
[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class NativeExportCoverTests : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync(windows: true);
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    [Fact]
    public async Task AClipExportWritesItsCoverBesideItAndAsItsArt()
    {
        var ct = TestContext.Current.CancellationToken;
        var info = await new FfmpegMediaProbe().ProbeAsync(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "counter-1080p.mp4"), ct);
        var rate = info.Audio?.SampleRate is > 0 ? info.Audio.SampleRate : 48_000;
        var total = (long)Math.Round(Math.Min(2, info.DurationSeconds) * rate);
        var plain = new ComposeSnapshot(info, TestPlan.FromKept(rate, total, [new(0, total)]), null, new(new(160, 90), 10, 1_000_000));
        var covered = plain with { Clip = new(new("c1", 1, null, ClipLook.Original, 0, 0, 0, false, false, 0, CoverSeconds: 1.0), null) };
        var directory = Directory.CreateTempSubdirectory("voxclip-w6-native-cover-").FullName;
        try
        {
            var output = Path.Combine(directory, "clip.mp4");
            var result = await new Exporter().ExportAsync(new(covered, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, output, null), null, ct);
            var cover = ExportCover.PathFor(output);
            Assert.Equal((cover, true), (result.Cover, result.CoverEmbedded));
            var jpeg = await File.ReadAllBytesAsync(cover, ct);
            Assert.Equal([0xFF, 0xD8], jpeg[..2]);
            Assert.True((await File.ReadAllBytesAsync(output, ct)).AsSpan().IndexOf(jpeg) > 0, "the same JPEG is the MP4's covr art");
            Assert.Empty(Directory.GetFiles(directory, "*.partial").Concat(Directory.GetFiles(directory, "*.cover")));
            var none = Path.Combine(directory, "plain.mp4");
            var without = await new Exporter().ExportAsync(new(plain, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, none, null), null, ct);
            Assert.Equal(((string?)null, false), (without.Cover, without.CoverEmbedded));
            Assert.False(File.Exists(ExportCover.PathFor(none)));
        }
        finally { Directory.Delete(directory, true); }
    }
}
