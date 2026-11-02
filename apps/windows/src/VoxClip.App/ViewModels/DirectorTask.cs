namespace VoxClip.App.ViewModels;

internal enum DirectorTaskPhase { Ready, AwaitingApproval, Working, Review, Failed, Closed }
internal sealed record DirectorTaskSnapshot(Guid Id, DirectorTaskPhase Phase, string Status, bool CanApply);

internal sealed class DirectorTask : IDisposable
{
    private readonly RewriteSession session;
    private bool approving;
    internal Guid Id { get; } = Guid.NewGuid();
    internal event EventHandler? Changed;
    internal DirectorTask(RewriteSession session)
    {
        this.session = session;
        session.Changed += SessionChanged;
    }
    internal DirectorTaskSnapshot Snapshot => new(Id,
        !session.IsOpen ? DirectorTaskPhase.Closed : approving ? DirectorTaskPhase.AwaitingApproval :
        session.IsProposing ? DirectorTaskPhase.Working : session.Problem.Length > 0 ? DirectorTaskPhase.Failed :
        session.Review?.Diff.Hunks.Count > 0 ? DirectorTaskPhase.Review : DirectorTaskPhase.Ready,
        !session.IsOpen ? "Rewrite closed" : approving ? "Waiting for your approval. Nothing has been sent." :
        session.IsProposing ? "Waiting for " + (session.Connector?.Name ?? "the connector") + "…" :
        session.Problem.Length > 0 ? session.Problem : session.Review?.Diff.Hunks.Count > 0 ? "Review the proposed changes" :
        "Describe what should change, or edit the words below.",
        session.IsOpen && session.LocalAction is not null && !session.Editor.Busy && !session.Editor.IsReadOnly && !session.Editor.IsLeaving);
    internal void SetApproval(bool waiting) { approving = waiting; Changed?.Invoke(this, EventArgs.Empty); }
    private void SessionChanged(object? sender, EventArgs args) => Changed?.Invoke(this, EventArgs.Empty);
    public void Dispose() => session.Changed -= SessionChanged;
}
