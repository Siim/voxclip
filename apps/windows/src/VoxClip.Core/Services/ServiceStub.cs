using VoxClip.Core.Domain.Shared;
namespace VoxClip.Core.Services;

internal static class ServiceStub
{
    internal static Task<T> Missing<T>(string track, CancellationToken ct)
        => ct.IsCancellationRequested ? Task.FromCanceled<T>(ct) : Task.FromException<T>(new VoxClipException(VoxClipErrorCode.NotImplemented, track));
    internal static Task Missing(string track, CancellationToken ct)
        => ct.IsCancellationRequested ? Task.FromCanceled(ct) : Task.FromException(new VoxClipException(VoxClipErrorCode.NotImplemented, track));
}
