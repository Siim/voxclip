using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using Windows.System;

namespace VoxClip.App.Controls;

public sealed partial class TimelineView
{
    private sealed class ItemBarPanel : StackPanel
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new ItemBarPeer(this);

        private sealed class ItemBarPeer(ItemBarPanel owner) : FrameworkElementAutomationPeer(owner)
        {
            protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
        }
    }

    private readonly ItemBarPanel itemBar = new() { Spacing = 3, Padding = new(8, 3, 8, 2), Visibility = Visibility.Collapsed };
    private readonly StackPanel itemFields = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly StackPanel itemActions = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly TextBlock itemReason = new() { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly List<(Button Button, Func<TimelineEdit?> Edit, string Unavailable)> barCommands = [];
    private Project? barProject;
    private TimelineItemId[] barSelection = [];
    private bool barEditable;
    private double barHead = double.NaN;
    private double itemBarHeight;

    private void InitializeItemBar(Grid layout)
    {
        AutomationProperties.SetName(itemBar, "Selected timeline items");
        AutomationProperties.SetAutomationId(itemBar, "Timeline.ItemBar");
        AutomationProperties.SetLiveSetting(itemReason, AutomationLiveSetting.Polite);
        itemBar.Children.Add(new ScrollViewer { Content = itemFields, HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        itemBar.Children.Add(new ScrollViewer { Content = itemActions, HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        itemBar.Children.Add(itemReason);
        layout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        Grid.SetRow(itemBar, 2); layout.Children.Add(itemBar);
    }

    private void RefreshItemBar()
    {
        if (model is null || itemLayout is null || itemPlan is null || selectedItems.Count == 0)
        {
            // With no item selected the row holds the edit bar's range actions instead (issue #41).
            itemBar.Visibility = Visibility.Collapsed; barSelection = []; barCommands.Clear();
            itemBarHeight = RefreshEditBar() ? EditBarHeight : 0; return;
        }
        editBar.Visibility = Visibility.Collapsed;
        if (ReferenceEquals(model.Project, barProject) && barSelection.SequenceEqual(selectedItems) && barEditable == CanEditItems)
        {
            RefreshItemActions(true); return;
        }
        barProject = model.Project; barSelection = selectedItems.ToArray(); barEditable = CanEditItems; barHead = double.NaN;
        itemBar.Visibility = Visibility.Visible; itemFields.Children.Clear(); itemActions.Children.Clear(); barCommands.Clear();
        var items = barSelection.Select(id => itemLayout.Items.FirstOrDefault(item => item.Id == id)).OfType<TimelineItem>().ToArray();
        var single = items.Length == 1 ? items[0] : null;
        var editable = CanEditItems && items.All(TimelineItemEditing.Editable);
        itemFields.Children.Add(BarLabel(single is not null ? TimelineItemDetails.Read(model.Project, model.Project.Edits.ActiveClipId, single).Title : $"{items.Length} items"));
        if (single is { Hidden: false } item && item.EditedIntervals.Count > 0)
        {
            var id = item.Id;
            var details = TimelineItemDetails.Read(model.Project, model.Project.Edits.ActiveClipId, item);
            var start = item.SourceAnchor;
            var length = TimelineItemEditing.Length(item);
            var startEdited = item.EditedIntervals[0].Start;
            Exact("Start", start, "s", editable && TimelineItemEditing.Connected(item), value => new TimelineEdit.Move([id], value));
            itemFields.Children.Add(BarLabel(TimelineItemEditing.Word(model.Words, start)));
            Exact("Length", length, "s", editable, value => new TimelineEdit.Trim(id, TimelineEdge.End,
                EndSource(startEdited + value, itemPlan)));
            if (TimelineItemEditing.CanFade(item))
            {
                Exact("Fade in", details.FadeIn, "s", editable, value => new TimelineEdit.Fade(id, TimelineEdge.Start, value));
                Exact("Fade out", details.FadeOut, "s", editable, value => new TimelineEdit.Fade(id, TimelineEdge.End, value));
            }
            if (TimelineItemEditing.Audio(item))
                Exact("Volume", details.Level, "dB", editable, value => details.SetGain(id, value));
            if (TimelineItemEditing.CanSlip(item))
                Exact(item.Kind switch { "music" => "Song from", "sound" => "Sound from", _ => "Recording from" }, details.Offset, "s", editable,
                    value => new TimelineEdit.Slip(id, value - details.Offset));
            if (details.Track is { } track)
            {
                Exact("Dips under voice", track.Ducking ? track.DuckDb ?? MusicMix.DuckDb : 0, "dB", editable,
                    value => new TimelineEdit.SetDuck(track.Id, value));
                var loopEdit = new TimelineEdit.SetLoop(id, !details.Loop);
                var reason = editable ? new TimelineEditSession(model, model.Project.Edits.ActiveClipId).Probe([loopEdit], out _, out _) : "This item is read-only.";
                var loop = new CheckBox { Content = "Loop", IsChecked = details.Loop, IsEnabled = reason is null, MinWidth = 0 };
                ToolTipService.SetToolTip(loop, reason ?? "Loop the song when it ends.");
                if (reason is not null) itemFields.Children.Add(BarLabel(reason));
                loop.Click += (_, _) => { if (!CommitItems(loopEdit)) loop.IsChecked = details.Loop; };
                itemFields.Children.Add(loop);
            }
        }
        AddCommand("Split", () => new TimelineEdit.Split(barSelection, model.SourceTime), "Split at playhead (B)");
        AddCommand("Duplicate", () => new TimelineEdit.Duplicate(barSelection), "Duplicate item (Ctrl+D)");
        if (single is not null)
            AddCommand("Add keyframe", () =>
            {
                if (!TimelineItemEditing.Audio(single) || single.EditedIntervals.Count == 0 || itemPlan is not { } placement) return null;
                var audio = TimelineItemDetails.Read(model.Project, model.Project.Edits.ActiveClipId, single);
                var local = placement.MapTime(model.SourceTime) - single.EditedIntervals[0].Start;
                return new TimelineEdit.AddGainPoint(single.Id, model.SourceTime, audio.Envelope(local));
            }, "Choose a sound or music item.");
        AddCommand("Delete", () => selectedGainPoint is { } point && single is not null ? new TimelineEdit.RemoveGainPoint(single.Id, point.T) : new TimelineEdit.Delete(barSelection), "Delete item (Delete)");
        if (single is not null)
        {
            var music = new Button { Content = "Music…", IsEnabled = single.Id.Type == TimelineItemType.Music, Padding = new(6, 2, 6, 2) };
            ToolTipService.SetToolTip(music, music.IsEnabled ? "Open Music" : "Choose a music item.");
            music.Click += (_, _) => OpenItem(single); itemActions.Children.Add(music);
            if (single.Hidden && single.Reason is { } reason)
            {
                var restore = new Button { Content = "Restore Words", IsEnabled = CanEditItems, Padding = new(6, 2, 6, 2) };
                restore.Click += (_, _) => RestoreItemWords(single);
                itemActions.Children.Add(restore); itemFields.Children.Add(BarLabel(reason));
            }
        }
        itemBarHeight = 86;
        RefreshItemActions(true);
    }

    private static double EndSource(double at, EditPlan placementPlan)
    {
        var sample = 1 / placementPlan.SampleRate;
        return at <= 0 ? placementPlan.SourceTime(at) : placementPlan.SourceTime(at - sample) + sample;
    }

    private TextBlock BarLabel(string label) => new() { Text = label, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Foreground = Brush("VcTextSecondaryBrush") };

    private void Exact(string label, double value, string unit, bool editable, Func<double, TimelineEdit> edit)
    {
        var original = value.ToString("0.###", CultureInfo.InvariantCulture);
        var field = new TextBox { Text = original, IsReadOnly = !editable, Width = 64, MinWidth = 0, Height = 30, MinHeight = 30, Padding = new(4, 2, 4, 2) };
        AutomationProperties.SetName(field, $"{label} in {(unit == "dB" ? "decibels" : "seconds")}");
        var finishing = false;
        void CommitField()
        {
            if (finishing || !editable || field.Text == original) return;
            finishing = true;
            if (!double.TryParse(field.Text.Replace('−', '-'), NumberStyles.Float, CultureInfo.InvariantCulture, out var number) || !double.IsFinite(number))
            { itemMessage = "Enter a valid time."; Draw(); field.Text = original; }
            else if (!CommitItems(edit(number))) field.Text = original;
            finishing = false;
        }
        field.KeyDown += (_, args) =>
        {
            if (args.Key == VirtualKey.Escape) { field.Text = original; slider.Focus(FocusState.Programmatic); args.Handled = true; }
            else if (args.Key == VirtualKey.Enter) { CommitField(); slider.Focus(FocusState.Programmatic); args.Handled = true; }
        };
        field.LostFocus += (_, _) => CommitField();
        itemFields.Children.Add(BarLabel(label)); itemFields.Children.Add(field); itemFields.Children.Add(BarLabel(unit));
    }

    private void AddCommand(string label, Func<TimelineEdit?> edit, string help)
    {
        var action = new Button { Content = label, Padding = new(6, 2, 6, 2), MinWidth = 0 };
        action.Click += (_, _) => { if (edit() is { } command) CommitItems(command); };
        itemActions.Children.Add(action);
        barCommands.Add((action, edit, help));
    }

    private void RefreshItemActions(bool force = false)
    {
        if (model is null || barCommands.Count == 0 || !force && Math.Abs(barHead - model.SourceTime) < .1) return;
        barHead = model.SourceTime;
        var session = CanEditItems ? new TimelineEditSession(model, model.Project.Edits.ActiveClipId) : null;
        var reasons = new List<string>();
        foreach (var (button, edit, help) in barCommands)
        {
            var command = edit();
            var reason = command is null ? help : session is null ? "This item is read-only." : session.Probe([command], out _, out _);
            button.IsEnabled = reason is null;
            ToolTipService.SetToolTip(button, reason ?? help);
            AutomationProperties.SetHelpText(button, reason ?? help);
            if (reason is not null && command is not null && !reasons.Contains(reason)) reasons.Add(reason);
        }
        itemReason.Text = itemMessage ?? string.Join(" · ", reasons);
        itemReason.Foreground = Brush("VcTextSecondaryBrush");
        ToolTipService.SetToolTip(itemReason, itemReason.Text);
    }

    private void RestoreItemWords(TimelineItem item)
    {
        if (model?.State is not { } state || !CanEditItems || !item.Hidden) return;
        var end = item.Id.Type switch
        {
            TimelineItemType.Effect => ClipEffects.Rendered(model.Project, model.Project.Edits.ActiveClipId).FirstOrDefault(effect => effect.Id == item.Id.Value)?.End,
            TimelineItemType.Footage => model.Project.Media.Footage?.FirstOrDefault(footage => footage.Id == item.Id.Value)?.End,
            TimelineItemType.Motion => model.Project.MotionCues.FirstOrDefault(cue => cue.Id == item.Id.Value)?.SourceEnd,
            _ => null
        };
        if (end is not { } upper) return;
        var ids = model.Words.Where(word => word.End > item.SourceAnchor && word.Start < upper && state.CutWordIds.Contains(word.Id)).Select(word => word.Id)
            .Concat(state.Pauses.Where(pause => pause.End > item.SourceAnchor && pause.Start < upper && state.CutPauseIds.Contains(pause.Id)).Select(pause => pause.Id)).ToArray();
        if (ids.Length > 0) model.Apply(new EditOperation.RestoreSelection(ids));
    }

    private void PlaceItemPeers(ItemHit hit, bool selected)
    {
        var id = hit.Item.Id;
        if (!itemNodes.TryGetValue(id, out var nodes))
        {
            var control = new TimelineItemControl { Container = itemPeers, SelectItem = (value, extend) => SelectItem(id, value, extend) };
            var start = new TimelineRangeControl("Timeline item start"); var end = new TimelineRangeControl("Timeline item end");
            foreach (var (peer, edge) in new (TimelineRangeControl Peer, TimelineEdge? Edge)[] { (control, null), (start, TimelineEdge.Start), (end, TimelineEdge.End) })
            {
                AutomationProperties.SetAutomationId(peer, $"Timeline.Item.{id.Type}.{id.Value}{(edge is null ? "" : "." + edge)}");
                peer.Read = () => ReadItemRange(id, edge);
                peer.KeyDown += (_, args) =>
                {
                    if (args.Key is not (VirtualKey.Left or VirtualKey.Right) || peer.Set is null || InputState.Down(VirtualKey.Control) || InputState.Down(VirtualKey.Menu)) return;
                    var range = peer.Read(); peer.Set(Math.Clamp(range.Value + (args.Key == VirtualKey.Right ? 1 : -1), range.Minimum, range.Maximum));
                    args.Handled = true;
                };
                itemPeers.Children.Add(peer);
            }
            nodes = new(control, start, end);
            itemNodes.Add(id, nodes);
        }
        var name = TimelineItemEditing.Name(hit.Item.Kind);
        var full = TimelineItemEditing.Label(hit.Item, hit.Details, hit.Item.AxisIntervals.FirstOrDefault().Start, hit.Item.AxisIntervals.LastOrDefault().End, selected);
        AutomationProperties.SetName(nodes.Item, full);
        AutomationProperties.SetName(nodes.Start, name + " start"); AutomationProperties.SetName(nodes.End, name + " end");
        AutomationProperties.SetHelpText(nodes.Item, TimelineItemEditing.Help);
        AutomationProperties.SetHelpText(nodes.Start, "Trim start one word with Left or Right. Trim to playhead: Ctrl+Shift+[.");
        AutomationProperties.SetHelpText(nodes.End, "Trim end one word with Left or Right. Trim to playhead: Ctrl+Shift+].");
        var writable = CanEditItems && TimelineItemEditing.Editable(hit.Item) && model?.Words.Count > 0;
        nodes.Item.Set = writable && id.Type != TimelineItemType.Clip ? value => SetItemRange(id, null, value) : null;
        nodes.Start.Set = writable ? value => SetItemRange(id, TimelineEdge.Start, value) : null;
        nodes.End.Set = writable ? value => SetItemRange(id, TimelineEdge.End, value) : null;
        nodes.Start.Visibility = nodes.End.Visibility = hit.Item.Hidden ? Visibility.Collapsed : Visibility.Visible;
        nodes.Item.UpdateSelection(selected);
        Place(nodes.Item, hit.Rect.Left, hit.Rect.Width); Place(nodes.Start, hit.Rect.Left, Math.Min(6, hit.Rect.Width));
        Place(nodes.End, Math.Max(hit.Rect.Left, hit.Rect.Right - 6), Math.Min(6, hit.Rect.Width));
        void Place(TimelineRangeControl peer, double x, double width)
        {
            Canvas.SetLeft(peer, x); Canvas.SetTop(peer, hit.Rect.Top); peer.Width = width; peer.Height = hit.Rect.Height; peer.Refresh();
        }
    }

    private TimelineRange ReadItemRange(TimelineItemId id, TimelineEdge? edge)
    {
        if (model is null || itemPlan is null || itemLayout?.Items.FirstOrDefault(item => item.Id == id) is not { } item) return new(0, 0, 0, 1, "");
        var axisEnd = item.AxisIntervals.LastOrDefault().End;
        var source = edge == TimelineEdge.End ? (Edited ? EndSource(axisEnd, itemPlan) : axisEnd) : item.SourceAnchor;
        var index = TimelineItemEditing.WordStepValue(model.Words, source, edge);
        return new(0, Math.Max(0, model.Words.Count - 1), index, 1, TimelineItemEditing.Clock(source));
    }

    private void SetItemRange(TimelineItemId id, TimelineEdge? edge, double value)
    {
        if (model is not { Words.Count: > 0 } || itemPlan is null) return;
        var current = (int)ReadItemRange(id, edge).Value;
        var target = Math.Clamp((int)Math.Round(value), 0, model.Words.Count - 1);
        if (current == target) return;
        var word = model.Words[target];
        if (edge is { } boundary) CommitItems(new TimelineEdit.Trim(id, boundary, boundary == TimelineEdge.Start ? word.Start : word.End));
        else if (id.Type == TimelineItemType.Part) CommitItems(new TimelineEdit.Move([id], word.Start));
        else CommitItems(new TimelineEdit.Nudge([id], TimelineNudge.Words, target - current));
    }
}
