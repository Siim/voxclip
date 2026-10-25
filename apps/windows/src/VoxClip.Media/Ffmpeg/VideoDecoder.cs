using System.Buffers;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Ffmpeg;

internal sealed unsafe class VideoDecoder : IDisposable
{
    private readonly DecodeSession decoder;
    private readonly NativeHandle transfer;
    private NativeHandle? scale;
    private ToneMapper? toneMapper;
    private AVPixelFormat scaleFormat = AVPixelFormat.AV_PIX_FMT_NONE;
    private int scaleWidth;
    private int scaleHeight;
    private int toneWidth;
    private int toneHeight;
    private AVPixelFormat toneFormat = AVPixelFormat.AV_PIX_FMT_NONE;
    private byte[] current;
    private byte[] next;
    private bool hasCurrent;
    private bool hasNext;
    private double nextPts;
    internal double Position { get; private set; }
    internal int Width { get; }
    internal int Height { get; }

    internal VideoDecoder(string path, bool hardware = true)
    {
        decoder = new(path, AVMediaType.AVMEDIA_TYPE_VIDEO, hardware);
        try
        {
            Width = decoder.Codec->width; Height = decoder.Codec->height;
            current = ArrayPool<byte>.Shared.Rent(checked(Width * Height * 4));
            next = ArrayPool<byte>.Shared.Rent(checked(Width * Height * 4));
            transfer = NativeHandle.Own(ffmpeg.av_frame_alloc(), NativeKind.Frame);
        }
        catch { Dispose(); throw; }
    }

    internal PixelBuffer ReadAt(double sourceTime, bool exact, CancellationToken ct)
    {
        if (hasCurrent && (sourceTime < Position || sourceTime - Position > 2)) Seek(sourceTime);
        if (!hasCurrent)
        {
            if (sourceTime > 2) decoder.Seek(sourceTime);
            if (!Read(current, out var pts, ct)) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: the video contains no decoded frames. Your edits are saved.");
            Position = pts; hasCurrent = true;
            hasNext = Read(next, out nextPts, ct);
        }
        var halfFrame = exact ? 0.5 / Math.Max(1, ffmpeg.av_q2d(decoder.Stream->avg_frame_rate)) : 0;
        while (hasNext && (exact ? Position < sourceTime - halfFrame : nextPts <= sourceTime + 1e-9))
        {
            (current, next) = (next, current);
            Position = nextPts;
            hasNext = Read(next, out nextPts, ct);
        }
        return new(current.AsMemory(0, Width * Height * 4), Width, Height, Width * 4);
    }

    internal void Seek(double sourceTime)
    {
        decoder.Seek(Math.Max(0, sourceTime));
        hasCurrent = false; hasNext = false;
    }

    private bool Read(byte[] destination, out double pts, CancellationToken ct)
    {
        pts = 0;
        if (!decoder.Next(ct)) return false;
        pts = decoder.Timestamp;
        var frame = decoder.Frame;
        if ((AVPixelFormat)frame->format == AVPixelFormat.AV_PIX_FMT_D3D11)
        {
            var software = (AVFrame*)transfer.Pointer;
            ffmpeg.av_frame_unref(software);
            Native.Check(ffmpeg.av_hwframe_transfer_data(software, frame, 0), "Copy hardware video frame");
            Native.Check(ffmpeg.av_frame_copy_props(software, frame), "Copy hardware frame colour properties");
            frame = software;
        }
        if (frame->color_trc is AVColorTransferCharacteristic.AVCOL_TRC_SMPTE2084 or AVColorTransferCharacteristic.AVCOL_TRC_ARIB_STD_B67 && ToneMapper.Available)
        {
            if (toneMapper is null || toneWidth != frame->width || toneHeight != frame->height || toneFormat != (AVPixelFormat)frame->format)
            {
                toneMapper?.Dispose();
                toneMapper = new(frame, decoder.Stream->time_base);
                toneWidth = frame->width; toneHeight = frame->height; toneFormat = (AVPixelFormat)frame->format;
            }
            frame = toneMapper.Convert(frame);
        }
        if (frame->width <= 0 || frame->height <= 0 || frame->data[0] == null)
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: a video frame cannot be converted. Your edits are saved.");
        if (scale is null || scaleWidth != frame->width || scaleHeight != frame->height || scaleFormat != (AVPixelFormat)frame->format)
        {
            scale?.Dispose(); scale = null;
            var context = ffmpeg.sws_getContext(frame->width, frame->height, (AVPixelFormat)frame->format,
                Width, Height, AVPixelFormat.AV_PIX_FMT_BGRA, (int)SwsFlags.SWS_BILINEAR, null, null, null);
            if (context == null) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: a video frame cannot be converted. Your edits are saved.");
            scale = NativeHandle.Own(context, NativeKind.Scale);
            Native.Colors((SwsContext*)scale.Pointer, frame->color_range == AVColorRange.AVCOL_RANGE_JPEG);
            scaleWidth = frame->width; scaleHeight = frame->height; scaleFormat = (AVPixelFormat)frame->format;
        }
        fixed (byte* pixels = destination)
        {
            var output = new byte_ptrArray4(); output[0] = pixels;
            var strides = new int_array4(); strides[0] = Width * 4;
            var rows = ffmpeg.sws_scale((SwsContext*)scale.Pointer, frame->data, frame->linesize, 0, frame->height, output, strides);
            Native.Check(rows, "Convert decoded video");
            if (rows != Height) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: a video frame cannot be converted. Your edits are saved.");
        }
        return true;
    }

    public void Dispose()
    {
        toneMapper?.Dispose(); scale?.Dispose(); transfer?.Dispose(); decoder?.Dispose();
        if (current is not null) { ArrayPool<byte>.Shared.Return(current); current = null!; }
        if (next is not null) { ArrayPool<byte>.Shared.Return(next); next = null!; }
    }
}
