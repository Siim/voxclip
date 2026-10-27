using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Pipeline;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Audio;

internal static class EditedWaveWriter
{
    internal static async Task WriteAsync(ComposeSnapshot snapshot, string path, CancellationToken ct, bool publish, string? scratchRoot = null)
    {
        snapshot = snapshot.VoiceLab?.CaptureSnapshot(snapshot) ?? snapshot;
        if (snapshot.Timeline.OutputSamples <= 0)
            throw new VoxClipException(VoxClipErrorCode.EverythingCut, "Keep at least one word before exporting.");
        var protectedPaths = new List<string> { snapshot.Media.Path };
        if (snapshot.VoiceLab is { } input)
        {
            var project = input.IsolatedProject();
            protectedPaths.AddRange(project.VoiceLab.Assets?.Select(asset =>
                Path.Combine(input.PaidRoot, project.Id, Path.GetFileName(asset.File))) ?? []);
        }
        OutputSafety.Validate(protectedPaths, [path]);
        var destination = OutputSafety.Resolve(path);
        var dataBytes = VoiceLabCapacity.Bytes(snapshot.Timeline.OutputSamples, 2 * sizeof(float));
        if (snapshot.VoiceLab is { Prepared.OutputPlan.RequiresSyntheticRendering: true } &&
            dataBytes > uint.MaxValue - 36L)
            throw new VoxClipException(VoxClipErrorCode.ExportFailed,
                "The edited WAV is too long for the supported WAV format. Your edits are saved.");
        var waveBytes = VoiceLabCapacity.Bytes(dataBytes, 1, 44);
        using var session = await VoiceLabRenderSession.PrepareAsync(snapshot, ct, scratchRoot ?? Path.GetTempPath(),
            new VoiceLabCapacity.Allocation(destination, waveBytes),
            publish ? VoiceLabCapacity.Rollback(destination) : new VoiceLabCapacity.Allocation(destination, 0)).ConfigureAwait(false);
        await MediaThread.Run("vc-audio-wave", () =>
        {
            path = OutputSafety.Resolve(path);
            var partial = path + ".partial";
            var owned = false;
            var prepared = false;
            var rate = checked((int)snapshot.Timeline.SampleRate);
            try
            {
                using (var stage = OutputSafety.CreatePartial(partial))
                {
                    owned = true;
                    using var audio = new EditedAudioReader(snapshot, rate, session: session, ct: ct);
                    using var output = new WaveWriter(stage, rate, 2, true);
                    var samples = new float[8192];
                    int count;
                    while ((count = audio.Read(samples, samples.Length / 2, ct)) > 0)
                        output.Write(samples.AsSpan(0, count * 2));
                }
                ct.ThrowIfCancellationRequested();
                if (publish) OutputSafety.Publish([path], ct: ct);
                prepared = true;
                return true;
            }
            finally { if (owned && (publish || !prepared)) OutputSafety.DeletePartial(partial); }
        }, ct).ConfigureAwait(false);
    }
}
