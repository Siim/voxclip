using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using VoxClip.Cli;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Core.Services.Media;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed partial class VoiceLabAudioMixerTests
{
    private static Project Fixture(string name) => ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(
        FixtureLoader.SharedRoot, "fixtures", "voice-lab", name)));

    private static byte[] Wave(int frames, int rate, short sample, Func<int, short>? at = null)
    {
        using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8); writer.Write(36 + frames * 2); writer.Write("WAVEfmt "u8); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(rate); writer.Write(rate * 2);
        writer.Write((short)2); writer.Write((short)16); writer.Write("data"u8); writer.Write(frames * 2);
        for (var i = 0; i < frames; i++) writer.Write(at?.Invoke(i) ?? sample);
        return stream.ToArray();
    }

    private static (Project project, string root) Asset(Project project, int frames = 21_600, short sample = 16_384,
        Func<int, short>? at = null)
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-mix-test-" + Guid.NewGuid().ToString("N"));
        var directory = Directory.CreateDirectory(Path.Combine(root, project.Id));
        var wav = Wave(frames, 24_000, sample, at);
        File.WriteAllBytes(Path.Combine(directory.FullName, "asset-one.wav"), wav);
        var hash = Convert.ToHexStringLower(SHA256.HashData(wav));
        var assets = project.VoiceLab.Assets!.Select(a => a.Id == "asset-one" ? a with
            { Sha256 = hash, DurationSeconds = frames / 24_000d } : a).ToArray();
        var segments = project.VoiceLab.Segments.Select(segment => segment with
        {
            Candidates = segment.Candidates.Select(candidate => candidate.Recipe is { } recipe ? candidate with
            { Recipe = recipe with { Chunks = recipe.Chunks.Select(chunk => chunk.AssetId == "asset-one"
                ? chunk with { AssetSha256 = hash } : chunk).ToArray() } } : candidate).ToArray()
        }).ToArray();
        return (project with { VoiceLab = project.VoiceLab with { Assets = assets, Segments = segments } }, root);
    }

    private sealed class Source(float[] samples) : IVoiceLabSource
    {
        public void Read(long startSample, Span<float> stereo, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            samples.AsSpan(checked((int)startSample * 2), stereo.Length).CopyTo(stereo);
        }
    }

    private sealed class BlockingSeamSource : IVoiceLabSource
    {
        internal readonly ManualResetEventSlim Entered = new(false);
        public void Read(long startSample, Span<float> stereo, CancellationToken ct)
        {
            if (startSample == 2490)
            {
                Entered.Set();
                ct.WaitHandle.WaitOne();
                ct.ThrowIfCancellationRequested();
            }
            stereo.Fill(0.2f);
        }
    }

    private sealed class PreviewWorker : IPreviewVideoWorker
    {
        public Task Ready => Task.CompletedTask;
        public double Position { get; private set; }
        public Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            Position = source;
            return Task.FromResult(new PixelBuffer(new byte[16], 2, 2, 8));
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class PreviewComposer : IFrameComposer
    {
        public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime,
            bool forPreview, CancellationToken ct) => output.Pixels.Span.Clear();
    }

    private sealed class CancelOnCompose(CancellationTokenSource cancellation) : IFrameComposer
    {
        public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime,
            bool forPreview, CancellationToken ct)
        { cancellation.Cancel(); ct.ThrowIfCancellationRequested(); }
    }

    private sealed class NoEncoderProbe : IEncoderProbe
    {
        public Task<IReadOnlyList<EncoderInfo>> ProbeAsync(EncoderCacheKey key,
            IProgress<MediaProgress>? progress, CancellationToken ct)
            => throw new Xunit.Sdk.XunitException("Encoder probing must not start before paid asset validation.");
    }

    private static Project At48k(Project project)
    {
        const long scale = 48;
        var segments = project.VoiceLab.Segments.Select(segment => segment with
        {
            Candidates = segment.Candidates.Select(candidate => candidate.Recipe is { } recipe ? candidate with
            {
                Recipe = recipe with
                {
                    Chunks = recipe.Chunks.Select(chunk => chunk with
                    { SourceStartSample = chunk.SourceStartSample * scale, SourceEndSample = chunk.SourceEndSample * scale }).ToArray(),
                    RoomTone = recipe.RoomTone is { } tone ? tone with
                    { SourceStartSample = tone.SourceStartSample * scale, SourceEndSample = tone.SourceEndSample * scale } : null,
                    Seams = new(
                        recipe.Seams.In with { FadeSamples = recipe.Seams.In.FadeSamples * scale,
                            SourceHandleSamples = recipe.Seams.In.SourceHandleSamples * scale },
                        recipe.Seams.Out with { FadeSamples = recipe.Seams.Out.FadeSamples * scale,
                            SourceHandleSamples = recipe.Seams.Out.SourceHandleSamples * scale }),
                    Video = recipe.Video with { SourceStartSample = recipe.Video.SourceStartSample * scale,
                        SourceEndSample = recipe.Video.SourceEndSample * scale, OutputSamples = recipe.Video.OutputSamples * scale }
                }
            } : candidate).ToArray()
        }).ToArray();
        return project with
        {
            Media = project.Media with { Source = project.Media.Source with
                { Audio = project.Media.Source.Audio! with { SampleRate = 48_000 } } },
            VoiceLab = project.VoiceLab with { Segments = segments }
        };
    }

    private static Project WithNonUnityFit(Project project, double stretch = 1.05)
    {
        var segments = project.VoiceLab.Segments.Select(segment =>
        {
            var candidates = segment.Candidates.Select(candidate =>
            {
                if (candidate.Recipe is not { } recipe) return candidate;
                var audio = recipe.Audio with
                {
                    TrimEnd = recipe.Audio.TrimStart + recipe.OutDuration / stretch,
                    Stretch = stretch
                };
                var chunks = recipe.Chunks.ToArray();
                chunks[^1] = chunks[^1] with
                {
                    AssembledEndFrame = (long)Math.Round(audio.TrimEnd * 24_000, MidpointRounding.AwayFromZero)
                };
                return candidate with { Recipe = recipe with { Audio = audio, Chunks = chunks } };
            }).ToArray();
            return segment with { Audio = candidates[segment.SelectedCandidateIndex].Recipe!.Audio,
                Candidates = candidates };
        }).ToArray();
        return project with { VoiceLab = project.VoiceLab with { Segments = segments } };
    }

    private static VoiceLabTempoTrack StagedFit(PreparedVoiceLabAsset asset, VoiceLabSelectedRecipe selected,
        float before, Func<long, float> body, float after, int sourceRate = 1000)
    {
        var inFrames = (long)Math.Round(selected.Recipe.Seams.In.AssetHandleFrames * asset.Stretch,
            MidpointRounding.AwayFromZero);
        var bodyFrames = (long)Math.Round((selected.Piece.OutputEndSample - selected.Piece.OutputStartSample) *
            asset.SampleRate / (double)sourceRate, MidpointRounding.AwayFromZero);
        var outFrames = (long)Math.Round(selected.Recipe.Seams.Out.AssetHandleFrames * asset.Stretch,
            MidpointRounding.AwayFromZero);
        var frames = inFrames + bodyFrames + outFrames + 1;
        var folder = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "voxclip-fit-test-" +
            Guid.NewGuid().ToString("N"))).FullName;
        using (var stream = new FileStream(Path.Combine(folder, "fitted.f32"), FileMode.CreateNew))
        using (var writer = new BinaryWriter(stream))
            for (long i = 0; i < frames; i++)
            {
                var value = i < inFrames ? before : i < inFrames + bodyFrames ? body(i - inFrames) : after;
                writer.Write(value); writer.Write(value);
            }
        return VoiceLabTempoTrack.OpenOwned(folder, asset.SampleRate, frames, inFrames);
    }

    [Fact]
    public async Task PassageMixesPrivateAssetOnItsOwnGridWithCenteredSeams()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            Assert.NotNull(prepared.SelectedSegmentRecipes[0].Recipe.RoomTone);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var source = new float[7000 * 2];
                Array.Fill(source, 0.2f);
                source.AsSpan(2500 * 2, 700 * 2).Fill(-0.6f);
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(source));
                var output = new float[prepared.OutputPlan.OutputSamples * 2];
                var offset = 0;
                while (offset < output.Length / 2)
                    offset += mix.Read(output.AsSpan(offset * 2), 137, TestContext.Current.CancellationToken);
                Assert.Equal(7000, offset);
                Assert.Equal(0.2f, output[1000 * 2], 5);
                Assert.Equal(0.2f, output[5000 * 2], 5);
                Assert.InRange(output[2800 * 2], 0.69f, 0.71f); // generated 0.5 + source room tone 0.2
                Assert.Equal(0.2f, output[(2500 - 10) * 2], 5); // left seam endpoint
                Assert.InRange(output[(2500 + 9) * 2], 0.69f, 0.71f); // right seam endpoint
                Assert.Equal(0.2f, output[(3200 + 10) * 2], 5);
                Assert.Equal(0, mix.Remaining);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void MissingTempoCapabilityIsExplicit()
    {
        Assert.Throws<VoiceLabTempoException>(() => VoiceLabTempo.RequireCapability(() => false));
        VoiceLabTempo.RequireCapability(() => true);
    }

    [Fact]
    public async Task NearUnityStoredFitCannotEnterTheUnityWavePath()
    {
        Assert.False(VoiceLabTempo.RequiresFit(1));
        Assert.False(VoiceLabTempo.RequiresFit(Math.BitDecrement(1d)));
        Assert.False(VoiceLabTempo.RequiresFit(Math.BitIncrement(1d)));
        Assert.True(VoiceLabTempo.RequiresFit(Math.BitIncrement(Math.BitIncrement(1d))));
        Assert.True(VoiceLabTempo.RequiresFit(1 + 1e-9));
        Assert.True(VoiceLabTempo.RequiresFit(double.NaN));
        var (project, root) = Asset(WithNonUnityFit(Fixture("passage-render-v3.voxclip"), 1 + 1e-9));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full,
                VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root,
                TestContext.Current.CancellationToken);
            try
            {
                var selected = Assert.Single(prepared.SelectedSegmentRecipes);
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(new float[7000 * 2]),
                    selected.Piece.OutputStartSample + 100);
                Assert.Throws<VoiceLabTempoException>(() => mix.Read(new float[8], 4,
                    TestContext.Current.CancellationToken));
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task NonUnityPassageUsesSameFittedSignalForBodyAndBothHandles()
    {
        var (project, root) = Asset(WithNonUnityFit(Fixture("passage-render-v3.voxclip")),
            sample: 16_384);
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var selected = Assert.Single(prepared.SelectedSegmentRecipes);
                using var track = StagedFit(handles[selected.SegmentId], selected, .8f,
                    frame => .4f * (float)Math.Sin(2 * Math.PI * 40 * frame / 24_000), -.7f);
                var tracks = new Dictionary<string, VoiceLabTempoTrack> { [selected.SegmentId] = track };
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(new float[7000 * 2]),
                    tempoTracks: tracks);
                var output = new float[7000 * 2]; var count = 0;
                while (count < 7000)
                    count += mix.Read(output.AsSpan(count * 2), 137, TestContext.Current.CancellationToken);
                Assert.Equal(7000, count);
                Assert.Equal(.8 * Math.Sin(Math.PI * 5 / 38), output[2495 * 2], 4);
                Assert.Equal(-.7 * Math.Cos(Math.PI * 15 / 38), output[3205 * 2], 4);
                Assert.Equal(.4 * Math.Sin(2 * Math.PI * 40 * .031), output[2531 * 2], 4);
                var positiveCrossings = 0;
                for (var i = 2601; i < 3100; i++)
                    if (output[(i - 1) * 2] <= 0 && output[i * 2] > 0) positiveCrossings++;
                Assert.InRange(positiveCrossings, 19, 21);
                Assert.Equal(0, mix.Remaining);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task NonUnityTouchingSeamUsesBothFittedHandleMarkers()
    {
        var (project, root) = Asset(WithNonUnityFit(Fixture("touching-render-v3.voxclip")));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var first = prepared.SelectedSegmentRecipes[0]; var second = prepared.SelectedSegmentRecipes[1];
                using var left = StagedFit(handles[first.SegmentId], first, .1f, _ => .3f, .7f);
                using var right = StagedFit(handles[second.SegmentId], second, -.6f, _ => -.2f, .1f);
                var tracks = new Dictionary<string, VoiceLabTempoTrack>
                    { [first.SegmentId] = left, [second.SegmentId] = right };
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(new float[7000 * 2]),
                    startSample: 3190, tempoTracks: tracks);
                var output = new float[20 * 2];
                Assert.Equal(20, mix.Read(output, 20, TestContext.Current.CancellationToken));
                var uLeft = 5 * Math.PI / 38;
                var uRight = 15 * Math.PI / 38;
                Assert.Equal(.3 * Math.Cos(uLeft) - .6 * Math.Sin(uLeft), output[5 * 2], 4);
                Assert.Equal(.7 * Math.Cos(uRight) - .2 * Math.Sin(uRight), output[15 * 2], 4);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task NonUnityFitPreservesFortyHertzAcrossReal48kSourceSeams()
    {
        var (project, root) = Asset(WithNonUnityFit(At48k(Fixture("passage-render-v3.voxclip"))));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var selected = Assert.Single(prepared.SelectedSegmentRecipes);
                using var track = StagedFit(handles[selected.SegmentId], selected, .8f,
                    frame => .4f * (float)Math.Sin(2 * Math.PI * 40 * frame / 24_000), -.7f, 48_000);
                using var mix = new VoiceLabAudioMixer(prepared, handles,
                    new Source(new float[336_000 * 2]), startSample: 119_520,
                    tempoTracks: new Dictionary<string, VoiceLabTempoTrack> { [selected.SegmentId] = track });
                var output = new float[35_040 * 2]; var count = 0;
                while (count < output.Length / 2)
                    count += mix.Read(output.AsSpan(count * 2), 4096, TestContext.Current.CancellationToken);
                Assert.Equal(35_040, count);
                var before = output[(119_760 - 119_520) * 2];
                Assert.Equal(.8 * Math.Sin(Math.PI * 240 / 1918), before, 4);
                var body = output[(121_488 - 119_520) * 2];
                Assert.Equal(.4 * Math.Sin(2 * Math.PI * 40 * .031), body, 4);
                var after = output[(153_840 - 119_520) * 2];
                Assert.Equal(-.7 * Math.Cos(Math.PI * 720 / 1918), after, 4);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void TaggedCursorAndCaptionsFollowPlanForIncludedExcludedAndDisabledClip()
    {
        var project = Fixture("passage-render-v3.voxclip");
        var included = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
        var cursor = new TimelineCursor(new RenderTimeline.VoiceLab(included.OutputPlan));
        Assert.Equal(2.5, cursor.Source(2.5), 5);
        Assert.Equal(2.8, cursor.Source(2.8), 5);
        Assert.Equal(3.2, cursor.Source(3.2), 5);
        Assert.Contains(included.OutputPlan.Captions, word => word.Id == "vl-passage:word:0" && word.Text == "new");
        Assert.Contains(included.OutputPlan.Captions, word => word.Id == "vl-passage:word:1" && word.Text == "words");
        var excludedClip = project.Edits.Clips[0] with { StartWordId = "w1", EndWordId = "w2" };
        var excludedProject = project with { Edits = project.Edits with
            { Clips = [excludedClip], ActiveClipId = excludedClip.Id } };
        var excluded = VoiceLabRenderContract.Prepare(excludedProject, VoiceLabOutputScope.Clip(excludedClip.Id),
            VoiceLabLabelPosition.TopLeft);
        Assert.False(excluded.OutputPlan.RequiresSyntheticRendering);
        Assert.All(excluded.OutputPlan.Pieces, piece => Assert.Equal(VoiceLabOutputPieceKind.Source, piece.Kind));
        var disabled = VoiceLabProject.SetEnabled(project, "vl-passage", false);
        Assert.False(VoiceLabRenderContract.Prepare(disabled, VoiceLabOutputScope.Full,
            VoiceLabLabelPosition.TopLeft).OutputPlan.RequiresSyntheticRendering);
        var bisectedClip = project.Edits.Clips[0] with { StartWordId = "w4", EndWordId = "w4" };
        var bisected = project with { Edits = project.Edits with { Clips = [bisectedClip] } };
        Assert.Equal(VoiceLabProjectErrorCode.InvalidScope,
            Assert.Throws<VoiceLabProjectException>(() => VoiceLabRenderContract.Prepare(bisected,
                VoiceLabOutputScope.Clip(bisectedClip.Id), VoiceLabLabelPosition.TopLeft)).Code);
    }

    [Fact]
    public async Task Real48kSourceGridResamples24kAssetWithoutChangingOutputLength()
    {
        var (project, root) = Asset(At48k(Fixture("passage-render-v3.voxclip")));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var source = new float[336_000 * 2]; Array.Fill(source, 0.2f);
                source.AsSpan(120_000 * 2, 33_600 * 2).Fill(-0.6f);
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(source));
                var block = new float[4096 * 2]; long frames = 0;
                while (true)
                {
                    var count = mix.Read(block, 4096, TestContext.Current.CancellationToken);
                    if (count == 0) break;
                    if (frames <= 134_400 && frames + count > 134_400)
                        Assert.InRange(block[checked((int)(134_400 - frames) * 2)], 0.69f, 0.71f);
                    frames += count;
                }
                Assert.Equal(336_000, frames);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task FullTakeUsesAllChunksAndNoInventedRoomTone()
    {
        var (project, root) = Asset(Fixture("full-take-render-v3.voxclip"), 172_800,
            at: frame => frame < 86_400 ? (short)8192 : (short)-8192);
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            Assert.Equal(2, prepared.SelectedSegmentRecipes[0].Recipe.Chunks.Count);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var source = new float[7000 * 2]; Array.Fill(source, -0.6f);
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(source));
                var block = new float[258 * 2]; long count = 0;
                while (true)
                {
                    var read = mix.Read(block, 258, TestContext.Current.CancellationToken);
                    if (read == 0) break;
                    for (var i = 0; i < read; i++)
                    {
                        var expected = count + i < 3500 ? 0.25f : -0.25f;
                        Assert.Equal(expected, block[2 * i], 4);
                    }
                    count += read;
                }
                Assert.Equal(7000, count);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task TouchingSyntheticPiecesShareOneCenteredSeam()
    {
        var (project, root) = Asset(Fixture("touching-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var source = new float[7000 * 2]; Array.Fill(source, 0.2f);
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(source));
                var output = new float[7000 * 2]; var count = 0;
                while (count < 7000) count += mix.Read(output.AsSpan(count * 2), 4096, TestContext.Current.CancellationToken);
                Assert.Equal(7000, count);
                Assert.InRange(output[3190 * 2], 0.69f, 0.71f);
                Assert.InRange(output[3200 * 2], 0.96f, 1.01f);
                Assert.InRange(output[3209 * 2], 0.69f, 0.71f);
                Assert.InRange(output[3000 * 2], 0.69f, 0.71f);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void OneSampleGapCannotBeSwallowedByOverlappingSeams()
    {
        var project = Fixture("one-sample-gap-render-v3.voxclip");
        Assert.Equal(VoiceLabProjectErrorCode.OverlappingFades,
            Assert.Throws<VoiceLabProjectException>(() => VoiceLabRenderContract.Prepare(
                project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft)).Code);
    }

    [Fact]
    public void RoomToneLoopUsesFullTailAndHeadAcrossRepeatedBoundaries()
    {
        var tone = new float[500 * 2];
        for (var i = 0; i < 500; i++) tone[2 * i] = tone[2 * i + 1] = i / 500f;
        for (var cycle = 1; cycle <= 3; cycle++)
        {
            var boundary = cycle * 450L;
            var before = VoiceLabAudioMixer.RoomToneSample(tone, boundary - 1, 0, 50);
            var first = VoiceLabAudioMixer.RoomToneSample(tone, boundary, 0, 50);
            var endFade = VoiceLabAudioMixer.RoomToneSample(tone, boundary + 49, 0, 50);
            var after = VoiceLabAudioMixer.RoomToneSample(tone, boundary + 50, 0, 50);
            Assert.InRange(before, 0.89f, 0.90f);
            Assert.InRange(first, 0.88f, 0.90f); // original tail frame 450 participates
            Assert.InRange(endFade, 0.11f, 0.13f); // tail frame 499 blends into head frame 49
            Assert.InRange(after, 0.09f, 0.11f);
        }
    }

    [Fact]
    public async Task ClipContainingSynthKeepsOrdinaryFadesAtItsSourceEdges()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Clip("clip-main"), VoiceLabLabelPosition.TopLeft);
            Assert.Equal(VoiceLabOutputPieceKind.Source, prepared.OutputPlan.Pieces[0].Kind);
            Assert.Equal(VoiceLabOutputPieceKind.Source, prepared.OutputPlan.Pieces[^1].Kind);
            Assert.True(prepared.OutputPlan.Pieces[0].SourceStartSample > 0);
            Assert.True(prepared.OutputPlan.Pieces[^1].SourceEndSample < prepared.OutputPlan.TotalSourceSamples);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var source = new float[7000 * 2]; Array.Fill(source, 0.2f);
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(source));
                var output = new float[prepared.OutputPlan.OutputSamples * 2]; var count = 0;
                while (count < output.Length / 2)
                    count += mix.Read(output.AsSpan(count * 2), 4096, TestContext.Current.CancellationToken);
                Assert.Equal(0, output[0]);
                Assert.Equal(0.04f, output[2], 5);
                Assert.Equal(0.2f, output[10], 5);
                Assert.Equal(0, output[^2]);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task OrdinarySourceCutsMatchLegacyJoinGainOutsideGeneratedSeams()
    {
        var project = Fixture("passage-render-v3.voxclip");
        project = project with { Edits = project.Edits with { CutWordIds = ["w1", "w9"] } };
        var (stored, root) = Asset(project);
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(stored, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var state = EditingEngine.FromProject(stored)! with { ActiveClipId = null };
            var segments = EditingEngine.BuildSegments(state, stored.Media.Source.DurationSeconds);
            var legacy = EditingEngine.BuildEditPlan(segments, stored.Media.Source.DurationSeconds, 1000,
                state.PauseKeepSeconds);
            Assert.Equal(legacy.OutputSamples, prepared.OutputPlan.OutputSamples);
            var handles = await VoiceLabAssets.PrepareAsync(stored, prepared.OutputPlan, root,
                TestContext.Current.CancellationToken);
            try
            {
                var source = new float[7000 * 2]; Array.Fill(source, .2f);
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(source));
                var output = new float[prepared.OutputPlan.OutputSamples * 2]; var count = 0;
                while (count < output.Length / 2)
                    count += mix.Read(output.AsSpan(count * 2), 4096, TestContext.Current.CancellationToken);
                var generatedEdges = prepared.OutputPlan.Pieces.Where(piece => piece.Kind == VoiceLabOutputPieceKind.Synth)
                    .SelectMany(piece => new[] { piece.OutputStartSample, piece.OutputEndSample }).ToArray();
                foreach (var piece in prepared.OutputPlan.Pieces.Where(piece => piece.Kind == VoiceLabOutputPieceKind.Source))
                    for (var sample = piece.OutputStartSample; sample < piece.OutputEndSample; sample++)
                    {
                        if (generatedEdges.Any(edge => Math.Abs(sample - edge) < 10)) continue;
                        Assert.Equal(.2 * legacy.JoinGain(sample), output[checked((int)sample * 2)], 5);
                    }
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void CapturedRequestDoesNotAliasMutableProjectCollections()
    {
        var project = Fixture("passage-render-v3.voxclip");
        var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
        var input = VoiceLabRenderInput.Capture(project, prepared, Path.GetTempPath());
        var original = input.IsolatedProject();
        var segments = (IList<VoiceLabSegment>)project.VoiceLab.Segments;
        segments[0] = segments[0] with { Enabled = false };
        Assert.True(input.IsolatedProject().VoiceLab.Segments[0].Enabled);
        Assert.True(original.VoiceLab.Segments[0].Enabled);
        Assert.Throws<VoiceLabProjectException>(() => prepared.Verify(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft));
    }

    [Fact]
    public void NativeSnapshotRejectsDifferentSourceGridAndStaleCaptionsBeforePreparation()
    {
        var project = Fixture("passage-render-v3.voxclip");
        var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
        var input = VoiceLabRenderInput.Capture(project, prepared, Path.GetTempPath());
        var reference = project.Media.Source;
        var media = new MediaInfo(reference.AbsolutePath, reference.DurationSeconds, reference.Video, reference.Audio,
            new(640, 360), "h264", "aac", false, 0, 1, 0);
        var plan = new EditPlan(1000, 7000, [], [new MediaInterval(0, 7000)], 7000, []);
        var snapshot = new ComposeSnapshot(media, plan, null, new(new(640, 360), 30, 4_000_000)) { VoiceLab = input };
        Assert.NotSame(plan, input.CaptureSnapshot(snapshot).Plan);
        Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract,
            Assert.Throws<VoiceLabProjectException>(() => input.CaptureSnapshot(snapshot with
                { Media = media with { Audio = new(48_000, 1) } })).Code);
        Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract,
            Assert.Throws<VoiceLabProjectException>(() => input.CaptureSnapshot(snapshot with
                { Media = media with { Audio = new(1000, 2) } })).Code);
        Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract,
            Assert.Throws<VoiceLabProjectException>(() => input.CaptureSnapshot(snapshot with
                { Media = media with { OrientedSize = new(360, 640) } })).Code);
        Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract,
            Assert.Throws<VoiceLabProjectException>(() => input.CaptureSnapshot(snapshot with
                { Media = media with { Path = "/a/different/source.mov" } })).Code);
        var words = prepared.OutputPlan.Captions.Select((word, i) => new MeasuredCaptionWord(i, word.Id, word.Text,
            word.Text, word.Start, word.End, 0, 0, [], 0, false, null, null, null)).ToArray();
        var captions = new CaptionTrack(new CaptionStyle(), new(640, 360), words, [], prepared.OutputPlan.Duration);
        Assert.NotSame(captions, input.CaptureSnapshot(snapshot with { Captions = captions }).Captions);
        words[0] = words[0] with { Raw = "stale" };
        Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract,
            Assert.Throws<VoiceLabProjectException>(() => input.CaptureSnapshot(snapshot with { Captions = captions })).Code);
        words[0] = words[0] with { Raw = words[0].Text };
        input.CaptureSnapshot(snapshot with { Captions = captions });
        Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract,
            Assert.Throws<VoiceLabProjectException>(() => input.CaptureSnapshot(snapshot with
                { Captions = captions with { Duration = double.NaN } })).Code);
        input.CaptureSnapshot(snapshot with { Captions = captions });
        var badPage = new CaptionPage(0, [], double.NaN, 1, 0, 0, false, [], [], default, default,
            [], [], null, default);
        Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract,
            Assert.Throws<VoiceLabProjectException>(() => input.CaptureSnapshot(snapshot with
                { Captions = captions with { Pages = [badPage] } })).Code);
    }

    [Fact]
    public async Task LowCapacityRefusesBeforePaidCopyPreviewAndOutputPartial()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var input = VoiceLabRenderInput.Capture(project, prepared, root);
            var reference = project.Media.Source;
            var media = new MediaInfo(reference.AbsolutePath, reference.DurationSeconds, reference.Video, reference.Audio,
                new(640, 360), "h264", "aac", false, 0, 1, 0);
            var plan = new EditPlan(1000, 7000, [], [new MediaInterval(0, 7000)], 7000, []);
            var snapshot = new ComposeSnapshot(media, plan, null, new(new(640, 360), 30, 4_000_000))
                { VoiceLab = input };
            var mp4 = Path.Combine(root, "result.mp4");
            var wav = Path.Combine(root, "result.wav");
            File.WriteAllText(mp4, "previous MP4");
            File.WriteAllText(wav, "previous WAV");
            var queries = 0;
            VoiceLabCapacity.AvailableBytes.Value = _ => { queries++; return 0; };
            var export = new Exporter(new PreviewComposer(), new NoEncoderProbe());
            var exportError = await Assert.ThrowsAsync<VoxClipException>(() => export.ExportAsync(new(
                snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, mp4, null),
                null, TestContext.Current.CancellationToken));
            Assert.Equal(VoxClipErrorCode.DiskFull, exportError.Code);
            var waveError = await Assert.ThrowsAsync<VoxClipException>(() => EditedWaveWriter.WriteAsync(snapshot, wav,
                TestContext.Current.CancellationToken, true));
            Assert.Equal(VoxClipErrorCode.DiskFull, waveError.Code);
            await using (var preview = new PreviewEngine(new PreviewComposer(), initialize: _ => { },
                createWorker: (_, _) => throw new Xunit.Sdk.XunitException("Video workers must not start")))
            {
                var previewError = await Assert.ThrowsAsync<VoxClipException>(() => preview.LoadAsync(snapshot, null,
                    TestContext.Current.CancellationToken));
                Assert.Equal(VoxClipErrorCode.DiskFull, previewError.Code);
            }
            Assert.True(queries >= 3);
            Assert.Equal("previous MP4", File.ReadAllText(mp4));
            Assert.Equal("previous WAV", File.ReadAllText(wav));
            Assert.False(File.Exists(mp4 + ".partial"));
            Assert.False(File.Exists(wav + ".partial"));
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
        }
        finally
        {
            VoiceLabCapacity.AvailableBytes.Value = null;
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public void CapacityAddsPeakStagesOnTheSameVolumeAndRejectsOverflow()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-capacity-test-").FullName;
        try
        {
            var queries = new List<string>();
            VoiceLabCapacity.AvailableBytes.Value = root => { queries.Add(root); return 9; };
            Assert.Equal(VoxClipErrorCode.DiskFull, Assert.Throws<VoxClipException>(() =>
                VoiceLabCapacity.Require([
                    new(Path.GetTempPath(), 5), new(directory, 5)
                ])).Code);
            Assert.Single(queries);
            VoiceLabCapacity.Require([new(Path.GetTempPath(), 5), new(directory, 4)]);
            Assert.Equal(VoxClipErrorCode.DiskFull, Assert.Throws<VoxClipException>(() =>
                VoiceLabCapacity.Require([new(Path.GetTempPath(), long.MaxValue), new(directory, 1)])).Code);
        }
        finally
        {
            VoiceLabCapacity.AvailableBytes.Value = null;
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void CapacityGroupsAliasesAndChecksSeparateVolumesIndependently()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-capacity-volumes-").FullName;
        try
        {
            var first = Path.Combine(directory, "drive-letter");
            var alias = Path.Combine(directory, "mounted-alias");
            var second = Path.Combine(directory, "other-volume");
            VoiceLabCapacity.VolumeIdentity.Value = path => path == second ? "volume-b" : "volume-a";
            var queries = new List<string>();
            VoiceLabCapacity.AvailableBytes.Value = volume => { queries.Add(volume); return 9; };
            Assert.Equal(VoxClipErrorCode.DiskFull, Assert.Throws<VoxClipException>(() =>
                VoiceLabCapacity.Require([new(first, 5), new(alias, 5)])).Code);
            Assert.Equal(["volume-a"], queries);
            queries.Clear();
            VoiceLabCapacity.Require([new(first, 5), new(second, 5)]);
            Assert.Equal(2, queries.Count);
            Assert.Contains("volume-a", queries);
            Assert.Contains("volume-b", queries);
        }
        finally
        {
            VoiceLabCapacity.VolumeIdentity.Value = null;
            VoiceLabCapacity.AvailableBytes.Value = null;
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public async Task PhysicalSourceSizeIsCheckedInMediaBeforePaidPreparation()
    {
        var (baseProject, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var source = Path.Combine(root, "source.mp4");
            File.WriteAllText(source, "old");
            var project = baseProject with { Media = baseProject.Media with { Source = baseProject.Media.Source with
                { AbsolutePath = source, SizeBytes = 3 } } };
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var input = VoiceLabRenderInput.Capture(project, prepared, root);
            var reference = project.Media.Source;
            var snapshot = new ComposeSnapshot(new MediaInfo(source, reference.DurationSeconds,
                reference.Video, reference.Audio, new(640, 360), "h264", "aac", false, 0, 1, 0),
                new EditPlan(1000, 7000, [], [new MediaInterval(0, 7000)], 7000, []), null,
                new(new(640, 360), 30, 4_000_000)) { VoiceLab = input };
            input.CaptureSnapshot(snapshot);
            File.WriteAllText(source, "altered");
            Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract,
                (await Assert.ThrowsAsync<VoiceLabProjectException>(() =>
                    VoiceLabRenderSession.PrepareAsync(snapshot, TestContext.Current.CancellationToken))).Code);
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task WaveCreateFailureDoesNotDeleteAnotherStage()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var input = VoiceLabRenderInput.Capture(project, prepared, root);
            var reference = project.Media.Source;
            var snapshot = new ComposeSnapshot(new MediaInfo(reference.AbsolutePath, reference.DurationSeconds,
                reference.Video, reference.Audio, new(640, 360), "h264", "aac", false, 0, 1, 0),
                new EditPlan(1000, 7000, [], [new MediaInterval(0, 7000)], 7000, []), null,
                new(new(640, 360), 30, 4_000_000)) { VoiceLab = input };
            var destination = Path.Combine(root, "voice.wav");
            File.WriteAllText(destination, "previous WAV");
            OutputSafety.BeforePartialOpen.Value = path =>
            {
                Assert.EndsWith("voice.wav.partial", path, StringComparison.Ordinal);
                File.WriteAllText(path, "other stage");
            };
            await Assert.ThrowsAsync<IOException>(() => EditedWaveWriter.WriteAsync(snapshot, destination,
                TestContext.Current.CancellationToken, true));
            Assert.Equal("previous WAV", File.ReadAllText(destination));
            Assert.Equal("other stage", File.ReadAllText(destination + ".partial"));
        }
        finally
        {
            OutputSafety.BeforePartialOpen.Value = null;
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public void CliSyntheticPublicationIncludesSidecarAndRejectsPaidWaveDestination()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var input = VoiceLabRenderInput.Capture(project, prepared, root);
            var reference = project.Media.Source;
            var media = new MediaInfo(reference.AbsolutePath, reference.DurationSeconds, reference.Video, reference.Audio,
                new(640, 360), "h264", "aac", false, 0, 1, 0);
            var plan = new EditPlan(1000, 7000, [], [new MediaInterval(0, 7000)], 7000, []);
            var snapshot = new ComposeSnapshot(media, plan, null, new(new(640, 360), 30, 4_000_000)) { VoiceLab = input };
            var mp4 = Path.Combine(root, "result.mp4");
            var srt = Path.Combine(root, "result.srt");
            var wave = Path.Combine(root, "result.wav");
            var destinations = CliOperations.ExportDestinations(snapshot, mp4, srt, wave);
            Assert.Equal([mp4, srt, wave, mp4 + ".provenance.json"], destinations);
            CliOperations.ValidateExportDestinations(snapshot, destinations);
            Assert.Throws<VoxClipException>(() => CliOperations.ValidateExportDestinations(snapshot,
                CliOperations.ExportDestinations(snapshot, mp4, srt, Path.Combine(root, project.Id, "asset-one.wav"))));
            Assert.Throws<VoxClipException>(() => CliOperations.ValidateExportDestinations(snapshot,
                CliOperations.ExportDestinations(snapshot, mp4, srt, mp4 + ".provenance.json")));
            Assert.Equal(VoiceLabProjectErrorCode.UnsupportedRendering,
                Assert.Throws<VoiceLabProjectException>(() => CliOperations.BuildPlan(project, true)).Code);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task PaidInputCannotBeAnMp4OrWaveDestination()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var input = VoiceLabRenderInput.Capture(project, prepared, root);
            var reference = project.Media.Source;
            var media = new MediaInfo(reference.AbsolutePath, reference.DurationSeconds, reference.Video, reference.Audio,
                new(640, 360), "h264", "aac", false, 0, 1, 0);
            var plan = new EditPlan(1000, 7000, [], [new MediaInterval(0, 7000)], 7000, []);
            var snapshot = new ComposeSnapshot(media, plan, null, new(new(640, 360), 30, 4_000_000)) { VoiceLab = input };
            var paid = Path.Combine(root, project.Id, "asset-one.wav");
            var before = SHA256.HashData(File.ReadAllBytes(paid));
            Assert.Throws<VoxClipException>(() => Exporter.Validate(new(snapshot, new ExportTarget.FullEdit(),
                ExportAspect.Source, ExportQuality.Standard, paid, null)));
            await Assert.ThrowsAsync<VoxClipException>(() => EditedAudioReader.WriteWaveAsync(snapshot, paid,
                TestContext.Current.CancellationToken));
            Assert.Equal(before, SHA256.HashData(File.ReadAllBytes(paid)));
            Assert.False(File.Exists(paid + ".partial"));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task CancelStopsOnDemandSeamSourceReadWithoutRetainedPcm()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var source = new BlockingSeamSource();
                using var mix = new VoiceLabAudioMixer(prepared, handles, source, 2485);
                using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
                var reading = Task.Run(() => mix.Read(new float[30 * 2], 30, cancellation.Token));
                Assert.True(source.Entered.Wait(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken));
                cancellation.Cancel();
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => reading.WaitAsync(TimeSpan.FromSeconds(2),
                    TestContext.Current.CancellationToken));
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task PreviewPauseFailureDisposesProvisionalSynthSessionAndKeepsOldGraph()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var plan = new EditPlan(1000, 7000, [], [new MediaInterval(0, 7000)], 7000, []);
            var reference = project.Media.Source;
            var legacy = new ComposeSnapshot(
                new MediaInfo("legacy.mp4", 7, reference.Video, null, new(640, 360), "h264", null, false, 0, -1, 0),
                plan, null, new(new(640, 360), 30, 2_000_000));
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var input = VoiceLabRenderInput.Capture(project, prepared, root);
            var synthetic = legacy with
            {
                Media = new MediaInfo(reference.AbsolutePath, reference.DurationSeconds, reference.Video, reference.Audio,
                    new(640, 360), "h264", "aac", false, 0, 1, 0),
                VoiceLab = input
            };
            var failPause = 0;
            await using var preview = new PreviewEngine(new PreviewComposer(), initialize: _ => { },
                createWorker: (_, _) => new PreviewWorker(), clockOverride: () =>
                {
                    if (Volatile.Read(ref failPause) != 0 && new System.Diagnostics.StackTrace().GetFrames()!
                        .Any(frame => frame.GetMethod()?.Name == "Pause"))
                    {
                        Volatile.Write(ref failPause, 0);
                        throw new IOException("Pause clock failed");
                    }
                    return 0;
                });
            await preview.LoadAsync(legacy, null, TestContext.Current.CancellationToken);
            await preview.PlayAsync(TestContext.Current.CancellationToken);
            Volatile.Write(ref failPause, 1);
            var error = await Assert.ThrowsAsync<IOException>(() => preview.UpdateSnapshotAsync(synthetic,
                TestContext.Current.CancellationToken));
            Assert.Contains("Pause clock failed", error.Message, StringComparison.Ordinal);
            await preview.PauseAsync(TestContext.Current.CancellationToken);
            await preview.SeekAsync(1, true, TestContext.Current.CancellationToken);
            Assert.Equal(1, preview.Position.SourceTime, 5);
            Assert.True(File.Exists(Path.Combine(root, project.Id, "asset-one.wav")));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task CorruptPaidAssetCannotCreatePartialOrReplaceAnyMarkedOutput()
    {
        var (project, root) = Asset(Fixture("passage-render-v3.voxclip"));
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var input = VoiceLabRenderInput.Capture(project, prepared, root);
            var reference = project.Media.Source;
            var media = new MediaInfo(reference.AbsolutePath, reference.DurationSeconds, reference.Video, reference.Audio,
                new(640, 360), "h264", "aac", false, 0, 1, 0);
            var plan = new EditPlan(1000, 7000, [], [new MediaInterval(0, 7000)], 7000, []);
            var snapshot = new ComposeSnapshot(media, plan, null, new(new(640, 360), 30, 4_000_000))
                { VoiceLab = input };
            var mp4 = Path.Combine(root, "result.mp4");
            var srt = Path.Combine(root, "result.srt");
            var sidecar = mp4 + ".provenance.json";
            var paths = new[] { mp4, srt, sidecar };
            for (var i = 0; i < paths.Length; i++) File.WriteAllText(paths[i], "original " + i);
            File.WriteAllText(Path.Combine(root, project.Id, "asset-one.wav"), "corrupt paid bytes");
            var export = new Exporter(new PreviewComposer(), new NoEncoderProbe());
            var error = await Assert.ThrowsAsync<VoiceLabAssetException>(() => export.ExportAsync(new(
                snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard,
                mp4, srt), null, TestContext.Current.CancellationToken));
            Assert.Equal(VoiceLabAssetErrorCode.Altered, error.Code);
            for (var i = 0; i < paths.Length; i++)
            {
                Assert.Equal("original " + i, File.ReadAllText(paths[i]));
                Assert.False(File.Exists(paths[i] + ".partial"));
            }
            Assert.Equal("corrupt paid bytes", File.ReadAllText(Path.Combine(root, project.Id, "asset-one.wav")));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    [Trait("Category", "RequiresFFmpeg")]
    [Trait("Category", "RequiresWindows")]
    public async Task NativePassageUsesProductionWaveComposerAndMarkedExporter()
    {
        await NativeTest.RequireAsync(windows: true);
        await ShippingRuntimeIdentityTests.MatchShippingReportWhenEvidencePresentAsync();
        var source = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "voice-lab-7s.mkv");
        NativeTest.Require(File.Exists(source), "The committed seven-second Voice Lab source fixture is missing.");
        var ct = TestContext.Current.CancellationToken;
        var probed = await new FfmpegMediaProbe().ProbeAsync(source, ct);
        Assert.Equal(7, probed.DurationSeconds, 5);
        var baseProject = At48k(Fixture("passage-render-v3.voxclip"));
        baseProject = baseProject with { Media = baseProject.Media with { Source = baseProject.Media.Source with
        {
            AbsolutePath = source, RelativePath = Path.GetFileName(source), SizeBytes = new FileInfo(source).Length,
            Video = probed.Video, Audio = probed.Audio
        } } };
        var (project, root) = Asset(baseProject, at: i =>
        {
            var pulse = i is >= 4_800 and < 4_896 or >= 13_200 and < 13_296 ? 0.1 : 0;
            return (short)Math.Round(21_000 * Math.Sin(2 * Math.PI * 660 * i / 24_000) + 3_000 * pulse);
        });
        try
        {
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var input = VoiceLabRenderInput.Capture(project, prepared, root);
            var total = 7L * 48_000;
            var edit = new EditPlan(48_000, total, [], [new MediaInterval(0, total)], total, []);
            var snapshot = new ComposeSnapshot(probed, edit, null, new(probed.OrientedSize, 30, 2_000_000))
                { VoiceLab = input };
            await using (var preview = new PreviewEngine())
            {
                await preview.LoadAsync(snapshot, null, ct);
                await preview.SeekAsync(2.8, true, ct);
                await using var frames = preview.ReadFramesAsync(ct).GetAsyncEnumerator(ct);
                PreviewFrame? shown = null;
                for (var attempt = 0; attempt < 3; attempt++)
                {
                    Assert.True(await frames.MoveNextAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5), ct));
                    if (Math.Abs(frames.Current.EditedPts - 2.8) < 0.04)
                    { shown = frames.Current; break; }
                }
                Assert.NotNull(shown);
                Assert.Equal(2.8, shown!.SourcePts, 2);
                using var video = new VideoDecoder(source, false);
                var original = video.ReadAt(shown.SourcePts, true, ct);
                Assert.True(shown.Buffer.Pixels.Span.SequenceEqual(original.Pixels.Span) == false,
                    "The caption-off preview must still draw the generated-audio disclosure.");
                if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } frameEvidence)
                {
                    Directory.CreateDirectory(frameEvidence);
                    WritePpm(Path.Combine(frameEvidence, "windows-native-preview-disclosure.ppm"), shown.Buffer);
                }
            }
            var wave = Path.Combine(root, "render.wav");
            await EditedWaveWriter.WriteAsync(snapshot, wave, ct, true);
            Assert.Equal(44 + total * 8, new FileInfo(wave).Length);
            Assert.InRange(WaveFrequency(wave, 1.0), 330, 370);
            Assert.InRange(WaveFrequency(wave, 2.8), 630, 690);
            Assert.InRange(WaveFrequency(wave, 4.0), 535, 585);

            var mp4 = Path.Combine(root, "render.mp4");
            var result = await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(),
                ExportAspect.Source, ExportQuality.Standard, mp4, null), null, ct);
            Assert.Equal(210, result.Frames);
            Assert.Equal(total, result.AudioSamples);
            Assert.True(File.Exists(mp4));
            var sidecarPath = mp4 + ".provenance.json";
            using var sidecar = JsonDocument.Parse(File.ReadAllBytes(sidecarPath));
            Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(mp4))),
                sidecar.RootElement.GetProperty("export").GetProperty("sha256").GetString());
            var packet = VoiceLabDisclosureTests.ExtractTopLevelXmp(File.ReadAllBytes(mp4));
            var document = XDocument.Parse(Encoding.UTF8.GetString(packet));
            XNamespace iptc = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/";
            Assert.Equal(VoiceLabDisclosureWriter.DigitalSourceType,
                document.Descendants().Attributes(iptc + "DigitalSourceType").Single().Value);
            Assert.DoesNotContain(Path.Combine(root, project.Id), File.ReadAllText(sidecarPath), StringComparison.Ordinal);
            var previousMp4 = SHA256.HashData(File.ReadAllBytes(mp4));
            var previousSidecar = File.ReadAllBytes(sidecarPath);
            using (var cancellation = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                var cancelling = new Exporter(new CancelOnCompose(cancellation), new EncoderProbe());
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelling.ExportAsync(new(snapshot,
                    new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, mp4, null),
                    null, cancellation.Token));
            }
            Assert.Equal(previousMp4, SHA256.HashData(File.ReadAllBytes(mp4)));
            Assert.Equal(previousSidecar, File.ReadAllBytes(sidecarPath));
            Assert.False(File.Exists(mp4 + ".partial"));
            Assert.False(File.Exists(sidecarPath + ".partial"));
            if (Environment.GetEnvironmentVariable("VOXCLIP_VOICE_EVIDENCE_DIR") is { Length: > 0 } evidence)
            {
                Directory.CreateDirectory(evidence);
                File.Copy(wave, Path.Combine(evidence, "windows-native-passage.wav"), true);
                File.Copy(mp4, Path.Combine(evidence, "windows-native-passage.mp4"), true);
                File.Copy(sidecarPath, Path.Combine(evidence, "windows-native-passage.provenance.json"), true);
            }
        }
        finally { Directory.Delete(root, true); }
    }

    private static double WaveFrequency(string path, double seconds)
    {
        using var stream = File.OpenRead(path);
        using var reader = new BinaryReader(stream);
        const int rate = 48_000;
        const int frames = 4800;
        stream.Position = 44 + (long)(seconds * rate) * 8;
        var crossings = 0;
        var previous = reader.ReadSingle(); reader.ReadSingle();
        for (var i = 1; i < frames; i++)
        {
            var sample = reader.ReadSingle(); reader.ReadSingle();
            if (previous <= 0 && sample > 0) crossings++;
            previous = sample;
        }
        return crossings * (double)rate / frames;
    }

    private static void WritePpm(string path, PixelBuffer frame)
    {
        using var stream = File.Create(path);
        var header = Encoding.ASCII.GetBytes($"P6\n{frame.Width} {frame.Height}\n255\n");
        stream.Write(header);
        var pixels = frame.Pixels.Span;
        for (var y = 0; y < frame.Height; y++)
            for (var x = 0; x < frame.Width; x++)
            {
                var offset = y * frame.Stride + x * 4;
                stream.WriteByte(pixels[offset + 2]);
                stream.WriteByte(pixels[offset + 1]);
                stream.WriteByte(pixels[offset]);
            }
    }
}
