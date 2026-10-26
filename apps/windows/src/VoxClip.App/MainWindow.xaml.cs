using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.Pages;
using VoxClip.App.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using System.Runtime.InteropServices;
using Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.App;

/// <summary>Mica window with a TitleBar over a NavigationView: Home, the open project's clips and Recent; design §2 and §3.3.</summary>
public sealed partial class MainWindow : Window, IUpdateRestartWindow
{
    internal string? ProjectPath { get; private set; }
    internal string CurrentScreen => ContentFrame.Content is EditorPage ? "editor" : ContentFrame.Content is HomePage ? "home" : "none";
    /// <summary>Sidebar rows for this window.</summary>
    internal ShellViewModel Shell { get; } = new();
    private readonly HomePage home = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim navigation = new(1, 1);
    private bool closingApproved;
    private bool closingInProgress;
    private bool restartPrepared;
    private EditorPage? editor;
    private bool syncingSelection;
    private string? dropName;
#if DEBUG
    internal EditorPage? DebugEditor => editor;
    internal bool DebugHoldNavigation() => navigation.Wait(0);
    internal void DebugReleaseNavigation() => navigation.Release();
    internal SidebarRow? DebugSelectedRow => Nav.SelectedItem as SidebarRow;
    /// <summary>Select a row as a click does: the NavigationView raises the same SelectionChanged.</summary>
    internal void DebugSelect(SidebarRow row) => Nav.SelectedItem = row;
    internal Task DebugInvokeAsync(SidebarRow row) => InvokeRowAsync(row);
#endif
    private Button? updateRestart;
    /// <summary>Construct the shell on the DispatcherQueue thread; architecture §7.2.</summary>
    public MainWindow()
    {
        InitializeComponent();
        if (Content is not FrameworkElement || Root is null || ContentFrame is null || AppTitleBar is null)
            throw new InvalidOperationException("MainWindow XAML root did not load. Check the app PRI and compiled XAML.");
        Title = "VoxClip";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var (width, height) = (1280, 800);
#if DEBUG
        // Captures launch at their size: the shared VM's compositor stops presenting a window after an external resize.
        var requested = Program.Arguments.FirstOrDefault(argument => argument.StartsWith("--window-size=", StringComparison.Ordinal))?["--window-size=".Length..].Split('x');
        if (requested is [var w, var h] && int.TryParse(w, out var requestedWidth) && int.TryParse(h, out var requestedHeight)) (width, height) = (requestedWidth, requestedHeight);
#endif
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(width * scale), (int)(height * scale)));
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) { presenter.PreferredMinimumWidth = (int)(760 * scale); presenter.PreferredMinimumHeight = (int)(600 * scale); }
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "VoxClip.ico"));
        App.Services.ApplyTheme(Root);
        App.Services.SettingsChanged += SettingsChanged;
        App.Services.BusyChanged += BusyChanged;
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.O, VirtualKeyModifiers.Control, async () => await ChooseAsync(false)));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.N, VirtualKeyModifiers.Control, () => App.NewWindow()));
        Root.KeyboardAccelerators.Add(Accelerator((VirtualKey)188, VirtualKeyModifiers.Control, App.OpenSettings));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Left, VirtualKeyModifiers.Menu, ShowHome));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.W, VirtualKeyModifiers.Control, () => _ = RequestCloseAsync()));
        AppWindow.Closing += (appWindow, args) =>
        {
            if (App.Restart.IsPreparing) { args.Cancel = true; return; }
            if (closingApproved || editor is null) return;
            args.Cancel = true;
            _ = RequestCloseAsync();
        };
        Closed += WindowClosed;
        Root.SizeChanged += RootSizeChanged;
        home.Attach(this);
        home.ViewModel.RecentProjects.CollectionChanged += (_, _) => UpdateShell();
        ShowContent(home);
        _ = CheckUpdatesAsync();
    }

    private void SettingsChanged(object? sender, EventArgs args) => App.Services.ApplyTheme(Root);
    private async Task RequestCloseAsync()
    {
        if (closingInProgress || App.Restart.IsPreparing) return;
        closingInProgress = true;
        try
        {
            await navigation.WaitAsync();
            try
            {
                if (App.Restart.IsPreparing) return;
                if (editor is null || await editor.TrySaveBeforeLeavingAsync())
                {
                    closingApproved = true;
                    Close();
                }
            }
            finally { navigation.Release(); }
        }
        catch (Exception exception) { editor?.ResumeAfterFailedLeave(); ShowError(exception, "Close project"); }
        finally { closingInProgress = false; }
    }
    bool IUpdateRestartWindow.IsBusyForRestart => editor?.ViewModel?.Busy == true || App.Services.IsBusy;
    async Task<RestartPreparation> IUpdateRestartWindow.PrepareForRestartAsync()
    {
        if (!navigation.Wait(0)) return RestartPreparation.TransitionActive;
        try
        {
            if (closingInProgress) return RestartPreparation.TransitionActive;
            if (editor is { } current)
            {
                if (current.ViewModel.Busy) return RestartPreparation.Busy;
                if (!await current.TrySaveBeforeLeavingAsync()) return RestartPreparation.SaveFailed;
            }
            restartPrepared = true;
            return RestartPreparation.Ready;
        }
        finally { if (!restartPrepared) navigation.Release(); }
    }
    void IUpdateRestartWindow.ResumeAfterRestart()
    {
        if (!restartPrepared) return;
        restartPrepared = false;
        try { editor?.ResumeAfterFailedLeave(); }
        finally { navigation.Release(); }
    }
    private void BusyChanged(object? sender, EventArgs args)
    {
        if (updateRestart is null) return;
        updateRestart.IsEnabled = !App.Services.IsBusy;
        ToolTipService.SetToolTip(updateRestart, App.Services.IsBusy ? "Finish the current task first." : "Restart to update VoxClip.");
    }
    internal static KeyboardAccelerator Accelerator(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, args) =>
        {
            if (InputState.Down(VirtualKey.Control) && InputState.Down(VirtualKey.Menu)) return;
            action(); args.Handled = true;
        };
        return accelerator;
    }

    internal async Task ChooseAsync(bool projectOnly)
    {
        try
        {
            var picker = new FileOpenPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            foreach (var extension in projectOnly ? new[] { ".voxclip" } : new[] { ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".voxclip" }) picker.FileTypeFilter.Add(extension);
            var file = await picker.PickSingleFileAsync();
            if (file is not null) await OpenPathAsync(file.Path);
        }
        catch (Exception exception) { ShowError(exception, "Open video"); }
    }

    internal async Task OpenPathAsync(string path, bool demo = false)
    {
        if (App.Restart.IsPreparing) return;
        var fullPath = Path.GetFullPath(path);
        var newImport = !Path.GetExtension(fullPath).Equals(".voxclip", StringComparison.OrdinalIgnoreCase);
        var existing = App.Windows.FirstOrDefault(window => string.Equals(window.ProjectPath, fullPath, StringComparison.OrdinalIgnoreCase));
        if (existing is not null) { existing.Activate(); existing.ShowOpenProject(); return; }
        await navigation.WaitAsync();
        if (App.Restart.IsPreparing) { navigation.Release(); return; }
        var previous = editor;
        var previousPath = ProjectPath;
        var previousContent = ContentFrame.Content;
        EditorPage? incoming = null;
        var installed = false;
        try
        {
            if (previous is not null && !await previous.TrySaveBeforeLeavingAsync()) return;
            Core.Domain.Shared.Project project;
            string? mediaPath;
#if DEBUG
            if (demo)
            {
                project = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(fullPath, lifetime.Token));
                mediaPath = null;
            }
            else
#else
            if (demo) throw new InvalidOperationException("Demo mode is debug-only.");
#endif
            if (Path.GetExtension(fullPath).Equals(".voxclip", StringComparison.OrdinalIgnoreCase))
            {
                var opened = await App.Services.Projects.LoadAsync(fullPath, lifetime.Token);
                project = opened.Project;
                mediaPath = opened.ResolvedMediaPath;
            }
            else
            {
                var media = await App.Services.Probe.ProbeAsync(fullPath, lifetime.Token);
                var contentKey = await App.Services.Projects.ComputeContentKeyAsync(fullPath, null, lifetime.Token);
                project = ProjectFactory.Create(fullPath, media, contentKey);
                mediaPath = fullPath;
                fullPath = ProjectFactory.AvailablePath(Path.ChangeExtension(fullPath, ".voxclip"));
                try { await App.Services.Projects.SaveAsync(project, fullPath, lifetime.Token); }
                catch (UnauthorizedAccessException)
                {
                    fullPath = Path.Combine(App.Services.Data.Autosave, project.Id + ".voxclip");
                    await App.Services.Projects.SaveAsync(project, fullPath, lifetime.Token);
                    WindowNotice.Message = "Saved in VoxClip's folder. Use Save project as… to keep it with the video.";
                    WindowNotice.IsOpen = true;
                }
            }
            incoming = new EditorPage();
            ProjectPath = fullPath;
            ContentFrame.Content = incoming;
            await incoming.OpenAsync(this, project, mediaPath, demo, lifetime.Token);
            Watch(previous, incoming);
            editor = incoming;
            installed = true;
            UpdateShell();
            if (previous is not null)
            {
                try { await previous.CloseAsync(); }
                catch (Exception cleanup) { ShowError(cleanup, "Close project"); }
            }
            if (!demo)
            {
                try { await App.Services.RememberAsync(fullPath, lifetime.Token); }
                catch (Exception exception) { ShowError(exception, "Recent projects"); }
                if (newImport) await incoming.PromptTranscriptionAsync();
            }
        }
        catch (Exception exception)
        {
            if (!installed)
            {
                try
                {
                    ContentFrame.Content = previousContent;
                    ProjectPath = previousPath;
                    if (incoming is not null) { try { await incoming.CloseAsync(); } catch (Exception cleanup) { App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "project", cleanup.GetType().Name); } }
                }
                finally { previous?.ResumeAfterFailedLeave(); UpdateShell(); }
            }
            ShowError(exception, "Open project");
        }
        finally { navigation.Release(); }
    }

    internal void SetProjectPath(string path) => ProjectPath = path;
    /// <summary>Show Home without leaving the project: playback pauses and the editor page stays alive (ADR-R29).</summary>
    internal void ShowHome()
    {
        if (App.Restart.IsPreparing || !navigation.Wait(0)) { SyncSelection(); return; }
        try
        {
            editor?.PausePlayback();
            ShowContent(home);
        }
        finally { navigation.Release(); }
    }
    /// <summary>Show the editor scoped to Full take (null) or one clip; a scope change is the existing setActiveClip step.</summary>
    internal void ShowScope(string? clipId)
    {
        if (editor is not { } current || App.Restart.IsPreparing || !navigation.Wait(0)) { SyncSelection(); return; }
        try
        {
            if (!ReferenceEquals(ContentFrame.Content, current)) ShowContent(current);
            current.SelectScope(clipId);
        }
        finally { navigation.Release(); }
        SyncSelection();
    }
    /// <summary>Opening the project a window already holds returns to its editor at the current scope; Home keeps it open.</summary>
    private void ShowOpenProject()
    {
        if (editor is not { } current || App.Restart.IsPreparing || !navigation.Wait(0)) return;
        try { if (!ReferenceEquals(ContentFrame.Content, current)) ShowContent(current); }
        finally { navigation.Release(); }
    }
    private void ShowContent(Page page)
    {
        if (page is HomePage) home.Refresh();
        ContentFrame.Content = page;
        UpdateShell();
    }
    private bool ShowingHome => editor is null || ContentFrame.Content is HomePage;
    private void UpdateShell()
    {
        Shell.Update(editor?.ViewModel, ShowingHome, home.ViewModel.RecentProjects, ProjectPath);
        SyncSelection();
    }
    /// <summary>Keep the selected row equal to the shown page and the editor's activeClipId, without re-entering selection.</summary>
    private void SyncSelection()
    {
        var target = ShowingHome ? Shell.Home : Shell.ScopeRow(editor!.ViewModel.State?.ActiveClipId);
        if (target is null || ReferenceEquals(Nav.SelectedItem, target)) return;
        syncingSelection = true;
        try { Nav.SelectedItem = target; }
        finally { syncingSelection = false; }
    }
    private void Watch(EditorPage? previous, EditorPage next)
    {
        if (previous?.ViewModel is { } old) { old.Changed -= EditorChanged; old.SelectionChanged -= EditorChanged; old.PropertyChanged -= EditorPropertyChanged; }
        next.ViewModel.Changed += EditorChanged;
        next.ViewModel.SelectionChanged += EditorChanged;
        next.ViewModel.PropertyChanged += EditorPropertyChanged;
    }
    private void EditorChanged(object? sender, EventArgs args) => UpdateShell();
    private void EditorPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(EditorViewModel.Busy) or nameof(EditorViewModel.CanExport)) UpdateShell();
    }
    private void NavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (syncingSelection || args.SelectedItem is not SidebarRow row) return;
        switch (row.Kind)
        {
            case SidebarKind.Home: ShowHome(); break;
            case SidebarKind.FullTake: ShowScope(null); break;
            case SidebarKind.Clip or SidebarKind.Suggestion: ShowScope(row.ClipId); break;
        }
    }
    private async void NavItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer is not null && sender.MenuItemFromContainer(args.InvokedItemContainer) is SidebarRow row) await InvokeRowAsync(row);
    }
    /// <summary>Rows that do not select: a Recent project opens in place through OpenPathAsync; actions run on the editor.</summary>
    private async Task InvokeRowAsync(SidebarRow row)
    {
        if (row.Kind == SidebarKind.Recent && row.Recent is { } recent) await OpenPathAsync(recent.Path);
        else if (row.Key == "action:make") editor?.MakeClipFromPane();
        else if (row.Key == "action:find") editor?.ShowFindClips();
    }
    private void PaneToggleRequested(TitleBar sender, object args) => Nav.IsPaneOpen = !Nav.IsPaneOpen;
    private void RootSizeChanged(object sender, SizeChangedEventArgs args)
    {
        var mode = args.NewSize.Width >= (double)Application.Current.Resources["VcSizeBreakpointStack"] ? NavigationViewPaneDisplayMode.Left : NavigationViewPaneDisplayMode.LeftMinimal;
        if (Nav.PaneDisplayMode != mode) Nav.PaneDisplayMode = mode;
    }
    private void SettingsClicked(object sender, RoutedEventArgs args) => App.OpenSettings();
    internal void ShowError(Exception exception, string action)
    {
        var message = UiError.Message(exception, action);
        if (message.Length == 0) return;
        WindowNotice.Severity = InfoBarSeverity.Warning;
        WindowNotice.Message = message;
        WindowNotice.IsOpen = true;
        App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "import", $"action={action} code={(exception is VoxClipException known ? known.WireCode : exception.GetType().Name)} inner={exception.GetBaseException().GetType().Name} hresult=0x{exception.GetBaseException().HResult:X8}");
    }
    private static readonly string[] OpenableExtensions = [".mp4", ".mov", ".m4v", ".mkv", ".webm", ".voxclip"];
    /// <summary>Whole-window drop target: overlay copy from design §7 and §13.</summary>
    private async void FileDragOver(object sender, DragEventArgs args)
    {
        if (!args.DataView.Contains(StandardDataFormats.StorageItems)) return;
        args.AcceptedOperation = DataPackageOperation.Copy;
        args.DragUIOverride.Caption = editor is null ? "Import video in this window" : "Open in this window after saving";
        DropOverlay.Visibility = Visibility.Visible;
        if (dropName is not null) return;
        dropName = "";
        var deferral = args.GetDeferral();
        try { dropName = (await args.DataView.GetStorageItemsAsync()).FirstOrDefault()?.Name ?? ""; }
        catch (Exception) { dropName = ""; }
        finally { deferral.Complete(); }
        DropDetail.Text = editor is not null ? $"{editor.ViewModel.Title} is saved first."
            : Path.GetExtension(dropName).Equals(".voxclip", StringComparison.OrdinalIgnoreCase) ? dropName
            : $"{dropName} · VoxClip makes a new project next to the video";
    }
    private void FileDragLeave(object sender, DragEventArgs args) { DropOverlay.Visibility = Visibility.Collapsed; dropName = null; }
    private async void FileDropped(object sender, DragEventArgs args)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        dropName = null;
        try
        {
            var deferral = args.GetDeferral();
            try
            {
                var items = await args.DataView.GetStorageItemsAsync();
                if (items.FirstOrDefault() is { } file) await OpenDroppedAsync(file.Path);
            }
            finally { deferral.Complete(); }
        }
        catch (Exception exception) { ShowError(exception, "Import video"); }
    }
    /// <summary>A dropped file replaces the open project through OpenPathAsync, which saves it first; design §7.</summary>
    internal async Task OpenDroppedAsync(string path)
    {
        var extension = Path.GetExtension(path);
        if (extension.Length > 0 && !OpenableExtensions.Contains(extension, StringComparer.OrdinalIgnoreCase))
        {
            WindowNotice.Severity = InfoBarSeverity.Informational;
            WindowNotice.Message = $"VoxClip can't open {extension.TrimStart('.').ToUpperInvariant()} files on PC yet. Export the video as MP4 or MOV and try again.";
            WindowNotice.IsOpen = true;
            return;
        }
        await OpenPathAsync(path);
    }
