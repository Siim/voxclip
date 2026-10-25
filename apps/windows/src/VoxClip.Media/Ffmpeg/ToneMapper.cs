using System.Globalization;
using FFmpeg.AutoGen;

namespace VoxClip.Media.Ffmpeg;

internal sealed unsafe class ToneMapper : IDisposable
{
    private readonly NativeHandle graph;
    private readonly NativeHandle output;
    private readonly AVFilterContext* source;
    private readonly AVFilterContext* sink;
    internal static bool Available => ffmpeg.avfilter_get_by_name("zscale") != null;

    internal ToneMapper(AVFrame* frame, AVRational timeBase)
    {
        graph = NativeHandle.Own(ffmpeg.avfilter_graph_alloc(), NativeKind.Filter);
        AVFilterInOut* inputs = null;
        AVFilterInOut* outputs = null;
        try
        {
            var context = (AVFilterGraph*)graph.Pointer;
            context->nb_threads = Math.Clamp(Environment.ProcessorCount, 1, 8);
            AVFilterContext* input = null;
            AVFilterContext* result = null;
            var arguments = string.Create(CultureInfo.InvariantCulture,
                $"video_size={frame->width}x{frame->height}:pix_fmt={frame->format}:time_base={timeBase.num}/{timeBase.den}:pixel_aspect=1/1:colorspace={(int)frame->colorspace}:range={(int)frame->color_range}");
            Native.Check(ffmpeg.avfilter_graph_create_filter(&input, ffmpeg.avfilter_get_by_name("buffer"), "source", arguments, null, context), "Create HDR source");
            Native.Check(ffmpeg.avfilter_graph_create_filter(&result, ffmpeg.avfilter_get_by_name("buffersink"), "sink", null, null, context), "Create HDR sink");
            source = input; sink = result;
            outputs = ffmpeg.avfilter_inout_alloc(); inputs = ffmpeg.avfilter_inout_alloc();
            if (outputs == null || inputs == null) throw new OutOfMemoryException();
            outputs->name = ffmpeg.av_strdup("in"); outputs->filter_ctx = source; outputs->pad_idx = 0;
            inputs->name = ffmpeg.av_strdup("out"); inputs->filter_ctx = sink; inputs->pad_idx = 0;
            var filters = Filters(frame->color_range, frame->color_primaries, frame->color_trc, frame->colorspace);
            Native.Check(ffmpeg.avfilter_graph_parse_ptr(context, filters,
                &inputs, &outputs, null), "Configure HDR tone mapping");
            Native.Check(ffmpeg.avfilter_graph_config(context, null), "Initialize HDR tone mapping");
            output = NativeHandle.Own(ffmpeg.av_frame_alloc(), NativeKind.Frame);
        }
        catch { Dispose(); throw; }
        finally { ffmpeg.avfilter_inout_free(&inputs); ffmpeg.avfilter_inout_free(&outputs); }
    }

    internal static string Filters(AVColorRange range, AVColorPrimaries primaries, AVColorTransferCharacteristic transfer, AVColorSpace matrix)
    {
        var options = "zscale=t=linear:npl=100";
        var inputRange = range switch { AVColorRange.AVCOL_RANGE_MPEG => "limited", AVColorRange.AVCOL_RANGE_JPEG => "full", _ => null };
        var inputPrimaries = primaries switch
        {
            AVColorPrimaries.AVCOL_PRI_BT709 => "bt709", AVColorPrimaries.AVCOL_PRI_BT2020 => "bt2020",
            AVColorPrimaries.AVCOL_PRI_SMPTE432 => "smpte432", _ => null
        };
        var inputTransfer = transfer switch
        {
            AVColorTransferCharacteristic.AVCOL_TRC_BT709 => "bt709",
            AVColorTransferCharacteristic.AVCOL_TRC_SMPTE2084 => "smpte2084",
            AVColorTransferCharacteristic.AVCOL_TRC_ARIB_STD_B67 => "arib-std-b67", _ => null
        };
        var inputMatrix = matrix switch
        {
            AVColorSpace.AVCOL_SPC_BT709 => "bt709", AVColorSpace.AVCOL_SPC_BT2020_NCL => "2020_ncl",
            AVColorSpace.AVCOL_SPC_BT2020_CL => "2020_cl", AVColorSpace.AVCOL_SPC_RGB => "gbr", _ => null
        };
        if (inputRange is not null) options += ":rin=" + inputRange;
        if (inputPrimaries is not null) options += ":pin=" + inputPrimaries;
        if (inputTransfer is not null) options += ":tin=" + inputTransfer;
        if (inputMatrix is not null) options += ":min=" + inputMatrix;
        return options + ",format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=nv12";
    }

    internal AVFrame* Convert(AVFrame* frame)
    {
        var converted = (AVFrame*)output.Pointer;
        ffmpeg.av_frame_unref(converted);
        Native.Check(ffmpeg.av_buffersrc_add_frame_flags(source, frame, (int)AvBuffersrcFlag.AV_BUFFERSRC_FLAG_KEEP_REF), "Submit HDR frame");
        Native.Check(ffmpeg.av_buffersink_get_frame(sink, converted), "Read tone-mapped frame");
        return converted;
    }

    public void Dispose() { output?.Dispose(); graph?.Dispose(); }
}
