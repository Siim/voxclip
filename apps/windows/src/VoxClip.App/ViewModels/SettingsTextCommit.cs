namespace VoxClip.App.ViewModels;

internal sealed class SettingsTextCommit(Func<string> read, Func<Task<bool>> save, Action<Exception> failed)
{
    private string committed = read();
    private Task<bool>? pending;

    internal Task<bool> CommitAsync() => pending ??= CommitCoreAsync();

    private async Task<bool> CommitCoreAsync()
    {
        await Task.Yield();
        try
        {
            var text = read();
            if (text == committed) return true;
            if (!await save()) return false;
            committed = text;
            return read() == committed;
        }
        catch (Exception exception) { failed(exception); return false; }
        finally { pending = null; }
    }
}
