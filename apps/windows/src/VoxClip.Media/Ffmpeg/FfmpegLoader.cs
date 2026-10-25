using VoxClip.Core.Domain.Shared;
namespace VoxClip.Media.Ffmpeg;

/// <summary>Single native loader and error gate; architecture §6.1. Bindings 9.0.1.1 pair with pinned BtbN FFmpeg n9.0 LGPL-shared.</summary>
public static class FfmpegLoader
{
    /// <summary>Load verified dynamic libraries from the app directory. win-media installs SafeHandles and owner-thread initialization here.</summary>
    public static Task InitializeAsync(CancellationToken ct) => ct.IsCancellationRequested ? Task.FromCanceled(ct) :
        Task.FromException(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-media"));
    /// <summary>Reject GPL/nonfree configurations before any media use; architecture §6.1.</summary>
    public static void ValidateConfiguration(string configuration)
    {
        if (configuration.Contains("--enable-gpl", StringComparison.Ordinal) || configuration.Contains("--enable-nonfree", StringComparison.Ordinal))
            throw new VoxClipException(VoxClipErrorCode.FfmpegLicenceGate, "This VoxClip build contains a GPL or nonfree FFmpeg and can't run.");
    }
    /// <summary>Central negative-return-code boundary; architecture §6.1. The caller supplies av_strerror text.</summary>
    public static void Check(int result, string operation, string errorText)
    {
        if (result < 0) throw new MediaException(result, operation, errorText);
    }
}
