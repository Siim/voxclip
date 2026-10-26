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

/// <summary>Mica editor shell with a custom native title bar; design §3.3.</summary>
public sealed partial class MainWindow : Window, IUpdateRestartWindow
{
    internal string? ProjectPath { get; private set; }
    internal string CurrentScreen => ContentFrame.Content is EditorPage ? "editor" : ContentFrame.Content is HomePage ? "home" : "none";
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim navigation = new(1, 1);
    private bool closingApproved;
    private bool closingInProgress;
    private bool restartPrepared;
    private EditorPage? editor;
#if DEBUG
    internal EditorPage? DebugEditor => editor;
    internal bool DebugHoldNavigation() => navigation.Wait(0);
    internal void DebugReleaseNavigation() => navigation.Release();
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
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(1280 * scale), (int)(800 * scale)));
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) { presenter.PreferredMinimumWidth = (int)(760 * scale); presenter.PreferredMinimumHeight = (int)(600 * scale); }
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "VoxClip.ico"));
        App.Services.ApplyTheme(Root);
        App.Services.SettingsChanged += SettingsChanged;
        App.Services.BusyChanged += BusyChanged;
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.O, VirtualKeyModifiers.Control, async () => await ChooseAsync(false)));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.N, VirtualKeyModifiers.Control, () => App.NewWindow()));
        Root.KeyboardAccelerators.Add(Accelerator((VirtualKey)188, VirtualKeyModifiers.Control, App.OpenSettings));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Left, VirtualKeyModifiers.Menu, GoHome));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.W, VirtualKeyModifiers.Control, () => _ = RequestCloseAsync()));
        AppWindow.Closing += (appWindow, args) =>
        {
            if (App.Restart.IsPreparing) { args.Cancel = true; return; }
            if (closingApproved || editor is null) return;
            args.Cancel = true;
            _ = RequestCloseAsync();
        };
        Closed += WindowClosed;
        GoHome();
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
        if (existing is not null) { existing.Activate(); return; }
        await navigation.WaitAsync();
        if (App.Restart.IsPreparing) { navigation.Release(); return; }
        var previous = editor;
        var previousPath = ProjectPath;
        var previousContent = ContentFrame.Content;
        var previousSubtitle = AppTitleBar.Subtitle;
        var previousBackButton = AppTitleBar.IsBackButtonVisible;
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
            AppTitleBar.IsBackButtonVisible = true;
            AppTitleBar.Subtitle = project.Title ?? Path.GetFileNameWithoutExtension(fullPath);
            await incoming.OpenAsync(this, project, mediaPath, demo, lifetime.Token);
            editor = incoming;
            installed = true;
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
                    AppTitleBar.IsBackButtonVisible = previousBackButton;
                    AppTitleBar.Subtitle = previousSubtitle;
                    if (incoming is not null) { try { await incoming.CloseAsync(); } catch (Exception cleanup) { App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "project", cleanup.GetType().Name); } }
                }
                finally { previous?.ResumeAfterFailedLeave(); }
            }
            ShowError(exception, "Open project");
        }
        finally { navigation.Release(); }
    }

    internal void SetProjectPath(string path) => ProjectPath = path;
    internal async void GoHome() => await GoHomeAsync();
    internal async Task GoHomeAsync()
    {
        if (App.Restart.IsPreparing) return;
        await navigation.WaitAsync();
        try
        {
            if (App.Restart.IsPreparing) return;
            if (editor is { } previous)
            {
                if (!await previous.TrySaveBeforeLeavingAsync()) return;
                await previous.CloseAsync();
                editor = null;
            }
            ProjectPath = null;
            AppTitleBar.IsBackButtonVisible = false;
            AppTitleBar.Subtitle = "";
            var home = new HomePage();
            home.Attach(this);
            ContentFrame.Content = home;
        }
        catch (Exception exception) { ShowError(exception, "Close project"); }
        finally { navigation.Release(); }
    }
    private void BackRequested(TitleBar sender, object args) => GoHome();
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
    private void FileDragOver(object sender, DragEventArgs args)
    {
        if (!args.DataView.Contains(StandardDataFormats.StorageItems)) return;
        args.AcceptedOperation = DataPackageOperation.Copy;
        args.DragUIOverride.Caption = editor is null ? "Import video in this window" : "Open in this window after saving";
    }
    private async void FileDropped(object sender, DragEventArgs args)
    {
        try
        {
            var deferral = args.GetDeferral();
            try
            {
                var items = await args.DataView.GetStorageItemsAsync();
                if (items.FirstOrDefault() is { } file) await OpenPathAsync(file.Path);
            }
            finally { deferral.Complete(); }
        }
        catch (Exception exception) { ShowError(exception, "Import video"); }
    }
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
