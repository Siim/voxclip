using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace VoxClip.App;

public sealed partial class MainWindow
{
    private (string Clip, string Part)? partDrag;

    private void PartBadgeLoaded(object sender, RoutedEventArgs args)
    {
        if (sender is not Border badge || badge.DataContext is not SidebarRow row) return;
        void Update()
        {
            if (!int.TryParse(row.Number, out var number) || number < 1) return;
            var model = editor?.ViewModel;
            var part = model?.ClipParts.FirstOrDefault(candidate => candidate.Id == row.PartId);
            badge.BorderBrush = model?.StoryRecordingRegions.Count > 1 && part?.Recording is { } recording
                ? RecordingStyle.Brush(badge, recording, part.RecordingShade) : StoryPartStyle.Brush(badge, number);
            badge.Background = row.IsActive ? Ui.ThemeBrush(badge, "VcBgInputBrush") : null;
            badge.BorderThickness = new(row.IsActive ? 2 : 1);
        }
        void Changed(object? model, System.ComponentModel.PropertyChangedEventArgs change)
        {
            if (change.PropertyName is nameof(SidebarRow.Number) or nameof(SidebarRow.IsActive)) Update();
        }
        void Unloaded(object element, RoutedEventArgs unload)
        {
            row.PropertyChanged -= Changed;
            badge.Unloaded -= Unloaded;
        }
        row.PropertyChanged += Changed;
        badge.Unloaded += Unloaded;
        Update();
    }

    private void PartRowLoaded(object sender, RoutedEventArgs args)
    {
        if (sender is not Border line) return;
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            if (line.DataContext is not SidebarRow { PartId: { } id } || editor is not { } page || ShowingHome) return;
            var model = page.ViewModel;
            if (model.ClipParts.FirstOrDefault(part => part.Id == id) is not { } row) return;
            Add($"Play Part {row.Number}", () => page.PlayStoryPart(id), !model.IsReadOnly && !model.Busy);
            Add(model.HasSeveralRecordings ? "Show in transcript" : "Show in Take", () =>
            {
                if (!model.HasSeveralRecordings) ShowScope(null, keepSelection: true);
                else model.FollowRecording(row.First);
                page.RevealOutline(row.First);
            });
            menu.Items.Add(new MenuFlyoutSeparator());
            Add("Move Up", () => model.MovePart(id, row.Number - 2), model.CanEditParts && row.Number > 1, "Ctrl+Alt+Up");
            Add("Move Down", () => model.MovePart(id, row.Number), model.CanEditParts && row.Number < model.ClipParts.Count, "Ctrl+Alt+Down");
            Add("Make Clip of This Part", () => model.MakeClipsOfParts(id), model.CanEditParts);
            menu.Items.Add(new MenuFlyoutSeparator());
            Add("Remove Part", () => model.RemovePart(id), model.CanRemovePart, "Delete",
                model.ClipParts.Count == 1 ? EditorViewModel.LastPartReason : null);
        };
        line.ContextFlyout = menu;

