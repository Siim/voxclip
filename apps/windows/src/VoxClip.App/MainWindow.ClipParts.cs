using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
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
            badge.BorderBrush = StoryPartStyle.Brush(badge, number);
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
            Add("Show in Take", () => { ShowScope(null, keepSelection: true); page.RevealOutline(row.First); });
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
