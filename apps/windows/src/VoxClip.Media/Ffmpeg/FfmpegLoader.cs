using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Media.Ffmpeg;

/// <summary>Single native loader and LGPL/ABI gate; architecture §6.1.</summary>
public static class FfmpegLoader
{
    private static readonly object Gate = new();
    private static bool initialized;
    internal static string? RootOverride { get; set; }
    internal static IReadOnlyDictionary<string, int> LibraryMajors { get; } = new Dictionary<string, int>
    {
        ["avcodec"] = ffmpeg.LIBAVCODEC_VERSION_MAJOR,
        ["avformat"] = ffmpeg.LIBAVFORMAT_VERSION_MAJOR,
        ["avutil"] = ffmpeg.LIBAVUTIL_VERSION_MAJOR,
        ["avfilter"] = ffmpeg.LIBAVFILTER_VERSION_MAJOR,
        ["swresample"] = ffmpeg.LIBSWRESAMPLE_VERSION_MAJOR,
        ["swscale"] = ffmpeg.LIBSWSCALE_VERSION_MAJOR
    };
    /// <summary>Load verified dynamic libraries from the app directory. win-media installs SafeHandles and owner-thread initialization here.</summary>
    public static Task InitializeAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        lock (Gate)
        {
            if (initialized) return Task.CompletedTask;
            try { Initialize(); }
            catch (VoxClipException) { throw; }
            catch (Exception exception) when (exception is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or NotSupportedException)
            {
                throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing,
                    "VoxClip is missing some of its files. Reinstall VoxClip.", exception);
            }
            initialized = true;
        }
        return Task.CompletedTask;
    }
    private static unsafe void Initialize()
    {
        ffmpeg.RootPath = Path.GetFullPath(RootOverride ?? AppContext.BaseDirectory);
        ValidateConfiguration(ffmpeg.avcodec_configuration());
        if (!ffmpeg.avcodec_license().StartsWith("LGPL", StringComparison.Ordinal))
            throw new VoxClipException(VoxClipErrorCode.FfmpegLicenceGate, "This VoxClip build contains a GPL FFmpeg and can't run.");
        var versions = new Dictionary<string, uint>
        {
            ["avcodec"] = ffmpeg.avcodec_version(), ["avformat"] = ffmpeg.avformat_version(),
            ["avutil"] = ffmpeg.avutil_version(), ["avfilter"] = ffmpeg.avfilter_version(),
            ["swresample"] = ffmpeg.swresample_version(), ["swscale"] = ffmpeg.swscale_version()
        };
        foreach (var library in LibraryMajors)
            if (versions[library.Key] >> 16 != library.Value)
                throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing,
                    "VoxClip is missing some of its files. Reinstall VoxClip.", new BadImageFormatException(library.Key));
        ffmpeg.av_log_set_level(ffmpeg.AV_LOG_QUIET);
    }
    /// <summary>Reject GPL/nonfree configurations before any media use; architecture §6.1.</summary>
    public static void ValidateConfiguration(string configuration)
    {
        if (configuration.Contains("--enable-gpl", StringComparison.Ordinal) || configuration.Contains("--enable-nonfree", StringComparison.Ordinal))
            throw new VoxClipException(VoxClipErrorCode.FfmpegLicenceGate, "This VoxClip build contains a GPL FFmpeg and can't run.");
    }
    /// <summary>Central negative-return-code boundary; architecture §6.1. The caller supplies av_strerror text.</summary>
    public static void Check(int result, string operation, string errorText)
        => Check(result, operation, errorText, VoxClipErrorCode.DecodeFailed);

    internal static void Check(int result, string operation, string errorText, VoxClipErrorCode code)
    {
        if (result < 0) throw new MediaException(result, operation, errorText, code);
    }
}
