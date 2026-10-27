using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed class PendingProjectSave(Project initial)
{
    private readonly SemaphoreSlim writer = new(1, 1);
    private Project current = initial;
    private long revision;
    private long saved;
    internal bool HasChanges => revision != saved;
    internal void Mark(Project project)
    {
        if (ReferenceEquals(current, project)) return;
        current = project;
        revision++;
    }
    internal async Task FlushAsync(Func<Project, CancellationToken, Task> write, CancellationToken ct)
    {
        await writer.WaitAsync(ct);
        try
        {
            if (!HasChanges) return;
            var snapshot = current;
            var version = revision;
            await write(snapshot, ct);
            saved = version;
        }
        finally { writer.Release(); }
    }
}
