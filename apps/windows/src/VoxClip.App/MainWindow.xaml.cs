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
using VoxClip.Core.Domain.Captions;
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
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer takeRefresh;
    private CancellationTokenSource takeLoads = new();
    private (string Path, string? Frame, CaptionCard? Card, bool Unreadable, bool Demo, bool Missing, bool AudioOnly)? take;
    private Dictionary<string, (string? Frame, CaptionCard? Card)> clipTiles = [];
#if DEBUG
    internal EditorPage? DebugEditor => editor;
    internal bool DebugHoldNavigation() => navigation.Wait(0);
    internal void DebugReleaseNavigation() => navigation.Release();
    internal SidebarRow? DebugSelectedRow => Nav.SelectedItem as SidebarRow;
    /// <summary>Select a row as a click does: the NavigationView raises the same SelectionChanged.</summary>
    internal void DebugSelect(SidebarRow row) => Nav.SelectedItem = row;
    internal Task DebugInvokeAsync(SidebarRow row) => InvokeRowAsync(row);
    internal Task DebugRequestCloseAsync() => RequestCloseAsync(ShellPath.CloseWindow);
    internal FrameworkElement? DebugContainer(SidebarRow row) => Nav.ContainerFromMenuItem(row) as FrameworkElement;
    internal bool DebugCalloutTipOpen => CalloutTip.IsOpen;
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
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Left, VirtualKeyModifiers.Menu, () => ShowHome(ShellPath.Back)));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Number1, VirtualKeyModifiers.Control, () => ShowHome(ShellPath.HomeShortcut)));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Number2, VirtualKeyModifiers.Control, () => ShowScope(null, via: ShellPath.EditorShortcut)));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.W, VirtualKeyModifiers.Control, () => _ = RequestCloseAsync(ShellPath.CloseShortcut)));
        AppWindow.Closing += (appWindow, args) =>
        {
            if (App.Restart.IsPreparing) { args.Cancel = true; return; }
            if (closingApproved || editor is null) return;
            args.Cancel = true;
            _ = RequestCloseAsync(ShellPath.CloseWindow);
        };
        Closed += WindowClosed;
        Root.SizeChanged += RootSizeChanged;
        // F6 is the window's, wherever focus is; a page that handles the key first doesn't stop the cycle.
        Root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(RegionKeyDown), true);
        // The editor's accelerators are scoped to its page, so the ones design §11.1 keeps working from the sidebar pane are
        // window accelerators that hand the key to the attached editor; [ and ] act on clip and suggestion rows.
        foreach (var gesture in ShortcutPolicy.PaneGestures) Root.KeyboardAccelerators.Add(PaneAccelerator(gesture));
        Nav.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(PaneRowKeyDown), false);
        takeRefresh = DispatcherQueue.CreateTimer();
        takeRefresh.IsRepeating = false;
        takeRefresh.Interval = TimeSpan.FromMilliseconds(500);
        takeRefresh.Tick += (_, _) => _ = RefreshTakeAsync();
        TranscriptionActivity.Changed += TranscriptionChanged;
        home.Attach(this);
        home.ViewModel.RecentProjects.CollectionChanged += (_, _) => UpdateShell();
        ShowContent(home);
        _ = CheckUpdatesAsync();
    }

    private void SettingsChanged(object? sender, EventArgs args)
    {
        App.Services.ApplyTheme(Root);
        if (editor is not null) takeRefresh.Start();
    }
    private void TranscriptionChanged(object? sender, EventArgs args) => ApplyTake();
    /// <summary>Close the window through the leave boundary (design §2): a refused save keeps the project open and, from
    /// Home, brings its editor back.</summary>
    private async Task RequestCloseAsync(ShellPath via)
    {
        if (closingInProgress || App.Restart.IsPreparing) return;
        closingInProgress = true;
        try
        {
            await navigation.WaitAsync();
            try
            {
                if (App.Restart.IsPreparing) return;
                var open = editor;
                var leave = await ShellNavigation.LeaveAsync(ShellNavigation.Route(via, false, open is not null), ShowingHome, () => open!.TrySaveBeforeLeavingAsync());
                if (leave == LeaveResult.Proceed)
                {
                    closingApproved = true;
                    Close();
                }
                else if (leave == LeaveResult.ShowEditor) ShowRefusedLeave(open!);
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
    /// <summary>A pane gesture ("Ctrl+Shift+K") as a window accelerator that runs the attached editor's shortcut while focus is
    /// on a sidebar row and the editor is showing. Elsewhere it does nothing, so the editor's own scoped accelerator or a
    /// text field takes the key; on Home nothing acts on the hidden editor.</summary>
    private KeyboardAccelerator PaneAccelerator(string gesture)
    {
        var parts = gesture.Split('+');
        var accelerator = new KeyboardAccelerator
        {
            Key = Enum.Parse<VirtualKey>(parts[^1]),
            Modifiers = (parts.Contains("Ctrl") ? VirtualKeyModifiers.Control : VirtualKeyModifiers.None) | (parts.Contains("Shift") ? VirtualKeyModifiers.Shift : VirtualKeyModifiers.None)
        };
        accelerator.Invoked += (_, args) =>
        {
            if (editor is { } page && !ShowingHome && FocusInPane() && !InputState.IsTextFocus(FocusManager.GetFocusedElement(Root.XamlRoot))
                && page.InvokeFromPane(gesture)) args.Handled = true;
        };
        return accelerator;
    }
    /// <summary>[ and ] on a clip or suggestion row step through the kept clips, and focus follows to the new scope's row.</summary>
    private void PaneRowKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (editor is not { } page || ShowingHome || args.Key is not ((VirtualKey)219 or (VirtualKey)221) || !FocusInPane() || FocusedRow() is not { } row) return;
        var modifier = InputState.Down(VirtualKey.Control) || InputState.Down(VirtualKey.Menu) || InputState.Down(VirtualKey.Shift);
        var step = ShortcutPolicy.RowClipStep(args.Key == (VirtualKey)219 ? '[' : ']', row.Kind, modifier);
        if (step == 0) return;
        args.Handled = true;
        page.ViewModel.CycleClip(step);
        if (Shell.ScopeRow(page.ViewModel.State?.ActiveClipId) is { } next && Nav.ContainerFromMenuItem(next) is Control container) container.Focus(FocusState.Keyboard);
    }
    private SidebarRow? FocusedRow()
    {
        for (var element = FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
            if (element is NavigationViewItem item) return Nav.MenuItemFromContainer(item) as SidebarRow;
        return null;
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
            if (file is not null) await OpenPathAsync(file.Path, projectOnly ? ShellPath.OpenProject : ShellPath.ImportVideo);
        }
        catch (Exception exception) { ShowError(exception, "Open video"); }
    }

    /// <summary>Open a video or project in place (design §2): a window that already holds it comes forward instead, and the
    /// open project is saved through the leave boundary first. <paramref name="via"/> names the path for ShellNavigation.</summary>
    internal async Task OpenPathAsync(string path, ShellPath via, bool demo = false)
    {
        if (App.Restart.IsPreparing) return;
        var fullPath = Path.GetFullPath(path);
        var newImport = !Path.GetExtension(fullPath).Equals(".voxclip", StringComparison.OrdinalIgnoreCase);
        var existing = App.Windows.FirstOrDefault(window => string.Equals(window.ProjectPath, fullPath, StringComparison.OrdinalIgnoreCase));
        if (ShellNavigation.Route(via, existing is not null, editor is not null, fullPath) == ShellRoute.ShowHoldingWindow) { existing!.Activate(); existing.ShowOpenProject(); return; }
        await navigation.WaitAsync();
        if (App.Restart.IsPreparing) { navigation.Release(); return; }
        var previous = editor;
        var previousPath = ProjectPath;
        var previousContent = ContentFrame.Content;
        EditorPage? incoming = null;
        var installed = false;
        try
        {
            var leave = await ShellNavigation.LeaveAsync(ShellNavigation.Route(via, false, previous is not null, fullPath), ShowingHome, () => previous!.TrySaveBeforeLeavingAsync());
            if (leave != LeaveResult.Proceed)
            {
                if (leave == LeaveResult.ShowEditor) ShowRefusedLeave(previous!);
                return;
            }
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
            _ = RefreshTakeAsync();
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
    private double? rightColumnWidth;
    /// <summary>The right column width the user chose with the splitter (delta §3.3), from ui.rightColumnWidth and kept to
    /// the column's range, or null while the column follows the window. It holds across projects.</summary>
    internal double? RightColumnWidth(double min, double max) =>
        EditorLayout.StoredRightColumnWidth(rightColumnWidth ?? App.Services.Settings.GetDouble("ui.rightColumnWidth"), min, max);
    /// <summary>The user moved the splitter: the width applies in this window at once and is then stored in
    /// ui.rightColumnWidth. Nothing else writes the key.</summary>
    internal void RememberRightColumnWidth(double width, double min, double max)
    {
        if (EditorLayout.RightColumnWidthToStore(width, min, max) is not { } stored || stored == rightColumnWidth) return;
        rightColumnWidth = stored;
        _ = SaveRightColumnWidthAsync(stored);
    }
    private static async Task SaveRightColumnWidthAsync(double width)
    {
        try { await App.Services.SetAsync("ui.rightColumnWidth", width); }
        catch (Exception exception) { App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "settings", exception.GetType().Name); }
    }
    /// <summary>Showing the viewer where the transcript has no room closes the pane (delta §3.7).</summary>
    internal void CloseNavigationPane() => Nav.IsPaneOpen = false;
    /// <summary>Show Home without leaving the project: playback pauses and the editor page stays alive (ADR-R29).</summary>
    internal void ShowHome(ShellPath via)
    {
        if (ShellNavigation.Route(via, false, editor is not null) != ShellRoute.ShowHome || App.Restart.IsPreparing || !navigation.Wait(0)) { SyncSelection(); return; }
        try
        {
            editor?.PausePlayback();
            ShowContent(home);
        }
        finally { navigation.Release(); }
    }
    /// <summary>Show the editor scoped to Full take (null) or one clip; a scope change is the existing setActiveClip step.
    /// Choosing a row keeps focus on the row; Ctrl+2 from Home's content moves focus into the transcript (design C15).</summary>
    internal void ShowScope(string? clipId, bool keepSelection = false, ShellPath via = ShellPath.ScopeRow)
    {
        if (ShellNavigation.Route(via, false, editor is not null) != ShellRoute.ShowEditor || editor is not { } current || App.Restart.IsPreparing || !navigation.Wait(0)) { SyncSelection(); return; }
        var fromHome = !ReferenceEquals(ContentFrame.Content, current);
        var fromPane = FocusInPane();
        try
        {
            if (fromHome) ShowContent(current);
            current.SelectScope(clipId, keepSelection);
        }
        finally { navigation.Release(); }
        SyncSelection();
        if (fromHome && !fromPane) current.FocusTranscript();
    }
    private bool FocusInPane() => FocusManager.GetFocusedElement(Root.XamlRoot) is DependencyObject focused
        && InputState.DescendsFrom(focused, Nav) && !InputState.DescendsFrom(focused, ContentLayer);
    /// <summary>A refused leave keeps the project open and editable. From Home its editor comes back, so the explanation it
    /// shows is seen and heard (design §2).</summary>
    private void ShowRefusedLeave(EditorPage open)
    {
        ShowContent(open);
        open.FocusTranscript();
        open.AnnounceNotice();
    }
    /// <summary>A clip just made, or the one that already covers the words, is selected and scrolled into view (design §6.2).</summary>
    internal void RevealClip(string clipId)
    {
        ShowScope(clipId, keepSelection: true);
        if (Shell.ScopeRow(clipId) is { ClipId: not null } row) DispatcherQueue.TryEnqueue(() => (Nav.ContainerFromMenuItem(row) as UIElement)?.StartBringIntoView());
    }
    /// <summary>Opening the project a window already holds returns to its editor at the current scope; Home keeps it open.</summary>
    private void ShowOpenProject()
    {
        if (editor is not { } current || App.Restart.IsPreparing || !navigation.Wait(0)) return;
        try
        {
            if (ReferenceEquals(ContentFrame.Content, current)) return;
            ShowContent(current);
            current.FocusTranscript();
        }
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
        Shell.Finding = editor?.FindClips.Running;
        Shell.Callout = editor?.FindClips.Callout;
        Shell.NoneFound = editor?.FindClips.NoneFound;
        Shell.Update(editor?.ViewModel, ShowingHome, home.ViewModel.RecentProjects, ProjectPath);
        if (Shell.Callout is null || ShowingHome) CalloutTip.IsOpen = false;
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
        if (previous?.ViewModel is { } old) { old.Changed -= EditorEdited; old.SelectionChanged -= EditorChanged; old.PropertyChanged -= EditorPropertyChanged; }
        if (previous is not null) { previous.FindClips.Changed -= EditorChanged; previous.FindClips.Found -= SuggestionsFound; previous.FindClips.CalloutShown -= CalloutShown; }
        next.FindClips.Changed += EditorChanged;
        next.FindClips.Found += SuggestionsFound;
        next.FindClips.CalloutShown += CalloutShown;
        next.ViewModel.Changed += EditorEdited;
        next.ViewModel.SelectionChanged += EditorChanged;
        next.ViewModel.PropertyChanged += EditorPropertyChanged;
    }
    private void EditorChanged(object? sender, EventArgs args) => UpdateShell();
    /// <summary>New suggestions appear under Suggested and the first takes focus without being selected (design §6.2).</summary>
    private void SuggestionsFound(object? sender, string clipId) => FocusRow(Shell.Rows.FirstOrDefault(row => row.ClipId == clipId));
    /// <summary>An edit can change the take's first kept words, so the Full take thumbnail follows once edits settle.</summary>
    private void EditorEdited(object? sender, EventArgs args)
    {
        UpdateShell();
        takeRefresh.Start();
    }
    /// <summary>The Full take row's thumbnail (design §5.4): the take's poster frame, else its caption card, with its status.
    /// Made off the UI thread when the project opens and again after edits or placeholder settings change.</summary>
    private async Task RefreshTakeAsync()
    {
        takeRefresh.Stop();
        takeLoads.Cancel();
        if (editor is not { } current || ProjectPath is not { } path) { take = null; clipTiles = []; ApplyTake(); return; }
        if (take?.Path != path) { take = null; clipTiles = []; ApplyTake(); }
        var loads = takeLoads = new CancellationTokenSource();
        var project = current.ViewModel.Project;
        var (words, style) = (App.Services.ShowPlaceholderWords, App.Services.Get("captions.defaultStyleId", "vox-highlight"));
        var clips = current.ViewModel.Clips.Select(clip => clip.Id).ToArray();
        CaptionCard? card = null;
        string? frame = null;
        var unreadable = false;
        var tiles = new Dictionary<string, (string? Frame, CaptionCard? Card)>(StringComparer.Ordinal);
        // Cards and frames fail apart: a card that can't be made never stops the poster frames, and the other way round.
        try
        {
            // Clip rows use each clip's own first kept words and frame (design §3.4), centre-cropped to 9:16 by the tile.
            (card, var clipCards) = await Task.Run(() => (App.Services.Cards?.Card(project, null, words, style),
                clips.Select(id => (Id: id, Card: App.Services.Cards?.Card(project, id, words, style))).ToArray()), loads.Token);
            foreach (var (id, clipCard) in clipCards) tiles[id] = (null, clipCard);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception exception)
        {
            App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "project", $"action=Caption card code={exception.GetType().Name}");
        }
        if (current.MediaPath is { } media && project.Media.Source.Video is { } video)
        {
            var source = project.Media.Source;
            try
            {
                frame = await App.Services.Thumbnails.GetAsync(source.ContentKey, media, Thumbnails.Candidates(project, null), video.RotationDegrees, loads.Token);
                foreach (var id in clips)
                    tiles[id] = (await App.Services.Thumbnails.GetAsync(source.ContentKey, media, Thumbnails.Candidates(project, id), video.RotationDegrees, loads.Token),
                        tiles.TryGetValue(id, out var tile) ? tile.Card : null);
            }
            catch (OperationCanceledException) { return; }
            catch (VoxClipException exception)
            {
                // The decoder can't read the video (design §5.4.4 f).
                unreadable = true;
                App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "project", $"action=Poster frame code={exception.WireCode}");
            }
            catch (Exception exception)
            {
                App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "project", $"action=Poster frame code={exception.GetType().Name}");
            }
        }
        if (loads.IsCancellationRequested || !ReferenceEquals(editor, current)) return;
        take = (path, frame, card, unreadable, current.IsDemo, current.MediaPath is null && !current.IsDemo, project.Media.Source.Video is null);
        clipTiles = tiles;
        ApplyTake();
    }
    private void ApplyTake()
    {
        if (take is not { } current || !string.Equals(current.Path, ProjectPath, StringComparison.OrdinalIgnoreCase))
            Shell.TakeMedia = ProjectPath is { } path ? MediaTile.Empty(path) : null;
        else
        {
            var transcription = TranscriptionActivity.Status(current.Path);
            MediaStatus status = current.Demo ? new MediaStatus.Demo() : current.Missing ? new MediaStatus.Missing() : current.Unreadable ? new MediaStatus.Unreadable()
                : transcription is { } running ? running.Status : current.AudioOnly ? new MediaStatus.AudioOnly() : new MediaStatus.None();
            Shell.TakeMedia = new(current.Path, current.Frame, current.Card, status);
        }
        // Clip rows carry no chips: in the editor the InfoBar names a missing or unreadable video (design §5.4.4). A clip has
        // words, so a transcription doesn't change its tile.
        var state = Shell.TakeMedia?.Status ?? new MediaStatus.None();
        Shell.ClipMedia = clipTiles.ToDictionary(pair => pair.Key, pair => new MediaTile($"{ProjectPath}|{pair.Key}", pair.Value.Frame, pair.Value.Card,
            state is MediaStatus.Transcribing ? new MediaStatus.None() : state));
        UpdateShell();
    }
    /// <summary>A suggestion's Keep and Dismiss buttons act without selecting their row.</summary>
    private void RowButtonTapped(object sender, TappedRoutedEventArgs args) => args.Handled = true;
    /// <summary>A row's keys (F2, Delete, Ctrl+Enter) act only while focus is in that row, never from the transcript.</summary>
    private void ScopeRowKeys(object sender, RoutedEventArgs args)
    {
        if (sender is UIElement row) foreach (var accelerator in row.KeyboardAccelerators) accelerator.ScopeOwner = row;
    }
    private void KeepClicked(object sender, RoutedEventArgs args) { if (sender is FrameworkElement { Tag: string id }) ClipCommand(id, model => model.Keep(id)); }
    private void DismissClicked(object sender, RoutedEventArgs args) { if (sender is FrameworkElement { Tag: string id }) ClipCommand(id, model => model.Dismiss(id)); }
    private void KeepSuggestionInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => args.Handled = RowCommand(args, (model, id) => model.Keep(id));
    private void DismissSuggestionInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => args.Handled = RowCommand(args, (model, id) => model.Dismiss(id));
    private void RemoveClipInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => args.Handled = RowCommand(args, (model, id) => model.Remove(id));
    private void RemoveClipClicked(object sender, RoutedEventArgs args) { if (sender is FrameworkElement { Tag: string id }) ClipCommand(id, model => model.Remove(id)); }
    private void KeepAllClicked(object sender, RoutedEventArgs args) { if (RowEdits(SidebarKind.SuggestedHeader)) editor?.ViewModel.KeepAll(); }
    private void CancelFindingClicked(object sender, RoutedEventArgs args) => editor?.FindClips.Cancel();
    private void CalloutClosed(InfoBar sender, object args) => editor?.FindClips.Dismiss();
    /// <summary>Retry runs the search again; Set up AI… and Sign-in help open Settings at the AI page.</summary>
    private async void CalloutActionClicked(object sender, RoutedEventArgs args)
    {
        if (editor is not { } current || Shell.Callout is not { } callout) return;
        CalloutTip.IsOpen = false;
        if (callout.Action == ClipCallouts.Retry) await current.FindClips.RetryAsync();
        else App.OpenSettings("Providers & Keys");
    }
    private void CalloutTipActionClicked(TeachingTip sender, object args) => CalloutActionClicked(sender, new RoutedEventArgs());
    /// <summary>The none-found row's Find clips… opens the flyout at itself.</summary>
    private void FindClipsAgainClicked(object sender, RoutedEventArgs args) { if (RowEdits(SidebarKind.NoneFound)) editor?.ShowFindClips(sender as FrameworkElement); }
    /// <summary>A Find clips callout must be seen (design §13): the pane opens and scrolls to it, and when Find clips was
    /// asked for away from the pane, a tip points at it.</summary>
    private void CalloutShown(object? sender, FrameworkElement? anchor)
    {
        var fromPane = anchor is not null && InputState.DescendsFrom(anchor, Nav) && !InputState.DescendsFrom(anchor, ContentLayer);
        if (!Nav.IsPaneOpen) Nav.IsPaneOpen = true;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (Shell.Rows.FirstOrDefault(row => row.Kind == SidebarKind.Callout) is not { } row || Nav.ContainerFromMenuItem(row) is not FrameworkElement container) return;
            container.StartBringIntoView();
            if (fromPane) return;
            CalloutTip.Target = container;
            CalloutTip.Title = row.Title.Length > 0 ? row.Title : row.Detail;
            CalloutTip.ActionButtonContent = row.HasAction ? row.Action : null;
            CalloutTip.IsOpen = true;
        });
    }
    private void CancelTakeTranscriptionClicked(object sender, RoutedEventArgs args) { if (ProjectPath is { } path) TranscriptionActivity.Cancel(path); }
    private void CancelRecentTranscriptionClicked(object sender, RoutedEventArgs args) { if (sender is FrameworkElement { Tag: string path }) TranscriptionActivity.Cancel(path); }
    private async void RenameClipInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if ((args.Element as FrameworkElement)?.Tag is not string id || !RowEdits(id)) return;
        args.Handled = true;
        await RenameClipAsync(id);
    }
    private async void RenameClipClicked(object sender, RoutedEventArgs args) { if (sender is FrameworkElement { Tag: string id }) await RenameClipAsync(id); }
    private void CopyClipTextClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string id } && editor?.ViewModel.Clips.FirstOrDefault(clip => clip.Id == id) is { } clip) ShareHelpers.Copy(clip.Excerpt);
    }
    private async void ExportClipClicked(object sender, RoutedEventArgs args) { if (editor is not null && sender is FrameworkElement { Tag: string id } && RowEdits(id)) await editor.ExportClipAsync(id); }
    private async Task RenameClipAsync(string id)
    {
        if (!RowEdits(id) || editor?.ViewModel is not { } model || model.Clips.FirstOrDefault(clip => clip.Id == id) is not { } clip) return;
        // A title is at most 120 code points; a longer one keeps the dialog open with the reason under the box. MaxLength
        // counts UTF-16 units, so it only stops a paste far past the limit.
        var name = new TextBox { Header = "Clip title", Text = clip.Title, MaxLength = 2 * Core.Domain.Editing.EditingLimits.MaxClipTitleCodePoints };
        var problem = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Ui.ThemeBrush(Root, "VcStatusDangerForegroundBrush"), Visibility = Visibility.Collapsed };
        name.SelectAll();
        name.TextChanged += (_, _) => problem.Visibility = Visibility.Collapsed;
        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(name);
        body.Children.Add(problem);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Rename clip", Content = body, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (EditorViewModel.ClipTitleProblem(name.Text) is not { } reason) return;
            args.Cancel = true;
            problem.Text = reason;
            problem.Visibility = Visibility.Visible;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(name, reason);
            Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(name)?.RaiseNotificationEvent(Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.Other,
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.MostRecent, reason, "rename");
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && name.Text.Trim() != clip.Title && !model.Rename(id, name.Text))
            model.Notice = "This clip couldn't be renamed. Your edits are still here.";
        FocusRow(Shell.Rows.FirstOrDefault(row => row.ClipId == id));
    }
    /// <summary>Whether a row's commands may act: only rows that edit (<see cref="SidebarRow.Edits"/>). While Home shows, the
    /// project's rows only navigate, so a key or click that still reaches one is ignored and nothing changes in the hidden
    /// editor (design §2).</summary>
    private bool RowEdits(string clipId) => Shell.Rows.Any(row => row.ClipId == clipId && row.Edits);
    private bool RowEdits(SidebarKind kind) => Shell.Rows.Any(row => row.Kind == kind && row.Edits);
    private bool RowCommand(KeyboardAcceleratorInvokedEventArgs args, Func<EditorViewModel, string, bool> command)
    {
        if ((args.Element as FrameworkElement)?.Tag is not string id || !RowEdits(id)) return false;
        ClipCommand(id, model => command(model, id));
        return true;
    }
    /// <summary>Run a Keep, Dismiss or Remove, then move focus to the next clip or suggestion row, or to Full take when there is
    /// none (design §3.4).</summary>
    private void ClipCommand(string id, Func<EditorViewModel, bool> command)
    {
        if (editor?.ViewModel is not { } model || !RowEdits(id)) return;
        var after = Shell.Rows.SkipWhile(row => row.ClipId != id).Skip(1).Where(row => row.ClipId is not null).Select(row => row.ClipId).ToArray();
        if (!command(model)) return;
        var next = after.Select(clipId => Shell.Rows.FirstOrDefault(row => row.ClipId == clipId)).FirstOrDefault(row => row is not null);
        FocusRow(next ?? Shell.Rows.FirstOrDefault(row => row.Kind == SidebarKind.FullTake));
    }
    private void FocusRow(SidebarRow? row)
    {
        if (row is null) return;
        DispatcherQueue.TryEnqueue(() => (Nav.ContainerFromMenuItem(row) as Control)?.Focus(FocusState.Keyboard));
    }
    private void EditorPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(EditorViewModel.Busy) or nameof(EditorViewModel.CanExport)) UpdateShell();
    }
    private void NavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (syncingSelection || args.SelectedItem is not SidebarRow row) return;
        switch (row.Kind)
        {
            case SidebarKind.Home: ShowHome(ShellPath.SidebarHome); break;
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
        if (row.Kind == SidebarKind.Recent && row.Recent is { } recent) await OpenPathAsync(recent.Path, ShellPath.RecentRow);
        else if (row.Key == "action:make") editor?.MakeClipFromPane();
        else if (row.Key == "action:find") editor?.ShowFindClips(Nav.ContainerFromMenuItem(row) as FrameworkElement);
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
        if (ShellNavigation.Route(ShellPath.Drop, false, editor is not null, path) == ShellRoute.Unsupported)
        {
            WindowNotice.Severity = InfoBarSeverity.Informational;
            WindowNotice.Message = ShellNavigation.UnsupportedDrop(path) ?? "";
            WindowNotice.IsOpen = true;
            return;
        }
        await OpenPathAsync(path, ShellPath.Drop);
    }
    /// <summary>F6 and Shift+F6 move between regions in design §16 order: the sidebar, then the editor's command row,
    /// transcript, viewer, Captions and timeline, or Home's content. Focus outside every region counts as the sidebar, so
    /// F6 from the pane lands on the command row. A region that can't take focus, such as a closed pane, is skipped.</summary>
    private void RegionKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.F6 || InputState.Down(VirtualKey.Control) || InputState.Down(VirtualKey.Menu)) return;
        var regions = new List<(FrameworkElement[] Areas, Func<Control?> Target)>
            { ([], () => Nav.SelectedItem is { } selected ? Nav.ContainerFromMenuItem(selected) as Control : null) };
        if (ContentFrame.Content is EditorPage page) regions.AddRange(page.FocusRegions());
        else if (ContentFrame.Content is HomePage shown) regions.Add(([shown], () => FocusManager.FindFirstFocusableElement(shown) as Control));
        var focused = FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject;
        var current = Math.Max(0, regions.FindIndex(region => region.Areas.Any(area => InputState.DescendsFrom(focused, area))));
        var step = InputState.Down(VirtualKey.Shift) ? -1 : 1;
        for (var tried = 1; tried < regions.Count + 1; tried++)
            if (regions[((current + step * tried) % regions.Count + regions.Count) % regions.Count].Target() is { } target && target.Focus(FocusState.Keyboard)) break;
        args.Handled = true;
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
        takeRefresh.Stop();
        takeLoads.Cancel();
        TranscriptionActivity.Changed -= TranscriptionChanged;
        home.Detach();
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
