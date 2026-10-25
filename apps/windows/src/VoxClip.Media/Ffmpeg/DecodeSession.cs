using FFmpeg.AutoGen;

namespace VoxClip.Media.Ffmpeg;

internal sealed unsafe class DecodeSession : IDisposable
{
    private readonly NativeHandle input;
    private NativeHandle codec;
    private readonly NativeHandle packet;
    private readonly NativeHandle frame;
    private NativeHandle? device;
    private readonly AVCodecContext_get_format hardwareFormat = SelectHardware;
    private bool draining;
    private double lastTimestamp = double.NegativeInfinity;
    internal AVFormatContext* Format => (AVFormatContext*)input.Pointer;
    internal AVCodecContext* Codec => (AVCodecContext*)codec.Pointer;
    internal AVStream* Stream => Format->streams[Index];
    internal AVFrame* Frame => (AVFrame*)frame.Pointer;
    internal int Index { get; }
    internal long PacketsRead { get; private set; }
    internal long BytesRead => Format->pb == null ? 0 : Format->pb->bytes_read;
    internal double Origin => Format->start_time == ffmpeg.AV_NOPTS_VALUE ? 0 : Format->start_time / (double)ffmpeg.AV_TIME_BASE;
    internal double Timestamp => Native.Seconds(Frame->best_effort_timestamp, Stream->time_base) - Origin;

    internal DecodeSession(string path, AVMediaType type, bool hardware = false)
    {
        input = NativeHandle.Own(Native.Open(path), NativeKind.Input);
        try
        {
            Index = Native.Stream(Format, type);
            if (Index < 0) throw new VoxClip.Core.Domain.Shared.VoxClipException(
                type == AVMediaType.AVMEDIA_TYPE_AUDIO ? VoxClip.Core.Domain.Shared.VoxClipErrorCode.NoAudioTrack : VoxClip.Core.Domain.Shared.VoxClipErrorCode.DecodeFailed,
                type == AVMediaType.AVMEDIA_TYPE_AUDIO ? "This video has no audio track, so there is nothing to transcribe."
                    : "VoxClip couldn't decode this video: the video track is missing. Your edits are saved.");
            for (var index = 0; index < Format->nb_streams; index++)
                if (index != Index) Format->streams[index]->discard = AVDiscard.AVDISCARD_ALL;
            codec = NativeHandle.Own(Native.Decoder(Stream), NativeKind.Codec);
            if (hardware && OperatingSystem.IsWindows())
            {
                AVBufferRef* reference = null;
                if (ffmpeg.av_hwdevice_ctx_create(&reference, AVHWDeviceType.AV_HWDEVICE_TYPE_D3D11VA, null, null, 0) >= 0)
                {
                    device = NativeHandle.Own(reference, NativeKind.Buffer);
                    Codec->hw_device_ctx = ffmpeg.av_buffer_ref(reference);
                    Codec->get_format = hardwareFormat;
                }
            }
            var result = ffmpeg.avcodec_open2(Codec, Codec->codec, null);
            if (result < 0 && device is not null)
            {
                codec.Dispose();
                device.Dispose(); device = null;
                codec = NativeHandle.Own(Native.Decoder(Stream), NativeKind.Codec);
                result = ffmpeg.avcodec_open2(Codec, Codec->codec, null);
            }
            Native.Check(result, "Open decoder");
            packet = NativeHandle.Own(ffmpeg.av_packet_alloc(), NativeKind.Packet);
            frame = NativeHandle.Own(ffmpeg.av_frame_alloc(), NativeKind.Frame);
        }
        catch { Dispose(); throw; }
    }

    private static AVPixelFormat SelectHardware(AVCodecContext* context, AVPixelFormat* formats)
    {
        for (var index = 0; formats[index] != AVPixelFormat.AV_PIX_FMT_NONE; index++)
            if (formats[index] == AVPixelFormat.AV_PIX_FMT_D3D11) return formats[index];
        return formats[0];
    }

