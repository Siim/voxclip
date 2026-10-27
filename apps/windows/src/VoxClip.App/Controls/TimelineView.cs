using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using Windows.Foundation;
using Windows.System;

namespace VoxClip.App.Controls;

public sealed class TimelineView : UserControl
{
    private const double TrackTop = TimelineLayout.TrackTop;
    private const double TrackHeight = 30;
    private readonly Canvas canvas = new() { Height = 60, IsHitTestVisible = false };
    private readonly Canvas geometryBand = new() { Height = 60, IsHitTestVisible = false };
    private readonly Rectangle trackBed = new() { Height = TrackHeight, RadiusX = 6, RadiusY = 6 };
    private readonly CompositeTransform viewportTransform = new();
    private readonly CompositeTransform bracketTransform = new();
    private readonly Rectangle leftDim = new() { Height = TrackHeight };
    private readonly Rectangle rightDim = new() { Height = TrackHeight };
    private readonly TimelineScene scene = new();
    private readonly TimelineRetainedPool<FrameworkElement> retained;
    private TimelineWindow rendered = new(0, 1);
    private readonly Canvas handles = new() { Height = 60 };
    private readonly Grid track = new() { Height = 60, VerticalAlignment = VerticalAlignment.Center };
    private readonly TimelineRangeControl slider = new("Playhead") { Height = TrackHeight, Margin = new Thickness(0, TrackTop, 0, 0), VerticalAlignment = VerticalAlignment.Top };
    private readonly TimelineRangeControl startHandle = new("Clip start") { Width = 24, Height = 36, Visibility = Visibility.Collapsed };
    private readonly TimelineRangeControl endHandle = new("Clip end") { Width = 24, Height = 36, Visibility = Visibility.Collapsed };
    private readonly Rectangle playhead = new() { Width = 2, Height = TrackHeight + 2, IsHitTestVisible = false };
    private readonly Polygon head = new() { Points = [new(0, 0), new(12, 0), new(12, 3), new(6, 7), new(0, 3)], IsHitTestVisible = false };
    private readonly StackPanel transport = new() { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    private readonly SymbolIcon playGlyph = new(Symbol.Play);
    private readonly Button play;
    private readonly TextBlock time = new() { FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    private readonly Run elapsed = new();
    private readonly Run total = new();
    private readonly CommunityToolkit.WinUI.Controls.Segmented mode = new() { Height = 32, VerticalAlignment = VerticalAlignment.Center };
    private readonly DispatcherTimer animation = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Stopwatch animationClock = new();
    private EditorViewModel? model;
    private readonly TimelineViewportState viewport = new();
    private readonly TimelineFrame frame = new();
    private EditPlan? plan;
    private TimelineWindow view = new(0, 1);
    private TimelineWindow animationStart;
    private TimelineWindow animationEnd;
    private string? scope;
    private IReadOnlyList<float> waveform = [];
    private bool scrubbing;
    private bool trimming;
    private bool trimStart;
    private string? trimId;
    private int trimFirst;
    private int trimLast;
    private string? hoverWord;
    public event EventHandler<double>? SeekRequested;
    public event EventHandler? PlayRequested;
    private bool Edited => mode.SelectedIndex == 0;

    public TimelineView()
    {
        retained = new(CreateRetained);
        geometryBand.RenderTransform = viewportTransform;
        Canvas.SetTop(geometryBand, TrackTop);
        Canvas.SetTop(trackBed, TrackTop); canvas.Children.Add(trackBed);
        canvas.Children.Add(geometryBand);
        for (var index = 0; index < retained.Nodes.Count; index++)
            if (index < TimelineRetainedPool<object>.Layers) geometryBand.Children.Add(retained.Nodes[index]);
            else canvas.Children.Add(retained.Nodes[index]);
        retained.Nodes[12].RenderTransform = bracketTransform;
        canvas.Children.Add(leftDim); canvas.Children.Add(rightDim);
        Canvas.SetTop(leftDim, TrackTop); Canvas.SetTop(rightDim, TrackTop);
        canvas.Children.Add(playhead); canvas.Children.Add(head);
        IsTabStop = false;
        var layout = new Grid { Height = 72, ColumnSpacing = 16, Padding = new Thickness(16, 0, 16, 0) };
        layout.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new());
        mode.Items.Add(new CommunityToolkit.WinUI.Controls.SegmentedItem { Content = "Edited" });
        mode.Items.Add(new CommunityToolkit.WinUI.Controls.SegmentedItem { Content = "Source" });
        mode.SelectedIndex = 1;
        AutomationProperties.SetName(mode, "Timeline time");
        mode.SelectionChanged += (_, _) => Rebuild(true);
        play = new Button { Width = 32, Height = 32, Padding = new Thickness(0), CornerRadius = new(16), Content = playGlyph };
        AutomationProperties.SetName(play, "Play");
        AutomationProperties.SetAcceleratorKey(play, "Space");
        ToolTipService.SetToolTip(play, "Play (Space)");
        play.Click += (_, _) => PlayRequested?.Invoke(this, EventArgs.Empty);
        time.FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"];
        time.Inlines.Add(elapsed); time.Inlines.Add(total);
        transport.Children.Add(play); transport.Children.Add(time);
        layout.Children.Add(transport);
        Grid.SetColumn(mode, 1); layout.Children.Add(mode);
        track.Children.Add(canvas); track.Children.Add(slider); track.Children.Add(handles);
        handles.Children.Add(startHandle); handles.Children.Add(endHandle);
        Grid.SetColumn(track, 2); layout.Children.Add(track);
        Content = layout;
        slider.Read = ReadPlayhead;
        slider.Set = value => Seek(FromDisplay(value));
        slider.KeyDown += PlayheadKeyDown;
        slider.PointerPressed += ScrubPressed;
        slider.PointerMoved += ScrubMoved;
        slider.PointerReleased += ScrubReleased;
        slider.PointerCanceled += (_, _) => scrubbing = false;
        slider.PointerCaptureLost += (_, _) => scrubbing = false;
        slider.DoubleTapped += RestoreCut;
        ConfigureTrim(startHandle, true);
        ConfigureTrim(endHandle, false);
        track.SizeChanged += (_, _) => Draw();
        ActualThemeChanged += (_, _) => { ApplyBrushes(); Draw(); };
        animation.Tick += (_, _) =>
        {
            var fraction = Math.Clamp(animationClock.Elapsed.TotalMilliseconds / 240, 0, 1);
            var eased = 1 - Math.Pow(1 - fraction, 3);
            view = new(animationStart.Start + (animationEnd.Start - animationStart.Start) * eased, animationStart.End + (animationEnd.End - animationStart.End) * eased);
            UpdateViewport();
            if (fraction >= 1) { animation.Stop(); Draw(); }
        };
        Ui.EffectsChanged += EffectsChanged;
        Unloaded += (_, _) => animation.Stop();
        ApplyBrushes();
    }

    internal bool ShowsTransport { set => transport.Visibility = value ? Visibility.Visible : Visibility.Collapsed; }
    internal Control FocusTarget => slider;
#if DEBUG
    internal Control DebugEndHandle => endHandle;
    internal IReadOnlyList<FrameworkElement> DebugDrawingNodes => retained.Nodes;
    internal int DebugBuildVersion => scene.BuildVersion;
    internal int DebugDrawingElementCount => 1 + canvas.Children.Count + geometryBand.Children.Count + TimelineRetainedPool<object>.Badges * 2;
    internal void DebugMoveViewport(TimelineWindow window) { view = window; UpdateViewport(); }
#endif
    internal void SetTransport(string elapsedTime, string length, bool playing)
    {
        elapsed.Text = elapsedTime; total.Text = " / " + length;
        playGlyph.Symbol = playing ? Symbol.Pause : Symbol.Play;
        AutomationProperties.SetName(play, PlaybackPresentation.Name(playing));
        ToolTipService.SetToolTip(play, PlaybackPresentation.Hint(playing));
    }
    internal void SetWaveform(IReadOnlyList<float> levels) { waveform = levels; Draw(); }
    public void Attach(EditorViewModel value)
    {
        model = value; model.Changed += Changed; model.SelectionChanged += SelectionChanged;
        model.PropertyChanged += PropertyChanged;
        Rebuild(false);
    }
    public void Detach()
    {
        if (model is not null) { model.Changed -= Changed; model.SelectionChanged -= SelectionChanged; model.PropertyChanged -= PropertyChanged; }
        animation.Stop(); Ui.EffectsChanged -= EffectsChanged;
    }
    private void Changed(object? sender, EventArgs args) => Rebuild(false);
    private void SelectionChanged(object? sender, EventArgs args) => Draw();
    private void PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(EditorViewModel.IsReadOnly) or nameof(EditorViewModel.Busy)) Draw();
    }
    private void EffectsChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (!Ui.AnimationsEnabled && animation.IsEnabled) { animation.Stop(); view = animationEnd; }
        ApplyBrushes(); Draw();
    });
    private Brush Brush(string key) => Ui.ThemeBrush(this, key);
    private void ApplyBrushes()
    {
        total.Foreground = Brush("VcTextSecondaryBrush");
        playhead.Fill = head.Fill = Brush("VcTimelinePlayheadBrush");
        foreach (var handle in new[] { startHandle, endHandle })
        {
            var clear = ((SolidColorBrush)Brush("VcTimelineTrackBrush")).Color; clear.A = 0;
            var hit = new Grid { Background = new SolidColorBrush(clear) };
            hit.Children.Add(new Border { Width = 7, Height = 36, CornerRadius = new(2), Background = Brush("VcAccentTextBrush"), HorizontalAlignment = HorizontalAlignment.Center });
            handle.Content = hit;
        }
    }
    private double ToDisplay(double source) => Edited && plan is not null ? plan.MapTime(source) : source;
    private double FromDisplay(double displayed) => Edited && plan is not null ? plan.SourceTime(displayed) : displayed;
    private (double Start, double End)? ClipBounds()
    {
        var pending = trimming && trimId == viewport.ActiveClip?.Id;
        return viewport.Bounds(pending ? trimFirst : viewport.First, pending ? trimLast : viewport.Last);
    }
    private void Rebuild(bool forceZoom)
    {
        if (model is null) return;
        viewport.Reset(model);
        if (AutomationProperties.GetName(startHandle) != viewport.StartName) AutomationProperties.SetName(startHandle, viewport.StartName);
        if (AutomationProperties.GetName(endHandle) != viewport.EndName) AutomationProperties.SetName(endHandle, viewport.EndName);
        plan = TimelineLayout.Plan(model);
        viewport.Prepare(plan);
        var bounds = ClipBounds();
        var source = TimelineLayout.Window(model.Project.Media.Source.DurationSeconds, bounds?.Start, bounds?.End);
        var next = new TimelineWindow(ToDisplay(source.Start), ToDisplay(source.End));
        var changedScope = scope != model.State?.ActiveClipId;
        scope = model.State?.ActiveClipId;
        animation.Stop();
        if ((changedScope || forceZoom) && Ui.AnimationsEnabled && IsLoaded)
        {
            animationStart = view; animationEnd = next; animationClock.Restart(); animation.Start();
        }
        else view = next;
        Draw();
    }
    public void Position(double source)
    {
        UpdateViewport(source: source);
    }

    private TimelineRange ReadPlayhead()
    {
        return plan is null ? new(0, 1, 0, 0.1, "") : frame.Playhead;
    }
    private void Seek(double source)
    {
        if (model is null) return;
        source = Math.Clamp(source, 0, model.Project.Media.Source.DurationSeconds);
        model.SourceTime = source;
        Position(source);
        SeekRequested?.Invoke(this, source);
    }
    private void PlayheadKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (model is null) return;
        if (args.Key is VirtualKey.Left or VirtualKey.Right)
        {
            var index = TimelineLayout.Step(model.Words, model.SourceTime, args.Key == VirtualKey.Right ? 1 : -1, InputState.Down(VirtualKey.Shift));
            if (index >= 0) Seek(model.Words[index].Start);
            args.Handled = true;
        }
        else if (args.Key is VirtualKey.Home or VirtualKey.End) { Seek(FromDisplay(args.Key == VirtualKey.Home ? view.Start : view.End)); args.Handled = true; }
    }
    private double PointerTime(PointerRoutedEventArgs args) => FromDisplay(view.Time(args.GetCurrentPoint(track).Position.X, track.ActualWidth));
    private void ScrubPressed(object sender, PointerRoutedEventArgs args)
    {
        if (!args.GetCurrentPoint(slider).Properties.IsLeftButtonPressed) return;
        scrubbing = true; slider.Focus(FocusState.Pointer); slider.CapturePointer(args.Pointer); Scrub(args); args.Handled = true;
    }
    private void ScrubMoved(object sender, PointerRoutedEventArgs args)
    {
        if (scrubbing) Scrub(args);
        if (model is null || model.Words.Count == 0) return;
        var word = model.Words[TimelineLayout.WordAt(model.Words, PointerTime(args))];
        if (hoverWord != word.Id) { hoverWord = word.Id; ToolTipService.SetToolTip(slider, $"{model.DisplayText(word)} · {EditorViewModel.Timecode(word.Start)}"); }
    }
    private void Scrub(PointerRoutedEventArgs args)
    {
        var source = PointerTime(args);
        if (InputState.Down(VirtualKey.Shift) && model is { Words.Count: > 0 }) source = model.Words[TimelineLayout.WordAt(model.Words, source)].Start;
        Seek(source);
    }
    private void ScrubReleased(object sender, PointerRoutedEventArgs args)
    {
        if (!scrubbing) return;
        Scrub(args); scrubbing = false; slider.ReleasePointerCapture(args.Pointer); args.Handled = true;
    }
    private void RestoreCut(object sender, DoubleTappedRoutedEventArgs args)
    {
        if (model?.State is not { } state) return;
        var source = FromDisplay(view.Time(args.GetPosition(track).X, track.ActualWidth));
        var ids = model.Words.Where(word => word.Start <= source && source < word.End && state.CutWordIds.Contains(word.Id)).Select(word => word.Id)
            .Concat(state.Pauses.Where(pause => pause.Start <= source && source < pause.End && state.CutPauseIds.Contains(pause.Id)).Select(pause => pause.Id)).ToArray();
        if (ids.Length > 0) model.Apply(new EditOperation.RestoreSelection(ids));
        args.Handled = true;
    }

    private void ConfigureTrim(TimelineRangeControl handle, bool start)
    {
        handle.Read = () => ReadTrim(start);
        handle.Set = value => ChangeTrim(start, (int)Math.Round(value));
        handle.KeyDown += (_, args) =>
        {
            if (args.Key == VirtualKey.Escape && trimming) { trimming = false; handle.ReleasePointerCaptures(); Draw(); args.Handled = true; return; }
            if (args.Key is not (VirtualKey.Left or VirtualKey.Right)) return;
            ChangeTrim(start, (int)ReadTrim(start).Value + (args.Key == VirtualKey.Right ? 1 : -1)); args.Handled = true;
        };
        handle.PointerPressed += (_, args) =>
        {
            if (model?.State?.ActiveClipId is not { } id || !args.GetCurrentPoint(handle).Properties.IsLeftButtonPressed) return;
            var clip = model.Clips.First(clip => clip.Id == id);
            trimId = id; trimFirst = model.Index(clip.Clip.StartWordId); trimLast = model.Index(clip.Clip.EndWordId);
            trimming = true; trimStart = start; animation.Stop();
            handle.Focus(FocusState.Pointer); handle.CapturePointer(args.Pointer); args.Handled = true;
        };
        handle.PointerMoved += (_, args) =>
        {
            if (!trimming || trimStart != start || model is null) return;
            UpdateViewport(args.GetCurrentPoint(track).Position.X); args.Handled = true;
        };
        handle.PointerReleased += (_, args) =>
        {
            if (!trimming || trimStart != start) return;
            trimming = false; handle.ReleasePointerCapture(args.Pointer);
            if (model is not null && trimId is not null) TimelineLayout.CommitTrim(model, trimId, trimFirst, trimLast);
            Draw(); args.Handled = true;
        };
        handle.PointerCanceled += (_, _) => { trimming = false; Draw(); };
        handle.PointerCaptureLost += (_, _) => { if (trimming) { trimming = false; Draw(); } };
    }
    private TimelineRange ReadTrim(bool start)
    {
        return start ? frame.Start : frame.End;
    }
    private void ChangeTrim(bool start, int target)
    {
        if (model?.State?.ActiveClipId is not { } id || model.Clips.FirstOrDefault(clip => clip.Id == id) is not { } clip) return;
        var first = model.Index(clip.Clip.StartWordId); var last = model.Index(clip.Clip.EndWordId);
        (first, last) = TimelineLayout.Trim(first, last, target, model.Words.Count, start);
        TimelineLayout.CommitTrim(model, id, first, last);
    }

    private void Draw()
    {
        var width = track.ActualWidth;
        if (model is null || width <= 0 || plan is null) return;
        leftDim.Fill = rightDim.Fill = Brush("VcTimelineScopeDimBrush");
        rendered = animation.IsEnabled ? new(Math.Min(view.Start, animationEnd.Start), Math.Max(view.End, animationEnd.End)) : view;
        scene.Build(model, plan, rendered, waveform, width, Edited);
        canvas.Clip = new RectangleGeometry { Rect = new(0, 0, width, 60) };
        trackBed.Fill = Brush("VcTimelineTrackBrush"); trackBed.Width = width;
        var keys = new[] { "VcTimelineKeptBackgroundBrush", "VcTimelineWaveformBrush", "VcWordFillerBrush", "VcCutStrokeBrush", "VcCutStrokeBrush", "VcCutStrokeBrush", "VcCutStrokeBrush", "VcCutStrokeBrush", "VcSelectionTranscriptBrush", "VcAccentTextBrush", "VcAccentSoftBrush", "VcAccentTextBrush", "VcAccentTextBrush", "VcLineStrongBrush", "VcLineStrongBrush" };
        for (var index = 0; index < scene.Layers.Length; index++)
        {
            var path = (Microsoft.UI.Xaml.Shapes.Path)retained.Nodes[index];
            var lines = index is 5 or 6 or >= 12;
            path.Data = Geometry(scene.Layers[index], lines, index == 1);
            path.Fill = lines ? null : Brush(keys[index]);
            path.Stroke = lines ? Brush(keys[index]) : null;
            path.StrokeThickness = lines ? 2 : 0;
            path.StrokeDashArray = index == 14 || index == 12 && model.Clips.Any(clip => clip.Id == model.State?.ActiveClipId && clip.IsSuggested) ? [3, 3] : null;
            path.Opacity = index is 3 or 4 ? TimelineLayout.CutOpacity(index == 4) : 1;
        }
        for (var index = 0; index < TimelineRetainedPool<object>.Badges; index++)
        {
            var badge = (Grid)retained.Nodes[TimelineRetainedPool<object>.Layers + index];
            badge.Visibility = index < scene.Clips.Count ? Visibility.Visible : Visibility.Collapsed;
            if (index >= scene.Clips.Count) continue;
            var clip = scene.Clips[index].Clip;
            var selected = clip.Id == model.State?.ActiveClipId;
            var border = (Rectangle)badge.Children[0];
            border.Fill = Brush(selected ? "VcAccentDefaultBrush" : "VcClipBadgeBackgroundBrush");
            border.Stroke = clip.IsSuggested ? Brush("VcLineStrongBrush") : null;
            border.StrokeDashArray = clip.IsSuggested ? [2, 2] : null;
            var text = (TextBlock)badge.Children[1];
            text.Text = clip.Number.ToString(System.Globalization.CultureInfo.InvariantCulture);
            text.Foreground = Brush(selected ? "VcAccentOnBrush" : "VcTextSecondaryBrush");
        }
        UpdateViewport();
    }
    private static FrameworkElement CreateRetained(int index)
    {
        if (index < TimelineRetainedPool<object>.Layers) return new Microsoft.UI.Xaml.Shapes.Path();
        var badge = new Grid { Width = 18, Height = 18, Visibility = Visibility.Collapsed };
        badge.Children.Add(new Rectangle { RadiusX = 4, RadiusY = 4, StrokeThickness = 1 });
        badge.Children.Add(new TextBlock { FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"], HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        Canvas.SetTop(badge, TimelineLayout.BadgeTop);
        return badge;
    }
    private void UpdateViewport(double? pointer = null, double? source = null)
    {
        if (model is null || plan is null) return;
        frame.Compute(viewport, scene, plan, rendered, view, track.ActualWidth, source ?? model.SourceTime, Edited,
            trimming, trimStart, trimId, trimFirst, trimLast, !model.IsReadOnly && !model.Busy, pointer);
        trimFirst = frame.First; trimLast = frame.Last;
        retained.Move(view);
        viewportTransform.ScaleX = frame.Scale;
        viewportTransform.TranslateX = frame.Translation;
        for (var index = 0; index < frame.BadgeCount; index++)
        {
            var badge = retained.Nodes[TimelineRetainedPool<object>.Layers + index];
            badge.Visibility = frame.Badges[index].Visible ? Visibility.Visible : Visibility.Collapsed;
            Canvas.SetLeft(badge, frame.Badges[index].Left);
        }
        leftDim.Width = frame.LeftDim; rightDim.Width = frame.RightDim; Canvas.SetLeft(rightDim, frame.RightEdge);
        bracketTransform.ScaleX = frame.BracketScale; bracketTransform.TranslateX = frame.BracketTranslation;
        startHandle.Visibility = endHandle.Visibility = frame.HasTrim ? Visibility.Visible : Visibility.Collapsed;
        if (frame.HasTrim)
        {
            startHandle.IsEnabled = endHandle.IsEnabled = frame.TrimEnabled;
            Canvas.SetLeft(startHandle, frame.StartLeft); Canvas.SetLeft(endHandle, frame.EndLeft);
            Canvas.SetTop(startHandle, TrackTop - 3); Canvas.SetTop(endHandle, TrackTop - 3);
            startHandle.Refresh(); endHandle.Refresh();
        }
        Canvas.SetLeft(playhead, frame.PlayheadLeft); Canvas.SetTop(playhead, TrackTop - 1);
        Canvas.SetLeft(head, frame.HeadLeft); Canvas.SetTop(head, TrackTop - 7);
        slider.Refresh();
    }
    private static PathGeometry Geometry(IEnumerable<TimelineMark> marks, bool lines, bool rounded = false)
    {
        var geometry = new PathGeometry();
        foreach (var mark in marks)
        {
            var figure = new PathFigure { StartPoint = new(mark.X, mark.Y), IsClosed = !lines, IsFilled = !lines };
            if (lines) figure.Segments.Add(new LineSegment { Point = new(mark.X + mark.Width, mark.Y + mark.Height) });
            else if (rounded)
            {
                var radius = Math.Min(4, Math.Min(mark.Width, mark.Height) / 2);
                figure.StartPoint = new(mark.X + radius, mark.Y);
                void Line(double horizontal, double vertical) => figure.Segments.Add(new LineSegment { Point = new(horizontal, vertical) });
                void Arc(double horizontal, double vertical) => figure.Segments.Add(new ArcSegment { Point = new(horizontal, vertical), Size = new(radius, radius), SweepDirection = SweepDirection.Clockwise });
                Line(mark.X + mark.Width - radius, mark.Y); Arc(mark.X + mark.Width, mark.Y + radius);
                Line(mark.X + mark.Width, mark.Y + mark.Height - radius); Arc(mark.X + mark.Width - radius, mark.Y + mark.Height);
                Line(mark.X + radius, mark.Y + mark.Height); Arc(mark.X, mark.Y + mark.Height - radius);
                Line(mark.X, mark.Y + radius); Arc(mark.X + radius, mark.Y);
            }
            else
            {
                figure.Segments.Add(new LineSegment { Point = new(mark.X + mark.Width, mark.Y) });
                figure.Segments.Add(new LineSegment { Point = new(mark.X + mark.Width, mark.Y + mark.Height) });
                figure.Segments.Add(new LineSegment { Point = new(mark.X, mark.Y + mark.Height) });
            }
            geometry.Figures.Add(figure);
        }
        return geometry;
    }
#if DEBUG
    internal static Canvas CutPattern(double width, bool pause, SolidColorBrush stroke)
    {
        var hatch = new Canvas { Width = width, Height = TrackHeight, Clip = new RectangleGeometry { Rect = new(0, 0, width, TrackHeight) } };
        var area = new TimelineMark(0, 0, width, TrackHeight);
        hatch.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = Geometry([area], false), Fill = stroke, Opacity = TimelineLayout.CutOpacity(pause) });
        hatch.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = Geometry(TimelineScene.HatchMarks(area, TimelineLayout.HatchPeriod(pause)), true), Stroke = stroke, StrokeThickness = 2 });
        return hatch;
    }
#endif
}
