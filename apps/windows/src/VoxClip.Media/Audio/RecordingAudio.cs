using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Audio;

internal sealed class RecordingAudio(ComposeSnapshot snapshot, int rate) : IVoiceLabSource, IDisposable
{
    private sealed record Input(AudioDecoder Decoder)
    {
        internal long Next { get; set; } = -1;
    }

    private readonly Dictionary<string, Input> inputs = new(StringComparer.Ordinal);

    public void Read(long startSample, Span<float> stereo, CancellationToken ct)
    {
        var recording = snapshot.RecordingAt(startSample);
        if (snapshot.SpanSources.Count > 0 && (recording is null ||
            stereo.Length / 2 > recording.OffsetSamples + recording.DurationSamples - startSample))
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "A part comes from one recording.");
        Read(recording, startSample, stereo, ct);
    }

    internal void Read(RecordingRenderSource? recording, long startSample, Span<float> stereo, CancellationToken ct)
    {
        var key = recording?.ContentKey ?? "";
        if (!inputs.TryGetValue(key, out var input))
        {
            var decoder = new AudioDecoder(recording is null ? snapshot.Media.Path : RecordingRendering.RequirePath(recording), 2,
                recording is null ? null : rate);
            if (decoder.SampleRate != rate)
            {
                decoder.Dispose();
                throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: the edit plan audio sample rate does not match the source. Your edits are saved.");
            }
            inputs.Add(key, input = new(decoder));
        }
        var local = startSample - (recording?.OffsetSamples ?? 0);
        if (input.Next != local) input.Decoder.Seek(local);
        var frames = stereo.Length / 2;
        input.Decoder.Read(stereo, frames, ct);
        input.Next = local + frames;
        if (recording is { GainDb: not 0 })
        {
            var gain = (float)Math.Pow(10, recording.GainDb / 20);
            for (var index = 0; index < stereo.Length; index++) stereo[index] *= gain;
        }
    }

    public void Dispose()
    {
        foreach (var input in inputs.Values) input.Decoder.Dispose();
    }
}
