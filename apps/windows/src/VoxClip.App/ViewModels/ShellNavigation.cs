namespace VoxClip.App.ViewModels;

/// <summary>What a window navigation does with the open project.</summary>
public enum ShellRoute
{
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

/// <summary>The window's navigation decisions (ADR-R29, design §2). Sidebar Home, Ctrl+1 and Alt+Left only show Home: the
/// editor stays alive and nothing is saved. Every path that opens a project — a Recent row, a Home tile, its Open and
/// Locate…, Import video…, Open project…, a drop and file activation — opens in place and saves the open project first;
/// closing the window does the same. A refused leave keeps the project open and, from Home, brings its editor back so its
/// explanation is seen. MainWindow routes each path through here.</summary>
public static class ShellNavigation
{
    /// <summary>The file types a window opens: the import types and projects (design §7).</summary>
    public static IReadOnlyList<string> Openable { get; } = [".mp4", ".mov", ".m4v", ".mkv", ".webm", ".voxclip"];

    public static ShellRoute Open(bool heldByAWindow, bool projectOpen) =>
        heldByAWindow ? ShellRoute.ShowHoldingWindow : projectOpen ? ShellRoute.LeaveThenOpen : ShellRoute.Open;

    /// <summary>A dropped file: an unsupported type is explained and changes nothing; anything else opens like <see cref="Open"/>.</summary>
    public static ShellRoute Drop(string path, bool heldByAWindow, bool projectOpen) =>
        UnsupportedDrop(path) is not null ? ShellRoute.Unsupported : Open(heldByAWindow, projectOpen);

    /// <summary>Design §13's copy for a dropped file VoxClip can't open, or null when it can.</summary>
    public static string? UnsupportedDrop(string path)
    {
        var extension = Path.GetExtension(path);
        return extension.Length == 0 || Openable.Contains(extension, StringComparer.OrdinalIgnoreCase) ? null
            : $"VoxClip can't open {extension.TrimStart('.').ToUpperInvariant()} files on PC yet. Export the video as MP4 or MOV and try again.";
    }

    /// <summary>The close button, Ctrl+W or the system close.</summary>
    public static ShellRoute Close(bool projectOpen) => projectOpen ? ShellRoute.LeaveThenClose : ShellRoute.Close;

    /// <summary>A refused leave keeps the project open, editable, with its explanation (design §2). The explanation lives in
    /// the editor, so when Home is showing the editor comes back.</summary>
    public static bool ShowEditorAfterRefusedLeave(bool showingHome) => showingHome;
}