    internal bool Next(CancellationToken ct)
    {
        try
        {
            var available = NextCore(ct);
            if (available) lastTimestamp = Timestamp;
            return available;
        }
        catch (VoxClip.Core.Domain.Shared.MediaException) when (device is not null)
        {
            var previous = lastTimestamp;
            codec.Dispose(); device.Dispose(); device = null;
            codec = NativeHandle.Own(Native.Decoder(Stream), NativeKind.Codec);
            Native.Check(ffmpeg.avcodec_open2(Codec, Codec->codec, null), "Open software decoder");
            Seek(double.IsFinite(previous) ? Math.Max(0, previous) : 0);
            while (NextCore(ct))
            {
                if (Timestamp <= previous + 1e-9) continue;
                lastTimestamp = Timestamp; return true;
            }
            return false;
        }
    }

    private bool NextCore(CancellationToken ct)
    {
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            ffmpeg.av_frame_unref(Frame);
            var result = ffmpeg.avcodec_receive_frame(Codec, Frame);
            if (result >= 0) return true;
            if (result == ffmpeg.AVERROR_EOF) return false;
            if (!Native.Again(result)) Native.Check(result, "Decode frame");
            if (draining) return false;
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var nativePacket = (AVPacket*)packet.Pointer;
                ffmpeg.av_packet_unref(nativePacket);
                result = ffmpeg.av_read_frame(Format, nativePacket);
                if (result == ffmpeg.AVERROR_EOF)
                {
                    Native.Check(ffmpeg.avcodec_send_packet(Codec, null), "Drain decoder");
                    draining = true;
                    break;
                }
                Native.Check(result, "Read media packet");
                PacketsRead++;
                if (nativePacket->stream_index != Index) continue;
                Native.Check(ffmpeg.avcodec_send_packet(Codec, nativePacket), "Send decoder packet");
                break;
            }
        }
    }

    internal void Seek(double seconds)
    {
        var seekIndex = Index;
        var container = System.Runtime.InteropServices.Marshal.PtrToStringUTF8((nint)Format->iformat->name);
        if (Codec->codec_type == AVMediaType.AVMEDIA_TYPE_AUDIO && container?.Contains("matroska", StringComparison.Ordinal) == true)
        {
            var videoIndex = Native.Stream(Format, AVMediaType.AVMEDIA_TYPE_VIDEO);
            if (videoIndex >= 0 && ffmpeg.avformat_index_get_entries_count(Format->streams[videoIndex]) > 0)
                seekIndex = videoIndex;
        }
        var timeBase = ffmpeg.av_q2d(Format->streams[seekIndex]->time_base);
        try
        {
            if (seekIndex != Index) Format->streams[seekIndex]->discard = AVDiscard.AVDISCARD_DEFAULT;
            var result = SeekWithFallback(seconds, Origin, timeBase,
                target => ffmpeg.av_seek_frame(Format, seekIndex, target, ffmpeg.AVSEEK_FLAG_BACKWARD));
            Native.Check(result, "Seek media");
        }
        finally
        {
            if (seekIndex != Index) Format->streams[seekIndex]->discard = AVDiscard.AVDISCARD_ALL;
        }
        ffmpeg.avcodec_flush_buffers(Codec);
        draining = false;
        lastTimestamp = double.NegativeInfinity;
    }

    internal static int SeekWithFallback(double seconds, double origin, double timeBase, Func<long, int> seek)
    {
        var target = (long)Math.Floor((seconds + origin) / timeBase);
        var result = seek(target);
        if (result < 0 && seconds < 0)
            result = seek((long)Math.Floor(origin / timeBase));
        return result;
    }

    public void Dispose()
    {
        frame?.Dispose(); packet?.Dispose(); codec?.Dispose(); device?.Dispose(); input?.Dispose();
        GC.KeepAlive(hardwareFormat);
    }
}