        void Add(string title, Action invoke, bool enabled = true, string shortcut = "", string? reason = null)
        {
            var item = new MenuFlyoutItem { Text = title, IsEnabled = enabled, KeyboardAcceleratorTextOverride = shortcut };
            if (reason is not null) AutomationProperties.SetHelpText(item, reason);
            item.Click += (_, _) => invoke();
            menu.Items.Add(item);
        }
    }

    private void PartRecordingLabelLoaded(object sender, RoutedEventArgs args)
    {
        if (sender is not ContentPresenter host) return;
        ObserveRecordingRows(host, (page, model) =>
        {
            host.Content = model.StoryRecordingRegions.Count > 1 && host.DataContext is SidebarRow { PartId: { } id } &&
                model.ClipParts.FirstOrDefault(part => part.Id == id)?.Recording is { } recording ? RecordingStyle.Label(host, recording) : null;
        });
    }

    private void PartVersionRowsLoaded(object sender, RoutedEventArgs args)
    {
        if (sender is not StackPanel host) return;
        ObserveRecordingRows(host, (page, model) =>
        {
            var wasExpanded = host.Children.OfType<Expander>().Any(expander => expander.IsExpanded);
            host.Children.Clear();
            if (host.DataContext is not SidebarRow { PartId: { } id } || model.ClipParts.FirstOrDefault(part => part.Id == id) is not { } part) return;
            if (part.Part.TakeReason is { Length: > 0 } chosenReason) host.Children.Add(Ui.Text(chosenReason, "HelperText"));
            var versions = model.RecordingVersions(part);
            if (versions.Count == 0) return;
            var choices = new StackPanel { Spacing = 6 };
            choices.Children.Add(RecordingStyle.Label(host, part.Recording!, $"{part.Recording!.Label} · Playing · {part.TakeTime}"));
            choices.Children.Add(Ui.Text(string.Join(" ", model.Words.Skip(part.First).Take(part.Last - part.First + 1).Select(model.DisplayText))));
            foreach (var version in versions)
            {
                var choice = new StackPanel { Spacing = 3, Padding = new(6), Background = Ui.ThemeBrush(host, "VcBgMutedBrush") };
                choice.Children.Add(RecordingStyle.Label(host, version.Recording, $"{version.Recording.Label} · {version.Time}"));
                var words = new TextBlock { TextWrapping = TextWrapping.Wrap };
                foreach (var word in model.Words.SkipWhile(word => word.Id != version.FirstId).TakeWhile(word => word.Id != version.LastId)
                    .Append(model.Words.First(word => word.Id == version.LastId)))
                {
                    if (words.Inlines.Count > 0) words.Inlines.Add(new Run { Text = " " });
                    var run = new Run { Text = model.DisplayText(word) };
                    if (version.ChangedWordIds.Contains(word.Id)) { var underline = new Underline(); underline.Inlines.Add(run); words.Inlines.Add(underline); }
                    else words.Inlines.Add(run);
                }
                choice.Children.Add(words);
                choice.Children.Add(Ui.Text(version.Delivery, "HelperText"));
                var unavailable = model.RecordingVersionDisabledReason(id, version);
                var copy = model.RecordingVersionCopyReason(part, version);
                var play = Ui.Button("Play in Place", () => page.PlayRecordingVersion(id, version));
                var use = Ui.Button(copy is null ? "Use This Version" : "Use in a Copy", () =>
                {
                    if (model.UseRecordingVersion(id, version)) page.RevealOutline(model.SelectionStart);
                });
                play.IsEnabled = use.IsEnabled = unavailable is null && model.CanEditParts;
                choice.Children.Add(play);
                choice.Children.Add(use);
                if ((unavailable ?? copy) is { } reason)
                {
                    choice.Children.Add(Ui.Text(reason, "HelperText"));
                    AutomationProperties.SetHelpText(play, reason);
                    AutomationProperties.SetHelpText(use, reason);
                }
                if (model.RecordingUnavailable(version.Recording.Key) is not null)
                    choice.Children.Add(Ui.Button("Locate…", () => page.LocateRecording(version.Recording.Key)));
                choices.Children.Add(choice);
            }
            var fold = new Expander { Content = choices, Header = wasExpanded ? "Other versions" : $"{versions.Count + 1} versions", IsExpanded = wasExpanded,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch };
            fold.Expanding += (_, _) => fold.Header = "Other versions";
            fold.Collapsed += (_, _) => fold.Header = $"{versions.Count + 1} versions";
            AutomationProperties.SetName(fold, $"{versions.Count} other versions of part {part.Number}");
            host.Children.Add(fold);
        });
    }

    private void OutlineRecordingRowsLoaded(object sender, RoutedEventArgs args)
    {
        if (sender is not StackPanel host) return;
        ObserveRecordingRows(host, (page, model) =>
        {
            host.Children.Clear();
            if (model.ActiveClip is not null)
            {
                var recordings = model.RecordingRegions.Skip(1).Select(region => (region.Key, region.Label, Region: (VoxClip.Core.Domain.Editing.ProjectClock.Region?)region))
                    .Concat(model.RecordingCompanions.Select(source => (source.ContentKey, VoxClip.Core.Domain.Editing.ProjectClock.Label(source), Region: (VoxClip.Core.Domain.Editing.ProjectClock.Region?)null)));
                foreach (var (key, label, region) in recordings)
                {
                    var reason = model.RecordingUnavailable(key);
                    var title = $"Add a part from {label}";
                    var button = Ui.Button(title, () => { if (model.PickPartFrom(key)) page.RevealRecordingStart(); });
                    if (region is not null) button.Content = RecordingStyle.Label(host, region, title);
                    button.IsEnabled = reason is null && model.CanEditParts;
                    AutomationProperties.SetName(button, title);
                    AutomationProperties.SetHelpText(button, reason ?? "");
                    host.Children.Add(button);
                    if (region is not null)
                    {
                        var menu = new MenuFlyout();
                        AddMenuItem("Use whole recording as a part", () => model.UseWholeRecordingAsPart(key), button.IsEnabled);
                        AddMenuItem("Show in transcript", () => { model.ChooseRecordingView(new(RecordingViewKind.Recording, key)); page.RevealRecordingStart(); }, true);
                        var removeReason = model.RemoveRecordingReason(key);
                        AddMenuItem($"Remove recording {label}", () => model.RemoveRecording(key), removeReason is null && model.CanEditParts);
                        var more = new DropDownButton { Content = "More", Flyout = menu };
                        AutomationProperties.SetName(more, $"More actions for recording {label}");
                        host.Children.Add(more);
                        if (removeReason is not null) host.Children.Add(Ui.Text(removeReason, "HelperText"));

                        void AddMenuItem(string text, Action click, bool enabled)
                        {
                            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
                            item.Click += (_, _) => click();
                            menu.Items.Add(item);
                        }
                    }
                    if (reason is not null)
                    {
                        host.Children.Add(Ui.Text(reason, "HelperText"));
                        if (reason.EndsWith("Locate it to use its words.", StringComparison.Ordinal))
                            host.Children.Add(Ui.Button("Locate…", () => page.LocateRecording(key)));
                        else if (model.RecordingReference(key) is { } source)
                            host.Children.Add(Ui.Button("Transcribe on this PC", () => page.TranscribeCompanion(source)));
                    }
                }
            }
            page.AddRecordingControl(host);
        });
    }

    private void SingleRecordingActionsLoaded(object sender, RoutedEventArgs args)
    {
        if (sender is not StackPanel host) return;
        ObserveRecordingRows(host, (page, model) =>
        {
            host.Children.Clear();
            if (!model.HasSeveralRecordings && model.RecordingCompanions.Count == 0) page.AddRecordingControl(host);
        });
    }

    private void ObserveRecordingRows(FrameworkElement host, Action<Pages.EditorPage, EditorViewModel> update)
    {
        if (editor is not { } page) return;
        var model = page.ViewModel;
        void Changed(object? sender, EventArgs args) => update(page, model);
        void ContextChanged(FrameworkElement sender, DataContextChangedEventArgs args) => update(page, model);
        void Unloaded(object sender, RoutedEventArgs args)
        {
            model.Changed -= Changed;
            host.DataContextChanged -= ContextChanged;
            host.Unloaded -= Unloaded;
        }
        model.Changed += Changed;
        host.DataContextChanged += ContextChanged;
        host.Unloaded += Unloaded;
        update(page, model);
    }

    private void AddPartClicked(object sender, RoutedEventArgs args) => editor?.ViewModel.AddSelectionAsPart();

    private void RemovePartClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { DataContext: SidebarRow { PartId: { } id } }) editor?.ViewModel.RemovePart(id);
    }

    private bool HandlePartKey(SidebarRow row, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs args, EditorViewModel model)
    {
        if (row.PartId is not { } id || model.ClipParts.FirstOrDefault(part => part.Id == id) is not { } part) return false;
        var control = InputState.Down(VirtualKey.Control);
        var alt = InputState.Down(VirtualKey.Menu);
        if (InputState.Down(VirtualKey.Shift)) return false;
        if (control && alt && args.Key is VirtualKey.Up or VirtualKey.Down)
        {
            if (model.MovePart(id, part.Number - 1 + (args.Key == VirtualKey.Up ? -1 : 1))) FocusPartRow(id);
            return true;
        }
        if (!control && !alt && args.Key is VirtualKey.Delete or VirtualKey.Back)
        {
            if (model.RemovePart(id) && model.SelectedPart is { } selected && model.IsStoryClip) FocusPartRow(selected.Id);
            return true;
        }
        return false;
    }

    private void FocusPartRow(string id)
    {
        if (Shell.Rows.FirstOrDefault(row => row.PartId == id) is not { } target) return;
        Nav.ScrollIntoView(target);
        DispatcherQueue.TryEnqueue(() => (Nav.ContainerFromMenuItem(target) as Control)?.Focus(FocusState.Keyboard));
    }

    private void PartDragStarting(UIElement sender, DragStartingEventArgs args)
    {
        partDrag = null;
        if (sender is not FrameworkElement { DataContext: SidebarRow { PartId: { } id } } || editor?.ViewModel is not { CanEditParts: true, ActiveClip.Id: { } clip })
        { args.Cancel = true; return; }
        partDrag = (clip, id);
        args.Data.RequestedOperation = DataPackageOperation.Move;
    }

    private void PartDropCompleted(UIElement sender, DropCompletedEventArgs args) => partDrag = null;

    private int? PartDropDestination(Border target, bool after)
    {
        if (partDrag is not { } drag || editor?.ViewModel is not { } model || model.ActiveClip?.Id != drag.Clip ||
            target.DataContext is not SidebarRow { PartId: { } id }) return null;
        return model.PartDropIndex(drag.Part, id, after);
    }

    private void PartDragOver(object sender, DragEventArgs args)
    {
        if (sender is not Border target || partDrag is null) return;
        var after = args.GetPosition(target).Y > target.ActualHeight / 2;
        args.Handled = true;
        if (PartDropDestination(target, after) is null)
        {
            args.AcceptedOperation = DataPackageOperation.None;
            target.BorderThickness = new(0);
            return;
        }
        args.AcceptedOperation = DataPackageOperation.Move;
        target.BorderBrush = Ui.ThemeBrush(target, "VcTintDefaultBrush");
        target.BorderThickness = after ? new(0, 0, 0, 2) : new(0, 2, 0, 0);
    }

    private void PartDragLeave(object sender, DragEventArgs args)
    {
        if (sender is Border target) target.BorderThickness = new(0);
    }

    private void PartDrop(object sender, DragEventArgs args)
    {
        if (sender is not Border target || partDrag is not { } drag) return;
        var destination = PartDropDestination(target, args.GetPosition(target).Y > target.ActualHeight / 2);
        target.BorderThickness = new(0);
        partDrag = null;
        if (destination is { } index) editor?.ViewModel.MovePart(drag.Part, index);
        args.Handled = true;
    }
}
