using Microsoft.UI.Xaml;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using Windows.Foundation;
using Windows.System;

namespace VoxClip.App.Controls;

public sealed partial class TimelineView
{
    private sealed record ItemHit(TimelineItem Item, TimelineItemDetails Details, TimeRange Range, Rect Rect, double Left, double Right);
    private sealed record ItemDrag(TimelineEditSession Session, ItemHit Hit, TimelineItemGesture Gesture, Point Origin,
        TimelineItemId[] Ids, GainPoint? Point, bool AddPoint, bool Band, TimeRange? PreviousBand, TimelineItemId? PreviousBandItem)
    {
        internal bool Moved { get; set; }
    }
    private sealed record ItemNodes(TimelineItemControl Item, TimelineRangeControl Start, TimelineRangeControl End);

    private readonly Canvas itemDrawing = new() { IsHitTestVisible = false };
    private readonly TimelineSelectionCanvas itemPeers = new() { IsHitTestVisible = false };
    private readonly Canvas itemOverlay = new() { IsHitTestVisible = false };
    private readonly List<ItemHit> itemHits = [];
    private readonly Dictionary<TimelineItemId, ItemNodes> itemNodes = [];
    private readonly List<TimelineItemId> selectedItems = [];
    private TimelineItemId? hoveredItem;
    private readonly InputSystemCursor resizeCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
    private TimelineItemLayout? itemLayout;
    private EditPlan? itemPlan;
    private Project? itemProject;
    private TimelineAxis itemAxis;
    private TimelineWindow? lastItemWindow;
    private double lastItemWidth;
    private double[] duckContour = [];
    private ItemDrag? itemDrag;
    private Point? marquee;
    private TimelineItemId[] marqueeSelection = [];
    private TimelineItemId[] previousMarqueeSelection = [];
    private TimeRange? audioBand;
    private TimelineItemId? audioBandItem;
    private GainPoint? selectedGainPoint;
    private string? itemMessage;
    private readonly TextBlock itemFeedback = new() { Margin = new(8, 2, 8, 0), FontSize = 11, IsHitTestVisible = false };
    private double? itemGuide;
    private Point? itemFeedbackOrigin;
    private string? gestureReadout;
    private bool trimMoved;
    private double trimOriginX;
    private double scrubOrigin;
    private (int Start, int End)? scrubSelection;
    private (double Start, double End)? priorAskRange;
    private TimelineWindow overviewOrigin;
    private TimelineAxis ItemAxis => Edited ? TimelineAxis.Edited : TimelineAxis.Source;
    private bool CanEditItems => model is { IsReadOnly: false, Busy: false } && !renderingBlocked;
    public event EventHandler? OpenMusicRequested;

