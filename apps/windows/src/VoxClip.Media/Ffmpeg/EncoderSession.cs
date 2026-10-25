using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Pipeline;

namespace VoxClip.Media.Ffmpeg;

internal unsafe delegate void PacketSink(AVPacket* packet);

internal sealed unsafe class EncoderSession : IDisposable
{
    private readonly NativeHandle handle;
    private readonly NativeHandle packet;
    internal AVCodecContext* Context => (AVCodecContext*)handle.Pointer;
    internal EncoderSession(string name, OutputSpec output, bool audio = false)
    {
        var software = name == EncoderProbe.SoftwareMediaFoundation;
        var codecName = software ? "h264_mf" : name;
        var codec = ffmpeg.avcodec_find_encoder_by_name(codecName);
        if (codec == null) throw new VoxClipException(VoxClipErrorCode.EncoderUnavailable, ExportErrors.EncoderUnavailable);
        handle = NativeHandle.Own(ffmpeg.avcodec_alloc_context3(codec), NativeKind.Codec);
        try
        {
            var context = Context;
            context->flags |= ffmpeg.AV_CODEC_FLAG_GLOBAL_HEADER;
            AVDictionary* options = null;
            try
            {
                if (audio)
                {
                    context->sample_rate = output.AudioSampleRate;
                    ffmpeg.av_channel_layout_default(&context->ch_layout, output.AudioChannels);
                    context->sample_fmt = AVSampleFormat.AV_SAMPLE_FMT_FLTP;
                    context->bit_rate = output.AudioBitrate;
                    context->time_base = new() { num = 1, den = output.AudioSampleRate };
                }
                else
                {
                    context->width = output.Size.Width; context->height = output.Size.Height;
                    context->pix_fmt = AVPixelFormat.AV_PIX_FMT_NV12;
                    context->framerate = ffmpeg.av_d2q(output.FrameRate, 100_000);
                    context->time_base = new() { num = context->framerate.den, den = context->framerate.num };
                    context->bit_rate = output.VideoBitrate;
                    var rateControl = RateControl(codecName, output.VideoBitrate);
                    context->rc_max_rate = rateControl.MaximumRate;
                    context->rc_buffer_size = rateControl.BufferSize;
                    context->gop_size = (int)Native.Round(2 * output.FrameRate);
                    context->profile = ffmpeg.AV_PROFILE_H264_HIGH;
                    context->color_primaries = AVColorPrimaries.AVCOL_PRI_BT709;
                    context->color_trc = AVColorTransferCharacteristic.AVCOL_TRC_BT709;
                    context->colorspace = AVColorSpace.AVCOL_SPC_BT709;
                    context->color_range = AVColorRange.AVCOL_RANGE_MPEG;
                    switch (codecName)
                    {
                        case "h264_nvenc":
                            Set(&options, "preset", "p5"); Set(&options, "tune", "hq"); Set(&options, "rc", "vbr"); context->max_b_frames = 2; break;
                        case "h264_qsv": Set(&options, "preset", "medium"); break;
                        case "h264_amf": Set(&options, "usage", "transcoding"); Set(&options, "quality", "balanced"); Set(&options, "rc", "vbr_peak"); break;
                        case "h264_mf": Set(&options, "hw_encoding", software ? "0" : "1"); Set(&options, "rate_control", "pc_vbr"); break;
                        default: throw new VoxClipException(VoxClipErrorCode.EncoderUnavailable, ExportErrors.EncoderUnavailable);
                    }
                    if (codecName != "h264_mf") Set(&options, "profile", "high");
                }
                Native.Check(ffmpeg.avcodec_open2(context, codec, &options), "Open " + name, VoxClipErrorCode.ExportFailed);
            }
            finally { ffmpeg.av_dict_free(&options); }
            packet = NativeHandle.Own(ffmpeg.av_packet_alloc(), NativeKind.Packet);
        }
        catch { Dispose(); throw; }
    }

    internal void Send(AVFrame* frame, PacketSink consume, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        Native.Check(ffmpeg.avcodec_send_frame(Context, frame), "Submit encoder frame", VoxClipErrorCode.ExportFailed);
        var encoded = (AVPacket*)packet.Pointer;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var result = ffmpeg.avcodec_receive_packet(Context, encoded);
            if (Native.Again(result) || result == ffmpeg.AVERROR_EOF) break;
            Native.Check(result, "Receive encoded packet", VoxClipErrorCode.ExportFailed);
            try { consume(encoded); }
            finally { ffmpeg.av_packet_unref(encoded); }
        }
    }

    private static void Set(AVDictionary** options, string key, string value) => Native.Check(ffmpeg.av_dict_set(options, key, value, 0), "Set encoder option", VoxClipErrorCode.ExportFailed);
    internal static (long MaximumRate, int BufferSize) RateControl(string name, long bitrate) =>
        (name is "h264_nvenc" or "h264_qsv" or "h264_amf" ? (long)(bitrate * 1.5) : 0,
         name == "h264_nvenc" ? (int)Math.Min(int.MaxValue, bitrate * 2) : 0);
    public void Dispose() { packet?.Dispose(); handle?.Dispose(); }
}
