using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using System.Text.Json;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed partial class VoiceLabAudioMixerTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SharedMicroRecipeRendersTheSame48kSamplesAsMac(bool shortSource)
    {
        using var fixture = JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/hard-join-review-cases.json"));
        var row = fixture.RootElement.GetProperty("microRecipe");
        var (project, root) = Asset(At48k(Fixture("passage-render-v3.voxclip")), sample: 16384);
        try
        {
            var segment = project.VoiceLab.Segments[0];
            var recipe = segment.Candidates[0].Recipe!;
            var incoming = new VoiceLabMicroPause(0.14, 0.3);
            var outgoing = new VoiceLabMicroPause(-0.4, -0.14);
            recipe = recipe with { Audio = recipe.Audio with { Stretch = 1 },
                Words = [recipe.Words![0] with { Start = 0.14 }, recipe.Words[1] with { End = 0.56 }],
                RoomTone = new(216000, 240000, 0),
                Seams = new(new(VoiceLabSeamKind.Hard, 576, 288, 240, incoming), new(VoiceLabSeamKind.Hard, 576, 288, 240, outgoing)) };
            segment = segment with { Audio = recipe.Audio, Words = recipe.Words, Candidates = [segment.Candidates[0] with { Recipe = recipe }, segment.Candidates[1]] };
            project = project with { VoiceLab = project.VoiceLab with { Segments = [segment] } };
            if (shortSource)
            {
                VoiceLabWord[] nextWords = [new("next", 0.14, 0.16, true)];
                var nextRecipe = recipe with { OutDuration = 0.3, Audio = recipe.Audio with { TrimEnd = 0.4 }, Words = nextWords,
                    Seams = new(recipe.Seams.In with { MicroPause = VoiceLabHardJoin.Pause(nextWords, 0.3, true) }, recipe.Seams.Out with { MicroPause = VoiceLabHardJoin.Pause(nextWords, 0.3, false) }),
                    Video = recipe.Video with { SourceStartSample = 153600, SourceEndSample = 168000, OutputSamples = 14400 },
                    Chunks = [recipe.Chunks[0] with { SourceStartSample = 153600, SourceEndSample = 168000, AssembledEndFrame = 9600 }] };
                var next = segment with { Id = "vl-next", Replace = segment.Replace with { Start = 3.2, End = 3.5, FirstWordId = "w6", LastWordId = "w6" },
                    OutDuration = 0.3, Audio = nextRecipe.Audio, Words = nextWords,
                    Candidates = [segment.Candidates[0] with { Recipe = nextRecipe }] };
                VoiceLabWord[] words = [recipe.Words![0], recipe.Words[1] with { End = 0.54 }];
                recipe = recipe with { OutDuration = 0.68, Audio = recipe.Audio with { TrimEnd = 0.78 }, Words = words,
                    Seams = recipe.Seams with { Out = recipe.Seams.Out with { MicroPause = VoiceLabHardJoin.Pause(words, 0.68, false) } },
                    Video = recipe.Video with { SourceEndSample = 152640, OutputSamples = 32640 },
                    Chunks = [recipe.Chunks[0] with { SourceEndSample = 152640, AssembledEndFrame = 18720 }] };
                segment = segment with { Replace = segment.Replace with { End = 3.18 }, OutDuration = 0.68, Audio = recipe.Audio, Words = words,
                    Candidates = [segment.Candidates[0] with { Recipe = recipe }] };
                project = project with { VoiceLab = project.VoiceLab with { Segments = [segment, next] } };
            }
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var source = Enumerable.Range(0, 336000).SelectMany(frame => new[] { frame is >= 216000 and < 240000 ? 0.01f : 0.2f, frame is >= 216000 and < 240000 ? 0.01f : 0.2f }).ToArray();
                using var mix = new VoiceLabAudioMixer(prepared, handles, new Source(source));
                var output = new float[336000 * 2];
                var frames = 0;
                while (frames < 336000) frames += mix.Read(output.AsSpan(frames * 2), Math.Min(4096, 336000 - frames), TestContext.Current.CancellationToken);
                foreach (var sample in row.GetProperty("samples").EnumerateArray())
                {
                    if (shortSource && sample.GetProperty("frame").GetInt32() >= 24720) continue;
                    Assert.InRange(Math.Abs(output[(120000 + sample.GetProperty("frame").GetInt32()) * 2] - sample.GetProperty("expected").GetDouble()), 0, row.GetProperty("sampleTolerance").GetDouble());
                }
                if (shortSource)
                {
                    Assert.InRange(Math.Abs(output[152640 * 2] - 0.01), 0, 1e-6);
                    Assert.InRange(Math.Abs(output[152880 * 2] - 0.21 * Math.Sqrt(0.5)), 0, 1e-6);
                    Assert.Equal(0.2f, output[153120 * 2]);
                    Assert.InRange(Math.Abs(output[153600 * 2] - 0.01), 0, 1e-6);
                }
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task HardJoinRecipeUsesOutputSecondsFor48kRendering()
    {
        var (project, root) = Asset(At48k(Fixture("passage-render-v3.voxclip")), sample: 16384);
        try
        {
            var segment = project.VoiceLab.Segments[0];
            var recipe = segment.Candidates[0].Recipe!;
            var incoming = new VoiceLabMicroPause(0.14, 0.3);
            var outgoing = new VoiceLabMicroPause(-0.4, -0.14);
            recipe = recipe with
            {
                Audio = recipe.Audio with { Stretch = 1 },
                Words = [recipe.Words![0] with { Start = 0.14 }, recipe.Words[1] with { End = 0.56 }],
                Seams = new(new(VoiceLabSeamKind.Hard, 576, 288, 240, incoming), new(VoiceLabSeamKind.Hard, 576, 288, 240, outgoing)),
                EdgeGain = new(Out: new(1, outgoing)),
                RoomTone = recipe.RoomTone! with { GainDb = -300 }
            };
            segment = segment with { Audio = recipe.Audio, Words = recipe.Words, Candidates = [segment.Candidates[0] with { Recipe = recipe }, segment.Candidates[1]] };
            project = project with { VoiceLab = project.VoiceLab with { Segments = [segment] } };
            project = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project));
            Assert.Equal(recipe.EdgeGain, project.VoiceLab.Segments[0].Candidates[0].Recipe!.EdgeGain);
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft);
            var handles = await VoiceLabAssets.PrepareAsync(project, prepared.OutputPlan, root, TestContext.Current.CancellationToken);
            try
            {
                var source = new float[336000 * 2];
                Array.Fill(source, 0.2f);
                using var mix = new VoxClip.Media.VoiceLab.VoiceLabAudioMixer(prepared, handles, new Source(source));
                var output = new float[336000 * 2];
                var frames = 0;
                while (frames < 336000)
                {
                    var count = mix.Read(output.AsSpan(frames * 2), Math.Min(4096, 336000 - frames), TestContext.Current.CancellationToken);
                    Assert.True(count > 0);
                    frames += count;
                }
                Assert.Equal(336000, frames);
                const int start = 120000;
                const int end = 153600;
                foreach (var seconds in new[] { 0.2, 0.4, 0.5475 })
                {
                    var offset = (int)Math.Round(seconds * 48000);
                    var voice = VoiceLabHardJoin.GeneratedWeight(seconds, 0.7, incoming, outgoing);
                    var boost = Math.Pow(10, VoiceLabHardJoin.EdgeGainDb(seconds, 0.7, recipe.EdgeGain) / 20);
                    Assert.InRange(Math.Abs(output[(start + offset) * 2] - 0.5 * voice * boost), 0, 2e-6);
                }
                foreach (var offset in new[] { 0, 2400, 4800, 28800, 31200, 33599 }) Assert.InRange(Math.Abs(output[(start + offset) * 2]), 0, 1e-10);
                Assert.InRange(Math.Abs(output[(end + 720) * 2] - 0.2 * VoiceLabHardJoin.SourceWeight(0.015, false)), 0, 2e-6);
                Assert.Equal(0.2f, output[(end + 960) * 2]);
                Assert.Equal(0.2f, output[(start - 960) * 2]);
            }
            finally { foreach (var handle in handles.Values) handle.Dispose(); }
        }
        finally { Directory.Delete(root, true); }
    }
}