    private void InitializeItemEditing(Grid layout)
    {
        track.Children.Insert(2, itemPeers);
        canvas.Children.Add(itemOverlay);
        track.Children.Add(itemFeedback);
        AutomationProperties.SetLiveSetting(itemFeedback, AutomationLiveSetting.Polite);
        InitializeItemBar(layout);
        slider.PointerExited += (_, _) => UpdateItemHover(null);
        KeyDown += (_, args) =>
        {
            if (args.Handled || InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot)) || model?.CorrectionWordId is not null) return;
            var shortcut = TimelineKeys.Resolve((int)args.Key, InputState.Down(VirtualKey.Control), InputState.Down(VirtualKey.Shift), InputState.Down(VirtualKey.Menu));
            if (HandleItemKey(shortcut)) args.Handled = true;
        };
    }

    private double ItemOffset => Edited && story is null && model?.ActiveClip is not null && ClipBounds() is { } bounds ? ToDisplay(bounds.Start) : 0;
    private double ItemToScreen(double time) => !Edited && story is not null ? ToDisplay(time) : time + ItemOffset;
    private double ScreenToItem(double time) => !Edited && story is not null ? FromDisplay(time) : time - ItemOffset;
    private double ItemAt(Point point) => ScreenToItem(view.Time(point.X, track.ActualWidth));
    private double ItemX(double itemTime, double width) => view.X(ItemToScreen(itemTime), width);

    private void RefreshItemProjection()
    {
        if (model is null) return;
        lastItemWindow = null;
        if (ReferenceEquals(model.Project, itemProject) && itemAxis == ItemAxis) return;
        if (itemProject?.Edits.ActiveClipId != model.Project.Edits.ActiveClipId) ClearItemSelection();
        itemProject = model.Project;
        itemAxis = ItemAxis;
        var clipId = model.Project.Edits.ActiveClipId;
        itemPlan = RenderCallerInputs.PlacementPlan(model.Project, clipId);
        itemLayout = TimelineItems.Layout(model.Project, itemPlan, clipId, itemAxis);
        selectedItems.RemoveAll(id => !itemLayout.Items.Any(item => item.Id == id));
        duckContour = DuckContour(model.Project, clipId, itemPlan);
    }

    private static double[] DuckContour(Project project, string? clipId, EditPlan editPlan)
    {
        if (project.Music.FirstOrDefault(track => track.ClipId == clipId) is not { Ducking: true } track) return [];
        var activity = new bool[(int)Math.Ceiling(editPlan.Duration / MusicMix.FrameSeconds)];
        foreach (var word in project.Transcript?.Words ?? [])
        {
            var start = Math.Clamp((int)Math.Floor(editPlan.MapTime(word.Start) / MusicMix.FrameSeconds), 0, activity.Length);
            var end = Math.Clamp((int)Math.Ceiling(editPlan.MapTime(word.End) / MusicMix.FrameSeconds), 0, activity.Length);
            if (end > start && editPlan.MapTime(word.End) > editPlan.MapTime(word.Start)) Array.Fill(activity, true, start, end - start);
        }
        return MusicMix.DuckingGainsDb(activity, true, track.DuckDb ?? MusicMix.DuckDb);
    }

    private void DrawItems(double width)
    {
        if (model is null || itemLayout is null || itemPlan is null || width <= 0) return;
        if (lastItemWindow == view && lastItemWidth == width) return;
        lastItemWindow = view; lastItemWidth = width;
        itemDrawing.Children.Clear(); itemHits.Clear();
        var displayed = new HashSet<TimelineItemId>();
        var preview = itemDrag is { Session.IsCurrent: true } drag && !ReferenceEquals(drag.Session.PreviewProject, drag.Session.Baseline)
            ? drag.Session.PreviewProject : null;
        var changed = preview is not null && itemDrag!.Hit.Item.Lane == TimelineLane.V1;
        var layout = preview is null ? itemLayout : TimelineItems.Layout(preview,
            changed ? RenderCallerInputs.PlacementPlan(preview, preview.Edits.ActiveClipId) : itemPlan, preview.Edits.ActiveClipId, ItemAxis);
        foreach (var lane in Enum.GetValues<TimelineLane>())
        {
            if (lane != TimelineLane.M1) Paint(itemDrawing, Brush("VcTimelineTrackBrush"), 0, metrics.Top(lane) + metrics.LaneHeight(lane), width, 1, 1);
            var hint = lane switch
            {
                TimelineLane.T1 => "Add a title with Titles & effects", TimelineLane.B1 => "Add B-roll with ✦ Ask Claude",
                TimelineLane.FX => "Director results land here", TimelineLane.S1 => "Add a sound with Titles & effects",
                TimelineLane.M1 => "Choose background music", _ => null
            };
            if (hint is not null && !layout.Items.Any(item => item.Lane == lane)) ItemText(itemDrawing, hint, 6, metrics.Top(lane) + 3, width - 10, "VcTextTertiaryBrush");
        }
        foreach (var item in layout.Items)
        {
            var selected = selectedItems.Contains(item.Id);
            var details = TimelineItemDetails.Read(preview ?? model.Project, model.Project.Edits.ActiveClipId, item);
            var row = metrics.RowHeight(item.Lane);
            var top = metrics.Top(item.Lane) + Math.Min(item.Row, (int)(metrics.LaneHeight(item.Lane) / row) - 1) * row + 2;
            var height = item.Lane == TimelineLane.V1 ? Math.Min(row - 4, 15) : row - 4;
            var ranges = item.Hidden && item.Marker is { } marker ? [new TimeRange(marker, marker)] : item.AxisIntervals;
            foreach (var range in ranges)
            {
                var left = ItemX(range.Start, width); var right = ItemX(range.End, width);
                if (item.Hidden) { left -= 4; right += 4; }
                if (right < 0 || left > width || right < left) continue;
                var visibleLeft = Math.Clamp(left, 0, Math.Max(0, width - 1));
                var visibleRight = Math.Clamp(right, visibleLeft + 1, width);
                var box = new Rect(visibleLeft, top, visibleRight - visibleLeft, height);
                var hit = new ItemHit(item, details, range, box, left, right);
                var speech = item.Lane == TimelineLane.V1;
                if (!speech || item.Id.Type == TimelineItemType.Part || selected || changed) DrawItem(hit, selected, width);
                if (!speech || item.Id.Type == TimelineItemType.Part)
                    itemHits.Add(hit);
                if (preview is null && displayed.Add(item.Id)) PlaceItemPeers(hit, selected);
            }
        }
        foreach (var hit in itemHits.Where(hit => hit.Item.Lane == TimelineLane.M1))
            foreach (var other in itemHits.Where(other => other.Item.Lane == TimelineLane.M1 && other.Item.Id != hit.Item.Id && other.Range.Start < hit.Range.Start))
            {
                var left = hit.Rect.Left; var right = Math.Min(other.Rect.Right, Math.Min(hit.Rect.Right, left + 2 * width / view.Duration));
                if (right <= left) continue;
                var brush = Brush("VcTextSecondaryBrush");
                itemDrawing.Children.Add(new Line { X1 = left, X2 = right, Y1 = hit.Rect.Top, Y2 = hit.Rect.Bottom, Stroke = brush, Opacity = .5 });
                itemDrawing.Children.Add(new Line { X1 = left, X2 = right, Y1 = hit.Rect.Bottom, Y2 = hit.Rect.Top, Stroke = brush, Opacity = .5 });
            }
        if (preview is null)
            foreach (var id in itemNodes.Keys.Where(id => !displayed.Contains(id)).ToArray())
            {
                var node = itemNodes[id]; itemPeers.Children.Remove(node.Item); itemPeers.Children.Remove(node.Start); itemPeers.Children.Remove(node.End);
                itemNodes.Remove(id);
            }
        DrawItemFeedback(width);
    }

    private void DrawItem(ItemHit hit, bool selected, double width)
    {
        var box = hit.Rect;
        var item = hit.Item;
        var stroke = Brush(selected ? "VcTextPrimaryBrush" : "VcTimelineCueTextBrush");
        var background = Brush(item.Lane is TimelineLane.S1 or TimelineLane.M1 ? "VcTimelineCueBrush" : "VcAiTintBrush");
        var border = new Border { Width = box.Width, Height = box.Height, CornerRadius = new(2),
            Background = item.Hidden ? null : background, BorderBrush = stroke, BorderThickness = new(selected || item.Hidden ? 1 : 0) };
        Canvas.SetLeft(border, box.X); Canvas.SetTop(border, box.Y); itemDrawing.Children.Add(border);
        if (box.Width >= 24 && !item.Hidden)
            ItemText(itemDrawing, (item.Id.Type == TimelineItemType.Music ? "♪ " : "") + hit.Details.Title, box.Left + 5, box.Top + 1, box.Width - 10, "VcTimelineCueTextBrush");
        foreach (var notch in item.SeamNotches)
        {
            var x = ItemX(notch, width);
            if (x > box.Left && x < box.Right) Paint(itemDrawing, stroke, x, box.Top + 1, 1, box.Height - 2, .65);
        }
        if (!TimelineItemEditing.Editable(item)) return;
        var audio = TimelineItemEditing.Audio(item);
        if (audio) DrawItemAudio(hit);
        if (!selected && itemDrag?.Hit.Item.Id != item.Id && hoveredItem != item.Id) return;
        if (TimelineItemEditing.CanFade(item))
        {
            DrawFade(hit, true, stroke); DrawFade(hit, false, stroke);
        }
        if (hit.Left >= 0) Paint(itemDrawing, stroke, hit.Left, box.Top + 4, 2, Math.Max(1, box.Height - 8), .9);
        if (hit.Right <= width) Paint(itemDrawing, stroke, Math.Max(0, hit.Right - 2), box.Top + 4, 2, Math.Max(1, box.Height - 8), .9);
        if (TimelineItemEditing.CanSlip(item) && box.Width > 35)
            ItemText(itemDrawing, "⇔", box.Left + box.Width / 2 - 7, box.Bottom - 14, 20, "VcTimelineCueTextBrush");
    }

    private void DrawFade(ItemHit hit, bool leading, Brush stroke)
    {
        var box = hit.Rect;
        var edge = leading ? hit.Left : hit.Right;
        if (edge < box.Left || edge > box.Right || box.Width < 12) return;
        var seconds = leading ? hit.Details.FadeIn : hit.Details.FadeOut;
        var direction = leading ? 1 : -1;
        var edgeX = edge + direction * 3;
        var dotX = Math.Clamp(edgeX + direction * seconds * lastItemWidth / view.Duration, box.Left + 3, box.Right - 3);
        if (seconds > 0)
            itemDrawing.Children.Add(new Line { X1 = edge, X2 = dotX, Y1 = box.Bottom, Y2 = box.Top + 3, Stroke = stroke, Opacity = .65 });
        var dot = new Ellipse { Width = 5, Height = 5, Fill = stroke };
        Canvas.SetLeft(dot, dotX - 2.5); Canvas.SetTop(dot, box.Top + 1); itemDrawing.Children.Add(dot);
    }

    private void DrawItemAudio(ItemHit hit)
    {
        var box = hit.Rect;
        var ink = Brush("VcTimelineCueTextBrush");
        DrawItemWaveform(hit, ink);
        if (audioBandItem == hit.Item.Id && audioBand is { } band)
        {
            var lower = Math.Max(box.Left, ItemX(band.Start, lastItemWidth));
            var upper = Math.Min(box.Right, ItemX(band.End, lastItemWidth));
            if (upper > lower) Paint(itemDrawing, Brush("VcTintDefaultBrush"), lower, box.Top, upper - lower, box.Height, .45);
        }
        var points = new Polyline { Stroke = ink, StrokeThickness = 1.2 };
        var duck = new Polyline { Stroke = ink, Opacity = .55, StrokeDashArray = [3, 2] };
        var count = Math.Clamp((int)(box.Width / 4), 1, 250);
        for (var index = 0; index <= count; index++)
        {
            var x = box.Left + box.Width * index / count;
            var local = LocalTime(hit, x);
            var db = hit.Details.Level + hit.Details.Envelope(local);
            points.Points.Add(new(x, VolumeY(hit, db)));
            if (hit.Item.Id.Type == TimelineItemType.Music && duckContour.Length > 0)
            {
                var frame = (int)((hit.Item.EditedIntervals[0].Start + local) / MusicMix.FrameSeconds);
                duck.Points.Add(new(x, VolumeY(hit, db + duckContour[Math.Clamp(frame, 0, duckContour.Length - 1)])));
            }
        }
        itemDrawing.Children.Add(points); if (duck.Points.Count > 0) itemDrawing.Children.Add(duck);
        foreach (var point in hit.Details.Points ?? [])
        {
            var x = AudioX(hit, point.T);
            if (x < box.Left || x > box.Right) continue;
            var dot = new Ellipse { Width = 7, Height = 7, Fill = ink,
                Stroke = selectedGainPoint == point && selectedItems.Contains(hit.Item.Id) ? Brush("VcTintDefaultBrush") : null, StrokeThickness = 2 };
            Canvas.SetLeft(dot, x - 3.5); Canvas.SetTop(dot, VolumeY(hit, hit.Details.Level + point.Db) - 3.5); itemDrawing.Children.Add(dot);
        }
    }

    private static double VolumeY(ItemHit hit, double db) => hit.Rect.Top + 6 + Math.Max(1, hit.Rect.Height - 10) * Math.Clamp((6 - db) / 46, 0, 1);
    private double LocalTime(ItemHit hit, double x)
    {
        var at = ScreenToItem(view.Start + x / lastItemWidth * view.Duration);
        return (Edited ? at : itemPlan!.MapTime(at)) - hit.Item.EditedIntervals[0].Start;
    }
    private double AudioX(ItemHit hit, double time)
    {
        var editedTime = hit.Item.EditedIntervals[0].Start + time;
        return ItemX(Edited ? editedTime : itemPlan!.SourceTime(editedTime), lastItemWidth);
    }
    private void ItemText(Canvas layer, string text, double left, double top, double width, string brush)
    {
        if (width <= 0) return;
        var label = new TextBlock { Text = text, FontSize = 11, MaxWidth = width, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = Brush(brush) };
        Canvas.SetLeft(label, left); Canvas.SetTop(label, top); layer.Children.Add(label);
    }

    private ItemHit? HitItem(Point point) => itemHits.LastOrDefault(hit => hit.Rect.Contains(point));
    private void UpdateItemHover(Point? point)
    {
        if (itemDrag is not null || marquee is not null || scrubbing || trimming) return;
        var hit = point is { } position ? HitItem(position) : null;
        var resize = hit is not null && point is { } pointer && TimelineItemEditing.Editable(hit.Item) &&
            (Math.Abs(hit.Left - pointer.X) <= 6 || Math.Abs(hit.Right - pointer.X) <= 6);
        ProtectedCursor = resize ? resizeCursor : null;
        if (hoveredItem == hit?.Item.Id) return;
        hoveredItem = hit?.Item.Id;
        RedrawItems();
    }

    private bool ItemPressed(Point point, PointerRoutedEventArgs args)
    {
        if (model is null) return false;
        var ctrl = InputState.Down(VirtualKey.Control); var shift = InputState.Down(VirtualKey.Shift); var alt = InputState.Down(VirtualKey.Menu);
        if (HitItem(point) is not { } hit)
        {
            if (point.Y < metrics.Top(TimelineLane.T1) || point.Y >= metrics.Top(TimelineLane.M1) + metrics.MusicHeight ||
                point.Y >= metrics.VideoTop && point.Y < metrics.Top(TimelineLane.S1) ||
                ctrl && shift && point.Y >= metrics.EffectsTop && point.Y < metrics.EffectsTop + metrics.EffectsHeight) return false;
            previousMarqueeSelection = selectedItems.ToArray();
            marqueeSelection = ctrl || shift ? previousMarqueeSelection : [];
            if (!ctrl && !shift) ClearItemSelection();
            marquee = point;
        }
        else
        {
            var selected = selectedItems.Contains(hit.Item.Id);
            var audio = TimelineItemEditing.Audio(hit.Item);
            var key = audio ? (hit.Details.Points ?? []).Select(keyframe => (GainPoint?)keyframe).FirstOrDefault(keyframe => keyframe is { } value &&
                Math.Abs(AudioX(hit, value.T) - point.X) <= 5 && Math.Abs(VolumeY(hit, hit.Details.Level + value.Db) - point.Y) <= 5) : null;
            var line = audio && Math.Abs(point.Y - VolumeY(hit, hit.Details.Level + hit.Details.Envelope(LocalTime(hit, point.X)))) <= 4;
            var slipCombo = ctrl && alt && TimelineItemEditing.CanSlip(hit.Item);
            if ((ctrl || shift) && !slipCombo) { SelectItem(hit.Item.Id, !selected, true); slider.Focus(FocusState.Pointer); args.Handled = true; return true; }
            if (!selected) SelectItem(hit.Item.Id, true, false);
            else { selectedGainPoint = null; itemMessage = null; }
            var gesture = alt ? TimelineItemGesture.Duplicate : TimelineItemGesture.Move;
            var band = false;
            var add = false;
            var local = point.Y - hit.Rect.Top;
            var leadingFade = Math.Clamp(hit.Left + 3 + hit.Details.FadeIn * lastItemWidth / view.Duration, hit.Rect.Left + 3, Math.Max(hit.Rect.Left + 3, hit.Rect.Right - 3));
            var trailingFade = Math.Clamp(hit.Right - 3 - hit.Details.FadeOut * lastItemWidth / view.Duration, hit.Rect.Left + 3, Math.Max(hit.Rect.Left + 3, hit.Rect.Right - 3));
            if (slipCombo) gesture = TimelineItemGesture.Slip;
            else if (TimelineItemEditing.CanFade(hit.Item) && hit.Rect.Width >= 12 && local <= 7 && Math.Abs(point.X - leadingFade) <= 5) gesture = TimelineItemGesture.FadeIn;
            else if (TimelineItemEditing.CanFade(hit.Item) && hit.Rect.Width >= 12 && local <= 7 && Math.Abs(point.X - trailingFade) <= 5) gesture = TimelineItemGesture.FadeOut;
            else if (key is not null && !alt) { gesture = TimelineItemGesture.Keyframe; selectedGainPoint = key; }
            else if (Math.Abs(point.X - hit.Left) <= Math.Min(6, hit.Rect.Width / 3) && hit.Range.Start == hit.Item.AxisIntervals.FirstOrDefault().Start) gesture = TimelineItemGesture.Start;
            else if (Math.Abs(point.X - hit.Right) <= Math.Min(6, hit.Rect.Width / 3) && hit.Range.End == hit.Item.AxisIntervals.LastOrDefault().End) gesture = TimelineItemGesture.End;
            else if (line)
            {
                add = alt;
                gesture = audioBandItem == hit.Item.Id && audioBand is { } span && span.Start <= ItemAt(point) && ItemAt(point) <= span.End
                    ? TimelineItemGesture.Dip : TimelineItemGesture.Volume;
            }
            else if (selected && TimelineItemEditing.CanSlip(hit.Item) && Math.Abs(point.X - (hit.Rect.Left + hit.Rect.Width / 2)) <= 8 && point.Y >= hit.Rect.Bottom - 12)
                gesture = TimelineItemGesture.Slip;
            else if (selected && audio && local > hit.Rect.Height / 2) band = true;
            var ids = gesture is TimelineItemGesture.Move or TimelineItemGesture.Duplicate ? new[] { hit.Item.Id }.Concat(selectedItems.Where(id => id != hit.Item.Id)).ToArray() : [hit.Item.Id];
            if (CanEditItems && TimelineItemEditing.Editable(hit.Item))
                itemDrag = new(new(model, model.Project.Edits.ActiveClipId), hit, gesture, point, ids, key, add, band, audioBand, audioBandItem);
        }
        animation.Stop(); slider.Focus(FocusState.Pointer); slider.CapturePointer(args.Pointer); args.Handled = true;
        return true;
    }

    private bool ItemMoved(PointerRoutedEventArgs args)
    {
        var position = args.GetCurrentPoint(track).Position;
        if (marquee is { } origin)
        {
            var rect = DragRect(origin, position);
            if (rect.Width >= 3 || rect.Height >= 3)
                SetItemSelection(marqueeSelection.Concat(itemHits.Where(hit => TimelineItemEditing.Connected(hit.Item) && Overlaps(rect, hit.Rect)).Select(hit => hit.Item.Id)));
            itemOverlay.Children.Clear();
            Paint(itemOverlay, Brush("VcTintDefaultBrush"), rect.X, rect.Y, rect.Width, rect.Height, .3);
            args.Handled = true; return true;
        }
        if (itemDrag is not { } drag || model is null) return false;
        if (!drag.Session.IsCurrent) { EndTimelineCapture(); return true; }
        var dx = position.X - drag.Origin.X; var dy = position.Y - drag.Origin.Y;
        drag.Moved = Math.Max(Math.Abs(dx), Math.Abs(dy)) >= 3;
        if (!drag.Moved || drag.AddPoint) { drag.Session.Cancel(); gestureReadout = null; itemGuide = null; RedrawItems(); return true; }
        if (drag.Band)
        {
            var low = drag.Hit.Item.AxisIntervals[0].Start; var high = drag.Hit.Item.AxisIntervals[^1].End;
            var (start, end) = Ordered(ItemAt(drag.Origin), ItemAt(position));
            audioBandItem = drag.Hit.Item.Id;
            audioBand = new(Math.Clamp(start, low, high), Math.Clamp(end, low, high));
        }
        else
        {
            var layout = itemLayout! with { SnapTargets = [.. itemLayout.SnapTargets, new(ScreenToItem(ToDisplay(model.SourceTime)), TimelineSnapKind.Playhead, null)] };
            var scale = track.ActualWidth / view.Duration;
            var snappingNow = snapping.IsChecked == true && !InputState.Down(VirtualKey.Menu) && !InputState.Down(VirtualKey.N);
            var delta = drag.Hit.Item.Lane == TimelineLane.V1 ? dx / scale : ItemAt(position) - ItemAt(drag.Origin);
            var edit = TimelineItemEditing.Build(drag.Gesture, drag.Hit.Item, drag.Hit.Details, drag.Ids, layout, drag.Session.Plan,
                ItemAxis, model.Words, delta, -dy * 46 / Math.Max(1, drag.Hit.Rect.Height - 10), ItemAt(position), 8 / scale,
                snappingNow, drag.Point, audioBand);
            drag.Session.Preview(edit.Edits, edit.Undo);
            gestureReadout = edit.Refusal ?? drag.Session.Reason ?? edit.Readout;
            itemGuide = edit.Refusal is null && drag.Session.Reason is null ? edit.Guide : null;
            itemFeedbackOrigin = position;
        }
        RedrawItems(); args.Handled = true; return true;
    }

    private bool ItemReleased(PointerRoutedEventArgs args)
    {
        if (itemDrag is { } drag)
        {
            ItemMoved(args);
            if (itemDrag != drag)
            {
                slider.ReleasePointerCapture(args.Pointer); args.Handled = true; return true;
            }
            itemDrag = null;
            var at = ItemAt(args.GetCurrentPoint(track).Position);
            if (drag.AddPoint && !drag.Moved && drag.Hit.Item.AxisIntervals.Count > 0)
            {
                var source = TimelineItems.SourceAnchor(at, ItemAxis, drag.Session.Plan);
                CommitItems(new TimelineEdit.AddGainPoint(drag.Hit.Item.Id, source, drag.Hit.Details.Envelope(LocalTime(drag.Hit, args.GetCurrentPoint(track).Position.X))));
            }
            else if (!drag.Band && drag.Moved)
            {
                var old = drag.Session.Baseline;
                if (drag.Session.Commit())
                {
                    model?.Announce(model.UndoActionName ?? "Timeline changed");
                    if (drag.Gesture == TimelineItemGesture.Duplicate && itemLayout is { } current && model is not null)
                    {
                        var existing = TimelineItems.Layout(old, drag.Session.Plan, old.Edits.ActiveClipId, ItemAxis).Items.Select(item => item.Id).ToHashSet();
                        SetItemSelection(current.Items.Where(item => !existing.Contains(item.Id)).Select(item => item.Id));
                    }
                    if (drag.Gesture == TimelineItemGesture.Keyframe) selectedGainPoint = null;
                }
                else itemMessage = drag.Session.Reason;
            }
            else if (!drag.Moved && drag.Point is null) SelectItem(drag.Hit.Item.Id, true, false);
        }
        else if (marquee is null) return false;
        marquee = null;
        EndTimelineCapture(); slider.ReleasePointerCapture(args.Pointer); Draw(); args.Handled = true; return true;
    }

    private void EndTimelineCapture()
    {
        var active = itemDrag is not null || marquee is not null || gestureReadout is not null;
        if (marquee is not null) SetItemSelection(previousMarqueeSelection);
        if (itemDrag is { Band: true } band) { audioBand = band.PreviousBand; audioBandItem = band.PreviousBandItem; }
        itemDrag?.Session.Cancel(); itemDrag = null; marquee = null; marqueeSelection = [];
        previousMarqueeSelection = [];
        scrubbing = selecting = ranging = false; gestureReadout = null; itemGuide = null; itemFeedbackOrigin = null;
        if (active) RedrawItems();
    }

    private static Rect DragRect(Point first, Point last) => new(Math.Min(first.X, last.X), Math.Min(first.Y, last.Y), Math.Abs(first.X - last.X), Math.Abs(first.Y - last.Y));
    private static bool Overlaps(Rect first, Rect last) => first.Left <= last.Right && first.Right >= last.Left && first.Top <= last.Bottom && first.Bottom >= last.Top;
    private void RedrawItems() { lastItemWindow = null; DrawItems(track.ActualWidth); }

    private void DrawItemFeedback(double width)
    {
        itemOverlay.Children.Clear();
        if (itemGuide is { } guide) Paint(itemOverlay, new SolidColorBrush(Microsoft.UI.Colors.Gold), ItemX(guide, width),
            TimelineLayout.OverviewHeight, 1.5, metrics.Height - TimelineLayout.OverviewHeight - 10, 1);
        itemFeedback.Text = itemFeedbackOrigin is null ? gestureReadout ?? (selectedItems.Count == 0 ? itemMessage : null) ?? "" : "";
        itemFeedback.Visibility = itemFeedback.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        itemFeedback.Foreground = Brush("VcTextPrimaryBrush");
        itemFeedback.HorizontalAlignment = HorizontalAlignment.Left; itemFeedback.VerticalAlignment = VerticalAlignment.Top;
        if (itemFeedbackOrigin is { } point && gestureReadout is { } readout)
        {
            var left = Math.Clamp(point.X + 8, 0, Math.Max(0, width - 240)); var top = Math.Max(TimelineLayout.OverviewHeight, point.Y - 26);
            var badge = new Border { Background = Brush("VcTimelineLaneBrush"), BorderBrush = Brush("VcTextSecondaryBrush"), BorderThickness = new(1),
                Padding = new(6, 2, 6, 2), CornerRadius = new(3), MaxWidth = width,
                Child = new TextBlock { Text = readout, FontSize = 11, Foreground = Brush("VcTextPrimaryBrush") } };
            Canvas.SetLeft(badge, left); Canvas.SetTop(badge, top); itemOverlay.Children.Add(badge);
        }
    }

    private void ClearItemSelection()
    {
        selectedItems.Clear(); selectedGainPoint = null; audioBand = null; audioBandItem = null; itemMessage = null;
    }
    private void SetItemSelection(IEnumerable<TimelineItemId> selection)
    {
        var ids = selection.Distinct().ToArray();
        if (selectedItems.SequenceEqual(ids)) return;
        ClearItemSelection(); selectedItems.AddRange(ids);
        if (ids.Length > 0) { model?.ClearSelection(); if (model?.AskClaude.TimeRange is not null) model.SetAskClaudeTimeRange(null); }
        Draw();
    }
    private void SelectItem(TimelineItemId id, bool selected, bool extend) => SetItemSelection(extend
        ? selected ? selectedItems.Append(id) : selectedItems.Where(item => item != id)
        : selected ? [id] : []);

    private void OpenItem(TimelineItem item)
    {
        if (item.Id.Type == TimelineItemType.Music) OpenMusicRequested?.Invoke(this, EventArgs.Empty);
        else if (item.Id.Type == TimelineItemType.Effect) model?.AdjustAskClaudeFromTimeline(item.Id.Value);
        else if (item.Id.Type == TimelineItemType.Motion)
        {
            SelectItem(item.Id, true, false);
            itemFields.Children.OfType<TextBox>().FirstOrDefault()?.Focus(FocusState.Programmatic);
        }
    }

    private bool CommitItems(TimelineEdit edit)
    {
        if (!CanEditItems || model is null) return false;
        var session = new TimelineEditSession(model, model.Project.Edits.ActiveClipId);
        var committed = session.Commit([edit]);
        itemMessage = session.Reason;
        if (committed) model.Announce(model.UndoActionName ?? "Timeline changed");
        else if (itemMessage is { } refusal) model.Announce(refusal);
        Draw();
        return committed;
    }

    private bool HandleItemKey(TimelineShortcut shortcut)
    {
        if (model is null || shortcut == TimelineShortcut.None) return false;
        switch (shortcut)
        {
            case TimelineShortcut.Escape:
                if (itemDrag is not null || marquee is not null || trimming || scrubbing || overviewDragging || ranging)
                {
                    if (scrubbing) RestoreScrub();
                    if (ranging) model.SetAskClaudeTimeRange(priorAskRange);
                    if (overviewDragging) { overviewDragging = false; view = overviewOrigin; overview.ReleasePointerCaptures(); scrollRange.ReleasePointerCaptures(); VisibleRangeChanged?.Invoke(this, VisibleRange); }
                    CancelTrim(); EndTimelineCapture(); slider.ReleasePointerCaptures(); Draw(); return true;
                }
                if (selectedItems.Count == 0) return false;
                ClearItemSelection(); Draw(); return true;
            case TimelineShortcut.Snapping:
                if (itemDrag is null) snapping.IsChecked = snapping.IsChecked != true;
                return true;
            case TimelineShortcut.ZoomIn or TimelineShortcut.ZoomOut or TimelineShortcut.Fit:
                ZoomItems(shortcut); return true;
            case TimelineShortcut.Split:
                CommitItems(new TimelineEdit.Split(selectedItems.ToArray(), model.SourceTime)); return true;
            case TimelineShortcut.SplitAll:
                CommitItems(new TimelineEdit.SplitAll(model.SourceTime)); return true;
            case TimelineShortcut.Select:
                var head = ToDisplay(model.SourceTime);
                if (itemLayout?.Items.FirstOrDefault(item => TimelineItemEditing.Connected(item) && !item.Hidden && item.AxisIntervals.Any(range =>
                    ItemToScreen(range.Start) <= head && head < ItemToScreen(range.End))) is not { } target) return false;
                SelectItem(target.Id, true, false); return true;
        }
        if (selectedItems.Count == 0 || itemLayout is null) return false;
        var ids = selectedItems.ToArray();
        var item = itemLayout.Items.FirstOrDefault(item => item.Id == ids[0]);
        if (item is null) return false;
        if (shortcut is TimelineShortcut.Next or TimelineShortcut.Previous)
        {
            var items = itemLayout.Items.Where(candidate => TimelineItemEditing.Connected(candidate) && !candidate.Hidden)
                .OrderBy(candidate => ItemToScreen(candidate.AxisIntervals[0].Start)).ThenBy(candidate => candidate.Lane).ToArray();
            if (items.Length == 0) return false;
            var index = Array.FindIndex(items, candidate => candidate.Id == item.Id);
            var next = items[(index + (shortcut == TimelineShortcut.Next ? 1 : items.Length - 1) + items.Length) % items.Length];
            SelectItem(next.Id, true, false);
            var time = ItemToScreen(next.AxisIntervals[0].Start);
            if (time < view.Start || time > view.End) ChangeWindow(new(time - view.Duration / 2, time + view.Duration / 2));
            return true;
        }
        TimelineEdit? edit = shortcut switch
        {
            TimelineShortcut.EarlierFrame => new TimelineEdit.Nudge(ids, TimelineNudge.Frames, -1),
            TimelineShortcut.LaterFrame => new TimelineEdit.Nudge(ids, TimelineNudge.Frames, 1),
            TimelineShortcut.EarlierWord => new TimelineEdit.Nudge(ids, TimelineNudge.Words, -1),
            TimelineShortcut.LaterWord => new TimelineEdit.Nudge(ids, TimelineNudge.Words, 1),
            TimelineShortcut.TrimStart => new TimelineEdit.Trim(item.Id, TimelineEdge.Start, model.SourceTime),
            TimelineShortcut.TrimEnd => new TimelineEdit.Trim(item.Id, TimelineEdge.End, model.SourceTime),
            TimelineShortcut.Duplicate => new TimelineEdit.Duplicate(ids),
            TimelineShortcut.Delete => selectedGainPoint is { } point ? new TimelineEdit.RemoveGainPoint(item.Id, point.T) : new TimelineEdit.Delete(ids),
            TimelineShortcut.VolumeUp or TimelineShortcut.VolumeDown when TimelineItemEditing.Audio(item) => new TimelineEdit.SetGain(item.Id,
                TimelineItemDetails.Read(model.Project, model.Project.Edits.ActiveClipId, item).Gain + (shortcut == TimelineShortcut.VolumeUp ? 1 : -1)),
            _ => null
        };
        if (edit is null) return false;
        if (CommitItems(edit) && edit is TimelineEdit.RemoveGainPoint) { selectedGainPoint = null; RedrawItems(); }
        return true;
    }

    internal void ZoomItems(TimelineShortcut shortcut)
    {
        if (shortcut == TimelineShortcut.Fit)
        {
            ChangeWindow(story is null && ClipBounds() is { } bounds ? new(ToDisplay(bounds.Start), ToDisplay(bounds.End)) : new(0, AxisDuration));
            return;
        }
        var anchor = Math.Clamp(view.X(ToDisplay(model?.SourceTime ?? 0), 1), 0, 1);
        ChangeWindow(TimelineLayout.Zoom(view, AxisDuration, shortcut == TimelineShortcut.ZoomIn ? 1.5 : 1 / 1.5, anchor));
    }

    private void RestoreScrub()
    {
        if (model is null) return;
        if (scrubSelection is { } selection) { model.Select(selection.Start); model.Select(selection.End, true); }
        else model.ClearSelection();
        Seek(scrubOrigin);
    }
}
