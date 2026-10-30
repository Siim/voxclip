using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed class PendingProjectSave(Project initial, Action<Project>? onSaved = null)
{
    private readonly SemaphoreSlim writer = new(1, 1);
    private Project current = initial;
    private long revision;
    private long saved;
    private Project? writing;
    internal IEnumerable<Project> RetainedProjects => writing is { } snapshot ? [current, snapshot] : [current];
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
            writing = snapshot;
            await write(snapshot, ct);
            saved = version;
            onSaved?.Invoke(snapshot);
        }
        finally { writing = null; writer.Release(); }
    }
}
