using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed partial class VoiceLabAudioMixerTests
{
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
