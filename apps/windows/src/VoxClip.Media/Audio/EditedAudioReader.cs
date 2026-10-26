using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Audio;

internal sealed unsafe class EditedAudioReader : IDisposable
{
    private readonly AudioDecoder decoder;
    private readonly EditPlan plan;
    private readonly VoiceLabAudioMixer? mixer;
    private readonly NativeHandle resample;
    private readonly float[] source = new float[4096 * 2];
    private readonly float[] converted;
    private int convertedCount;
    private int convertedOffset;
    private int part;
    private long partOffset;
    private long outputIndex;
    private long produced;
    private bool draining;
    internal long TotalFrames { get; }

    internal EditedAudioReader(ComposeSnapshot snapshot, int outputRate, double startEdited = 0,
        VoiceLabRenderSession? session = null, CancellationToken ct = default)
    {
        plan = snapshot.Plan;
        decoder = new(snapshot.Media.Path, 2);
        var timeline = snapshot.Timeline;
        if (decoder.SampleRate != (int)timeline.SampleRate)
        { decoder.Dispose(); throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: the edit plan audio sample rate does not match the source. Your edits are saved."); }
        var layout = new AVChannelLayout();
        ffmpeg.av_channel_layout_default(&layout, 2);
        SwrContext* context = null;
        try
        {
            Native.Check(ffmpeg.swr_alloc_set_opts2(&context, &layout, AVSampleFormat.AV_SAMPLE_FMT_FLT, outputRate,
                &layout, AVSampleFormat.AV_SAMPLE_FMT_FLT, decoder.SampleRate, 0, null), "Configure edited audio resampler");
            Native.Check(ffmpeg.swr_init(context), "Initialize edited audio resampler");
            resample = NativeHandle.Own(context, NativeKind.Resample);
        }
        catch { decoder.Dispose(); if (context != null) ffmpeg.swr_free(&context); throw; }
        finally { ffmpeg.av_channel_layout_uninit(&layout); }
        converted = new float[(int)Math.Ceiling(4096.0 * outputRate / decoder.SampleRate + 256) * 2];
        var sourceOffset = Math.Clamp(Native.Round(startEdited * timeline.SampleRate), 0, timeline.OutputSamples);
        outputIndex = sourceOffset;
        TotalFrames = Native.Round((timeline.OutputSamples - sourceOffset) * outputRate / timeline.SampleRate);
        if (timeline is VoxClip.Core.Domain.VoiceLab.RenderTimeline.VoiceLab voice && voice.Plan.RequiresSyntheticRendering)
        {
            try
            {
                mixer = (session ?? throw new InvalidOperationException("Prepare generated audio before opening the reader."))
                    .CreateMixer(new NativeVoiceLabSource(decoder), sourceOffset, ct);
            }
            catch { resample.Dispose(); decoder.Dispose(); throw; }
        }
        else
        {
            while (part < plan.Kept.Count && sourceOffset >= plan.Kept[part].EndSample - plan.Kept[part].StartSample)
            { sourceOffset -= plan.Kept[part].EndSample - plan.Kept[part].StartSample; part++; }
            partOffset = sourceOffset;
            if (part < plan.Kept.Count) decoder.Seek(plan.Kept[part].StartSample + partOffset);
        }
    }

    internal int Read(Span<float> target, int frames, CancellationToken ct)
    {
        frames = (int)Math.Min(frames, TotalFrames - produced);
        var written = 0;
        while (written < frames)
        {
            ct.ThrowIfCancellationRequested();
            if (convertedOffset >= convertedCount)
            {
                if (!Fill(ct))
                {
                    if (mixer is not null)
                        throw new VoxClipException(VoxClipErrorCode.DecodeFailed,
                            "The generated Voice Lab audio ended before the planned output. Your edits are saved.");
                    target.Slice(written * 2, (frames - written) * 2).Clear();
                    written = frames; break;
                }
            }
            var count = Math.Min(frames - written, convertedCount - convertedOffset);
            converted.AsSpan(convertedOffset * 2, count * 2).CopyTo(target[(written * 2)..]);
            convertedOffset += count; written += count;
        }
        produced += written;
        return written;
    }

    private bool Fill(CancellationToken ct)
    {
        while (true)
        {
            var count = 0;
            if (mixer is not null)
            {
                count = mixer.Read(source, 4096, ct);
            }
            else if (part < plan.Kept.Count)
            {
                var range = plan.Kept[part];
                var length = range.EndSample - range.StartSample;
                count = (int)Math.Min(4096, length - partOffset);
                decoder.Read(source, count, ct);
                for (var index = 0; index < count; index++)
                {
                    var gain = (float)plan.JoinGain(outputIndex + index);
                    source[index * 2] *= gain; source[index * 2 + 1] *= gain;
                }
                partOffset += count;
                outputIndex += count;
                if (partOffset >= length)
                {
                    part++; partOffset = 0;
                    if (part < plan.Kept.Count) decoder.Seek(plan.Kept[part].StartSample);
                }
            }
            else if (draining) return false;
            fixed (float* sourcePointer = source)
            fixed (float* destinationPointer = converted)
            {
                var input = (byte*)sourcePointer; var output = (byte*)destinationPointer;
                convertedCount = ffmpeg.swr_convert((SwrContext*)resample.Pointer, &output, converted.Length / 2, count > 0 ? &input : null, count);
                Native.Check(convertedCount, "Resample edited audio");
            }
            convertedOffset = 0;
            if (count == 0 && convertedCount == 0) draining = true;
            if (convertedCount > 0) return true;
            if (draining) return false;
        }
    }

    internal static Task WriteWaveAsync(ComposeSnapshot snapshot, string path, CancellationToken ct, bool publish = true)
        => EditedWaveWriter.WriteAsync(snapshot, path, ct, publish);

    public void Dispose() { mixer?.Dispose(); resample.Dispose(); decoder.Dispose(); }
}
