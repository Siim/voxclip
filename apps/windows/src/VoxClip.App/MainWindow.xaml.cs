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
public sealed partial class MainWindow : Window
{
    internal string? ProjectPath { get; private set; }
    internal string CurrentScreen => ContentFrame.Content is EditorPage ? "editor" : ContentFrame.Content is HomePage ? "home" : "none";
    private readonly CancellationTokenSource lifetime = new();
    private EditorPage? editor;
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
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) { presenter.PreferredMinimumWidth = (int)(960 * scale); presenter.PreferredMinimumHeight = (int)(600 * scale); }
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "VoxClip.ico"));
        App.Services.ApplyTheme(Root);
        App.Services.SettingsChanged += SettingsChanged;
        App.Services.BusyChanged += BusyChanged;
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.O, VirtualKeyModifiers.Control, async () => await ChooseAsync(false)));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.N, VirtualKeyModifiers.Control, () => App.NewWindow()));
        Root.KeyboardAccelerators.Add(Accelerator((VirtualKey)188, VirtualKeyModifiers.Control, App.OpenSettings));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Left, VirtualKeyModifiers.Menu, GoHome));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.W, VirtualKeyModifiers.Control, Close));
        Closed += WindowClosed;
        GoHome();
        _ = CheckUpdatesAsync();
    }

    private void SettingsChanged(object? sender, EventArgs args) => App.Services.ApplyTheme(Root);
    private void BusyChanged(object? sender, EventArgs args)
    {
        if (updateRestart is null) return;
        updateRestart.IsEnabled = !App.Services.IsBusy;
        ToolTipService.SetToolTip(updateRestart, App.Services.IsBusy ? "Finish the export first." : "Restart to update VoxClip.");
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
        var fullPath = Path.GetFullPath(path);
        var newImport = !Path.GetExtension(fullPath).Equals(".voxclip", StringComparison.OrdinalIgnoreCase);
        var existing = App.Windows.FirstOrDefault(window => string.Equals(window.ProjectPath, fullPath, StringComparison.OrdinalIgnoreCase));
        if (existing is not null) { existing.Activate(); return; }
        try
        {
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
            if (editor is not null) await editor.CloseAsync();
            editor = new EditorPage();
            ProjectPath = fullPath;
            ContentFrame.Content = editor;
            AppTitleBar.IsBackButtonVisible = true;
            AppTitleBar.Subtitle = project.Title ?? Path.GetFileNameWithoutExtension(fullPath);
            await editor.OpenAsync(this, project, mediaPath, demo, lifetime.Token);
            if (!demo)
            {
                try { await App.Services.RememberAsync(fullPath, lifetime.Token); }
                catch (Exception exception) { ShowError(exception, "Recent projects"); }
                if (newImport) await editor.PromptTranscriptionAsync(App.Services.Get("transcription.engineMode", "local") == "local");
            }
        }
        catch (Exception exception) { ShowError(exception, "Open project"); }
    }

    internal void SetProjectPath(string path) => ProjectPath = path;
    internal async void GoHome() => await GoHomeAsync();
    internal async Task GoHomeAsync()
    {
        var previous = editor;
        editor = null;
        if (previous is not null)
        {
            try { await previous.CloseAsync(); } catch (Exception exception) { ShowError(exception, "Close project"); }
        }
        ProjectPath = null;
        AppTitleBar.IsBackButtonVisible = false;
        AppTitleBar.Subtitle = "";
        var home = new HomePage();
        home.Attach(this);
        ContentFrame.Content = home;
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
        App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "import", exception is VoxClipException known ? known.WireCode : exception.GetType().Name);
    }
    private void FileDragOver(object sender, DragEventArgs args)
    {
        if (!args.DataView.Contains(StandardDataFormats.StorageItems)) return;
        args.AcceptedOperation = DataPackageOperation.Copy;
        args.DragUIOverride.Caption = editor is null ? "Drop to transcribe" : "Open as a new project";
    }
    private async void FileDropped(object sender, DragEventArgs args)
    {
        try
        {
            var deferral = args.GetDeferral();
            try
            {
                var items = await args.DataView.GetStorageItemsAsync();
                if (items.FirstOrDefault() is { } file) await (editor is null ? this : App.NewWindow()).OpenPathAsync(file.Path);
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
            restart.Click += async (_, _) => { try { await App.Services.Updates.ApplyAsync(update, lifetime.Token); } catch (Exception exception) { ShowError(exception, "Update"); } };
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
