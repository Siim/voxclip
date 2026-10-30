using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Share;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Controls;

internal sealed class ExportDialog : ContentDialog
{
    private readonly MainWindow owner;
    private readonly EditorViewModel model;
    private readonly bool demo;
    private readonly Func<Project, EditState?, CancellationToken, Task<ComposeSnapshot>> snapshot;
    private readonly RadioButtons aspect;
    private readonly RadioButtons quality;
    private readonly RadioButtons target;
    private readonly ComboBox styles;
    private readonly CheckBox srt = new() { Content = "Also save .srt" };
    private readonly TextBox folder = new() { Header = "Save to" };
    private readonly InfoBar notice = Ui.Notice();
    private readonly ProgressBar progress = new() { Visibility = Visibility.Collapsed, Width = 360 };
    private readonly StackPanel form = Ui.Stack(16);
    private readonly TextBlock disclosure = Ui.Text("This video contains AI-modified speech. It will show AI MODIFIED.", "HelperText");
    private readonly TextBox caption = new() { Header = "Share caption", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90 };
    private readonly StackPanel share = Ui.Stack();
    private readonly StackPanel exportedFiles = Ui.Stack(4);
    private string captionTarget = "full";
    private readonly CancellationTokenSource lifetime = new();
    /// <summary>Export clip… chooses only this clip (design §2 step 7); null offers the kept clips, where manual clips always
    /// count (ADR-R29).</summary>
    private readonly string? onlyClip;
    private bool running;
    private bool composing;
    private bool closed;
    private string? exported;

