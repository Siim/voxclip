using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Share;

namespace VoxClip.App.Controls;

internal sealed class ExportDialog : ContentDialog
{
    private readonly MainWindow owner;
    private readonly EditorViewModel model;
    private readonly bool demo;
    private readonly Func<CancellationToken, EditState?, Task<ComposeSnapshot>> snapshot;
    private readonly RadioButtons aspect;
    private readonly RadioButtons quality;
    private readonly RadioButtons target;
    private readonly ComboBox styles;
    private readonly CheckBox srt = new() { Content = "Also save captions as SRT" };
    private readonly TextBox folder = new() { Header = "Destination folder" };
    private readonly InfoBar notice = Ui.Notice();
    private readonly ProgressBar progress = new() { Visibility = Visibility.Collapsed };
    private readonly TextBox caption = new() { Header = "Share caption", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90 };
    private readonly StackPanel share = Ui.Stack();
    private readonly StackPanel exportedFiles = Ui.Stack(4);
    private string captionTarget = "full";
    private readonly CancellationTokenSource lifetime = new();
    private bool running;
    private bool composing;
    private string? exported;

    internal ExportDialog(MainWindow owner, EditorViewModel model, bool demo, Func<CancellationToken, EditState?, Task<ComposeSnapshot>> snapshot, bool preferSelectedClips = false)
    {
        this.owner = owner; this.model = model; this.demo = demo; this.snapshot = snapshot;
        Title = "Export"; PrimaryButtonText = "Export"; CloseButtonText = "Cancel"; DefaultButton = ContentDialogButton.Primary;
        var body = Ui.Stack(16); body.MinWidth = 400;
        body.Children.Add(Ui.Text("Your source stays untouched. Captions are burned into the exported video.", "HelperText"));
        aspect = Ui.Radios("Aspect", ["Source", "16:9", "9:16", "1:1"], (int)model.Project.Export.Aspect);
        quality = Ui.Radios("Quality", ["Standard", "High"], (int)model.Project.Export.Quality);
        target = Ui.Radios("Export scope", ["Full edit", $"Selected clips ({model.SelectedClipCount})"], preferSelectedClips ? 1 : 0);
        srt.IsChecked = model.Project.Export.Srt;
        folder.Text = model.Project.Export.Folder ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "VoxClip");
        styles = Ui.Choice("Caption style", []);
        styles.SelectionChanged += (_, _) => { if (styles.SelectedItem is ComboBoxItem item && item.Tag is string id) model.SetCaptionStyle(id); };
        Opened += async (_, _) => await Ui.RunAsync(notice, async () =>
        {
            var entries = await App.Services.ReadStylesAsync(lifetime.Token);
            styles.Items.Add(new ComboBoxItem { Content = "Off", Tag = "off" });
            foreach (var entry in entries) styles.Items.Add(new ComboBoxItem { Content = entry.Name, Tag = entry.Id });
            styles.SelectedItem = styles.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == model.Project.Captions.StyleId);
        }, "Caption styles");
        body.Children.Add(target); body.Children.Add(aspect); body.Children.Add(quality); body.Children.Add(styles); body.Children.Add(srt); body.Children.Add(folder);
        body.Children.Add(Ui.Button("Choose folder…", () => _ = Ui.RunAsync(notice, ChooseFolderAsync, "Export folder")));
        body.Children.Add(progress); body.Children.Add(notice);
        // share.captions holds 3,000 Unicode scalars (voice-lab §11.3), but MaxLength counts UTF-16 units, so it is only a loose
        // bound: TextChanging cuts typed, pasted and loaded text with SharePostText.CapCaption, as the Mac field does, and keeps
        // the caret where it was.
        caption.MaxLength = 6000;
        caption.TextChanging += (_, _) =>
        {
            var capped = SharePostText.CapCaption(caption.Text);
            if (capped.Length == caption.Text.Length) return;
            var caret = Math.Min(caption.SelectionStart, capped.Length);
            caption.Text = capped;
            caption.Select(caret, 0);
        };
        var counts = Ui.Text("", "HelperText");
        caption.TextChanged += (_, _) =>
        {
            model.SetShareCaption(captionTarget, caption.Text);
            try
            {
                var weight = SharePostText.XWeight(caption.Text);
                counts.Text = $"X {weight}/280 · LinkedIn {SharePostText.LinkedInLength(caption.Text):N0}/3,000";
                if (weight > 280) counts.Foreground = Ui.ThemeBrush(counts, "VcStatusWarningBrush"); else counts.ClearValue(TextBlock.ForegroundProperty);
            }
            catch (Exception exception) { Ui.Show(notice, UiError.Message(exception, "Share"), InfoBarSeverity.Warning); }
        };
        share.Visibility = Visibility.Collapsed; share.Children.Add(Ui.Text("Ready to share", "SubtitleTextBlockStyle")); share.Children.Add(exportedFiles); share.Children.Add(caption); share.Children.Add(counts);
        share.Children.Add(Ui.Button("Copy caption", () => { ShareHelpers.Copy(caption.Text); Ui.Show(notice, "Caption copied."); }));
        share.Children.Add(Ui.Button("Show in Explorer", () => { if (exported is not null) ShareHelpers.Reveal(exported); }));
        share.Children.Add(Ui.Button("Open X composer", () => _ = OpenComposerAsync("x")));
        share.Children.Add(Ui.Button("Open LinkedIn composer", () => _ = OpenComposerAsync("linkedin")));
        share.Children.Add(Ui.Text("Attach the revealed video in your browser. VoxClip never posts for you.", "HelperText")); body.Children.Add(share);
        Content = new ScrollViewer { Content = body, MaxHeight = 620 };
        PrimaryButtonClick += Export;
        CloseButtonClick += (_, args) => { if (running) { lifetime.Cancel(); args.Cancel = true; } };
        Closing += (_, args) => { if (running) { lifetime.Cancel(); args.Cancel = true; } };
        Closed += (_, _) => lifetime.Dispose();
        if (demo) { IsPrimaryButtonEnabled = false; Ui.Show(notice, "Demo fixtures use a synthetic preview and cannot be exported. Open a real project to export."); }
    }
    /// <summary>One composer at a time: a click while the X text is still being cut does nothing.</summary>
    private async Task OpenComposerAsync(string destination)
    {
        if (composing) return;
        composing = true;
        try { await Ui.RunAsync(notice, () => ShareHelpers.OpenComposerAsync(destination, caption.Text, exported!), "Share"); }
        finally { composing = false; }
    }
    private async Task ChooseFolderAsync()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker(); picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        var picked = await picker.PickSingleFolderAsync(); if (picked is not null) folder.Text = picked.Path;
    }
    private async void Export(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        if (running || demo || model.IsLeaving) return;
        await Ui.RunAsync(notice, async () =>
        {
            if (model.IsLeaving) return;
            if (!Path.IsPathFullyQualified(folder.Text)) { Ui.Show(notice, "Choose an absolute destination folder.", InfoBarSeverity.Warning); return; }
            var selectedClips = target.SelectedIndex == 1 ? model.Clips.Where(clip => clip.Selected).ToArray() : [];
            if (target.SelectedIndex == 1 && selectedClips.Length == 0) { Ui.Show(notice, "Choose clips to export."); return; }
            running = true; model.Busy = true; App.Services.BusyOperations++; IsPrimaryButtonEnabled = false; progress.Visibility = Visibility.Visible;
            try
            {
                model.SetExport(new((ExportAspect)aspect.SelectedIndex, (ExportQuality)quality.SelectedIndex, srt.IsChecked == true, folder.Text));
                Directory.CreateDirectory(folder.Text);
                var jobs = selectedClips.Length == 0 ? new ClipRow?[] { null } : selectedClips.Cast<ClipRow?>().ToArray();
                foreach (var clip in jobs)
                {
                    ExportTarget exportTarget = clip is null ? new ExportTarget.FullEdit() : new ExportTarget.Clip(clip.Id);
                    var state = ExportSelection.Scope(model.State, exportTarget);
                    var compose = await snapshot(lifetime.Token, state);
                    var aspectName = new[] { "source", "16x9", "9x16", "1x1" }[aspect.SelectedIndex];
                    var pattern = App.Services.Get("export.fileNamePattern", "{project}-{clip}-{aspect}");
                    var title = string.Join("_", pattern.Replace("{project}", model.Title, StringComparison.Ordinal).Replace("{clip}", clip?.Title ?? "full", StringComparison.Ordinal).Replace("{aspect}", aspectName, StringComparison.Ordinal).Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).TrimEnd('.', ' ');
                    if (title.Length > 180) title = string.Concat(title.EnumerateRunes().Take(90).Select(rune => rune.ToString()));
                    var output = ProjectFactory.AvailablePath(Path.Combine(folder.Text, (title.Length == 0 ? "VoxClip" : title) + ".mp4"));
                    var result = await App.Services.Exporter.ExportAsync(new(compose, exportTarget,
                        (ExportAspect)aspect.SelectedIndex, (ExportQuality)quality.SelectedIndex, output, srt.IsChecked == true ? Path.ChangeExtension(output, ".srt") : null),
                        new Progress<ExportProgress>(value => { progress.IsIndeterminate = value.Fraction is null; progress.Value = (value.Fraction ?? 0) * 100; Ui.Show(notice, value.Phase); }), lifetime.Token);
                    exported = result.Output;
                    if (result.SoftwareEncoding) Ui.Show(notice, "Exporting without hardware acceleration");
                    var fileRow = new Button { Content = Path.GetFileName(result.Output) + " · " + EditorViewModel.Timecode(result.DurationSeconds), CanDrag = true };
                    fileRow.DragStarting += async (_, drag) =>
                    {
                        var deferral = drag.GetDeferral();
                        try { drag.Data.SetStorageItems([await Windows.Storage.StorageFile.GetFileFromPathAsync(result.Output)]); drag.Data.RequestedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy; }
                        catch (Exception exception) { drag.Cancel = true; Ui.Show(notice, UiError.Message(exception, "Share"), InfoBarSeverity.Warning); }
                        finally { deferral.Complete(); }
                    };
                    exportedFiles.Children.Add(fileRow);
                    var shareId = clip?.Id ?? "full";
                    var words = model.Words.Where(word => state?.CutWordIds.Contains(word.Id) != true && (clip is null || model.Index(word.Id) >= model.Index(clip.Clip.StartWordId) && model.Index(word.Id) <= model.Index(clip.Clip.EndWordId))).Take(40).ToArray();
                    var sentence = new List<string>();
                    foreach (var word in words) { var text = model.DisplayText(word); sentence.Add(text); if (text.EndsWithAny(".!?…")) break; }
                    var defaultCaption = string.Join(" ", sentence);
                    if (sentence.Count == 40 && !defaultCaption.EndsWithAny(".!?…")) defaultCaption += "…";
                    if (clip is not null) defaultCaption = clip.Title + "\n\n" + defaultCaption;
                    void SelectExport() { exported = result.Output; captionTarget = shareId; caption.Text = model.Project.Share.Captions.GetValueOrDefault(shareId) ?? defaultCaption; }
                    fileRow.Click += (_, _) => SelectExport(); SelectExport();
                }
                share.Visibility = Visibility.Visible; CloseButtonText = "Done"; Ui.Show(notice, $"Saved {jobs.Length} video(s) to {folder.Text}");
                if (App.Services.Get("export.openFolderAfter", false) && exported is not null) ShareHelpers.Reveal(exported);
            }
            finally { running = false; model.Busy = false; App.Services.BusyOperations--; IsPrimaryButtonEnabled = !lifetime.IsCancellationRequested; progress.Visibility = Visibility.Collapsed; }
        }, "Export");
    }
}
