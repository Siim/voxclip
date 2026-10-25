using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Ffmpeg;

internal sealed unsafe class AudioDecoder : IDisposable
{
    private readonly DecodeSession decoder;
    private NativeHandle? resample;
    private AVChannelLayout inputLayout;
    private AVSampleFormat inputFormat = AVSampleFormat.AV_SAMPLE_FMT_NONE;
    private int inputRate;
    private float[] chunk = [];
    private int chunkFrames;
    private long chunkStart;
    private long position;
    private bool ended;
    private long? nextSample;
    internal int SampleRate { get; }
    internal int Channels { get; }
    internal long PacketsRead => decoder.PacketsRead;
    internal long BytesRead => decoder.BytesRead;

    internal AudioDecoder(string path, int channels = 0)
    {
        decoder = new(path, AVMediaType.AVMEDIA_TYPE_AUDIO);
        SampleRate = decoder.Codec->sample_rate;
        Channels = channels == 0 ? decoder.Codec->ch_layout.nb_channels : channels;
    }

    internal void Seek(long sample)
    {
        decoder.Seek(sample / (double)SampleRate - 0.5);
        ClearResampler();
        position = sample; chunkFrames = 0; ended = false; nextSample = null;
    }

    internal int Read(Span<float> output, int frames, CancellationToken ct)
    {
        var written = 0;
        while (written < frames)
        {
            ct.ThrowIfCancellationRequested();
            if (chunkFrames == 0 || position >= chunkStart + chunkFrames)
            {
                if (!Next(ct))
                {
                    output[(written * Channels)..(frames * Channels)].Clear();
                    position += frames - written;
                    return frames;
                }
                continue;
            }
            if (position < chunkStart)
            {
                var silence = (int)Math.Min(frames - written, chunkStart - position);
                output.Slice(written * Channels, silence * Channels).Clear();
                position += silence; written += silence;
                continue;
            }
            var offset = (int)(position - chunkStart);
            var count = Math.Min(frames - written, chunkFrames - offset);
            chunk.AsSpan(offset * Channels, count * Channels).CopyTo(output[(written * Channels)..]);
            position += count; written += count;
        }
        return written;
    }

    private bool Next(CancellationToken ct)
    {
        if (ended || !decoder.Next(ct)) { ended = true; return false; }
        var frame = decoder.Frame;
        if (frame->ch_layout.nb_channels <= 0 || frame->sample_rate <= 0 || frame->nb_samples < 0 || frame->extended_data == null)
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: an audio frame cannot be converted. Your edits are saved.");
        fixed (AVChannelLayout* previous = &inputLayout)
            if (resample is not null && (inputRate != frame->sample_rate || inputFormat != (AVSampleFormat)frame->format ||
                ffmpeg.av_channel_layout_compare(previous, &frame->ch_layout) != 0)) ClearResampler();
        if (resample is null)
        {
            var layout = new AVChannelLayout();
            ffmpeg.av_channel_layout_default(&layout, Channels);
            SwrContext* context = null;
            try
            {
                Native.Check(ffmpeg.swr_alloc_set_opts2(&context, &layout, AVSampleFormat.AV_SAMPLE_FMT_FLT, SampleRate,
                    &frame->ch_layout, (AVSampleFormat)frame->format, frame->sample_rate, 0, null), "Configure audio conversion");
                resample = NativeHandle.Own(context, NativeKind.Resample);
                if (frame->ch_layout.nb_channels == 1 && Channels == 2)
                {
                    var matrix = stackalloc double[] { 1, 1 };
                    Native.Check(ffmpeg.swr_set_matrix(context, matrix, 1), "Duplicate mono audio into stereo");
                }
                Native.Check(ffmpeg.swr_init(context), "Initialize audio conversion");
                fixed (AVChannelLayout* previous = &inputLayout)
                    Native.Check(ffmpeg.av_channel_layout_copy(previous, &frame->ch_layout), "Keep audio channel layout");
                inputRate = frame->sample_rate; inputFormat = (AVSampleFormat)frame->format;
            }
            finally { ffmpeg.av_channel_layout_uninit(&layout); }
        }
        var capacity = frame->nb_samples + 256;
        if (chunk.Length < capacity * Channels) chunk = new float[capacity * Channels];
        fixed (float* samples = chunk)
        {
            var destination = (byte*)samples;
            chunkFrames = ffmpeg.swr_convert((SwrContext*)resample.Pointer, &destination, capacity, frame->extended_data, frame->nb_samples);
            Native.Check(chunkFrames, "Convert audio samples");
        }
        var timestamp = Native.Round(decoder.Timestamp * SampleRate);
        var tolerance = Math.Max(1, (long)Math.Ceiling(ffmpeg.av_q2d(decoder.Stream->time_base) * SampleRate));
        chunkStart = nextSample is { } expected && Math.Abs(timestamp - expected) <= tolerance ? expected : timestamp;
        nextSample = chunkStart + chunkFrames;
        return true;
    }

    private void ClearResampler()
    {
        resample?.Dispose(); resample = null;
        fixed (AVChannelLayout* previous = &inputLayout) ffmpeg.av_channel_layout_uninit(previous);
        inputRate = 0; inputFormat = AVSampleFormat.AV_SAMPLE_FMT_NONE;
    }

    public void Dispose() { ClearResampler(); decoder.Dispose(); }
}