    internal ExportDialog(MainWindow owner, EditorViewModel model, bool demo, Func<Project, EditState?, CancellationToken, Task<ComposeSnapshot>> snapshot, string? clipId = null)
    {
        this.owner = owner; this.model = model; this.demo = demo; this.snapshot = snapshot;
        var selected = clipId ?? model.State?.ActiveClipId;
        onlyClip = model.KeptClips.Any(clip => clip.Id == selected) ? selected : null;
        Title = "Export"; PrimaryButtonText = "Export"; CloseButtonText = "Cancel"; DefaultButton = ContentDialogButton.Primary;
        var body = Ui.Stack(16); body.MinWidth = 400;
        form.Children.Add(Ui.Text("Your source stays untouched. Captions are burned into the exported video.", "HelperText"));
        aspect = Ui.Radios("Aspect", ["9:16", "1:1", "16:9", "Original"], EditorLayout.Frames.ToList().IndexOf(model.Project.Export.Aspect));
        quality = Ui.Radios("Quality", ["Standard", "High"], (int)model.Project.Export.Quality);
        target = new RadioButtons { Header = "What", MaxColumns = 1 };
        if (onlyClip is not null)
        {
            var clip = model.KeptClips.Single(clip => clip.Id == onlyClip);
            var currentClip = new RadioButton { Content = $"This clip\nClip {clip.Number} · {clip.Title} · {clip.Duration}" };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(currentClip, $"This clip, Clip {clip.Number} · {clip.Title} · {clip.Duration}");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(currentClip, "Export.ThisClip");
            target.Items.Add(currentClip);
        }
        target.Items.Add(new RadioButton { Content = $"All {model.KeptClips.Count} clips", IsEnabled = model.KeptClips.Count > 0 });
        target.Items.Add(new RadioButton { Content = $"Full video · {EditorViewModel.Duration(model.FullTakeDuration)}" });
        target.SelectedIndex = onlyClip is null ? 1 : 0;
        srt.IsChecked = model.Project.Export.Srt;
        folder.Text = model.Project.Export.Folder ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "VoxClip");
        styles = Ui.Choice("Captions", []);
        styles.SelectionChanged += (_, _) => { if (styles.SelectedItem is ComboBoxItem item && item.Tag is string id) model.SetCaptionStyle(id); };
        Opened += async (_, _) => await Ui.RunAsync(notice, async () =>
        {
            var entries = await App.Services.ReadStylesAsync(lifetime.Token);
            styles.Items.Add(new ComboBoxItem { Content = "Off", Tag = "off" });
            foreach (var entry in entries) styles.Items.Add(new ComboBoxItem { Content = entry.Name, Tag = entry.Id });
            styles.SelectedItem = styles.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == model.Project.Captions.StyleId);
        }, "Caption styles");
        form.Children.Add(target); form.Children.Add(aspect); form.Children.Add(quality); form.Children.Add(styles); form.Children.Add(srt); form.Children.Add(folder);
        form.Children.Add(Ui.Button("Choose folder…", () => _ = Ui.RunAsync(notice, ChooseFolderAsync, "Export folder")));
        form.Children.Add(disclosure); body.Children.Add(form);
        target.SelectionChanged += (_, _) => UpdateDisclosure();
        UpdateDisclosure();
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(progress, "Export progress");
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
        Closed += (_, _) => { closed = true; if (!running) lifetime.Dispose(); };
        if (demo) { IsPrimaryButtonEnabled = false; Ui.Show(notice, "Demo fixtures use a synthetic preview and cannot be exported. Open a real project to export."); }
    }
    private IReadOnlyList<ExportTarget> Targets() => ExportDialogRouting.SelectedTargets(model, onlyClip, target.SelectedIndex);
    private void UpdateDisclosure()
    {
        var contains = Targets().Any(item => model.ContainsAiSpeech(item is ExportTarget.Clip clip ? clip.Id : null));
        disclosure.Visibility = contains ? Visibility.Visible : Visibility.Collapsed;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, VoiceLabDisclosure.AccessibleName("Export video", contains));
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
            var route = new ExportDialogRouting(model, onlyClip, target.SelectedIndex, aspect.SelectedIndex, quality.SelectedIndex,
                srt.IsChecked == true, folder.Text, App.Services.Get("export.fileNamePattern", "{project}-{clip}-{aspect}"));
            var jobs = route.Targets;
            if (jobs.Count == 0) { Ui.Show(notice, "Choose clips to export."); return; }
            if (jobs.Select(job => model.ExportBlocked(demo, false, job is ExportTarget.Clip clip ? clip.Id : null)).FirstOrDefault(reason => reason is not null) is { } blocked) { Ui.Show(notice, blocked); return; }
            model.SetExport(route.Project.Export);
            running = true; model.Busy = true; App.Services.BusyOperations++; IsPrimaryButtonEnabled = false; progress.Visibility = Visibility.Visible;
            PrimaryButtonText = "Export";
            form.Visibility = Visibility.Collapsed;
            ExportTarget? currentTarget = null;
            try
            {
                Directory.CreateDirectory(route.Project.Export.Folder!);
                var jobNumber = 0;
                foreach (var exportTarget in jobs)
                {
                    var currentJob = ++jobNumber;
                    var clock = System.Diagnostics.Stopwatch.StartNew();
                    currentTarget = exportTarget;
                    var clip = exportTarget is ExportTarget.Clip clipTarget ? model.Clips.Single(clip => clip.Id == clipTarget.Id) : null;
                    model.SetExportActivity(exportTarget, ClipExportState.Exporting, 0);
                    var state = route.State(exportTarget);
                    var exportedProject = route.Project;
                    var job = await route.JobAsync(exportTarget, snapshot, lifetime.Token);
                    var result = await App.Services.Exporter.ExportAsync(job,
                        new Progress<ExportProgress>(value => { if (!running || !ReferenceEquals(currentTarget, exportTarget)) return; progress.IsIndeterminate = value.Fraction is null; progress.Value = (value.Fraction ?? 0) * 100; model.SetExportActivity(exportTarget, ClipExportState.Exporting, value.Fraction); Ui.Show(notice, ExportProgressText.Format(currentJob, jobs.Count, value.Fraction, clock.Elapsed.TotalSeconds)); }), lifetime.Token);
                    await App.Services.ExportLedger.RecordAsync(exportedProject, exportTarget, result.Output, lifetime.Token,
                        job.Snapshot.VoiceLab?.Prepared.Disclosure.Position ?? VoiceLabSettingsState.LabelPosition(App.Services.Settings.GetString("voiceLab.labelPosition")));
                    model.SetExportRecords(App.Services.ExportLedger.Records);
                    model.SetExportActivity(exportTarget, ClipExportState.None);
                    currentTarget = null;
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
                share.Visibility = Visibility.Visible; CloseButtonText = "Done"; Ui.Show(notice, $"Saved {jobs.Count} {(jobs.Count == 1 ? "video" : "videos")} to {folder.Text}");
                if (App.Services.Get("export.openFolderAfter", false) && exported is not null) ShareHelpers.Reveal(exported);
            }
            catch (OperationCanceledException) { if (currentTarget is not null) model.SetExportActivity(currentTarget, ClipExportState.None); throw; }
            catch (Exception exception)
            {
                if (currentTarget is not null) model.SetExportActivity(currentTarget, ClipExportState.Failed);
                Ui.Show(notice, UiError.ExportMessage(exception, folder.Text), InfoBarSeverity.Error);
                PrimaryButtonText = "Try again";
            }
            finally
            {
                running = false; model.Busy = false; App.Services.BusyOperations--; IsPrimaryButtonEnabled = !lifetime.IsCancellationRequested; progress.Visibility = Visibility.Collapsed;
                if (share.Visibility != Visibility.Visible) form.Visibility = Visibility.Visible;
                if (closed) lifetime.Dispose();
            }
        }, "Export");
    }
}
