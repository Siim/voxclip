namespace VoxClip.App.ViewModels;

internal enum InlineActivation { Pointer, Return, ControlReturn, Space }

internal sealed record InlineApprovalRequest(Guid Id, object Snapshot, string Title, string DataSent,
    string Detail, string Affirmative, bool IsBilled, Uri? PricingPage = null);

internal sealed class InlineApproval : IDisposable
{
    private readonly Func<bool> current;
    private readonly TaskCompletionSource<bool> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenRegistration cancellation;
    private int shownAt;
    private int retired;
    internal InlineApprovalRequest Request { get; }
    internal Task<bool> Completion => completion.Task;
    internal bool IsPending => Volatile.Read(ref retired) == 0 && current();
    internal void MarkShown(int eventTime) => shownAt = eventTime;
    internal event EventHandler? Changed;

    internal InlineApproval(InlineApprovalRequest request, Func<bool> current, CancellationToken token, int shownAt)
    {
        Request = request;
        this.current = current;
        this.shownAt = shownAt;
        cancellation = token.Register(Cancel);
    }

    internal static bool Allows(InlineActivation activation, bool repeat, int eventTime, int shownAt) => !repeat && (activation switch
    {
        InlineActivation.Pointer or InlineActivation.ControlReturn => true,
        InlineActivation.Return => unchecked((uint)(eventTime - shownAt)) is >= 500 and < 0x80000000,
        _ => false
    });

    internal bool Approve(InlineActivation activation, bool repeat, int eventTime)
    {
        if (Volatile.Read(ref retired) != 0 || !Allows(activation, repeat, eventTime, shownAt)) return false;
        if (!current()) { Cancel(); return false; }
        if (Interlocked.Exchange(ref retired, 1) != 0) return false;
        completion.TrySetResult(true);
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    internal void Cancel()
    {
        if (Interlocked.Exchange(ref retired, 1) != 0) return;
        completion.TrySetResult(false);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose() { Cancel(); cancellation.Dispose(); }
}
