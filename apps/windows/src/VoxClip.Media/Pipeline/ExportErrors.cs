using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Pipeline;

/// <summary>Export failure copy shared by the renderer and its caller; design section 13.</summary>
public static class ExportErrors
{
    internal const string EncoderUnavailable = "No H.264 encoder is available on this PC. Install the Media Feature Pack or update your graphics driver.";
    internal static bool IsEncoderFailure(Exception exception) => exception is MediaException native && native.NativeError != -28 &&
        (native.Operation.StartsWith("Open h264", StringComparison.Ordinal) || native.Operation is "Submit encoder frame" or "Receive encoded packet") ||
        exception is VoxClipException { Code: VoxClipErrorCode.EncoderUnavailable };

    /// <summary>Preserve typed special cases and give generic failures the export reassurance.</summary>
    public static VoxClipException Map(Exception exception, string destination, string? requiredSize = null)
    {
        if (exception is MediaException { NativeError: -28 } || exception is IOException io && (io.HResult & 0xffff) is 28 or 39 or 112)
            return new(VoxClipErrorCode.DiskFull, DiskFullMessage(Path.GetPathRoot(Path.GetFullPath(destination))!, requiredSize), exception);
        if (exception is MediaException native && native.Operation.StartsWith("Open h264", StringComparison.Ordinal) ||
            exception is VoxClipException { Code: VoxClipErrorCode.EncoderUnavailable })
            return new(VoxClipErrorCode.EncoderUnavailable, EncoderUnavailable, exception);
        var reason = exception is IOException locked && (locked.HResult & 0xffff) is 32 or 33
            ? "the destination is in use" : exception is UnauthorizedAccessException ? "permission to write the destination was denied" : exception.Message.TrimEnd('.');
        return new(VoxClipErrorCode.ExportFailed, $"Export stopped: {reason}. Your edits are saved.", exception);
    }
    /// <summary>Use an explicit known shortfall, or the approved unknown-size recovery copy.</summary>
    public static string DiskFullMessage(string volume, string? requiredSize) =>
        $"There isn't enough free space on {volume}. Free up {requiredSize ?? "space"} and try again.";
}
