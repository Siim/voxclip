using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Pipeline;

internal static class ExportErrors
{
    internal const string EncoderUnavailable = "No H.264 encoder is available on this PC. Install the Media Feature Pack or update your graphics driver.";
    internal static bool IsEncoderFailure(Exception exception) => exception is MediaException native && native.NativeError != -28 &&
        (native.Operation.StartsWith("Open h264", StringComparison.Ordinal) || native.Operation is "Submit encoder frame" or "Receive encoded packet") ||
        exception is VoxClipException { Code: VoxClipErrorCode.EncoderUnavailable };

    internal static VoxClipException Map(Exception exception, string destination)
    {
        if (exception is MediaException { NativeError: -28 } || exception is IOException io && (io.HResult & 0xffff) is 28 or 39 or 112)
            return new(VoxClipErrorCode.DiskFull, $"There isn't enough free space on {Path.GetPathRoot(Path.GetFullPath(destination))}. Free up additional space and try again.", exception);
        if (exception is MediaException native && native.Operation.StartsWith("Open h264", StringComparison.Ordinal) ||
            exception is VoxClipException { Code: VoxClipErrorCode.EncoderUnavailable })
            return new(VoxClipErrorCode.EncoderUnavailable, EncoderUnavailable, exception);
        var reason = exception is IOException locked && (locked.HResult & 0xffff) is 32 or 33
            ? "the destination is in use" : exception is UnauthorizedAccessException ? "permission to write the destination was denied" : exception.Message.TrimEnd('.');
        return new(VoxClipErrorCode.ExportFailed, $"Export stopped: {reason}. Your edits are saved.", exception);
    }
}
