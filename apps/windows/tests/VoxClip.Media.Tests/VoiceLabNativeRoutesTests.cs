using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using VoxClip.Cli;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;
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
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeCliExportsPersistedV3WithCombinedOutputs()
    {
        await NativeTest.RequireAsync(windows: true);
        await ShippingRuntimeIdentityTests.MatchShippingReportWhenEvidencePresentAsync();
        var data = Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR");
        NativeTest.Require(!string.IsNullOrWhiteSpace(data), "Set an isolated VOXCLIP_DATA_DIR before running the native CLI route.");
        var ct = TestContext.Current.CancellationToken;
        var (project, _, root) = await NativeCase("passage-render-v3.voxclip", false, new(1280, 720));
        try
        {
            project = project with { Edits = project.Edits with { ActiveClipId = null } };
            var source = Path.Combine(root, Path.GetFileName(project.Media.Source.AbsolutePath));
            File.Copy(project.Media.Source.AbsolutePath, source);
            var sourceKey = await new ProjectStore().ComputeContentKeyAsync(source, null, ct);
            project = project with { Media = project.Media with { Source = project.Media.Source with
            {
                AbsolutePath = source, RelativePath = Path.GetFileName(source), SizeBytes = new FileInfo(source).Length,
                ContentKey = sourceKey
            } } };
            var paid = Path.Combine(data!, "VoiceLab", project.Id);
            Directory.CreateDirectory(paid);
            File.Copy(Path.Combine(root, project.Id, "asset-one.wav"), Path.Combine(paid, "asset-one.wav"), true);
            var projectPath = Path.Combine(root, "persisted.voxclip");
            File.WriteAllText(projectPath, ProjectSerialization.Serialize(project));
            var mp4 = Path.Combine(root, "cli.mp4");
            var wav = Path.Combine(root, "cli.wav");
            var srt = Path.Combine(root, "cli.srt");
            var exit = await AcceptedCli.RunAsync(["--open", projectPath, "--export", mp4,
                "--audio-out", wav, "--srt", srt, "--style", "vox-highlight", "--json"], ct);
            Assert.Equal(0, exit);
            Assert.True(File.Exists(mp4)); Assert.True(File.Exists(wav)); Assert.True(File.Exists(srt));
            Assert.True(File.Exists(mp4 + ".provenance.json"));
            Assert.Equal(336_000L, (new FileInfo(wav).Length - 44) / 8);
            Assert.Contains("compositeWithTrainedAlgorithmicMedia", Encoding.UTF8.GetString(
                VoiceLabDisclosureTests.ExtractTopLevelXmp(File.ReadAllBytes(mp4))), StringComparison.Ordinal);
            using var provenance = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(mp4 + ".provenance.json"));
            Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(mp4))),
                provenance.RootElement.GetProperty("export").GetProperty("sha256").GetString());
            Assert.NotEmpty(File.ReadAllText(srt));
            if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } evidence)
            {
                Directory.CreateDirectory(evidence);
                foreach (var path in new[] { projectPath, mp4, wav, srt, mp4 + ".provenance.json" })
                    File.Copy(path, Path.Combine(evidence, Path.GetFileName(path)), true);
                var stableSource = Path.Combine(evidence, "ui-source.mkv");
                File.Copy(source, stableSource, true);
                var stableProject = project with { Media = project.Media with { Source = project.Media.Source with
                {
                    AbsolutePath = stableSource, RelativePath = Path.GetFileName(stableSource)
                } } };
                var stablePath = Path.Combine(evidence, "ui-project.voxclip");
                await new ProjectStore().SaveAsync(stableProject, stablePath, ct);
                Assert.Equal(stableSource, (await new ProjectStore().LoadAsync(stablePath, ct)).ResolvedMediaPath);
            }
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData("full", 7d, 2.8d)]
    [InlineData("clip", 3.4d, 1.75d)]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeAppPublishedVideoContainsReviewedVoiceAndDisclosure(
        string scope, double duration, double syntheticTime)
    {
        await NativeTest.RequireAsync(windows: true);
        var evidence = Environment.GetEnvironmentVariable("VOXCLIP_APP_EVIDENCE_DIR");
        NativeTest.RequireEvidence(evidence is not null && Directory.Exists(evidence),
            "Set VOXCLIP_APP_EVIDENCE_DIR to the isolated normal App export evidence.");
        var mp4 = Assert.Single(Directory.GetFiles(Path.Combine(evidence!, scope), "*.mp4"));
        var sidecar = mp4 + ".provenance.json";
        using var provenance = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(sidecar));
        Assert.Equal(scope, provenance.RootElement.GetProperty("scope").GetProperty("kind").GetString());
        Assert.Equal(duration, provenance.RootElement.GetProperty("export").GetProperty("durationSeconds").GetDouble());
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(mp4))),
            provenance.RootElement.GetProperty("export").GetProperty("sha256").GetString());
        Assert.Contains("compositeWithTrainedAlgorithmicMedia", Encoding.UTF8.GetString(
            VoiceLabDisclosureTests.ExtractTopLevelXmp(File.ReadAllBytes(mp4))), StringComparison.Ordinal);
        var segment = Assert.Single(provenance.RootElement.GetProperty("aiSegments").EnumerateArray());
        Assert.Equal(scope == "full" ? 2.5 : 1.45,
            segment.GetProperty("outputStart").GetDouble(), 2);
        Assert.Equal(scope == "full" ? 3.2 : 2.15,
            segment.GetProperty("outputEnd").GetDouble(), 2);

        var probed = await new FfmpegMediaProbe().ProbeAsync(mp4, TestContext.Current.CancellationToken);
        Assert.Equal(duration, probed.DurationSeconds, 2);
        Assert.Equal(new PixelSize(1280, 720), probed.OrientedSize);
        using var video = new VideoDecoder(mp4, false);
        var frame = video.ReadAt(scope == "full" ? .45 : .3, true, TestContext.Current.CancellationToken);
        AssertGlyphRegion(frame, 1000, 36);
        AssertCaptionGlyphs(frame);
        var frameEvidence = Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR");
        if (frameEvidence is { Length: > 0 })
        {
            Directory.CreateDirectory(frameEvidence);
            WritePpm(Path.Combine(frameEvidence, $"app-{scope}-decoded.ppm"), frame);
        }
        var generatedFrame = video.ReadAt(syntheticTime, true, TestContext.Current.CancellationToken);
        AssertGlyphRegion(generatedFrame, 1000, 36);
        AssertCaptionGlyphs(generatedFrame);
        if (frameEvidence is { Length: > 0 })
            WritePpm(Path.Combine(frameEvidence, $"app-{scope}-synthetic-decoded.ppm"), generatedFrame);
        using var audio = new AudioDecoder(mp4, 2);
        Assert.Equal(48_000, audio.SampleRate);
        Assert.InRange(DecodedFrequency(audio, syntheticTime), 630, 690);
        Assert.InRange(DecodedFrequency(audio, scope == "full" ? 1d : .5d),
            scope == "full" ? 330 : 390, scope == "full" ? 390 : 450);
    }

    private static void AssertCaptionGlyphs(PixelBuffer frame)
    {
        var pixels = frame.Pixels.Span;
        var bright = 0;
        for (var y = 550; y < 610; y++)
            for (var x = 500; x < 780; x++)
            {
                var offset = y * frame.Stride + x * 4;
                if (pixels[offset] > 195 && pixels[offset + 1] > 195 && pixels[offset + 2] > 195)
                    bright++;
            }
        Assert.True(bright > 100, $"The decoded App export has no caption glyphs: {bright} bright pixels.");
    }

    [Theory]
    [InlineData("full")]
    [InlineData("clip")]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeAppPublishedVideoUsesScopedSourceFrameOrder(string scope)
    {
        await NativeTest.RequireAsync(windows: true);
        var evidence = Environment.GetEnvironmentVariable("VOXCLIP_DYNAMIC_APP_EVIDENCE_DIR");
        NativeTest.RequireEvidence(evidence is not null && Directory.Exists(evidence),
            "Set VOXCLIP_DYNAMIC_APP_EVIDENCE_DIR to the isolated dynamic-source App export evidence.");
        var projectPath = Path.Combine(evidence!, "dynamic-project.voxclip");
        var project = (await new ProjectStore().LoadAsync(projectPath, TestContext.Current.CancellationToken)).Project;
        var prepared = VoiceLabRenderContract.Prepare(project,
            scope == "full" ? VoiceLabOutputScope.Full : VoiceLabOutputScope.Clip("clip-main"),
            VoiceLabLabelPosition.TopRight);
        var mp4 = Assert.Single(Directory.GetFiles(Path.Combine(evidence!, scope), "*.mp4"));
        using var source = new VideoDecoder(project.Media.Source.AbsolutePath, false);
        using var output = new VideoDecoder(mp4, false);
        Assert.Equal(160, output.Width); Assert.Equal(90, output.Height);
        var report = new List<string>();
        foreach (var editedTime in scope == "full" ? new[] { .4, 2.8, 5.2 } : new[] { .4, 1.8, 3.0 })
        {
            var sourceTime = prepared.OutputPlan.SourceTime(editedTime);
            var exported = output.ReadAt(editedTime, false, TestContext.Current.CancellationToken);
            var expected = FrameDifference(exported,
                source.ReadAt(sourceTime, false, TestContext.Current.CancellationToken));
            var wrong = FrameDifference(exported,
                source.ReadAt(sourceTime + .6, false, TestContext.Current.CancellationToken));
            report.Add($"edited={editedTime:F2} source={sourceTime:F2} matching={expected:F2} wrong={wrong:F2}");
            Assert.True(expected < 30 && expected + 3 < wrong,
                $"The App export did not follow the selected source frame at {editedTime:F2}: matching={expected:F2}, wrong={wrong:F2}.");
        }
        if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } frameEvidence)
        {
            Directory.CreateDirectory(frameEvidence);
            File.WriteAllLines(Path.Combine(frameEvidence, $"app-{scope}-frame-map.txt"), report);
        }
    }

    private static double FrameDifference(PixelBuffer left, PixelBuffer right)
    {
        var a = left.Pixels.Span; var b = right.Pixels.Span;
        double total = 0; var count = 0;
        // The upper-left centre stays clear of the top-right disclosure and lower captions.
        for (var y = 15; y < 60; y++)
            for (var x = 8; x < 95; x++)
            {
                var i = y * left.Stride + x * 4;
                var j = y * right.Stride + x * 4;
                for (var channel = 0; channel < 3; channel++) { total += Math.Abs(a[i + channel] - b[j + channel]); count++; }
            }
        return total / count;
    }

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
        await ShippingRuntimeIdentityTests.MatchShippingReportWhenEvidencePresentAsync();
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
        await ShippingRuntimeIdentityTests.MatchShippingReportWhenEvidencePresentAsync();
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
        await ShippingRuntimeIdentityTests.MatchShippingReportWhenEvidencePresentAsync();
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
        await ShippingRuntimeIdentityTests.MatchShippingReportWhenEvidencePresentAsync();
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false,
            storedStretch: stretch);
        try
        {
            var paid = Path.Combine(root, project.Id, "asset-one.wav");
            var paidHash = SHA256.HashData(File.ReadAllBytes(paid));
            var scratchRoot = Path.Combine(root, "scratch");
            Directory.CreateDirectory(scratchRoot);
            if (accepted)
            {
                var output = Path.Combine(root, "unity.wav");
                await EditedWaveWriter.WriteAsync(snapshot, output, TestContext.Current.CancellationToken, true, scratchRoot);
                Assert.Equal(44 + 336_000L * 8, new FileInfo(output).Length);
                Assert.InRange(WaveFrequency(output, 2.8), 630, 690);
            }
            else
            {
                var output = Path.Combine(root, "refused.wav");
                var refusal = await Assert.ThrowsAsync<VoiceLabTempoException>(() =>
                    EditedWaveWriter.WriteAsync(snapshot, output, TestContext.Current.CancellationToken, true, scratchRoot));
                Assert.Contains("which VoxClip does not support", refusal.Message, StringComparison.Ordinal);
                Assert.False(File.Exists(output)); Assert.False(File.Exists(output + ".partial"));
            }
            Assert.Empty(Directory.EnumerateFileSystemEntries(scratchRoot));
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
        NativeTest.RequireAudioOutput();
        await ShippingRuntimeIdentityTests.MatchShippingReportWhenEvidencePresentAsync();
        var ct = TestContext.Current.CancellationToken;
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false);
        var scratchBefore = Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*").ToHashSet(StringComparer.OrdinalIgnoreCase);
        try
        {
            await using (var preview = new PreviewEngine())
            {
                var muted = false;
                preview.AudioStatusChanged += (_, status) => muted |= status != PreviewAudioStatus.Available;
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
                Assert.False(muted, "The device clock must drive this run; the muted fallback took over.");
                await preview.LoadAsync(snapshot, null, ct); // replacement closes the former reader and audio owner
            }
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
            Assert.DoesNotContain(Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*"),
                path => !scratchBefore.Contains(path));
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData(Invalidated)]
    [InlineData(InUse)] // another app took the endpoint in exclusive mode and released it before the reopen
    [Trait("Category", "RequiresFFmpeg")]
    public async Task PreviewLostOutputReopensTheDefaultDeviceAtTheLostFrame(int loss)
    {
        await NativeTest.RequireAsync();
        var ct = TestContext.Current.CancellationToken;
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false);
        var scratchBefore = Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*").ToHashSet(StringComparer.OrdinalIgnoreCase);
        try
        {
            PreviewOutput[] outputs = [new(), new()]; // headphones, then the speakers Windows makes the default
            var opened = 0;
            var statuses = new System.Collections.Concurrent.ConcurrentQueue<PreviewAudioStatus>();
            await using (var preview = new PreviewEngine(new PreviewComposer(), initialize: _ => { },
                createWorker: (_, _) => new PreviewWorker(), createAudio: () => outputs[opened++]))
            {
                IPreviewEngine contract = preview;
                contract.AudioStatusChanged += (_, status) => statuses.Enqueue(status);
                await preview.LoadAsync(snapshot, null, ct);
                await preview.SeekAsync(2.7, true, ct);
                await preview.PlayAsync(ct);
                await Task.Delay(250, ct);
                Assert.True(preview.Position.EditedTime > 2.8, $"The device clock did not advance: {preview.Position.EditedTime}");
                outputs[0].Fail(CoreAudio(loss));
                var lost = 2.7 + outputs[0].FramesPlayed / 48_000d;
                await outputs[1].Started.WaitAsync(TimeSpan.FromSeconds(5), ct);
                Assert.True(preview.Position.IsPlaying);
                await Task.Delay(150, ct);
                await preview.PauseAsync(ct);
                // Both device clocks stop on pause, so the reopened clock must continue exactly from the lost frame.
                var expected = lost + outputs[1].FramesPlayed / 48_000d;
                Assert.InRange(preview.Position.EditedTime, expected - Frame, expected + Frame);
                Assert.Empty(statuses);
            }
            Assert.Equal(2, opened);
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
            Assert.DoesNotContain(Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*"),
                path => !scratchBefore.Contains(path));
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData(Invalidated, NotFound, PreviewAudioStatus.NoOutputDevice)]
    [InlineData(Invalidated, InUse, PreviewAudioStatus.OutputInUse)] // an exclusive-mode app took over the shared stream
    [InlineData(InUse, InUse, PreviewAudioStatus.OutputInUse)]
    [Trait("Category", "RequiresFFmpeg")]
    public async Task PreviewLostOutputWithoutReplacementPlaysMutedUntilTheNextPlay(int loss, int reopen, PreviewAudioStatus expected)
    {
        await NativeTest.RequireAsync();
        var ct = TestContext.Current.CancellationToken;
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false);
        var scratchBefore = Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*").ToHashSet(StringComparer.OrdinalIgnoreCase);
        try
        {
            PreviewOutput[] outputs = [new(), new()];
            var opens = new Queue<Func<IPreviewAudioOutput>>([() => outputs[0], () => throw CoreAudio(reopen), () => outputs[1]]);
            var statuses = new System.Collections.Concurrent.ConcurrentQueue<PreviewAudioStatus>();
            var reported = new TaskCompletionSource<long>(TaskCreationOptions.RunContinuationsAsynchronously);
            await using (var preview = new PreviewEngine(new PreviewComposer(), initialize: _ => { },
                createWorker: (_, _) => new PreviewWorker(), createAudio: () => opens.Dequeue()()))
            {
                IPreviewEngine contract = preview;
                contract.AudioStatusChanged += (_, status) =>
                {
                    statuses.Enqueue(status);
                    reported.TrySetResult(System.Diagnostics.Stopwatch.GetTimestamp());
                };
                await preview.LoadAsync(snapshot, null, ct);
                await preview.SeekAsync(2.7, true, ct);
                await preview.PlayAsync(ct);
                await Task.Delay(250, ct);
                Assert.True(preview.Position.EditedTime > 2.8, $"The device clock did not advance: {preview.Position.EditedTime}");
                outputs[0].Fail(CoreAudio(loss));
                var lost = 2.7 + outputs[0].FramesPlayed / 48_000d;
                var status = await reported.Task.WaitAsync(TimeSpan.FromSeconds(5), ct);
                Assert.True(preview.Position.IsPlaying);
                Assert.Contains(Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*"), path => !scratchBefore.Contains(path));
                await Task.Delay(250, ct);
                var before = System.Diagnostics.Stopwatch.GetElapsedTime(status).TotalSeconds;
                await preview.PauseAsync(ct);
                var after = System.Diagnostics.Stopwatch.GetElapsedTime(status).TotalSeconds;
                // The failed reopen reports the status and restarts the muted clock at the lost frame, so at the pause the clock
                // has run as long as the status has existed, to within a frame.
                var paused = preview.Position.EditedTime;
                Assert.InRange(paused, lost + before - Frame, lost + after + Frame);
                await Task.Delay(100, ct);
                Assert.Equal(paused, preview.Position.EditedTime);
                await preview.SeekAsync(3.6, true, ct);
                Assert.InRange(preview.Position.EditedTime, 3.59, 3.61);
                await preview.PlayAsync(ct); // the device is back, so this Play reopens it
                Assert.Equal([expected, PreviewAudioStatus.Available], statuses);
                await Task.Delay(200, ct);
                Assert.True(preview.Position.EditedTime > 3.7, $"The reopened device clock did not advance: {preview.Position.EditedTime}");
                Assert.True(outputs[1].FramesPlayed > 0);
            }
            Assert.Empty(opens);
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
            Assert.DoesNotContain(Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*"),
                path => !scratchBefore.Contains(path));
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData(false)] // the playing device fails
    [InlineData(true)] // the playing device is lost and its one reopen fails
    [Trait("Category", "RequiresFFmpeg")]
    public async Task PreviewFatalDeviceErrorFailsTheStartAndFaultsPlayback(bool duringReopen)
    {
        await NativeTest.RequireAsync();
        var ct = TestContext.Current.CancellationToken;
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false);
        var scratchBefore = Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*").ToHashSet(StringComparer.OrdinalIgnoreCase);
        try
        {
            PreviewOutput[] outputs = [new(), new()];
            var opens = new Queue<Func<IPreviewAudioOutput>>([() => new PreviewOutput(CoreAudio(UnsupportedFormat)), () => outputs[0]]);
            if (duringReopen) opens.Enqueue(() => new PreviewOutput(CoreAudio(UnsupportedFormat)));
            opens.Enqueue(() => outputs[1]);
            var statuses = new System.Collections.Concurrent.ConcurrentQueue<PreviewAudioStatus>();
            var faulted = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
            await using (var preview = new PreviewEngine(new PreviewComposer(), initialize: _ => { },
                createWorker: (_, _) => new PreviewWorker(), createAudio: () => opens.Dequeue()()))
            {
                IPreviewEngine contract = preview;
                contract.AudioStatusChanged += (_, status) => statuses.Enqueue(status);
                contract.PlaybackFaulted += (_, fault) => faulted.TrySetResult(fault);
                await preview.LoadAsync(snapshot, null, ct);
                await preview.SeekAsync(2.7, true, ct);
                // A start whose device fails Init throws, and playback stays stopped.
                var start = await Assert.ThrowsAnyAsync<COMException>(() => preview.PlayAsync(ct));
                Assert.Equal(UnsupportedFormat, start.HResult);
                Assert.False(preview.Position.IsPlaying);
                await preview.PlayAsync(ct); // the next start tries the device again
                await Task.Delay(250, ct);
                Assert.True(preview.Position.EditedTime > 2.8, $"The device clock did not advance: {preview.Position.EditedTime}");
                outputs[0].Fail(CoreAudio(duringReopen ? Invalidated : BufferError));
                var lost = 2.7 + outputs[0].FramesPlayed / 48_000d;
                var fault = await faulted.Task.WaitAsync(TimeSpan.FromSeconds(5), ct);
                Assert.Equal(duringReopen ? UnsupportedFormat : BufferError, fault.HResult);
                Assert.False(preview.Position.IsPlaying);
                Assert.InRange(preview.Position.EditedTime, lost - Frame, lost + Frame);
                Assert.Empty(statuses); // a fatal error never mutes playback
                // The fault fails the next start once; the start after it opens the device again.
                Assert.Same(fault, await Assert.ThrowsAnyAsync<COMException>(() => preview.PlayAsync(ct)));
                await preview.PlayAsync(ct);
                await outputs[1].Started.WaitAsync(TimeSpan.FromSeconds(5), ct);
                Assert.True(preview.Position.IsPlaying);
            }
            Assert.Empty(opens);
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
            Assert.DoesNotContain(Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*"),
                path => !scratchBefore.Contains(path));
        }
        finally { Directory.Delete(root, true); }
    }

    /// <summary>Who sees a device loss before the owner's clock tick does.</summary>
    public enum LossSeenBy
    {
        /// <summary>A pause reads the clock of a device whose owner has already failed.</summary>
        Pause,
        /// <summary>The device's pause call fails before its owner reports the loss.</summary>
        PauseCall,
        /// <summary>A seek while playing, which pauses first.</summary>
        Seek,
        /// <summary>A plan change while playing, which pauses first.</summary>
        PlanChange,
    }

    [Theory]
    [InlineData(LossSeenBy.Pause, 0)]
    [InlineData(LossSeenBy.Pause, NotFound)]
    [InlineData(LossSeenBy.Pause, InUse)]
    [InlineData(LossSeenBy.Pause, UnsupportedFormat)]
    [InlineData(LossSeenBy.PauseCall, 0)]
    [InlineData(LossSeenBy.PauseCall, NotFound)]
    [InlineData(LossSeenBy.PauseCall, InUse)]
    [InlineData(LossSeenBy.PauseCall, UnsupportedFormat)]
    [InlineData(LossSeenBy.Seek, 0)]
    [InlineData(LossSeenBy.Seek, NotFound)]
    [InlineData(LossSeenBy.Seek, InUse)]
    [InlineData(LossSeenBy.Seek, UnsupportedFormat)]
    [InlineData(LossSeenBy.PlanChange, 0)]
    [InlineData(LossSeenBy.PlanChange, NotFound)]
    [InlineData(LossSeenBy.PlanChange, InUse)]
    [InlineData(LossSeenBy.PlanChange, UnsupportedFormat)]
    [Trait("Category", "RequiresFFmpeg")]
    public async Task PreviewLossFirstSeenByACommandIsHandledAsOnTheOwnerTick(LossSeenBy seenBy, int reopen)
    {
        await NativeTest.RequireAsync();
        var ct = TestContext.Current.CancellationToken;
        var (project, snapshot, root) = await NativeCase("passage-render-v3.voxclip", false);
        var scratchBefore = Directory.GetDirectories(Path.GetTempPath(), "voxclip-voice-*").ToHashSet(StringComparer.OrdinalIgnoreCase);
        try
        {
            var device = new PreviewOutput();
            // The playing device and its one reopen (0: the reopen opens a device); every later start finds a working device.
            var opens = new Queue<Func<IPreviewAudioOutput>>([() => device, reopen switch
            {
                0 => () => new PreviewOutput(),
                UnsupportedFormat => () => new PreviewOutput(CoreAudio(reopen)),
                _ => () => throw CoreAudio(reopen),
            }]);
            var later = new System.Collections.Concurrent.ConcurrentQueue<PreviewOutput>();
            var attempts = 0;
            var statuses = new System.Collections.Concurrent.ConcurrentQueue<PreviewAudioStatus>();
            var faults = new System.Collections.Concurrent.ConcurrentQueue<Exception>();
            var composer = new GatedComposer();
            await using (var preview = new PreviewEngine(composer, initialize: _ => { }, createWorker: (_, _) => new PreviewWorker(),
                createAudio: () =>
                {
                    attempts++;
                    if (opens.TryDequeue(out var open)) return open();
                    var output = new PreviewOutput();
                    later.Enqueue(output);
                    return output;
                }))
            {
                IPreviewEngine contract = preview;
                contract.AudioStatusChanged += (_, status) => statuses.Enqueue(status);
                contract.PlaybackFaulted += (_, fault) => faults.Enqueue(fault);
                await preview.LoadAsync(snapshot, null, ct);
                await preview.SeekAsync(2.7, true, ct);
                await preview.PlayAsync(ct);
                await Task.Delay(250, ct);
                double lost;
                Task command;
                if (seenBy == LossSeenBy.PauseCall)
                {
                    // The clock stops but the owner has not reported the loss, so only the pause call can see it.
                    device.FailNextPause(CoreAudio(Invalidated));
                    lost = 2.7 + device.FramesPlayed / 48_000d;
                    command = preview.PauseAsync(ct);
                }
                else
                {
                    // Hold the owner inside a frame while the device fails and the command queues: the command sees the loss first.
                    await composer.HoldAsync(ct);
                    device.Fail(CoreAudio(Invalidated));
                    lost = 2.7 + device.FramesPlayed / 48_000d;
                    command = seenBy switch
                    {
                        LossSeenBy.Pause => preview.PauseAsync(ct),
                        LossSeenBy.Seek => preview.SeekAsync(4.2, true, ct),
                        _ => preview.UpdateSnapshotAsync(snapshot, ct),
                    };
                    composer.Release();
                }
                await command; // completes whatever the reopen does, so the editor keeps its preview
                var fatal = reopen == UnsupportedFormat;
                var resumed = !fatal && seenBy is LossSeenBy.Seek or LossSeenBy.PlanChange;
                var start = seenBy == LossSeenBy.Seek ? 4.2 : lost;
                Assert.Equal(resumed, preview.Position.IsPlaying);
                if (!resumed) Assert.InRange(preview.Position.EditedTime, start - Frame, start + Frame);
                if (fatal)
                {
                    // One fault from the failed reopen; the next start rethrows it once.
                    var fault = Assert.Single(faults);
                    Assert.Equal(UnsupportedFormat, fault.HResult);
                    Assert.Same(fault, await Assert.ThrowsAnyAsync<COMException>(() => preview.PlayAsync(ct)));
                }
                if (!resumed) await preview.PlayAsync(ct);
                await Task.Delay(150, ct);
                await preview.PauseAsync(ct);
                // Every device clock stops on pause, so the playhead is the start plus what the working device played.
                var expected = start + Assert.Single(later).FramesPlayed / 48_000d;
                Assert.InRange(preview.Position.EditedTime, expected - Frame, expected + Frame);
                Assert.Equal(fatal ? 1 : 0, faults.Count);
                PreviewAudioStatus[] reported = reopen is NotFound or InUse
                    ? [reopen == InUse ? PreviewAudioStatus.OutputInUse : PreviewAudioStatus.NoOutputDevice, PreviewAudioStatus.Available]
                    : [];
                Assert.Equal(reported, statuses);
            }
            Assert.Equal(3, attempts); // the playing device, exactly one reopen, and one later start
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
