using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App;

public sealed partial class MainWindow
{
    private WeakReference<Control>? paletteReturnFocus;
    private (EditorViewModel Model, string Id, string Title)? renaming;
    private readonly ShellInputSession renameInput = new();
    private bool renameCompositionJustEnded;

    private void FinishInlineRename(bool save, bool restoreFocus = true)
    {
        if (renaming is not { } pending) return;
        if (save)
        {
            if (EditorViewModel.ClipTitleProblem(RenameTitle.Text) is { } problem) { RenameProblem.Text = problem; return; }
            var current = pending.Model.Clips.FirstOrDefault(clip => clip.Id == pending.Id);
            if (ShowingHome || !ReferenceEquals(editor?.ViewModel, pending.Model) || !RowEdits(pending.Id) || pending.Model.IsReadOnly
                || pending.Model.Busy || pending.Model.IsLeaving || current is null || current.Title != pending.Title)
            { RenameProblem.Text = "This clip changed or is not editable. Cancel and try again. Your edits are safe."; return; }
            if (RenameTitle.Text.Trim() != current.Title && !pending.Model.Rename(pending.Id, RenameTitle.Text))
            { RenameProblem.Text = "This clip couldn't be renamed. Your edits are still here."; return; }
        }
        renaming = null;
        RenameEditor.Visibility = Visibility.Collapsed;
        if (restoreFocus)
        {
            if (Nav.IsPaneOpen) FocusRow(Shell.Rows.FirstOrDefault(row => row.ClipId == pending.Id) ?? Shell.ScopeRow(editor?.ViewModel.State?.ActiveClipId));
            else editor?.FocusTranscript();
        }
    }

    private void ToggleExplorer()
    {
        var restore = FocusInPane();
        Nav.IsPaneOpen = !Nav.IsPaneOpen;
        if (!Nav.IsPaneOpen && restore) editor?.FocusTranscript();
        if (Nav.IsPaneOpen) FocusRow(ShowingHome ? Shell.Home : Shell.ScopeRow(editor?.ViewModel.State?.ActiveClipId));
    }

    private void CloseShellTab()
    {
        if (!ShowingHome && editor?.CorrectionOpen == true) return;
        if (!ShowingHome && editor is { } page && page.Tabs.CloseActive()) return;
        _ = RequestCloseAsync(ShellPath.CloseShortcut);
    }

    private void CycleShellTab(int direction)
    {
        if (!ShowingHome && editor is { CorrectionOpen: false } page) ShowScope(page.Tabs.Model.Adjacent(direction), keepSelection: true);
    }

    private IReadOnlyList<ShellCommand> CurrentShellCommands()
    {
        var commands = new List<ShellCommand>
        {
            new("open", "Open video or project…", "Ctrl+O", () => !App.Restart.IsPreparing, () => _ = ChooseAsync(false)),
            new("home", "Go to Home", "Ctrl+1", () => !App.Restart.IsPreparing, () => ShowHome(ShellPath.HomeShortcut)),
            new("explorer", "Toggle Explorer", "Ctrl+B", () => true, ToggleExplorer),
            new("settings", "Open Settings", "Ctrl+,", () => !App.Restart.IsPreparing, App.OpenSettings)
        };
        commands.Add(new("help", "Keyboard shortcuts", "F1", () => true, () => _ = ShowKeyboardHelpAsync()));
        commands.Add(new("close", !ShowingHome && editor?.ViewModel.State?.ActiveClipId is not null ? "Close clip tab" : "Close project window", "Ctrl+W",
            () => !App.Restart.IsPreparing && editor?.CorrectionOpen != true, CloseShellTab, "Finish the current correction first."));
        if (ShowingHome) commands.Add(new("scope.full", "Open Full take", "Ctrl+2", () => editor is not null && !App.Restart.IsPreparing,
            () => ShowScope(null, via: ShellPath.EditorShortcut), "Open a project first."));
        if (!ShowingHome && editor is { } page) commands.AddRange(page.ShellCommands());
        return commands;
    }

    private void OpenCommandPalette()
    {
        if (Palette.Visibility == Visibility.Visible || App.Restart.IsPreparing || textFocus.OwnsComposition || FocusInDialog()) return;
        if (!ShowingHome && editor?.CorrectionOpen == true) return;
        Control? target = null;
        for (var element = FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
            if (element is Control control) { target = control; break; }
        paletteReturnFocus = target is null ? null : new(target);
        WorkspaceGate.IsEnabled = false;
        AppTitleBar.IsEnabled = false;
        StatusGate.IsEnabled = false;
        if (Workspace.ActualHeight > 0) Palette.MaxHeight = Math.Max(120, Workspace.ActualHeight - 32);
        Palette.Open(CurrentShellCommands());
    }

    private void CloseCommandPalette(bool restoreFocus)
    {
        Palette.Visibility = Visibility.Collapsed;
        WorkspaceGate.IsEnabled = true;
        AppTitleBar.IsEnabled = true;
        StatusGate.IsEnabled = true;
        var previous = paletteReturnFocus;
        paletteReturnFocus = null;
        if (!restoreFocus) return;
        if (previous?.TryGetTarget(out var target) == true && target.IsLoaded && target.IsEnabled
            && target.Visibility == Visibility.Visible && target.XamlRoot == Root.XamlRoot && target.Focus(FocusState.Keyboard)) return;
        if (!ShowingHome && editor is { } page) page.FocusTranscript();
        else CommandLauncher.Focus(FocusState.Keyboard);
    }

    private void UpdateShellChrome()
    {
        var page = ShowingHome ? null : editor;
        Title = page is null ? "VoxClip" : $"{page.ViewModel.Title} — VoxClip";
        if (!ReferenceEquals(AppTitleBar.Content, page?.Tabs)) AppTitleBar.Content = page?.Tabs;
        page?.UpdateShellChrome();
        RefreshShellStatus();
        Palette.UpdateCommands(CurrentShellCommands());
    }

    internal void RefreshShellChrome() => UpdateShellChrome();
    private bool FocusInDialog()
    {
        for (var element = FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
            if (element is ContentDialog) return true;
        return false;
    }
    private void RefreshShellStatus() => ShellStatus.Text = WindowNotice.IsOpen && !string.IsNullOrEmpty(WindowNotice.Message) ? WindowNotice.Message
        : !ShowingHome && editor is { } page ? page.ShellStatus
        : editor is null ? "Open a video to start." : "Home · Project remains open";
}
