namespace VoxClip.App.ViewModels;

public sealed record ShellCommand(string Id, string Title, string Shortcut, Func<bool> Available, Action Execute, string UnavailableReason = "Finish the current task first.")
{
    public bool IsEnabled => Available();
    public string Detail => IsEnabled ? Shortcut : UnavailableReason;
    public bool TryExecute()
    {
        if (!Available()) return false;
        Execute();
        return true;
    }
}

public static class ShellCommands
{
    public static IReadOnlyList<ShellCommand> Filter(IEnumerable<ShellCommand> commands, string query)
    {
        var terms = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return commands.Where(command => terms.All(term => command.Title.Contains(term, StringComparison.OrdinalIgnoreCase)
            || command.Shortcut.Contains(term, StringComparison.OrdinalIgnoreCase))).ToArray();
    }
}

public sealed class ShellInputSession
{
    public bool IsComposing { get; private set; }
    public void CompositionStarted() => IsComposing = true;
    public void CompositionEnded() => IsComposing = false;
    public bool MaySubmit(bool compositionJustEnded) => !IsComposing && !compositionJustEnded;
    public bool MayDismiss(bool compositionJustEnded) => !IsComposing && !compositionJustEnded;
}
