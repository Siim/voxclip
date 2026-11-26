using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

public sealed partial class Exporter
{
    internal static async Task WriteLipsyncVideoAsync(string input, string path, OutputSpec output, long frames,
        Action<VideoDecoder, long, PixelBuffer, CancellationToken> picture, CancellationToken ct, Action? release = null)
    {
        var available = await new EncoderProbe().ProbeAsync(WindowsAdapterIdentity.Read(), null, ct).ConfigureAwait(false);
        var name = EncoderProbe.Ladder.FirstOrDefault(candidate => available.Any(encoder => encoder.Name == candidate && encoder.Available));
        if (name is null) throw new VoxClipException(VoxClipErrorCode.EncoderUnavailable, ExportErrors.EncoderUnavailable);
        await MediaThread.Run("vc-lipsync-encode", () =>
        {
            try { return WriteLipsyncVideo(input, path, output, frames, picture, name, ct); }
            finally { release?.Invoke(); }
        }, ct).ConfigureAwait(false);
    }

    private static unsafe bool WriteLipsyncVideo(string input, string path, OutputSpec output, long frames,
        Action<VideoDecoder, long, PixelBuffer, CancellationToken> picture, string encoder, CancellationToken ct)
    {
        var size = output.Size;
        using var decoder = new VideoDecoder(input, hardware: false);
        using var video = new EncoderSession(encoder, output);
        using var mux = CreateMux(path, video, null, credits: null, out var stream, out _);
        var format = (AVFormatContext*)mux.Pointer;
        using var handle = NativeHandle.Own(Native.Frame(AVPixelFormat.AV_PIX_FMT_NV12, size.Width, size.Height), NativeKind.Frame);
        var nv12 = (AVFrame*)handle.Pointer;
        using var scaling = NativeHandle.Own(ffmpeg.sws_getContext(size.Width, size.Height, AVPixelFormat.AV_PIX_FMT_BGRA,
            size.Width, size.Height, AVPixelFormat.AV_PIX_FMT_NV12, (int)SwsFlags.SWS_BILINEAR, null, null, null), NativeKind.Scale);
        Native.Colors((SwsContext*)scaling.Pointer, true);
        var buffer = new PixelBuffer(new byte[checked(size.Width * size.Height * 4)], size.Width, size.Height, size.Width * 4);
        for (long index = 0; index < frames; index++)
        {
            ct.ThrowIfCancellationRequested();
            picture(decoder, index, buffer, ct);
            Native.Check(ffmpeg.av_frame_make_writable(nv12), "Reuse lip-sync video frame", VoxClipErrorCode.ExportFailed);
            using var memory = buffer.Pixels.Pin();
            var source = new byte_ptrArray4(); source[0] = (byte*)memory.Pointer;
            var strides = new int_array4(); strides[0] = buffer.Stride;
            Native.Check(ffmpeg.sws_scale((SwsContext*)scaling.Pointer, source, strides, 0, size.Height, nv12->data, nv12->linesize),
                "Convert lip-sync video frame", VoxClipErrorCode.ExportFailed);
            nv12->pts = index; nv12->duration = 1;
            nv12->color_primaries = AVColorPrimaries.AVCOL_PRI_BT709;
            nv12->color_trc = AVColorTransferCharacteristic.AVCOL_TRC_BT709;
            nv12->colorspace = AVColorSpace.AVCOL_SPC_BT709;
            nv12->color_range = AVColorRange.AVCOL_RANGE_MPEG;
            video.Send(nv12, packet => Mux(format, video, stream, packet), ct);
        }
        video.Send(null, packet => Mux(format, video, stream, packet), ct);
        Native.Check(ffmpeg.av_write_trailer(format), "Finalize lip-sync video", VoxClipErrorCode.ExportFailed);
        return true;
    }
}
