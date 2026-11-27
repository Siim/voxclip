using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using VoxClip.App.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    private static readonly string[] RecordingExtensions = [".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi"];
    private Button? pickAdd;
    private TextBlock? pickReason;
    private Button? selectionAdd;
    private TextBlock? selectionAddReason;
    private MediaReference? pendingRecording;
    private TranscriptionDialog? recordingTranscription;
    private bool readingRecording;
    private string? recordingProgress;

    private string? RecordingImportReason => readingRecording || pendingRecording is not null
        ? "Finish or cancel the recording you're adding first." : ViewModel.AddRecordingReason;

    private void RefreshSelectorBar()
    {
        if (disposed) return;
        var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var scroll = new ScrollViewer { Content = chips, HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
        SelectorBar.Children.Clear();
        SelectorBar.Children.Add(scroll);
        var scope = ViewModel.TranscriptRecordingView;
        if (ViewModel.StoryRecordingRegions.Count > 1)
            Chip(new(RecordingViewKind.PlayOrder), $"{ViewModel.ActiveClipLabel} · play order");
        if (ViewModel.HasSeveralRecordings || pendingRecording is not null)
        {
            foreach (var (region, index) in ViewModel.RecordingRegions.Select((region, index) => (region, index)))
            {
                var duration = EditorViewModel.Duration((double)region.DurationSamples / ViewModel.RecordingClock!.SampleRate);
                var status = region.GainDb == 0 ? "Transcribed" : FormattableString.Invariant(
                    $"{(region.GainDb < 0 ? "−" : "+")}{Math.Abs(region.GainDb):0.0} dB to match {ViewModel.RecordingRegions[0].Label}");
                Chip(new(RecordingViewKind.Recording, region.Key), $"{region.Label} · {duration} · {status}", region, $"Recording {region.Label}, {index + 1} of {ViewModel.RecordingRegions.Count}, transcribed");
            }
            if (ViewModel.HasSeveralRecordings) Chip(new(RecordingViewKind.All), "All");
        }
        foreach (var source in ViewModel.RecordingCompanions.Where(source => source.ContentKey != pendingRecording?.ContentKey))
        {
            chips.Children.Add(Ui.Text($"{ProjectClock.Label(source)} · Not transcribed"));
            var transcribe = Ui.Button("Transcribe on this PC", () => StartRecordingImport(RecordingPath(source), source, local: true));
            transcribe.IsEnabled = RecordingImportReason is null && File.Exists(RecordingPath(source));
            chips.Children.Add(transcribe);
        }
        if (pendingRecording is { } pending)
        {
            chips.Children.Add(Ui.Text($"{ProjectClock.Label(pending)} · {recordingProgress ?? "Not transcribed"}"));
            var cancel = Ui.Button("Cancel", () => recordingTranscription?.RequestClose());
            chips.Children.Add(cancel);
        }
        else if (readingRecording) chips.Children.Add(Ui.Text("Reading recording…"));
        AddRecordingControl(SelectorBar);
        pickAdd = null;
        pickReason = null;
        selectionAdd = null;
        selectionAddReason = null;
        if (ViewModel.PartPickPrompt is { } prompt)
        {
            var strip = new StackPanel { Spacing = 4 };
            strip.Children.Add(Ui.Text(prompt));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            pickAdd = Ui.Button("", () => ViewModel.AddSelectionAsPart());
            actions.Children.Add(pickAdd);
            actions.Children.Add(Ui.Button("Done", () => ViewModel.FinishPartPick()));
            pickReason = Ui.Text("", "HelperText");
            strip.Children.Add(actions);
            strip.Children.Add(pickReason);
            SelectorBar.Children.Add(strip);
        }
        else if (ViewModel.HasSeveralRecordings && ViewModel.ActiveClip is not null)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            selectionAdd = Ui.Button("", () => ViewModel.AddSelectionAsPart());
            actions.Children.Add(selectionAdd);
            selectionAddReason = Ui.Text("", "HelperText");
            actions.Children.Add(selectionAddReason);
            SelectorBar.Children.Add(actions);
            if (scope.Kind == RecordingViewKind.PlayOrder)
                SelectorBar.Children.Add(Ui.Button(ViewModel.ShowsRecordingContext ? "Hide surrounding context" : "Show surrounding context", ViewModel.ToggleRecordingContext));
        }
        RefreshRecordingSelection();

        void Chip(RecordingView choice, string title, ProjectClock.Region? region = null, string? accessible = null)
        {
            var button = new ToggleButton { Content = region is null ? title : RecordingStyle.Label(SelectorBar, region, title), IsChecked = scope == choice };
            AutomationProperties.SetName(button, accessible ?? title);
            button.Click += (_, _) => { if (ViewModel.ChooseRecordingView(choice)) RevealRecordingStart(); };
            chips.Children.Add(button);
        }
    }

    private void RefreshRecordingSelection()
    {
        if (pickAdd is not null && pickReason is not null)
            Update(pickAdd, pickReason, $"Add as Part {ViewModel.RecordingPartNumber}");
        if (selectionAdd is not null && selectionAddReason is not null)
            Update(selectionAdd, selectionAddReason, ViewModel.RecordingPartSelectionTitle);

        void Update(Button button, TextBlock reason, string? label)
        {
            button.Content = label ?? "";
            button.Visibility = label is null ? Visibility.Collapsed : Visibility.Visible;
            button.IsEnabled = ViewModel.CanAddPart;
            reason.Text = label is null ? "" : ViewModel.AddPartHelp;
            reason.Visibility = reason.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            AutomationProperties.SetHelpText(button, reason.Text);
        }
    }

    internal void AddRecordingControl(Panel host)
    {
        var reason = RecordingImportReason;
        var menu = new MenuFlyout();
        foreach (var source in ViewModel.RecordingCompanions)
        {
            var item = new MenuFlyoutItem { Text = $"{ProjectClock.Label(source)} · in this project as B-roll", IsEnabled = File.Exists(RecordingPath(source)) };
            item.Click += (_, _) => StartRecordingImport(RecordingPath(source), source);
            menu.Items.Add(item);
        }
        var choose = new MenuFlyoutItem { Text = "Choose a file…" };
        choose.Click += (_, _) => _ = RunAsync(async () =>
        {
            if (await PickRecordingFileAsync() is { } path) await ImportRecordingAsync(path, null, false);
        }, "Add a recording");
        menu.Items.Add(choose);
        var add = new DropDownButton { Content = "+ Add a recording", Flyout = menu, IsEnabled = reason is null };
        AutomationProperties.SetName(add, "Add a recording");
        AutomationProperties.SetHelpText(add, reason ?? "");
        host.Children.Add(add);
        if (reason is not null) host.Children.Add(Ui.Text(reason, "HelperText"));
    }

    internal void RevealRecordingStart()
    {
        Transcript.RefreshVisuals();
        if (ViewModel.Paragraphs.FirstOrDefault() is { } paragraph) Transcript.RevealWord(paragraph.StartIndex);
    }

    private void RevealRecordingAt(double time)
    {
        if (!ViewModel.HasSeveralRecordings || ViewModel.RecordingClock?.LocalTime(time) is not { } local) return;
        var index = Enumerable.Range(0, ViewModel.Words.Count).FirstOrDefault(index =>
            ViewModel.RecordingOf(index)?.Key == local.Key && ViewModel.Words[index].End >= time, -1);
        if (index < 0) return;
        ViewModel.FollowRecording(index);
        Transcript.RevealWord(index);
    }

    private async Task<string?> PickRecordingFileAsync()
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        foreach (var extension in RecordingExtensions) picker.FileTypeFilter.Add(extension);
        return (await picker.PickSingleFileAsync())?.Path;
    }

    private string RecordingPath(MediaReference source)
    {
        if (File.Exists(source.AbsolutePath)) return source.AbsolutePath;
        if (owner.ProjectPath is { } project && source.RelativePath is { } relative && Path.GetDirectoryName(project) is { } directory)
        {
            var candidate = Path.Combine(directory, relative);
            if (File.Exists(candidate)) return candidate;
        }
        if (MediaPath is { } primary && Path.GetDirectoryName(primary) is { } mediaDirectory)
        {
            var candidate = Path.Combine(mediaDirectory, Path.GetFileName(source.AbsolutePath));
            if (File.Exists(candidate)) return candidate;
        }
        return source.AbsolutePath;
    }

    private void RecordingDragOver(object sender, DragEventArgs args)
    {
        if (RecordingImportReason is null && args.DataView.Contains(StandardDataFormats.StorageItems)) args.AcceptedOperation = DataPackageOperation.Copy;
        args.Handled = true;
    }

    private async void RecordingDrop(object sender, DragEventArgs args)
    {
        args.Handled = true;
        if (RecordingImportReason is not null || !args.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var deferral = args.GetDeferral();
        try
        {
            var files = await args.DataView.GetStorageItemsAsync();
            if (files.OfType<StorageFile>().FirstOrDefault(file => RecordingExtensions.Contains(file.FileType, StringComparer.OrdinalIgnoreCase)) is { } file)
                StartRecordingImport(file.Path);
        }
        finally { deferral.Complete(); }
    }

    internal void StartRecordingImport(string path, MediaReference? companion = null, bool local = false) =>
        _ = RunAsync(() => ImportRecordingAsync(path, companion, local), "Add a recording");

    private async Task ImportRecordingAsync(string path, MediaReference? companion, bool local)
    {
        if (RecordingImportReason is not null) return;
        readingRecording = true;
        RefreshSelectorBar();
        try
        {
            var token = lifetime.Token;
            var info = await App.Services.Probe.ProbeAsync(path, token);
            if (info.Video is null || info.Audio is null || info.DurationSeconds <= 0)
            {
                ViewModel.Notice = "Choose a video with audio to add a recording.";
                return;
            }
            var key = await App.Services.Projects.ComputeContentKeyAsync(path, null, token);
            if (ViewModel.RecordingRegions.Any(region => region.Key == key))
            {
                ViewModel.Notice = "This recording is already in the transcript.";
                return;
            }
            companion ??= ViewModel.RecordingReference(key);
            if (companion is not null && companion.ContentKey != key) throw new InvalidOperationException("Choose the original recording.");
            var source = companion ?? ProjectFactory.Create(path, info, key).Media.Source;
            source = source with { AbsolutePath = path, Video = info.Video, Audio = info.Audio, DurationSeconds = info.DurationSeconds };
            if (await RecordingTranscriptCache.ReadAsync(key, token) is { } cached && ViewModel.AddSpokenRecording(source, cached))
            {
                RevealRecordingStart();
                return;
            }
            pendingRecording = source;
            var job = new TranscriptionDialog(owner, ViewModel, source, local, transcript =>
            {
                if (ViewModel.AddSpokenRecording(source, transcript)) RevealRecordingStart();
            }, progress => { recordingProgress = progress; RefreshSelectorBar(); });
            recordingTranscription = job;
            job.Dismissed += (_, _) =>
            {
                pendingRecording = null;
                recordingProgress = null;
                recordingTranscription = null;
                RefreshSelectorBar();
            };
            await job.ShowAsync();
        }
        finally
        {
            readingRecording = false;
            RefreshSelectorBar();
        }
    }

    internal void LocateRecording(string key) => _ = RunAsync(async () =>
    {
        if (ViewModel.RecordingReference(key) is not { } source) return;
        if (key == ViewModel.Project.Media.Source.ContentKey) { LocateClicked(this, new()); return; }
        if (await PickRecordingFileAsync() is not { } path) return;
        if (await App.Services.Projects.ComputeContentKeyAsync(path, null, lifetime.Token) != key)
        {
            ViewModel.Notice = "Choose the original recording.";
            return;
        }
        ViewModel.LocateSpokenRecording(source, path);
    }, "Locate recording");

    internal void TranscribeCompanion(MediaReference source) => StartRecordingImport(RecordingPath(source), source, local: true);
}
