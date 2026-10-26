using System.Globalization;
using System.Runtime.InteropServices;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.VoiceLab;

/// <summary>Owned, pitch-preserved PCM stage. Readers are opened by the mixer only while active.</summary>
internal sealed unsafe class VoiceLabTempoTrack : IDisposable
{
    private readonly string folder;
    private readonly string path;
    internal int Rate { get; }
    internal long Frames { get; }
    internal long BodyOriginFrame { get; }

    private VoiceLabTempoTrack(string folder, int rate, long frames, long bodyOriginFrame)
    {
        this.folder = folder;
        path = Path.Combine(folder, "fitted.f32");
        Rate = rate; Frames = frames; BodyOriginFrame = bodyOriginFrame;
    }

    // Also permits a previously staged track to be checked without an FFmpeg graph.
    internal static VoiceLabTempoTrack OpenOwned(string folder, int rate, long frames, long bodyOriginFrame)
    {
        var path = Path.Combine(folder, "fitted.f32");
        if (rate <= 0 || frames <= 0 || bodyOriginFrame < 0 || bodyOriginFrame >= frames ||
            new FileInfo(path).Length != checked(frames * 2 * sizeof(float))) throw new VoiceLabTempoException();
        return new(folder, rate, frames, bodyOriginFrame);
    }

    internal static VoiceLabTempoTrack Create(PreparedVoiceLabAsset asset, long outputSamples, double sourceRate,
        long preHandleFrames, long postHandleFrames, long beforeSamples, long afterSamples, CancellationToken ct)
    {
        var ratio = 1 / asset.Stretch;
        if (!double.IsFinite(ratio) || ratio <= 0 || !double.IsFinite(sourceRate) || sourceRate <= 0 ||
            preHandleFrames < 0 || postHandleFrames < 0 || beforeSamples < 0 || afterSamples < 0 ||
            preHandleFrames > asset.TrimStartFrame || postHandleFrames > asset.FrameCount - asset.TrimEndFrame)
            throw new VoiceLabTempoException();
        VoiceLabTempo.RequireCapability(() => ffmpeg.avfilter_get_by_name("atempo") != null);
        VoiceLabTempo.RequireVerifiedPlacement();
        var inputStart = asset.TrimStartFrame - preHandleFrames;
        var inputEnd = asset.TrimEndFrame + postHandleFrames;
        var expected = checked((long)Math.Round((inputEnd - inputStart) * asset.Stretch,
            MidpointRounding.AwayFromZero));
        if (expected <= 0 || expected > 192_000L * 86_400) throw new VoiceLabTempoException();
        var folder = Path.Combine(Path.GetTempPath(), "voxclip-tempo-" + Guid.NewGuid().ToString("N"));
        VoiceLabCapacity.Require([new VoiceLabCapacity.Allocation(folder, VoiceLabCapacity.Bytes(expected + 4096, 8))]);
        Directory.CreateDirectory(folder);
        try
        {
            var (count, firstPts) = Render(asset, inputStart, inputEnd, ratio, expected,
                Path.Combine(folder, "fitted.f32"), ct);
            // atempo can end with a short buffered tail. Never conceal missing body or handle audio.
            if (Math.Abs((firstPts + count) - expected) > 1024) throw new VoiceLabTempoException();
            var origin = checked((long)Math.Round(preHandleFrames * asset.Stretch,
                MidpointRounding.AwayFromZero) - firstPts);
            var step = asset.SampleRate / sourceRate;
            var firstNeeded = origin - beforeSamples * step;
            var lastNeeded = origin + (outputSamples + afterSamples - 1) * step;
            if (outputSamples <= 0 || firstNeeded < -1e-7 || lastNeeded >= count ||
                origin < 0 || origin >= count) throw new VoiceLabTempoException();
            return OpenOwned(folder, asset.SampleRate, count, origin);
        }
        catch { Directory.Delete(folder, true); throw; }
    }

