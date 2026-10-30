#pragma warning disable CS1591
namespace VoxClip.Core.Domain.VoiceLab;

public sealed class VoiceLabConfirmationRequiredException(VoiceLabCostPresentationResult decision) : Exception("Confirm the current whole-run cost.")
{
    public VoiceLabCostPresentationResult Decision { get; } = decision;
}

public sealed class VoiceLabRunDispatch(Func<CancellationToken, Task> authorize, Action<Action> start)
{
    public Task AuthorizeAsync(CancellationToken ct) => authorize(ct);
    public Task<T> Start<T>(Func<Task<T>> transport, CancellationToken ct)
    {
        Task<T>? sending = null;
        start(() => { ct.ThrowIfCancellationRequested(); sending = transport(); });
        return sending ?? throw new InvalidOperationException("The dispatch handshake did not start transport.");
    }
    public VoiceLabRunDispatch WithStart(Action<Action> launch) => new(authorize, action => start(() => launch(action)));
}
