namespace VoxClip.App.ViewModels;

/// <summary>Every way a window navigates (design §2, ADR-R29). MainWindow names the path when it navigates, so each one is
/// routed here, and ShellNavigationTests covers every value.</summary>
public enum ShellPath
{
    /// <summary>The sidebar's Home row.</summary>
    SidebarHome,
    /// <summary>Ctrl+1.</summary>
    HomeShortcut,
    /// <summary>Alt+Left.</summary>
    Back,
    /// <summary>The sidebar's Full take, clip or suggestion row, or a clip just made.</summary>
    ScopeRow,
    /// <summary>Ctrl+2.</summary>
    EditorShortcut,
    /// <summary>A sidebar Recent row.</summary>
    RecentRow,
    /// <summary>A Home tile, by click or Return.</summary>
    HomeTile,
    /// <summary>A Home tile's Open: its context menu, or the link beside a missing or unreadable video.</summary>
    HomeTileOpen,
    /// <summary>Import video… (Ctrl+O, Home, onboarding).</summary>
    ImportVideo,
    /// <summary>Open project… on Home.</summary>
    OpenProject,
    /// <summary>A file dropped on the window.</summary>
    Drop,
    /// <summary>File activation, or a second launch handing over a path.</summary>
    FileActivation,
    /// <summary>The path on the command line, or general.openLastProject at launch.</summary>
    Launch,
    /// <summary>The close button or the system close.</summary>
    CloseWindow,
    /// <summary>Ctrl+W.</summary>
    CloseShortcut,
}

/// <summary>What a window navigation does with the open project.</summary>
public enum ShellRoute
{
    /// <summary>Show Home; the editor stays alive and nothing is saved.</summary>
    ShowHome,
    /// <summary>Show the open project's editor; nothing is saved.</summary>
    ShowEditor,
    /// <summary>Nothing to do: there is no project to show.</summary>
    Stay,
    /// <summary>A window already holds the project: bring it forward at its current scope; nothing is saved or replaced.</summary>
    ShowHoldingWindow,
    /// <summary>No project is open: open in place.</summary>
    Open,
    /// <summary>Save the open project through the leave boundary, then open in place.</summary>
    LeaveThenOpen,
    /// <summary>No project is open: close the window.</summary>
    Close,
    /// <summary>Save the open project through the leave boundary, then close the window.</summary>
    LeaveThenClose,
    /// <summary>A dropped file VoxClip can't open: explain it and change nothing.</summary>
    Unsupported,
}

/// <summary>The outcome of a route's leave step.</summary>
public enum LeaveResult
{
    /// <summary>Go on with the route: nothing needed saving, or the save succeeded.</summary>
    Proceed,
    /// <summary>The save was refused and the editor is showing: stay, with its explanation.</summary>
    Stay,
    /// <summary>The save was refused while Home was showing: bring the editor back so its explanation is seen.</summary>
    ShowEditor,
}

/// <summary>The window's navigation decisions (ADR-R29, design §2). Sidebar Home, Ctrl+1 and Alt+Left only show Home, and the
/// scope rows and Ctrl+2 only show the editor: nothing is saved. Every path that opens a project — a Recent row, a Home tile
/// and its Open, Import video…, Open project…, a drop, file activation and launch — opens in place and saves the open
/// project first; closing the window does the same. A refused leave keeps the project open and, from Home, brings its
/// editor back so its explanation is seen.</summary>
public static class ShellNavigation
{
    /// <summary>The file types a window opens: the import types and projects (design §7).</summary>
    public static IReadOnlyList<string> Openable { get; } = [".mp4", ".mov", ".m4v", ".mkv", ".webm", ".voxclip"];

    /// <summary>The route for <paramref name="via"/>. <paramref name="heldByAWindow"/> says another window already holds the
    /// file being opened; <paramref name="file"/> is the dropped file for <see cref="ShellPath.Drop"/>.</summary>
    public static ShellRoute Route(ShellPath via, bool heldByAWindow, bool projectOpen, string? file = null) => via switch
    {
        ShellPath.SidebarHome or ShellPath.HomeShortcut or ShellPath.Back => ShellRoute.ShowHome,
        ShellPath.ScopeRow or ShellPath.EditorShortcut => projectOpen ? ShellRoute.ShowEditor : ShellRoute.Stay,
        ShellPath.Drop when file is not null && UnsupportedDrop(file) is not null => ShellRoute.Unsupported,
        ShellPath.RecentRow or ShellPath.HomeTile or ShellPath.HomeTileOpen or ShellPath.ImportVideo or ShellPath.OpenProject
            or ShellPath.Drop or ShellPath.FileActivation or ShellPath.Launch => Open(heldByAWindow, projectOpen),
        ShellPath.CloseWindow or ShellPath.CloseShortcut => projectOpen ? ShellRoute.LeaveThenClose : ShellRoute.Close,
        _ => throw new ArgumentOutOfRangeException(nameof(via), via, "Every navigation path needs a route.")
    };

    /// <summary>Run a route's leave step: the Leave routes save the open project through the leave boundary
    /// (<paramref name="trySaveBeforeLeaving"/>, the editor's TrySaveBeforeLeavingAsync) and no other route saves.</summary>
    public static async Task<LeaveResult> LeaveAsync(ShellRoute route, bool showingHome, Func<Task<bool>> trySaveBeforeLeaving)
    {
        ArgumentNullException.ThrowIfNull(trySaveBeforeLeaving);
        if (route is not (ShellRoute.LeaveThenOpen or ShellRoute.LeaveThenClose) || await trySaveBeforeLeaving()) return LeaveResult.Proceed;
        return showingHome ? LeaveResult.ShowEditor : LeaveResult.Stay;
    }

    /// <summary>Design §13's copy for a dropped file VoxClip can't open, or null when it can.</summary>
    public static string? UnsupportedDrop(string path)
    {
        var extension = Path.GetExtension(path);
        return extension.Length == 0 || Openable.Contains(extension, StringComparer.OrdinalIgnoreCase) ? null
            : $"VoxClip can't open {extension.TrimStart('.').ToUpperInvariant()} files on PC yet. Export the video as MP4 or MOV and try again.";
    }

    private static ShellRoute Open(bool heldByAWindow, bool projectOpen) =>
        heldByAWindow ? ShellRoute.ShowHoldingWindow : projectOpen ? ShellRoute.LeaveThenOpen : ShellRoute.Open;
}
