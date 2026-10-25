using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

/// <summary>FFmpeg presentation-timeline probing; architecture §6.2.</summary>
public sealed class FfmpegMediaProbe : IMediaProbe
{
    /// <inheritdoc />
    public Task<MediaInfo> ProbeAsync(string mediaPath, CancellationToken ct) => MediaThread.Run("vc-probe", () => Probe(mediaPath, ct), ct);

    private static unsafe MediaInfo Probe(string path, CancellationToken ct)
    {
        FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult();
        using var handle = NativeHandle.Own(Native.Open(path), NativeKind.Input);
        var format = (AVFormatContext*)handle.Pointer;
        var videoIndex = Native.Stream(format, AVMediaType.AVMEDIA_TYPE_VIDEO);
        var audioIndex = Native.Stream(format, AVMediaType.AVMEDIA_TYPE_AUDIO);
        VideoTrackInfo? video = null;
        AudioTrackInfo? audio = null;
        string? videoCodec = null;
        string? audioCodec = null;
        var hdr = false;
        var duration = format->duration == ffmpeg.AV_NOPTS_VALUE ? 0 : format->duration / (double)ffmpeg.AV_TIME_BASE;
        if (videoIndex >= 0)
        {
            var stream = format->streams[videoIndex];
            var parameters = stream->codecpar;
            var rotation = 0;
            var matrix = ffmpeg.av_packet_side_data_get(parameters->coded_side_data, parameters->nb_coded_side_data, AVPacketSideDataType.AV_PKT_DATA_DISPLAYMATRIX);
            if (matrix != null && matrix->size >= 36)
            {
                var degrees = -ffmpeg.av_display_rotation_get(in *(int_array9*)matrix->data);
                if (double.IsFinite(degrees)) rotation = ((int)Native.Round(degrees / 90) * 90 % 360 + 360) % 360;
            }
            var rate = ffmpeg.av_guess_frame_rate(format, stream, null);
            video = new(parameters->width, parameters->height, rate.den == 0 ? 30 : ffmpeg.av_q2d(rate), rotation);
            videoCodec = ffmpeg.avcodec_get_name(parameters->codec_id);
            hdr = parameters->color_trc is AVColorTransferCharacteristic.AVCOL_TRC_SMPTE2084 or AVColorTransferCharacteristic.AVCOL_TRC_ARIB_STD_B67;
        }
        var timelineStart = 0.0;
        if (audioIndex >= 0)
        {
            var stream = format->streams[audioIndex];
            audio = new(stream->codecpar->sample_rate, stream->codecpar->ch_layout.nb_channels);
            audioCodec = ffmpeg.avcodec_get_name(stream->codecpar->codec_id);
            timelineStart = Native.Seconds(stream->start_time, stream->time_base) -
                (format->start_time == ffmpeg.AV_NOPTS_VALUE ? 0 : format->start_time / (double)ffmpeg.AV_TIME_BASE);
        }
        var durationIndex = audioIndex >= 0 ? audioIndex : videoIndex;
        if (durationIndex >= 0)
        {
            var stream = format->streams[durationIndex];
            duration = PresentationDuration(Native.Seconds(stream->start_time, stream->time_base),
                stream->duration == ffmpeg.AV_NOPTS_VALUE ? null : Native.Seconds(stream->duration, stream->time_base),
                format->start_time == ffmpeg.AV_NOPTS_VALUE ? 0 : format->start_time / (double)ffmpeg.AV_TIME_BASE, duration);
        }
        if (!double.IsFinite(duration) || duration <= 0 || (video is null && audio is null))
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't decode this video: the file contains no playable media. Your edits are saved.");
        var size = video is null ? new PixelSize(0, 0) : video.RotationDegrees is 90 or 270
            ? new PixelSize(video.Height, video.Width) : new PixelSize(video.Width, video.Height);
        return new(Path.GetFullPath(path), duration, video, audio, size, videoCodec, audioCodec, hdr, videoIndex, audioIndex, timelineStart);
    }

    internal static double PresentationDuration(double start, double? duration, double origin, double fallback)
        => duration is { } length ? start + length - origin : fallback;
}
