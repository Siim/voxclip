using System.Runtime.InteropServices;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Ffmpeg;

internal static unsafe class Native
{
    internal static void Check(int result, string operation, VoxClipErrorCode code = VoxClipErrorCode.DecodeFailed)
    {
        if (result >= 0) return;
        var text = stackalloc byte[1024];
        ffmpeg.av_strerror(result, text, 1024);
        FfmpegLoader.Check(result, operation, Marshal.PtrToStringUTF8((nint)text) ?? "Native media failure.", code);
    }

    internal static bool Again(int result) => result == ffmpeg.AVERROR(ffmpeg.EAGAIN);
    internal static double Seconds(long pts, AVRational timeBase) => pts == ffmpeg.AV_NOPTS_VALUE ? 0 : pts * ffmpeg.av_q2d(timeBase);
    internal static long Round(double value) => checked((long)Math.Floor(value + 0.5));

    internal static AVFormatContext* Open(string path)
    {
        if (!File.Exists(path)) throw new VoxClipException(VoxClipErrorCode.MediaMissing, $"Can't find {Path.GetFileName(path)}. Edits are saved.");
        AVFormatContext* format = null;
        AVDictionary* options = null;
        try
        {
            Check(ffmpeg.av_dict_set(&options, "protocol_whitelist", "file", 0), "Restrict media protocols");
            Check(ffmpeg.avformat_open_input(&format, path, null, &options), "Open media");
            Check(ffmpeg.avformat_find_stream_info(format, null), "Read media streams");
            return format;
        }
        catch { ffmpeg.avformat_close_input(&format); throw; }
        finally { ffmpeg.av_dict_free(&options); }
    }

    internal static int Stream(AVFormatContext* format, AVMediaType type)
    {
        var best = ffmpeg.av_find_best_stream(format, type, -1, -1, null, 0);
        if (best < 0 && best != ffmpeg.AVERROR_STREAM_NOT_FOUND && best != ffmpeg.AVERROR_DECODER_NOT_FOUND) Check(best, "Find media stream");
        if (type == AVMediaType.AVMEDIA_TYPE_AUDIO)
            for (var index = 0; index < format->nb_streams; index++)
                if (format->streams[index]->codecpar->codec_type == type) return index;
        return best;
    }

    internal static AVCodecContext* Decoder(AVStream* stream)
    {
        var codec = ffmpeg.avcodec_find_decoder(stream->codecpar->codec_id);
        if (codec == null) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: no decoder is available. Your edits are saved.");
        var context = ffmpeg.avcodec_alloc_context3(codec);
        if (context == null) throw new OutOfMemoryException();
        try
        {
            Check(ffmpeg.avcodec_parameters_to_context(context, stream->codecpar), "Configure decoder");
            context->pkt_timebase = stream->time_base;
            context->thread_count = Math.Clamp(Environment.ProcessorCount, 1, 8);
            return context;
        }
        catch { ffmpeg.avcodec_free_context(&context); throw; }
    }

    internal static int SourceMatrix(AVColorSpace sourceSpace) => sourceSpace switch
    {
        AVColorSpace.AVCOL_SPC_FCC => ffmpeg.SWS_CS_FCC,
        AVColorSpace.AVCOL_SPC_BT470BG or AVColorSpace.AVCOL_SPC_SMPTE170M => ffmpeg.SWS_CS_ITU601,
        AVColorSpace.AVCOL_SPC_SMPTE240M => ffmpeg.SWS_CS_SMPTE240M,
        AVColorSpace.AVCOL_SPC_BT2020_NCL => ffmpeg.SWS_CS_BT2020,
        _ => ffmpeg.SWS_CS_ITU709
    };

    internal static void Colors(SwsContext* context, bool fullInput = false,
        AVColorSpace sourceSpace = AVColorSpace.AVCOL_SPC_BT709)
    {
        var source = ffmpeg.sws_getCoefficients(SourceMatrix(sourceSpace));
        var destination = ffmpeg.sws_getCoefficients(ffmpeg.SWS_CS_ITU709);
        Check(ffmpeg.sws_setColorspaceDetails(context, *(int_array4*)source, fullInput ? 1 : 0,
            *(int_array4*)destination, 0, 0, 1 << 16, 1 << 16), "Set BT.709 conversion");
    }

    internal static AVFrame* Frame(AVPixelFormat format, int width, int height)
    {
        var frame = ffmpeg.av_frame_alloc();
        if (frame == null) throw new OutOfMemoryException();
        frame->format = (int)format; frame->width = width; frame->height = height;
        try { Check(ffmpeg.av_frame_get_buffer(frame, 32), "Allocate video frame"); return frame; }
        catch { ffmpeg.av_frame_free(&frame); throw; }
    }
}

internal enum NativeKind { Input, Output, Codec, Frame, Packet, Scale, Resample, Buffer, Filter }

internal sealed unsafe class NativeHandle : SafeHandle
{
    private readonly int owner = Environment.CurrentManagedThreadId;
    private readonly NativeKind resourceKind;
    private NativeHandle(nint pointer, NativeKind kind) : base(0, true) { resourceKind = kind; SetHandle(pointer); }
    public override bool IsInvalid => handle == 0;
    internal nint Pointer { get { ObjectDisposedException.ThrowIf(IsClosed, this); return handle; } }

    internal static NativeHandle Own(void* pointer, NativeKind kind)
    {
        if (pointer == null) throw new OutOfMemoryException();
        return new((nint)pointer, kind);
    }

    protected override bool ReleaseHandle()
    {
        var pointer = (void*)handle;
        switch (resourceKind)
        {
            case NativeKind.Input: var input = (AVFormatContext*)pointer; ffmpeg.avformat_close_input(&input); break;
            case NativeKind.Output:
                var output = (AVFormatContext*)pointer;
                if (output->pb != null) ffmpeg.avio_closep(&output->pb);
                ffmpeg.avformat_free_context(output); break;
            case NativeKind.Codec: var codec = (AVCodecContext*)pointer; ffmpeg.avcodec_free_context(&codec); break;
            case NativeKind.Frame: var frame = (AVFrame*)pointer; ffmpeg.av_frame_free(&frame); break;
            case NativeKind.Packet: var packet = (AVPacket*)pointer; ffmpeg.av_packet_free(&packet); break;
            case NativeKind.Scale: ffmpeg.sws_freeContext((SwsContext*)pointer); break;
            case NativeKind.Resample: var resample = (SwrContext*)pointer; ffmpeg.swr_free(&resample); break;
            case NativeKind.Buffer: var buffer = (AVBufferRef*)pointer; ffmpeg.av_buffer_unref(&buffer); break;
            case NativeKind.Filter: var filter = (AVFilterGraph*)pointer; ffmpeg.avfilter_graph_free(&filter); break;
        }
        handle = 0;
        return true;
    }

    internal void DisposeOnOwner()
    {
        if (Environment.CurrentManagedThreadId != owner) throw new InvalidOperationException("Native context used from another thread.");
        Dispose();
    }

}

internal static class MediaThread
{
    internal static Task<T> Run<T>(string name, Func<T> action, CancellationToken ct)
    {
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { ct.ThrowIfCancellationRequested(); completion.SetResult(action()); }
            catch (OperationCanceledException) { completion.TrySetCanceled(ct); }
            catch (Exception exception) { completion.SetException(exception); }
        }) { IsBackground = true, Name = name };
        thread.Start();
        return completion.Task;
    }
}
