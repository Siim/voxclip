using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class VoiceLabDisclosureTests
{
    private static Project Project(string name) => ProjectSerialization.Deserialize(File.ReadAllText(
        Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", name + ".voxclip")));
    private static string Font => Path.Combine(FixtureLoader.SharedRoot, "fonts", "dm-sans", "DMSans-Bold.ttf");
    private static VoiceLabPreparedRender Prepare(Project project, VoiceLabOutputScope? scope = null) =>
        VoiceLabRenderContract.Prepare(project, scope ?? VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);

    [Fact]
    public void OpacityThresholdsAndWholeIntervalCollisionUseCorePlan()
    {
        var at = Prepare(Project("disclosure-at-30-render-v3"));
        var above = Prepare(Project("disclosure-above-30-render-v3"));
        var half = Prepare(Project("voice-changer-half-render-v3"));
        var whole = Prepare(Project("full-take-render-v3"));
        Assert.False(at.Disclosure.Persistent); Assert.True(above.Disclosure.Persistent);
        Assert.True(half.Disclosure.Persistent); Assert.Equal(new VoiceLabLabelInterval(0, 7), Assert.Single(whole.Disclosure.Intervals));
        using var overlay = new VoiceLabDisclosureOverlay(whole.Disclosure, 1000, 1000, Font,
            [new(2, 4, new SKRect(500, 0, 1000, 200))]);
        Assert.Equal(0, overlay.OpacityAt(0));
        Assert.Equal(.5, overlay.OpacityAt(.075), 3);
        Assert.Equal(1, overlay.OpacityAt(.15), 3);
        Assert.Equal(.5, overlay.OpacityAt(6.925), 3);
        Assert.Equal(0, overlay.OpacityAt(7));
        var bytes = Enumerable.Repeat((byte)255, 1000 * 1000 * 4).ToArray();
        overlay.Draw(new PixelBuffer(bytes, 1000, 1000, 4000), .3, CancellationToken.None);
        Assert.Contains(bytes.AsSpan(70 * 4000, 500 * 4).ToArray(), value => value < 255);
        Assert.All(bytes.AsSpan(70 * 4000 + 500 * 4, 500 * 4).ToArray(), value => Assert.Equal((byte)255, value));
        if (Environment.GetEnvironmentVariable("VOXCLIP_DISCLOSURE_EVIDENCE") is { } evidence)
        {
            Directory.CreateDirectory(evidence);
            using var bitmap = new SKBitmap(new SKImageInfo(1000, 1000, SKColorType.Bgra8888, SKAlphaType.Premul));
            System.Runtime.InteropServices.Marshal.Copy(bytes, 0, bitmap.GetPixels(), bytes.Length);
            using var png = SKImage.FromBitmap(bitmap).Encode(SKEncodedImageFormat.Png, 100);
            File.WriteAllBytes(Path.Combine(evidence, "windows-portable-offscreen-synthetic-disclosure.png"), png.ToArray());
        }
        Assert.True(Prepare(Project("passage-render-v3")).Disclosure.Required);
        Assert.True(Prepare(Project("passage-render-v3"), VoiceLabOutputScope.Clip("clip-main")).Disclosure.Required);
        Assert.False(Prepare(VoiceLabProject.SetEnabled(Project("passage-render-v3"), "vl-passage", false)).Disclosure.Required);
    }

    [Fact]
    public void ChipRequiresBothMarginsAndFrozenIntervalsAtEveryCorner()
    {
        var original = Prepare(Project("full-take-render-v3")).Disclosure;
        var intervals = original.Intervals.ToList();
        var kinds = original.Kinds.ToList();
        foreach (var position in Enum.GetValues<VoiceLabLabelPosition>())
        {
            var plan = original with { Position = position, Intervals = intervals, Kinds = kinds };
            Assert.Throws<ArgumentOutOfRangeException>(() => new VoiceLabDisclosureOverlay(
                plan, 195, 1000, Font, [new(1, 2, new SKRect(0, 0, 195, 200))]));
            using var overlay = new VoiceLabDisclosureOverlay(plan, 1000, 1000, Font,
                [new(1, 2, new SKRect(0, 0, 1000, 200))]);
            intervals.Clear(); kinds.Clear();
            Assert.Equal(1, overlay.OpacityAt(1));
            var pixels = Enumerable.Repeat((byte)255, 1000 * 1000 * 4).ToArray();
            overlay.Draw(new PixelBuffer(pixels, 1000, 1000, 4000), 1, CancellationToken.None);
            Assert.Contains(pixels, value => value < 255);
            intervals.AddRange(original.Intervals); kinds.AddRange(original.Kinds);
        }
    }

    [Fact]
    public async Task AsyncStageUsesProvenanceCapturedBeforeCallerMutation()
    {
        var folder = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "voxclip-disclosure-capture-" +
            Guid.NewGuid().ToString("N"))).FullName;
        try
        {
            var source = Path.Combine(folder, "large.mp4");
            File.Copy(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "bars-1080p.mp4"), source);
            await using (var file = new FileStream(source, FileMode.Open, FileAccess.Write))
            {
                file.Position = file.Length;
                const int freeLength = 64 * 1024 * 1024;
                var box = new byte[8];
                BinaryPrimitives.WriteUInt32BigEndian(box, freeLength);
                Encoding.ASCII.GetBytes("free").CopyTo(box, 4);
                await file.WriteAsync(box, TestContext.Current.CancellationToken);
                file.SetLength(file.Position + freeLength - box.Length);
            }
            var project = Project("passage-render-v3");
            var prepared = Prepare(project);
            var originalText = project.VoiceLab.Segments[0].Text!.New;
            var pending = VoiceLabDisclosureWriter.StageAsync(source, Path.Combine(folder, "stage.mp4"),
                "published.mp4", project, prepared, "0.1.0", DateTimeOffset.UtcNow,
                TestContext.Current.CancellationToken);
            Assert.False(pending.IsCompleted);
            var segments = (IList<VoiceLabSegment>)project.VoiceLab.Segments;
            segments[0] = segments[0] with { Text = segments[0].Text! with { New = "forged during copy" } };
            var staged = await pending;
            using var json = JsonDocument.Parse(staged.SidecarData);
            Assert.Equal(originalText, json.RootElement.GetProperty("aiSegments")[0].GetProperty("text").GetString());
            Assert.DoesNotContain("forged during copy", Encoding.UTF8.GetString(staged.SidecarData), StringComparison.Ordinal);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MarkedMp4SrtWaveAndSidecarPublishRollBackTogether(bool cancel)
    {
        var folder = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "voxclip-disclosure-publish-" +
            Guid.NewGuid().ToString("N"))).FullName;
        try
        {
            var source = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "bars-1080p.mp4");
            var mp4 = Path.Combine(folder, "published.mp4");
            var srt = Path.Combine(folder, "published.srt");
            var wave = Path.Combine(folder, "published.wav");
            var sidecar = mp4 + ".provenance.json";
            var destinations = new[] { mp4, srt, wave, sidecar };
            var originals = new[] { "old video", "old captions", "old wave", "old provenance" };
            for (var i = 0; i < destinations.Length; i++) File.WriteAllText(destinations[i], originals[i]);
            var project = Project("passage-render-v3");
            var staged = await VoiceLabDisclosureWriter.StageAsync(source, mp4 + ".partial", "published.mp4",
                project, Prepare(project), "0.1.0", DateTimeOffset.UtcNow, TestContext.Current.CancellationToken);
            Assert.Equal("published.mp4.provenance.json", staged.SidecarFilename);
            File.WriteAllText(srt + ".partial", "new captions");
            File.WriteAllText(wave + ".partial", "new wave");
            File.WriteAllBytes(sidecar + ".partial", staged.SidecarData);
            OutputSafety.Validate([source], destinations);
            using var cancellation = new CancellationTokenSource();
            var moved = 0;
            void Move(string from, string to)
            {
                if (!cancel && to == sidecar) throw new IOException("Injected sidecar publication failure");
                File.Move(from, to, true);
                if (cancel && ++moved == 1) cancellation.Cancel();
            }
            if (cancel)
                Assert.ThrowsAny<OperationCanceledException>(() => OutputSafety.Publish(destinations, Move, cancellation.Token));
            else
                Assert.Throws<IOException>(() => OutputSafety.Publish(destinations, Move, cancellation.Token));
            for (var i = 0; i < destinations.Length; i++)
            {
                Assert.Equal(originals[i], File.ReadAllText(destinations[i]));
                Assert.False(File.Exists(destinations[i] + ".partial"));
            }
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task StagesStandardXmpAndFinalHashWithoutPublishingOrTouchingExistingFiles()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-disclosure-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var source = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "bars-1080p.mp4");
            var stage = Path.Combine(root, "render.mp4.partial");
            var destination = Path.Combine(root, "render.mp4");
            File.WriteAllText(destination, "prior destination");
            var project = Project("passage-render-v3");
            var prepared = Prepare(project);
            var result = await VoiceLabDisclosureWriter.StageAsync(source, stage, "render.mp4", project, prepared,
                "0.1.0", DateTimeOffset.Parse("2026-10-26T12:00:00Z"), TestContext.Current.CancellationToken);
            if (Environment.GetEnvironmentVariable("VOXCLIP_DISCLOSURE_EVIDENCE") is { } evidence)
            {
                Directory.CreateDirectory(evidence);
                File.Copy(stage, Path.Combine(evidence, "windows-portable-staged-synthetic-disclosure.mp4"), true);
                File.WriteAllBytes(Path.Combine(evidence, "windows-portable-staged-synthetic-disclosure.provenance.json"), result.SidecarData);
            }
            Assert.Equal("prior destination", File.ReadAllText(destination));
            Assert.Equal("render.mp4.provenance.json", result.SidecarFilename);
            Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(stage))), result.Sha256);
            var packet = ExtractTopLevelXmp(File.ReadAllBytes(stage));
            var document = XDocument.Parse(Encoding.UTF8.GetString(packet));
            XNamespace iptc = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/";
            Assert.Equal(VoiceLabDisclosureWriter.DigitalSourceType,
                document.Descendants().Attributes(iptc + "DigitalSourceType").Single().Value);
            using var sidecar = JsonDocument.Parse(result.SidecarData);
            var rootElement = sidecar.RootElement;
            Assert.Equal("render.mp4", rootElement.GetProperty("export").GetProperty("file").GetString());
            Assert.Equal("0.1.0", rootElement.GetProperty("app").GetProperty("version").GetString());
            Assert.Equal("windows", rootElement.GetProperty("app").GetProperty("platform").GetString());
            Assert.Equal(project.Media.Source.ContentKey, rootElement.GetProperty("source").GetProperty("contentKey").GetString());
            Assert.Equal(result.Sha256, rootElement.GetProperty("export").GetProperty("sha256").GetString());
            Assert.False(rootElement.GetProperty("disclosure").GetProperty("c2pa").GetBoolean());
            Assert.DoesNotContain(project.Media.Source.AbsolutePath, Encoding.UTF8.GetString(result.SidecarData), StringComparison.Ordinal);
            Assert.Throws<IOException>(() => VoiceLabDisclosureWriter.StageAsync(source, stage, "render.mp4", project, prepared,
                "0.1.0", DateTimeOffset.UtcNow, CancellationToken.None).GetAwaiter().GetResult());
            Assert.True(File.Exists(stage));
            var repeated = Path.Combine(root, "repeated.mp4.partial");
            var duplicate = await Assert.ThrowsAsync<InvalidDataException>(() => VoiceLabDisclosureWriter.StageAsync(stage,
                repeated, "render.mp4", project, prepared, "0.1.0", DateTimeOffset.UtcNow, CancellationToken.None));
            Assert.Contains("already contains XMP", duplicate.Message, StringComparison.Ordinal);
            Assert.False(File.Exists(repeated));
            var sizeZero = Path.Combine(root, "size-zero-final-mdat.mp4");
            await using (var file = new FileStream(sizeZero, FileMode.CreateNew))
            {
                await using var sourceFile = File.OpenRead(source);
                await sourceFile.CopyToAsync(file, TestContext.Current.CancellationToken);
                await file.WriteAsync(new byte[] { 0, 0, 0, 0, (byte)'m', (byte)'d', (byte)'a', (byte)'t' }, TestContext.Current.CancellationToken);
            }
            var sizeZeroStage = Path.Combine(root, "size-zero-stage.mp4.partial");
            var rejected = await Assert.ThrowsAsync<InvalidDataException>(() => VoiceLabDisclosureWriter.StageAsync(sizeZero,
                sizeZeroStage, "render.mp4", project, prepared, "0.1.0", DateTimeOffset.UtcNow, CancellationToken.None));
            Assert.Contains("size-zero", rejected.Message, StringComparison.Ordinal);
            Assert.False(File.Exists(sizeZeroStage));
            var paid = Path.Combine(root, "paid-input.wav");
            var paidBytes = Encoding.UTF8.GetBytes("paid input must survive failed staging");
            File.WriteAllBytes(paid, paidBytes);
            var failed = Path.Combine(root, "failed.mp4.partial");
            await Assert.ThrowsAsync<InvalidDataException>(() => VoiceLabDisclosureWriter.StageAsync(paid, failed,
                "render.mp4", project, prepared, "0.1.0", DateTimeOffset.UtcNow, CancellationToken.None));
            Assert.Equal(paidBytes, File.ReadAllBytes(paid));
            Assert.False(File.Exists(failed));
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            var cancelledStage = Path.Combine(root, "cancel.mp4.partial");
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => VoiceLabDisclosureWriter.StageAsync(source, cancelledStage,
                "render.mp4", project, prepared, "0.1.0", DateTimeOffset.UtcNow, cancelled.Token));
            Assert.False(File.Exists(cancelledStage));
            Assert.True(File.Exists(source));
        }
        finally { Directory.Delete(root, true); }
    }

    // Test parser is independent of the writer: traverse ISO BMFF top-level boxes and require the Adobe XMP UUID.
    internal static byte[] ExtractTopLevelXmp(byte[] bytes)
    {
        var cursor = 0; var count = 0;
        while (cursor < bytes.Length)
        {
            Assert.True(bytes.Length - cursor >= 8);
            var size32 = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(cursor, 4));
            var size = size32 switch
            {
                0 => bytes.Length - cursor,
                1 when bytes.Length - cursor >= 16 => checked((int)BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(cursor + 8, 8))),
                _ => checked((int)size32)
            };
            Assert.InRange(size, size32 == 1 ? 16 : 8, bytes.Length - cursor);
            if (Encoding.ASCII.GetString(bytes, cursor + 4, 4) == "uuid" && size >= 24 &&
                bytes.AsSpan(cursor + 8, 16).SequenceEqual(Convert.FromHexString("BE7ACFCB97A942E89C71999491E3AFAC")))
            {
                count++;
                if (count == 1) return bytes.AsSpan(cursor + 24, size - 24).ToArray();
            }
            cursor += size;
        }
        throw new Xunit.Sdk.XunitException("Standard top-level XMP UUID box was not found.");
    }
}
