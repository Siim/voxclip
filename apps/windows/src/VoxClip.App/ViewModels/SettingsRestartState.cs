namespace VoxClip.App.ViewModels;

internal sealed class SettingsRestartState(Action<bool> setEditingEnabled)
{
    internal bool IsPreparing { get; private set; }

    internal async Task<bool> PrepareAsync(IEnumerable<SettingsTextCommit> commits)
    {
        if (IsPreparing) return false;
        IsPreparing = true;
        var ready = false;
        try
        {
            setEditingEnabled(false);
            foreach (var commit in commits)
                if (!await commit.CommitAsync()) return false;
            ready = true;
            return true;
        }
        finally { if (!ready) Resume(); }
    }

    internal void Resume()
    {
        IsPreparing = false;
        setEditingEnabled(true);
    }
}
