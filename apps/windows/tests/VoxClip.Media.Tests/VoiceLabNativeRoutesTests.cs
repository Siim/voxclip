using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using VoxClip.Cli;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Settings;
using VoxClip.Media.Audio;
using VoxClip.Media.Captions;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed partial class VoiceLabAudioMixerTests
{
    private static async Task<(Project Project, ComposeSnapshot Snapshot, string Root)> NativeCase(
        string fixture, bool distinctSecondAsset, PixelSize? outputSize = null, double? storedStretch = null)
    {
        var source = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab",
            outputSize is { Width: 1280, Height: 720 } ? "voice-lab-7s-720p.mkv" : "voice-lab-7s.mkv");
        NativeTest.Require(File.Exists(source), "The committed seven-second source is missing.");
        var probed = await new FfmpegMediaProbe().ProbeAsync(source, TestContext.Current.CancellationToken);
        var original = Fixture(fixture);
        if (storedStretch is { } stretch)
        {
            original = VoiceLabTempo.RequiresFit(stretch) ? WithNonUnityFit(original, stretch) :
                original with { VoiceLab = original.VoiceLab with
                {
                    Segments = original.VoiceLab.Segments.Select(segment => segment with
                    {
                        Audio = segment.Audio with { Stretch = stretch },
                        Candidates = segment.Candidates.Select(candidate => candidate.Recipe is { } recipe
                            ? candidate with { Recipe = recipe with { Audio = recipe.Audio with { Stretch = stretch } } }
                            : candidate).ToArray()
                    }).ToArray()
                } };
        }
        var baseProject = At48k(original);
        baseProject = baseProject with { Media = baseProject.Media with { Source = baseProject.Media.Source with
        {
            AbsolutePath = source, RelativePath = Path.GetFileName(source), SizeBytes = new FileInfo(source).Length,
            Video = probed.Video, Audio = probed.Audio
        } } };
        var full = fixture.StartsWith("full-take", StringComparison.Ordinal);
        var frames = full ? 172_800 : 21_600;
        var (project, root) = Asset(baseProject, frames, at: frame => Tone(frame,
            full && frame >= 86_400 ? 880 : 660));
        if (distinctSecondAsset)
        {
            const int secondFrames = 24_000;
            var bytes = Wave(secondFrames, 24_000, 0, frame => Tone(frame, 930));
            File.WriteAllBytes(Path.Combine(root, project.Id, "asset-two.wav"), bytes);
            var hash = Convert.ToHexStringLower(SHA256.HashData(bytes));
            var assets = project.VoiceLab.Assets!.Select(asset => asset.Id == "asset-two"
                ? asset with { Sha256 = hash, DurationSeconds = secondFrames / 24_000d } : asset).ToArray();
            var segments = project.VoiceLab.Segments.Select(segment => segment with
            {
                Audio = segment.Id == "vl-follow" ? segment.Audio with { AssetId = "asset-two" } : segment.Audio,
                Candidates = segment.Candidates.Select(candidate => candidate.Recipe is not { } recipe ? candidate : candidate with
                {
                    AssetId = segment.Id == "vl-follow" ? "asset-two" : candidate.AssetId,
                    Recipe = recipe with
                    {
                        Audio = segment.Id == "vl-follow" ? recipe.Audio with { AssetId = "asset-two" } : recipe.Audio,
                        Chunks = recipe.Chunks.Select(chunk => chunk.AssetId == "asset-two" || segment.Id == "vl-follow"
                            ? chunk with { AssetId = "asset-two", AssetSha256 = hash } : chunk).ToArray()
                    }
                }).ToArray()
            }).ToArray();
            project = project with { VoiceLab = project.VoiceLab with { Assets = assets, Segments = segments } };
        }
        var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
        var input = VoiceLabRenderInput.Capture(project, prepared, root);
        const long total = 7L * 48_000;
        var edit = new EditPlan(48_000, total, [], [new MediaInterval(0, total)], total, []);
        var snapshot = new ComposeSnapshot(probed, edit, null,
            new(outputSize ?? probed.OrientedSize, 30, 2_000_000)) { VoiceLab = input };
        return (project, snapshot, root);
    }

    private static short Tone(int frame, double hz) => (short)Math.Round(20_000 *
        Math.Sin(2 * Math.PI * hz * frame / 24_000));

    [Fact]
    public async Task EmptyWaveTimelineKeepsEverythingCutBeforeCapacityAndPublication()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-empty-wave-").FullName;
        try
        {
            var path = Path.Combine(root, "previous.wav");
            File.WriteAllText(path, "prior bytes");
            var snapshot = new ComposeSnapshot(new MediaInfo(Path.Combine(root, "source.mp4"), 7,
                null, null, new(640, 360), "h264", "aac", false, 0, 1, 0),
                new EditPlan(1000, 7000, [new MediaInterval(0, 7000)], [], 0, []), null,
                new(new(640, 360), 30, 2_000_000));
            VoiceLabCapacity.AvailableBytes.Value = _ => throw new Xunit.Sdk.XunitException(
                "Capacity cannot replace the empty timeline error.");
            var error = await Assert.ThrowsAsync<VoxClipException>(() => EditedWaveWriter.WriteAsync(snapshot,
                path, TestContext.Current.CancellationToken, true));
            Assert.Equal(VoxClipErrorCode.EverythingCut, error.Code);
            Assert.Equal("prior bytes", File.ReadAllText(path));
            Assert.False(File.Exists(path + ".partial"));
        }
        finally { VoiceLabCapacity.AvailableBytes.Value = null; Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData("full-take-render-v3.voxclip", false)]
    [InlineData("touching-render-v3.voxclip", true)]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeFullAndTouchingRoutesUseProductionAudioAndMarkedVideo(string fixture, bool touching)
    {
        await NativeTest.RequireAsync(windows: true);
        await new ShippingRuntimeIdentityTests().LoadedModulesMatchShippingReport();
        var ct = TestContext.Current.CancellationToken;
        var (project, snapshot, root) = await NativeCase(fixture, touching,
            touching ? null : new PixelSize(1280, 720));
        try
        {
            Assert.Equal(touching ? 2 : 1, snapshot.VoiceLab!.Prepared.SelectedSegmentRecipes.Count);
            if (!touching) Assert.Equal(2, snapshot.VoiceLab.Prepared.SelectedSegmentRecipes[0].Recipe.Chunks.Count);
            var wave = Path.Combine(root, touching ? "touching.wav" : "full.wav");
            await EditedWaveWriter.WriteAsync(snapshot, wave, ct, true);
            Assert.Equal(44 + 336_000L * 8, new FileInfo(wave).Length);
            if (touching)
            {
                Assert.InRange(WaveFrequency(wave, 2.85), 640, 680);
                Assert.InRange(WaveFrequency(wave, 3.32), 900, 960);
                Assert.InRange(WaveFrequency(wave, 2.25), 400, 460);
                Assert.InRange(WaveFrequency(wave, 3.7), 500, 550);
                Assert.True(WindowRms(wave, 3.195, .010) > .10, "The touching seam lost its outgoing samples.");
                Assert.True(WindowRms(wave, 3.205, .010) > .10, "The touching seam lost its incoming samples.");
            }
            else
            {
                Assert.InRange(WaveFrequency(wave, 1), 640, 680);
                Assert.InRange(WaveFrequency(wave, 4), 850, 910);
                Assert.True(WindowRms(wave, 3.495, .010) > .25, "The first chunk's end is missing.");
                Assert.True(WindowRms(wave, 3.505, .010) > .25, "The second chunk's start is missing.");
            }
            var mp4 = Path.Combine(root, touching ? "touching.mp4" : "full.mp4");
            var result = await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(),
                ExportAspect.Source, ExportQuality.Standard, mp4, null), null, ct);
            Assert.Equal(210, result.Frames);
            Assert.Equal(336_000, result.AudioSamples);
            var sidecar = mp4 + ".provenance.json";
            Assert.Contains("compositeWithTrainedAlgorithmicMedia", Encoding.UTF8.GetString(
                VoiceLabDisclosureTests.ExtractTopLevelXmp(File.ReadAllBytes(mp4))), StringComparison.Ordinal);
            using (var data = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(sidecar)))
                Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(mp4))),
                    data.RootElement.GetProperty("export").GetProperty("sha256").GetString());
            using (var decoded = new AudioDecoder(mp4, 2))
            {
                Assert.Equal(48_000, decoded.SampleRate);
                if (touching)
                {
                    Assert.InRange(DecodedFrequency(decoded, 2.85), 630, 690);
                    Assert.InRange(DecodedFrequency(decoded, 3.32), 890, 970);
                }
                else
                {
                    Assert.InRange(DecodedFrequency(decoded, 1), 630, 690);
                    Assert.InRange(DecodedFrequency(decoded, 4), 840, 920);
                }
            }
            if (!touching) await AssertRealSizeDisclosure(snapshot, mp4, ct);
            if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } evidence)
            {
                Directory.CreateDirectory(evidence);
                var label = touching ? "touching" : "full";
                File.Copy(wave, Path.Combine(evidence, label + ".wav"), true);
                File.Copy(mp4, Path.Combine(evidence, label + ".mp4"), true);
                File.Copy(sidecar, Path.Combine(evidence, label + ".provenance.json"), true);
            }
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
            if (touching) Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-two.wav")));
        }
        finally { Directory.Delete(root, true); }
    }

    private static double WindowRms(string wave, double start, double seconds)
    {
        using var file = File.OpenRead(wave);
        using var reader = new BinaryReader(file);
        file.Position = 44 + (long)(start * 48_000) * 8;
        var count = (int)(seconds * 48_000);
        double energy = 0;
        for (var i = 0; i < count; i++) { var sample = reader.ReadSingle(); reader.ReadSingle(); energy += sample * sample; }
        return Math.Sqrt(energy / count);
    }

    private static double DecodedFrequency(AudioDecoder decoder, double seconds)
    {
        decoder.Seek((long)(seconds * decoder.SampleRate));
        var samples = new float[4800 * 2];
        Assert.Equal(4800, decoder.Read(samples, 4800, TestContext.Current.CancellationToken));
        var crossings = 0;
        for (var i = 1; i < 4800; i++)
            if (samples[(i - 1) * 2] <= 0 && samples[i * 2] > 0) crossings++;
        return crossings * 10d;
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeExcludedClipAndDisabledSegmentUseUnmarkedSource(bool disabled)
    {
        await NativeTest.RequireAsync(windows: true);
        await new ShippingRuntimeIdentityTests().LoadedModulesMatchShippingReport();
        var ct = TestContext.Current.CancellationToken;
        var (original, template, root) = await NativeCase("passage-render-v3.voxclip", false);
        try
        {
            var project = disabled ? VoiceLabProject.SetEnabled(original, "vl-passage", false) with
                { Edits = original.Edits with { ActiveClipId = null } } : original;
            var scope = VoiceLabOutputScope.Full;
            ExportTarget target = new ExportTarget.FullEdit();
            if (!disabled)
            {
                var clip = project.Edits.Clips[0] with { StartWordId = "w1", EndWordId = "w2" };
                project = project with { Edits = project.Edits with { Clips = [clip], ActiveClipId = clip.Id } };
                scope = VoiceLabOutputScope.Clip(clip.Id);
                target = new ExportTarget.Clip(clip.Id);
            }
            var prepared = VoiceLabRenderContract.Prepare(project, scope, VoiceLabLabelPosition.TopLeft);
            Assert.False(prepared.OutputPlan.RequiresSyntheticRendering);
            Assert.All(prepared.OutputPlan.Pieces, piece => Assert.Equal(VoiceLabOutputPieceKind.Source, piece.Kind));
            var snapshot = template with { Plan = CliOperations.BuildPlan(project, true),
                VoiceLab = VoiceLabRenderInput.Capture(project, prepared, root) };
            var expected = prepared.OutputPlan.OutputSamples;
            var wave = Path.Combine(root, disabled ? "disabled.wav" : "excluded.wav");
            await EditedWaveWriter.WriteAsync(snapshot, wave, ct, true);
            Assert.Equal(44 + expected * 8, new FileInfo(wave).Length);
            var mp4 = Path.Combine(root, disabled ? "disabled.mp4" : "excluded.mp4");
            var result = await new Exporter().ExportAsync(new(snapshot, target, ExportAspect.Source,
                ExportQuality.Standard, mp4, null), null, ct);
            Assert.Equal(expected, result.AudioSamples);
            Assert.False(File.Exists(mp4 + ".provenance.json"));
            Assert.InRange(WaveFrequency(wave, disabled ? 1 : .35), disabled ? 330 : 310,
                disabled ? 370 : 350);
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeAllOutputPublicationRestoresPriorBytesOnFailureAndCancellation(bool cancel)
    {
        await NativeTest.RequireAsync(windows: true);
        await new ShippingRuntimeIdentityTests().LoadedModulesMatchShippingReport();
        var ct = TestContext.Current.CancellationToken;
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false);
        try
        {
            var mp4 = Path.Combine(root, "transaction.mp4");
            var srt = Path.Combine(root, "transaction.srt");
            var wav = Path.Combine(root, "transaction.wav");
            var sidecar = mp4 + ".provenance.json";
            var destinations = new[] { mp4, srt, wav, sidecar };
            var originals = new[] { "prior mp4", "prior srt", "prior wav", "prior provenance" };
            for (var i = 0; i < destinations.Length; i++) File.WriteAllText(destinations[i], originals[i]);
            await EditedWaveWriter.WriteAsync(snapshot, wav, ct, false);
            Assert.Equal(44 + 336_000L * 8, new FileInfo(wav + ".partial").Length);
            using (var stage = OutputSafety.CreatePartial(srt + ".partial"))
            {
                var bytes = Encoding.UTF8.GetBytes(Exporter.Subtitles(snapshot.Captions));
                stage.Write(bytes);
            }
            var result = await new Exporter().PrepareAsync(new(snapshot, new ExportTarget.FullEdit(),
                ExportAspect.Source, ExportQuality.Standard, mp4, null), null, ct);
            Assert.Equal(336_000, result.AudioSamples);
            Assert.True(File.Exists(mp4 + ".partial")); Assert.True(File.Exists(sidecar + ".partial"));
            var stagedMp4 = File.ReadAllBytes(mp4 + ".partial");
            Assert.Contains("compositeWithTrainedAlgorithmicMedia", Encoding.UTF8.GetString(
                VoiceLabDisclosureTests.ExtractTopLevelXmp(stagedMp4)), StringComparison.Ordinal);
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(ct);
            var moved = 0;
            void Move(string from, string to)
            {
                if (!cancel && to == sidecar) throw new IOException("Injected sidecar publication failure");
                File.Move(from, to, true);
                if (cancel && ++moved == 1) cancellation.Cancel();
            }
            if (cancel)
                Assert.ThrowsAny<OperationCanceledException>(() => OutputSafety.Publish(destinations, Move,
                    cancellation.Token));
            else
                Assert.Throws<IOException>(() => OutputSafety.Publish(destinations, Move, cancellation.Token));
            for (var i = 0; i < destinations.Length; i++)
            {
                Assert.Equal(originals[i], File.ReadAllText(destinations[i]));
                Assert.False(File.Exists(destinations[i] + ".partial"));
            }
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
        }
        finally { Directory.Delete(root, true); }
    }

    private static async Task AssertRealSizeDisclosure(ComposeSnapshot snapshot, string mp4, CancellationToken ct)
    {
        Assert.Equal(new PixelSize(1280, 720), snapshot.Output.Size);
        await using (var preview = new PreviewEngine())
        {
            await preview.LoadAsync(snapshot, null, ct);
            await preview.SeekAsync(.3, true, ct);
            await using var frames = preview.ReadFramesAsync(ct).GetAsyncEnumerator(ct);
            Assert.True(await frames.MoveNextAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(8), ct));
            var frame = frames.Current.Buffer;
            Assert.Equal(1280, frame.Width); Assert.Equal(720, frame.Height);
            AssertGlyphRegion(frame, 64, 36);
            if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } evidence)
                WritePpm(Path.Combine(evidence, "full-preview-1280x720.ppm"), frame);
        }
        using var video = new VideoDecoder(mp4, false);
        var exported = video.ReadAt(.3, true, ct);
        Assert.Equal(1280, exported.Width); Assert.Equal(720, exported.Height);
        AssertGlyphRegion(exported, 64, 36);
        if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } exportEvidence)
            WritePpm(Path.Combine(exportEvidence, "full-decoded-export-1280x720.ppm"), exported);
        var original = snapshot.VoiceLab!.IsolatedProject();
        var project = original with { Captions = original.Captions with
            { Position = new CaptionPosition(.12, .08) } };
        var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full,
            VoiceLabLabelPosition.TopLeft);
        var input = VoiceLabRenderInput.Capture(project, prepared, snapshot.VoiceLab.PaidRoot);
        var style = CaptionStyleLibrary.Load(FixtureLoader.SharedRoot).Find("vox-bold")!;
        var words = prepared.OutputPlan.Captions.Select(word =>
            new CaptionWord(word.Id, word.Text, word.Start, word.End)).ToArray();
        var built = await CaptionEngine.BuildAsync(new(style, project.Captions, snapshot.Output.Size,
            words, project.Transcript?.Language, 7), new HarfBuzzGlyphShaper(FixtureLoader.SharedRoot), null, ct);
        Assert.False(built.OverridesRejected);
        Assert.Equal(new CaptionPosition(.12, .08),
            new CaptionPosition(built.Style.Position.X, built.Style.Position.Y));
        var visible = Assert.Single(built.Pages, page => page.Start <= .3 && page.End > .3);
        var preferredChipRegion = new RectD(64, 36, 205, 37);
        Assert.Contains(built.Pages, page => page.Start < 7 && page.End > 0 &&
            page.Visual.X < preferredChipRegion.X + preferredChipRegion.Width &&
            page.Visual.X + page.Visual.Width > preferredChipRegion.X &&
            page.Visual.Y < preferredChipRegion.Y + preferredChipRegion.Height &&
            page.Visual.Y + page.Visual.Height > preferredChipRegion.Y);
        Assert.True(visible.WordRects.Count > 0, "The colliding page has no shaped caption glyphs.");
        var collision = snapshot with { VoiceLab = input, Captions = built };
        await using (var preview = new PreviewEngine())
        {
            await preview.LoadAsync(collision, null, ct);
            await preview.SeekAsync(.3, true, ct);
            await using var frames = preview.ReadFramesAsync(ct).GetAsyncEnumerator(ct);
            Assert.True(await frames.MoveNextAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(8), ct));
            var frame = frames.Current.Buffer;
            AssertGlyphRegion(frame, 1000, 36);
            using var decoder = new VideoDecoder(snapshot.Media.Path, false);
            var decoded = decoder.ReadAt(.3, true, ct);
            var baseline = new PixelBuffer(new byte[1280 * 720 * 4], 1280, 720, 1280 * 4);
            var captionless = new PixelBuffer(new byte[1280 * 720 * 4], 1280, 720, 1280 * 4);
            var composer = new FrameComposer();
            composer.Compose(decoded, baseline, collision with { VoiceLab = null }, .3, true, ct);
            composer.Compose(decoded, captionless, collision with { VoiceLab = null, Captions = null },
                .3, true, ct);
            var glyph = visible.WordRects[0];
            var glyphX = (int)Math.Floor(glyph.X);
            var glyphY = (int)Math.Floor(glyph.Y);
            var glyphWidth = (int)Math.Ceiling(glyph.W);
            var glyphHeight = (int)Math.Ceiling(glyph.H);
            Assert.True(ChangedPixels(baseline, captionless, glyphX, glyphY, glyphWidth, glyphHeight) > 100,
                "The naturally positioned caption did not render over the preferred chip corner.");
            Assert.InRange(ChangedPixels(frame, baseline, glyphX, glyphY, glyphWidth, glyphHeight), 0, 50);
            Assert.True(ChangedPixels(frame, baseline, 975, 30, 250, 55) > 500,
                "The naturally laid-out caption did not move the chip to the right.");
            composer.ReleaseThreadResources();
            if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } evidence)
                WritePpm(Path.Combine(evidence, "full-preview-collision-1280x720.ppm"), frame);
        }
        var captionedMp4 = Path.Combine(Path.GetDirectoryName(mp4)!, "full-captions.mp4");
        var captionedResult = await new Exporter().ExportAsync(new(collision, new ExportTarget.FullEdit(),
            ExportAspect.Source, ExportQuality.Standard, captionedMp4, null), null, ct);
        Assert.Equal(210, captionedResult.Frames);
        using (var captionedVideo = new VideoDecoder(captionedMp4, false))
        {
            var captionedFrame = captionedVideo.ReadAt(.3, true, ct);
            AssertGlyphRegion(captionedFrame, 1000, 36);
            Assert.True(ChangedPixels(captionedFrame, exported,
                (int)Math.Floor(visible.Visual.X), (int)Math.Floor(visible.Visual.Y),
                (int)Math.Ceiling(visible.Visual.Width), (int)Math.Ceiling(visible.Visual.Height)) > 100,
                "The decoded captioned export did not contain the colliding caption.");
            if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } evidence)
                WritePpm(Path.Combine(evidence, "full-decoded-export-collision-1280x720.ppm"), captionedFrame);
        }
    }

    private static int ChangedPixels(PixelBuffer actual, PixelBuffer baseline, int x, int y, int width, int height)
    {
        var left = actual.Pixels.Span; var right = baseline.Pixels.Span;
        var changed = 0;
        for (var row = y; row < y + height; row++)
            for (var column = x; column < x + width; column++)
            {
                var offset = row * actual.Stride + column * 4;
                if (Math.Abs(left[offset] - right[offset]) + Math.Abs(left[offset + 1] - right[offset + 1]) +
                    Math.Abs(left[offset + 2] - right[offset + 2]) > 45) changed++;
            }
        return changed;
    }

    private static void AssertGlyphRegion(PixelBuffer frame, int x, int y)
    {
        var bytes = frame.Pixels.Span;
        var dark = 0; var brightColumns = 0;
        // A high-contrast chip must have a dark field and separated bright glyph strokes.
        for (var column = x + 8; column < x + 205; column++)
        {
            var hasBright = false;
            for (var row = y + 5; row < y + 37; row++)
            {
                var offset = row * frame.Stride + column * 4;
                var b = bytes[offset]; var g = bytes[offset + 1]; var r = bytes[offset + 2];
                if (r < 65 && g < 65 && b < 65) dark++;
                if (r > 195 && g > 195 && b > 195) hasBright = true;
            }
            if (hasBright) brightColumns++;
        }
        Assert.True(dark > 600, $"The label has no dark chip field at ({x},{y}): {dark} pixels.");
        Assert.True(brightColumns > 45, $"The AI MODIFIED glyph strokes are absent at ({x},{y}): {brightColumns} columns.");
    }

    [Theory]
    [InlineData(1d, true)]
    [InlineData(0.9999999999999999d, true)]
    [InlineData(1.0000000000000002d, true)]
    [InlineData(1.000000001d, false)]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeFinalUnityBoundaryStopsRealFitBeforeSnapshotOrOutput(double stretch, bool accepted)
    {
        await NativeTest.RequireAsync(windows: true);
        await new ShippingRuntimeIdentityTests().LoadedModulesMatchShippingReport();
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false,
            storedStretch: stretch);
        try
        {
            var paid = Path.Combine(root, project.Id, "asset-one.wav");
            var paidHash = SHA256.HashData(File.ReadAllBytes(paid));
            var scratchBefore = Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*")
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (accepted)
            {
                var output = Path.Combine(root, "unity.wav");
                await EditedWaveWriter.WriteAsync(snapshot, output, TestContext.Current.CancellationToken, true);
                Assert.Equal(44 + 336_000L * 8, new FileInfo(output).Length);
                Assert.InRange(WaveFrequency(output, 2.8), 630, 690);
            }
            else
            {
                var output = Path.Combine(root, "refused.wav");
                var refusal = await Assert.ThrowsAsync<VoiceLabTempoException>(() =>
                    EditedWaveWriter.WriteAsync(snapshot, output, TestContext.Current.CancellationToken, true));
                Assert.Contains("unverified body and seam timing", refusal.Message, StringComparison.Ordinal);
                Assert.False(File.Exists(output)); Assert.False(File.Exists(output + ".partial"));
            }
            Assert.DoesNotContain(Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*"),
                path => !scratchBefore.Contains(path));
            Assert.Equal(paidHash, SHA256.HashData(File.ReadAllBytes(paid)));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativePreviewPlaysPausesSeeksAndReleasesSynthLease()
    {
        await NativeTest.RequireAsync(windows: true);
        await new ShippingRuntimeIdentityTests().LoadedModulesMatchShippingReport();
        var ct = TestContext.Current.CancellationToken;
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false);
        var scratchBefore = Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*").ToHashSet(StringComparer.OrdinalIgnoreCase);
        try
        {
            await using (var preview = new PreviewEngine())
            {
                await preview.LoadAsync(snapshot, null, ct);
                await preview.SeekAsync(2.7, true, ct);
                await preview.PlayAsync(ct);
                await Task.Delay(350, ct);
                Assert.True(preview.Position.EditedTime > 2.74,
                    $"WASAPI callback did not advance the production clock: {preview.Position.EditedTime}");
                await preview.PauseAsync(ct);
                var paused = preview.Position.EditedTime;
                await Task.Delay(100, ct);
                Assert.InRange(preview.Position.EditedTime, paused - .01, paused + .01);
                await preview.SeekAsync(3.6, true, ct);
                Assert.InRange(preview.Position.EditedTime, 3.59, 3.61);
                await preview.PlayAsync(ct);
                await Task.Delay(200, ct);
                Assert.True(preview.Position.EditedTime > 3.63);
                await preview.LoadAsync(snapshot, null, ct); // replacement closes the former reader and audio owner
            }
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
            Assert.DoesNotContain(Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*"),
                path => !scratchBefore.Contains(path));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeVolumeGuidAndJunctionAliasShareTheSameCapacityPool()
    {
        await NativeTest.RequireAsync(windows: true);
        var folder = Directory.CreateTempSubdirectory("voxclip-native-volume-").FullName;
        var junction = folder + "-junction";
        try
        {
            var drive = Path.GetPathRoot(folder)!;
            var identity = new StringBuilder(64);
            Assert.True(GetVolumeNameForVolumeMountPoint(drive, identity, identity.Capacity),
                $"Cannot identify owned scratch volume: {Marshal.GetLastWin32Error()}");
            var alias = Path.Combine(identity.ToString(), folder[drive.Length..]);
            var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", $"/d /c mklink /J \"{junction}\" \"{folder}\"")
            { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true })!;
            Assert.True(process.WaitForExit(10_000) && process.ExitCode == 0,
                "Creating the owned scratch junction failed: " + process.StandardError.ReadToEnd());
            Assert.True(Directory.Exists(alias)); Assert.True(Directory.Exists(junction));
            var queried = new List<string>();
            VoiceLabCapacity.VolumeIdentity.Value = null; // exercise the Windows resolver itself
            VoiceLabCapacity.AvailableBytes.Value = root => { queried.Add(root); return 9; };
            Assert.Equal(VoxClipErrorCode.DiskFull, Assert.Throws<VoxClipException>(() =>
                VoiceLabCapacity.Require([new(Path.Combine(folder, "one"), 4),
                    new(Path.Combine(alias, "two"), 3), new(Path.Combine(junction, "three"), 3)])).Code);
            Assert.Single(queried);
            Assert.Equal(identity.ToString(), queried[0], ignoreCase: true);
        }
        finally
        {
            VoiceLabCapacity.VolumeIdentity.Value = null;
            VoiceLabCapacity.AvailableBytes.Value = null;
            if (Directory.Exists(junction)) Directory.Delete(junction);
            Directory.Delete(folder, true);
        }
    }

    [DllImport("kernel32.dll", EntryPoint = "GetVolumeNameForVolumeMountPointW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeNameForVolumeMountPoint(string mount, StringBuilder name, int length);
}