    internal static (long count, long firstPts) Render(PreparedVoiceLabAsset asset, long inputStart, long inputEnd,
        double ratio, long expected, string destination, CancellationToken ct)
    {
        using var wave = new VoiceLabWaveReader(asset);
        using var graph = NativeHandle.Own(ffmpeg.avfilter_graph_alloc(), NativeKind.Filter);
        var context = (AVFilterGraph*)graph.Pointer;
        context->nb_threads = Math.Clamp(Environment.ProcessorCount, 1, 2);
        AVFilterContext* source = null; AVFilterContext* tempo = null; AVFilterContext* sink = null;
        var args = string.Create(CultureInfo.InvariantCulture,
            $"time_base=1/{asset.SampleRate}:sample_rate={asset.SampleRate}:sample_fmt=flt:channel_layout=stereo");
        Native.Check(ffmpeg.avfilter_graph_create_filter(&source, ffmpeg.avfilter_get_by_name("abuffer"), "source", args, null, context),
            "Create Voice Lab audio source");
        var rate = ratio.ToString("R", CultureInfo.InvariantCulture);
        Native.Check(ffmpeg.avfilter_graph_create_filter(&tempo, ffmpeg.avfilter_get_by_name("atempo"), "fit", "tempo=" + rate, null, context),
            "Create Voice Lab duration fit");
        Native.Check(ffmpeg.avfilter_graph_create_filter(&sink, ffmpeg.avfilter_get_by_name("abuffersink"), "sink", null, null, context),
            "Create Voice Lab audio sink");
        Native.Check(ffmpeg.avfilter_link(source, 0, tempo, 0), "Link Voice Lab audio source");
        Native.Check(ffmpeg.avfilter_link(tempo, 0, sink, 0), "Link Voice Lab audio sink");
        Native.Check(ffmpeg.avfilter_graph_config(context, null), "Initialize Voice Lab duration fit");
        var sinkContext = sink;
        using var sourceFrame = NativeHandle.Own(ffmpeg.av_frame_alloc(), NativeKind.Frame);
        using var outputFrame = NativeHandle.Own(ffmpeg.av_frame_alloc(), NativeKind.Frame);
        using var stream = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024);
        var block = new float[4096 * 2];
        long written = 0;
        long firstPts = ffmpeg.AV_NOPTS_VALUE;
        void Drain(bool eof)
        {
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var output = (AVFrame*)outputFrame.Pointer;
                ffmpeg.av_frame_unref(output);
                var result = ffmpeg.av_buffersink_get_frame(sinkContext, output);
                if (Native.Again(result))
                {
                    if (eof) throw new VoiceLabTempoException();
                    return;
                }
                if (result == ffmpeg.AVERROR_EOF) return;
                Native.Check(result, "Read fitted Voice Lab audio");
                if (output->format != (int)AVSampleFormat.AV_SAMPLE_FMT_FLT || output->ch_layout.nb_channels != 2 ||
                    output->nb_samples <= 0 || output->data[0] == null) throw new VoiceLabTempoException();
                if (written + output->nb_samples > expected + 1024) throw new VoiceLabTempoException();
                if (output->pts != ffmpeg.AV_NOPTS_VALUE)
                {
                    if (firstPts == ffmpeg.AV_NOPTS_VALUE) firstPts = output->pts;
                    if (Math.Abs(output->pts - (firstPts + written)) > 1) throw new VoiceLabTempoException();
                }
                stream.Write(new ReadOnlySpan<byte>(output->data[0], checked(output->nb_samples * 2 * sizeof(float))));
                written += output->nb_samples;
            }
        }
        for (long at = inputStart; at < inputEnd;)
        {
            ct.ThrowIfCancellationRequested();
            var count = (int)Math.Min(4096, inputEnd - at);
            wave.Read(at, 1, block.AsSpan(0, count * 2), ct);
            var frame = (AVFrame*)sourceFrame.Pointer;
            ffmpeg.av_frame_unref(frame);
            frame->format = (int)AVSampleFormat.AV_SAMPLE_FMT_FLT;
            frame->sample_rate = asset.SampleRate;
            frame->nb_samples = count;
            frame->pts = at - inputStart;
            ffmpeg.av_channel_layout_default(&frame->ch_layout, 2);
            Native.Check(ffmpeg.av_frame_get_buffer(frame, 0), "Allocate Voice Lab fit frame");
            block.AsSpan(0, count * 2).CopyTo(new Span<float>(frame->data[0], count * 2));
            Native.Check(ffmpeg.av_buffersrc_add_frame_flags(source, frame, 0), "Submit Voice Lab fit frame");
            at += count;
            Drain(false);
        }
        Native.Check(ffmpeg.av_buffersrc_add_frame_flags(source, null, 0), "Drain Voice Lab duration fit");
        Drain(true);
        ct.ThrowIfCancellationRequested();
        stream.Flush(true);
        return (written, firstPts == ffmpeg.AV_NOPTS_VALUE ? 0 : firstPts);
    }

    internal VoiceLabTempoReader OpenReader() => new(path, Rate, Frames, BodyOriginFrame);

    public void Dispose() => Directory.Delete(folder, true);
}

internal sealed class VoiceLabTempoReader : IDisposable
{
    private readonly FileStream input;
    private readonly float[] cache = new float[4096 * 2];
    private readonly int rate;
    private readonly long frames;
    private readonly long bodyOrigin;
    private long cachedStart = -1;
    private int cachedFrames;

    internal VoiceLabTempoReader(string path, int rate, long frames, long bodyOrigin)
    {
        input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.RandomAccess);
        this.rate = rate; this.frames = frames; this.bodyOrigin = bodyOrigin;
    }

    internal void Read(long relative, double sourceRate, Span<float> stereo, CancellationToken ct)
    {
        var step = rate / sourceRate;
        for (var i = 0; i < stereo.Length / 2; i++)
        {
            if ((i & 4095) == 0) ct.ThrowIfCancellationRequested();
            var position = bodyOrigin + (relative + i) * step;
            if (!double.IsFinite(position) || position < -1e-7 || position >= frames) throw new VoiceLabTempoException();
            var frame = (long)Math.Floor(Math.Max(0, position));
            var fraction = (float)(position - frame);
            for (var channel = 0; channel < 2; channel++)
            {
                var first = Sample(frame, channel);
                var next = frame + 1 < frames ? Sample(frame + 1, channel) : first;
                stereo[2 * i + channel] = first + (next - first) * fraction;
            }
        }
    }

    private float Sample(long frame, int channel)
    {
        if (frame < cachedStart || frame >= cachedStart + cachedFrames)
        {
            cachedStart = frame;
            cachedFrames = (int)Math.Min(4096, frames - frame);
            input.Position = checked(frame * 2 * sizeof(float));
            input.ReadExactly(MemoryMarshal.AsBytes(cache.AsSpan(0, cachedFrames * 2)));
        }
        return cache[checked((int)(frame - cachedStart) * 2 + channel)];
    }

    public void Dispose() => input.Dispose();
}