#if DEBUG
    internal string DebugNotice => WindowNotice.IsOpen ? WindowNotice.Message : "";
#endif
    internal async Task ShowOnboardingAsync() => await new OnboardingDialog(this) { XamlRoot = Root.XamlRoot }.ShowAsync();
    internal async Task CheckUpdatesAsync(bool manual = false)
    {
        try
        {
            if (!manual) await Task.Delay(TimeSpan.FromSeconds(10), lifetime.Token);
            var update = await App.Services.Updates.CheckAsync(manual, lifetime.Token);
            if (update is null) { if (manual) { WindowNotice.Message = "No update available. Development builds do not self-update."; WindowNotice.IsOpen = true; } return; }
            await App.Services.Updates.DownloadAsync(update, null, lifetime.Token);
            WindowNotice.Message = $"VoxClip {update.Version} is ready. Restart to update.";
            var restart = new Button { Content = "Restart now", IsEnabled = !App.Services.IsBusy };
            updateRestart = restart;
            BusyChanged(this, EventArgs.Empty);
            restart.Click += async (_, _) =>
            {
                RestartResult result;
                try
                {
                    result = await App.Restart.RunAsync(new UpdateRestartSettings(),
                        ct => App.Services.Updates.ApplyAsync(update, ct), lifetime.Token);
                }
                catch (Exception exception) { ShowError(exception, "Update"); return; }
                if (result is RestartResult.Dispatched or RestartResult.Cancelled) return;
                WindowNotice.Severity = result is RestartResult.SaveFailed or RestartResult.SettingsFailed or RestartResult.UpdateFailed
                    ? InfoBarSeverity.Error : InfoBarSeverity.Warning;
                WindowNotice.Message = result switch
                {
                    RestartResult.Busy => "Finish or cancel transcription, clip search or export before restarting. Your edits are still here.",
                    RestartResult.TransitionActive => "Finish opening or closing the project, then try restarting. Your edits are still here.",
                    RestartResult.SaveFailed => "Could not save every open project. Your projects are still open with their edits. Use Save project as… or check the folder, then try again.",
                    RestartResult.SettingsFailed => "Could not save settings. Your projects are still open. Check the settings folder, then try again.",
                    RestartResult.UpdateFailed => "Could not restart for the update. Your projects are still open with their edits. Try again when ready.",
                    _ => "An update restart is already in progress."
                };
                WindowNotice.IsOpen = true;
            };
            WindowNotice.ActionButton = restart;
            WindowNotice.IsOpen = true;
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { if (manual) ShowError(exception, "Update"); else App.Services.Log.Write(Core.Services.Logging.LogLevel.Info, "update", "automatic check unavailable"); }
    }
    private async void WindowClosed(object sender, WindowEventArgs args)
    {
        await lifetime.CancelAsync();
        if (editor is not null) await editor.CloseAsync();
        App.Services.SettingsChanged -= SettingsChanged;
        App.Services.BusyChanged -= BusyChanged;
        App.Windows.Remove(this);
        if (App.Windows.Count == 0) { App.Settings?.Close(); await App.Services.DisposeAsync(); }
        lifetime.Dispose();
    }
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);
}
