using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using VoxClip.App.ViewModels;
using VoxClip.App.Services;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using Windows.Foundation;
using Windows.System;

namespace VoxClip.App.Controls;

public sealed class TimelineView : UserControl
{
    private const double TrackTop = TimelineLayout.TrackTop;
    private const double TrackHeight = 30;
    private readonly Canvas canvas = new() { IsHitTestVisible = false, HighContrastAdjustment = ElementHighContrastAdjustment.None };
    private readonly Canvas geometryBand = new() { Height = 60, IsHitTestVisible = false };
    private readonly CompositeTransform viewportTransform = new();
    private readonly CompositeTransform bracketTransform = new();
    private readonly TranslateTransform playheadTransform = new();
    private readonly TranslateTransform headTransform = new();
    private readonly Rectangle leftDim = new() { Height = TrackHeight };
    private readonly Rectangle rightDim = new() { Height = TrackHeight };
    private readonly TimelineScene scene = new();
    private readonly TimelineRetainedPool<FrameworkElement> retained;
    private TimelineWindow rendered = new(0, 1);
    private readonly Canvas handles = new();
    private readonly Grid track = new() { VerticalAlignment = VerticalAlignment.Top };
    private readonly TimelineRangeControl slider = new("Playhead") { Height = TrackHeight, Margin = new Thickness(0, TrackTop, 0, 0), VerticalAlignment = VerticalAlignment.Top };
    private readonly TimelineRangeControl startHandle = new("Clip start") { Width = 32, Height = 32, Visibility = Visibility.Collapsed };
    private readonly TimelineRangeControl endHandle = new("Clip end") { Width = 32, Height = 32, Visibility = Visibility.Collapsed };
    private readonly Rectangle playhead = new() { Width = 2, Height = TrackHeight + 2, IsHitTestVisible = false };
    private readonly Polygon head = new() { Points = [new(0, 0), new(10.5, 0), new(10.5, 5.3), new(5.25, 10.6), new(0, 5.3)], IsHitTestVisible = false };
    private readonly StackPanel transport = new() { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    private readonly SymbolIcon playGlyph = new(Symbol.Play);
    private readonly Button play;
    private readonly TextBlock time = new() { FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    private readonly Run clockPrefix = new();
    private readonly Run elapsed = new();
    private readonly Run clockFrames = new();
    private readonly Run sourceElapsed = new();
    private readonly Run sourceFrames = new();
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
    private bool scrubbing;
    private bool trimming;
    private bool trimStart;
    private string? trimId;
    private int trimFirst;
    private int trimLast;
    private string? hoverWord;
    public event EventHandler<double>? SeekRequested;
    public event EventHandler? PlayRequested;
    private bool edited = true;
    private bool Edited => edited;
    private double frameWidth;
    private string transportLength = "";
    private bool? transportPlaying;
    private readonly Canvas headers = new() { Width = TimelineLayout.HeaderWidth, IsHitTestVisible = false };
    private readonly Canvas filmstrip = new() { IsHitTestVisible = false };
    private readonly Canvas captions = new() { IsHitTestVisible = false };
    private readonly Canvas rulerLabels = new() { IsHitTestVisible = false };
    private readonly Canvas laneDrawing = new() { IsHitTestVisible = false };
    private readonly CompositeTransform laneTransform = new();
    private readonly CompositeTransform audioTransform = new();
    private readonly CompositeTransform videoTransform = new();
    private readonly Canvas audioDrawing = new() { IsHitTestVisible = false };
    private readonly Canvas videoDrawing = new() { IsHitTestVisible = false };
    private readonly Microsoft.UI.Xaml.Shapes.Path[] mediaPaths = Enumerable.Range(0, 10).Select(_ => new Microsoft.UI.Xaml.Shapes.Path()).ToArray();
    private readonly Image[] thumbnails = Enumerable.Range(0, TimelineFilmstrip.Limit).Select(_ => new Image { Stretch = Stretch.UniformToFill }).ToArray();
    private readonly Thumbnails.FrameLease?[] thumbnailLeases = new Thumbnails.FrameLease?[TimelineFilmstrip.Limit];
    private readonly string?[] thumbnailKeys = new string?[TimelineFilmstrip.Limit];
    private readonly TimelineThumbnailSlot[] thumbnailSlots = new TimelineThumbnailSlot[TimelineFilmstrip.Limit];
    private readonly TextBlock[] ticks = Enumerable.Range(0, 20).Select(_ => new TextBlock { FontSize = 10 }).ToArray();
    private readonly Border[] cueBlocks = Enumerable.Range(0, 16).Select(_ => new Border { CornerRadius = new(2), Child = new TextBlock { FontSize = 11, Margin = new(4, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center } }).ToArray();
    private readonly Microsoft.UI.Xaml.Shapes.Path cueCuts = new();
    private readonly Rectangle selectionBar = new() { Height = 3 };
    private readonly Rectangle overviewWindow = new() { Height = 20, StrokeThickness = 1 };
    private readonly Rectangle overviewHead = new() { Width = 1.5, Height = 20 };
    private readonly Microsoft.UI.Xaml.Shapes.Path overviewClips = new();
    private readonly Microsoft.UI.Xaml.Shapes.Path overviewActive = new();
    private readonly Microsoft.UI.Xaml.Shapes.Path overviewSuggestions = new() { StrokeThickness = 1, StrokeDashArray = [3, 2] };
    private readonly Microsoft.UI.Xaml.Shapes.Path rulerTicks = new() { StrokeThickness = 1 };
    private readonly Microsoft.UI.Xaml.Shapes.Path trimBrackets = new() { StrokeThickness = 1.5 };
    private readonly TimelineRangeControl overview = new("Visible timeline window") { Height = TimelineLayout.OverviewHeight, VerticalAlignment = VerticalAlignment.Top };
    private readonly Slider zoom = new() { Minimum = 0, Maximum = 100, Width = 72, Height = 32, VerticalAlignment = VerticalAlignment.Center };
    private readonly ComboBox heightPicker = new() { Width = 58, Height = 32, MinHeight = 32, Padding = new(4, 0, 4, 0) };
    private readonly ToggleButton snapping = new() { Content = "Snap", IsChecked = true, MinWidth = 40, Height = 32, Padding = new(4, 0, 4, 0) };
    private readonly Button hide = new() { Content = "−", Width = 32, Height = 32, Padding = new(0), Visibility = Visibility.Collapsed };
    private readonly Button maximize = new() { Content = "↕", Width = 32, Height = 32, Padding = new(0), Visibility = Visibility.Collapsed };
    private readonly TextBlock sourceClock = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock selectionLength = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock stateMessage = new() { FontSize = 11, Margin = new(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
    private readonly TextBlock fxHint = new() { Text = "Director results land here", FontSize = 11, IsHitTestVisible = false };
    private readonly TextBlock videoName = new() { FontSize = 9, IsHitTestVisible = false, TextTrimming = TextTrimming.CharacterEllipsis };
    private TimelineTrackGeometry metrics = TimelineLayout.Tracks(1, true, true, true);
    private TimelineWaveform? envelope;
    private CancellationTokenSource? waveformRequest;
    private CancellationTokenSource? filmstripRequest;
    private Project? trimSnapshot;
    private IReadOnlyList<TimelineCaptions.Page> captionPages = [];
    private IReadOnlyList<TimelineCue> captionCues = [];
    private Project? captionSnapshot;
    private Action? hideCommand;
    private Action? maximizeCommand;
    private bool updatingControls;
    private bool selecting;
    private bool disposed;
    private bool renderingBlocked;
    private bool waveformUnavailable;
    private bool overviewDragging;
    private double overviewGrab;
    private readonly TextBlock[] headerNames = Enumerable.Range(0, 4).Select(_ => new TextBlock { FontSize = 11 }).ToArray();
    private readonly TextBlock[] headerIds = Enumerable.Range(0, 4).Select(_ => new TextBlock { FontSize = 10, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }).ToArray();
    private readonly LinkedList<(TimelineMediaTile Tile, TimelineMediaGeometry<PathGeometry> Geometry)> geometryCache = new();
    private readonly Microsoft.UI.Xaml.Shapes.Path cueBackgrounds = new();
    private readonly double[] overviewBadgeLeft = new double[TimelineRetainedPool<object>.Badges];
    private readonly bool[] overviewBadgeVisible = new bool[TimelineRetainedPool<object>.Badges];
    private readonly PathFigure[] bracketFigures = Enumerable.Range(0, 4).Select(_ => new PathFigure()).ToArray();
    private readonly LineSegment[] bracketLines = Enumerable.Range(0, 4).Select(_ => new LineSegment()).ToArray();
    private MediaReference? attachedSource;
    private readonly CancellationTokenSource?[] thumbnailLoading = new CancellationTokenSource?[TimelineFilmstrip.Limit];
    private readonly Microsoft.UI.Xaml.Shapes.Path videoSeams = new();
    private readonly Rectangle scrollThumb = new() { Height = 4, RadiusX = 2, RadiusY = 2 };
    private readonly TimelineRangeControl scrollRange = new("Timeline horizontal scroll") { Height = 32, VerticalAlignment = VerticalAlignment.Bottom };
    private readonly CompositeTransform rulerTransform = new();
    private readonly CompositeTransform captionTransform = new();
    private readonly double[] tickTimes = new double[20];
    private readonly double[] tickOffsets = new double[20];
    private int tickCount;
    private double preferredHeight;
    private string shownClockPrefix = "";
    private string shownElapsed = "";
    private string shownClockFrames = "";
    private string shownSourceElapsed = "";
    private string shownSourceFrames = "";
    public double PreferredPanelHeight => TimelineLayout.ToolbarHeight + metrics.Height;
    public event EventHandler<double>? PreferredPanelHeightChanged;
    public int TrackSize { get => Math.Max(0, heightPicker.SelectedIndex); set => heightPicker.SelectedIndex = Math.Clamp(value, 0, 2); }
    public event EventHandler<int>? TrackSizeChanged;
    public TimeRange VisibleRange => new(view.Start, view.End);
    public void SetVisibleRange(TimeRange value) => ChangeWindow(new(value.Start, value.End));
    public event EventHandler<TimeRange>? VisibleRangeChanged;
    public event EventHandler<bool>? ShowsCutsChanged;
    public bool ShowsCuts
    {
        get => !edited;
        set
        {
            if (edited == !value) return;
            var centre = FromDisplay((view.Start + view.End) / 2);
            edited = !value;
            updatingControls = true; mode.SelectedIndex = edited ? 0 : 1; updatingControls = false;
            var start = ToDisplay(centre) - view.Duration / 2;
            view = TimelineLayout.Clamp(new(start, start + view.Duration), AxisDuration);
            RefreshCues(); Draw(); ShowsCutsChanged?.Invoke(this, value);
        }
    }
    private double AxisDuration => model is null ? 1 : Edited && plan is not null ? plan.Duration : model.Project.Media.Source.DurationSeconds;

    public TimelineView()
    {
        retained = new(CreateRetained);
        geometryBand.RenderTransform = viewportTransform;
        Canvas.SetTop(geometryBand, TrackTop);
        canvas.Children.Add(geometryBand);
        for (var index = 0; index < retained.Nodes.Count; index++)
            if (index < TimelineRetainedPool<object>.Layers) { if (index is 8 or 10) geometryBand.Children.Add(retained.Nodes[index]); }
            else canvas.Children.Add(retained.Nodes[index]);
        retained.Nodes[12].RenderTransform = bracketTransform;
        canvas.Children.Add(leftDim); canvas.Children.Add(rightDim);
        Canvas.SetTop(leftDim, TrackTop); Canvas.SetTop(rightDim, TrackTop);
        canvas.Children.Add(playhead); canvas.Children.Add(head);
        playhead.RenderTransform = playheadTransform;
        head.RenderTransform = headTransform;
        Canvas.SetTop(playhead, TrackTop - 1);
        Canvas.SetTop(head, TrackTop - 7);
        IsTabStop = false;
        var layout = new Grid();
        layout.RowDefinitions.Add(new() { Height = new(TimelineLayout.ToolbarHeight) });
        layout.RowDefinitions.Add(new());
        var toolbar = new Grid { ColumnSpacing = 8, Padding = new(8, 0, 8, 0) };
        toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new());
        toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var title = new TextBlock { Text = "TIMELINE", FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
        toolbar.Children.Add(title);
        mode.Items.Add(new CommunityToolkit.WinUI.Controls.SegmentedItem { Content = "Edited" });
        mode.Items.Add(new CommunityToolkit.WinUI.Controls.SegmentedItem { Content = "Source" });
        mode.SelectedIndex = 0;
        AutomationProperties.SetName(mode, "Timeline time");
        mode.SelectionChanged += (_, _) => { if (!updatingControls) ShowsCuts = mode.SelectedIndex == 1; };
        play = new Button { Width = 32, Height = 32, Padding = new Thickness(0), CornerRadius = new(16), Content = playGlyph };
        AutomationProperties.SetName(play, "Play");
        AutomationProperties.SetAcceleratorKey(play, "Space");
        ToolTipService.SetToolTip(play, "Play (Space)");
        play.Click += (_, _) => PlayRequested?.Invoke(this, EventArgs.Empty);
        time.FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"];
        time.Inlines.Add(clockPrefix); time.Inlines.Add(elapsed); time.Inlines.Add(clockFrames); time.Inlines.Add(total);
        sourceClock.FontFamily = time.FontFamily; sourceClock.Inlines.Add(sourceElapsed); sourceClock.Inlines.Add(sourceFrames);
        var previous = Command("⏮", "Go to In", () => { if (ClipBounds() is { } bounds) Seek(bounds.Start); else Seek(0); });
        var next = Command("⏭", "Go to Out", () => Seek(ClipBounds()?.End ?? model?.Project.Media.Source.DurationSeconds ?? 0));
        transport.Children.Add(previous); transport.Children.Add(play); transport.Children.Add(next); transport.Children.Add(time);
        transport.Children.Add(sourceClock); transport.Children.Add(selectionLength);
        Grid.SetColumn(mode, 1); toolbar.Children.Add(mode);
        Grid.SetColumn(transport, 2); toolbar.Children.Add(transport);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        heightPicker.Items.Add("S"); heightPicker.Items.Add("M"); heightPicker.Items.Add("L"); heightPicker.SelectedIndex = 1;
        heightPicker.SelectionChanged += (_, _) => { Draw(); TrackSizeChanged?.Invoke(this, TrackSize); };
        AutomationProperties.SetName(heightPicker, "Timeline track height");
        AutomationProperties.SetName(snapping, "Snap timeline to words");
        AutomationProperties.SetName(zoom, "Timeline zoom");
        zoom.ValueChanged += (_, _) =>
        {
            if (updatingControls || model is null) return;
            var duration = Math.Max(.001, AxisDuration);
            var length = duration / Math.Pow(Math.Max(1, duration / .1), zoom.Value / 100);
            var anchor = Math.Clamp(view.X(ToDisplay(model.SourceTime), 1), 0, 1);
            ChangeWindow(TimelineLayout.Zoom(view, duration, view.Duration / length, anchor));
        };
        tools.Children.Add(snapping); tools.Children.Add(heightPicker);
        tools.Children.Add(Command("−", "Zoom out", () => ChangeWindow(TimelineLayout.Zoom(view, AxisDuration, 1 / 1.5, .5))));
        tools.Children.Add(zoom);
        tools.Children.Add(Command("+", "Zoom in", () => ChangeWindow(TimelineLayout.Zoom(view, AxisDuration, 1.5, .5))));
        tools.Children.Add(Command("↔", "Show entire timeline", () => ChangeWindow(new(0, Math.Max(.001, AxisDuration)))));
        AutomationProperties.SetName(hide, "Hide timeline (Ctrl+J)");
        AutomationProperties.SetName(maximize, "Maximize timeline");
        hide.Click += (_, _) => hideCommand?.Invoke();
        maximize.Click += (_, _) => maximizeCommand?.Invoke();
        tools.Children.Add(maximize); tools.Children.Add(hide);
        Grid.SetColumn(tools, 3); toolbar.Children.Add(tools);
        layout.Children.Add(toolbar);
        var body = new Grid();
        body.ColumnDefinitions.Add(new() { Width = new(TimelineLayout.HeaderWidth) }); body.ColumnDefinitions.Add(new());
        body.Children.Add(headers);
        Grid.SetColumn(track, 1); body.Children.Add(track);
        Grid.SetRow(body, 1); layout.Children.Add(body);
        laneDrawing.RenderTransform = laneTransform;
        audioDrawing.RenderTransform = audioTransform; videoDrawing.RenderTransform = videoTransform;
        foreach (var path in mediaPaths.Take(8)) audioDrawing.Children.Add(path);
        videoDrawing.Children.Add(mediaPaths[8]); videoDrawing.Children.Add(mediaPaths[9]); videoDrawing.Children.Add(videoSeams);
        laneDrawing.Children.Add(videoDrawing); laneDrawing.Children.Add(filmstrip); laneDrawing.Children.Add(audioDrawing);
        laneDrawing.Children.Add(videoName);
        foreach (var image in thumbnails) filmstrip.Children.Add(image);
        foreach (var label in ticks) { label.FontFamily = time.FontFamily; rulerLabels.Children.Add(label); }
        foreach (var cue in cueBlocks) captions.Children.Add(cue);
        captions.Children.Insert(0, cueBackgrounds); captions.Children.Add(cueCuts);
        canvas.Children.Insert(0, laneDrawing);
        canvas.Children.Add(captions); canvas.Children.Add(overviewClips); canvas.Children.Add(overviewActive); canvas.Children.Add(overviewSuggestions);
        canvas.Children.Add(overviewWindow); canvas.Children.Add(overviewHead);
        canvas.Children.Add(rulerTicks); canvas.Children.Add(rulerLabels); canvas.Children.Add(trimBrackets); canvas.Children.Add(selectionBar); canvas.Children.Add(fxHint); canvas.Children.Add(scrollThumb);
        captions.RenderTransform = captionTransform; rulerTicks.RenderTransform = rulerTransform;
        var bracketGeometry = new PathGeometry();
        for (var index = 0; index < bracketFigures.Length; index++)
        { bracketFigures[index].Segments.Add(bracketLines[index]); bracketGeometry.Figures.Add(bracketFigures[index]); }
        trimBrackets.Data = bracketGeometry;
        canvas.Children.Remove(playhead); canvas.Children.Remove(head);
        canvas.Children.Add(playhead); canvas.Children.Add(head);
        track.Children.Add(canvas); track.Children.Add(slider); track.Children.Add(overview); track.Children.Add(scrollRange); track.Children.Add(handles); track.Children.Add(stateMessage);
        handles.Children.Add(startHandle); handles.Children.Add(endHandle);
        Content = layout;
        for (var index = 0; index < headerNames.Length; index++)
        {
            headerIds[index].FontFamily = time.FontFamily;
            headers.Children.Add(headerNames[index]); headers.Children.Add(headerIds[index]);
            Canvas.SetLeft(headerIds[index], 8); Canvas.SetLeft(headerNames[index], 34);
        }
        overview.Read = () => new(0, Math.Max(0, AxisDuration - view.Duration), view.Start, Math.Min(view.Duration / 10, 1), "Visible timeline window");
        overview.Set = value => ChangeWindow(new(value, value + view.Duration));
        overview.PointerPressed += OverviewPressed;
        overview.PointerMoved += OverviewMoved;
        overview.PointerReleased += (_, args) => { overviewDragging = false; overview.ReleasePointerCapture(args.Pointer); args.Handled = true; };
        overview.PointerCanceled += (_, _) => overviewDragging = false;
        overview.PointerCaptureLost += (_, _) => overviewDragging = false;
        overview.KeyDown += OverviewKeyDown;
        scrollRange.Read = overview.Read; scrollRange.Set = overview.Set;
        scrollRange.PointerPressed += OverviewPressed; scrollRange.PointerMoved += OverviewMoved;
        scrollRange.PointerReleased += (_, args) => { overviewDragging = false; scrollRange.ReleasePointerCapture(args.Pointer); args.Handled = true; };
        scrollRange.PointerCanceled += (_, _) => overviewDragging = false;
        scrollRange.PointerCaptureLost += (_, _) => overviewDragging = false;
        scrollRange.KeyDown += OverviewKeyDown;
        slider.Read = ReadPlayhead;
        slider.Set = value => Seek(FromDisplay(value));
        slider.KeyDown += PlayheadKeyDown;
        slider.PointerPressed += ScrubPressed;
        slider.PointerMoved += ScrubMoved;
        slider.PointerReleased += ScrubReleased;
        slider.PointerCanceled += (_, _) => { scrubbing = selecting = false; };
        slider.PointerCaptureLost += (_, _) => { scrubbing = selecting = false; };
        slider.DoubleTapped += RestoreCut;
        ConfigureTrim(startHandle, true);
        ConfigureTrim(endHandle, false);
        track.SizeChanged += (_, _) => Draw();
        track.PointerWheelChanged += WheelChanged;
        SizeChanged += (_, _) =>
        {
            sourceClock.Visibility = selectionLength.Visibility = ActualWidth >= 1100 ? Visibility.Visible : Visibility.Collapsed;
            heightPicker.Visibility = ActualWidth >= 840 ? Visibility.Visible : Visibility.Collapsed;
        };
        ActualThemeChanged += (_, _) => { ApplyBrushes(); Draw(); };
        animation.Tick += (_, _) =>
        {
            var fraction = Math.Clamp(animationClock.Elapsed.TotalMilliseconds / 240, 0, 1);
            var eased = 1 - Math.Pow(1 - fraction, 3);
            view = new(animationStart.Start + (animationEnd.Start - animationStart.Start) * eased, animationStart.End + (animationEnd.End - animationStart.End) * eased);
            UpdateViewport();
            if (fraction >= 1) { animation.Stop(); Draw(); }
        };
        Loaded += (_, _) => { if (!disposed) { Ui.EffectsChanged -= EffectsChanged; Ui.EffectsChanged += EffectsChanged; Draw(); } };
        Unloaded += (_, _) => { animation.Stop(); CancelTrim(); ClearFilmstrip(); Ui.EffectsChanged -= EffectsChanged; };
        ApplyBrushes();
    }

    private static Button Command(string text, string name, Action action)
    {
        var button = new Button { Content = text, Width = 32, Height = 32, Padding = new(0) };
        AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => action();
        return button;
    }

    public void SetPanelCommands(Action? hideTimeline, Action? maximizeTimeline)
    {
        hideCommand = hideTimeline; maximizeCommand = maximizeTimeline;
        hide.Visibility = hideTimeline is null ? Visibility.Collapsed : Visibility.Visible;
        maximize.Visibility = maximizeTimeline is null ? Visibility.Collapsed : Visibility.Visible;
    }

    internal bool ShowsTransport { set => transport.Visibility = value ? Visibility.Visible : Visibility.Collapsed; }
    internal Control FocusTarget => slider;
#if DEBUG
    internal Control DebugEndHandle => endHandle;
    internal IReadOnlyList<FrameworkElement> DebugDrawingNodes => retained.Nodes;
    internal int DebugBuildVersion => scene.BuildVersion;
    internal int DebugDrawingElementCount => CountDrawing(canvas) + CountDrawing(headers);
    private static int CountDrawing(FrameworkElement element) => element is Panel panel ? 1 + panel.Children.OfType<FrameworkElement>().Sum(CountDrawing)
        : element is Border { Child: FrameworkElement child } ? 1 + CountDrawing(child) : 1;
    internal void DebugMoveViewport(TimelineWindow window) { view = window; UpdateViewport(); }
    internal void DebugFrame(TimelineWindow window, double pointer, double source, bool trim)
    {
        view = window;
        trimming = trim;
        trimId = viewport.ActiveClip?.Id;
        trimStart = true;
        UpdateViewport(pointer, source);
        trimming = false;
    }
    internal void DebugCreateRangePeers()
    {
        AutomationProperties.SetAutomationId(slider, "NativeProbe.Playhead");
        _ = FrameworkElementAutomationPeer.CreatePeerForElement(slider);
        _ = FrameworkElementAutomationPeer.CreatePeerForElement(startHandle);
        _ = FrameworkElementAutomationPeer.CreatePeerForElement(endHandle);
    }
#endif
    internal void SetTransport(string elapsedTime, string length, bool playing)
    {
        if (transportLength != length) { transportLength = length; total.Text = " / " + length; }
        if (transportPlaying == playing) return;
        transportPlaying = playing;
        playGlyph.Symbol = playing ? Symbol.Pause : Symbol.Play;
        AutomationProperties.SetName(play, PlaybackPresentation.Name(playing));
        ToolTipService.SetToolTip(play, PlaybackPresentation.Hint(playing));
    }
    internal void SetWaveform(IReadOnlyList<float> levels) => LoadWaveform(levels, .05);
    public void SetAudioEnvelope(AudioEnvelope? value) => LoadWaveform(value?.Rms ?? [], value?.FrameSeconds ?? .01);
    private async void LoadWaveform(IReadOnlyList<float> levels, double frameSeconds)
    {
        waveformRequest?.Cancel();
        var request = new CancellationTokenSource(); waveformRequest = request;
        var snapshot = model?.Project.Media.Source;
        var samples = levels.ToArray(); envelope = null; waveformUnavailable = false;
        try
        {
            var result = await Task.Run(() => TimelineWaveform.Create(samples, frameSeconds, request.Token), request.Token);
            if (!disposed && !request.IsCancellationRequested && ReferenceEquals(request, waveformRequest) && snapshot == model?.Project.Media.Source)
            { envelope = result; Draw(); }
        }
        catch (OperationCanceledException) { }
        catch (ArgumentException)
        {
            if (!disposed && ReferenceEquals(waveformRequest, request)) { waveformUnavailable = true; Draw(); }
        }
        finally { if (ReferenceEquals(waveformRequest, request)) waveformRequest = null; request.Dispose(); }
    }
    public void SetCaptionTrack(CaptionTrack? value, RenderTimeline mapping, Project expectedProject)
    {
        if (model is null || !ReferenceEquals(model.Project, expectedProject)) return;
        var attached = model;
        captionSnapshot = expectedProject;
        captionPages = value is null ? [] : value.Pages.Select(page =>
        {
            var start = mapping.SourceTime(page.Start); var end = mapping.SourceTime(page.End);
            if (page.Words.Count > 0)
            {
                var first = attached.Index(value.Words[page.Words[0]].Id); var last = attached.Index(value.Words[page.Words[^1]].Id);
                if (first >= 0 && last >= first && last < attached.Words.Count) { start = attached.Words[first].Start; end = attached.Words[last].End; }
            }
            return new TimelineCaptions.Page(new(page.Start, page.End), new(start, end),
                string.Join(" ", page.Words.Select(index => value.Words[index].Text)));
        }).ToArray();
        RefreshCues(); Draw();
    }
    private void RefreshCues()
    {
        var cuts = plan?.Cuts.Select(cut => new TimeRange(cut.StartSample / plan.SampleRate, cut.EndSample / plan.SampleRate)).ToArray() ?? [];
        captionCues = TimelineCaptions.Cues(captionPages, Edited ? TimelineAxis.Edited : TimelineAxis.Source, cuts);
    }
    public void Attach(EditorViewModel value)
    {
        if (model is not null) Detach();
        disposed = false;
        model = value; model.Changed += Changed; model.SelectionChanged += SelectionChanged;
        model.PropertyChanged += PropertyChanged;
        Rebuild(true);
    }
    public void Detach()
    {
        if (model is not null) { model.Changed -= Changed; model.SelectionChanged -= SelectionChanged; model.PropertyChanged -= PropertyChanged; }
        disposed = true; CancelTrim(); ClearFilmstrip(); waveformRequest?.Cancel();
        model = null; plan = null; envelope = null; captionPages = []; captionCues = []; captionSnapshot = null;
        scene.Tiles.Clear(); geometryCache.Clear(); attachedSource = null;
        animation.Stop(); Ui.EffectsChanged -= EffectsChanged;
    }
    private void Changed(object? sender, EventArgs args)
    {
        CancelTrim();
        if (!ReferenceEquals(captionSnapshot, model?.Project)) { captionPages = []; captionCues = []; captionSnapshot = null; }
        Rebuild(false);
    }
    private void SelectionChanged(object? sender, EventArgs args) => Draw();
    private void PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(EditorViewModel.IsReadOnly) or nameof(EditorViewModel.Busy)) { CancelTrim(); Draw(); }
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
        clockPrefix.Foreground = Brush("VcTextTertiaryBrush");
        playhead.Fill = head.Fill = Brush("VcTintDefaultBrush");
        sourceClock.Foreground = selectionLength.Foreground = Brush("VcTextSecondaryBrush");
        fxHint.Foreground = stateMessage.Foreground = videoName.Foreground = Brush("VcTextTertiaryBrush");
        foreach (var handle in new[] { startHandle, endHandle })
        {
            var clear = ((SolidColorBrush)Brush("VcTimelineTrackBrush")).Color; clear.A = 0;
            var hit = new Grid { Background = new SolidColorBrush(clear) };
            hit.Children.Add(new Border { Width = 2, Height = 22, Background = Brush("VcTimelineClipBracketBrush"), HorizontalAlignment = HorizontalAlignment.Center });
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
        if (attachedSource != model.Project.Media.Source)
        {
            waveformRequest?.Cancel(); envelope = null; waveformUnavailable = false; ClearFilmstrip();
            attachedSource = model.Project.Media.Source; scene.Tiles.Clear(); geometryCache.Clear();
        }
        renderingBlocked = false;
        try { model.RequireLegacyRendering(model.State is { } state ? state with { ActiveClipId = null } : null); }
        catch (VoiceLabProjectException) { renderingBlocked = true; }
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
        else if (changedScope || forceZoom || scene.BuildVersion == 0) view = next;
        else view = TimelineLayout.Clamp(view, AxisDuration);
        RefreshCues();
        Draw();
    }
    public void Position(double source)
    {
        if (model is null || plan is null || !double.IsFinite(source)) return;
        frame.ComputePlayhead(viewport, plan, view, frameWidth, source, Edited);
        MovePlayhead();
    }

    private TimelineRange ReadPlayhead()
    {
        return plan is null ? new(0, 1, 0, 0.1, "") : frame.Playhead;
    }
    private void Seek(double source)
    {
        if (model is null || renderingBlocked || model.IsReadOnly || !double.IsFinite(source)) return;
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
        else if (args.Key == VirtualKey.Space) { if (play.IsEnabled) PlayRequested?.Invoke(this, EventArgs.Empty); args.Handled = true; }
        else if (args.Key is VirtualKey.Add or VirtualKey.Subtract)
        { ChangeWindow(TimelineLayout.Zoom(view, AxisDuration, args.Key == VirtualKey.Add ? 1.5 : 1 / 1.5, .5)); args.Handled = true; }
        else if (args.Key is VirtualKey.PageUp or VirtualKey.PageDown)
        {
            var delta = view.Duration * (args.Key == VirtualKey.PageDown ? .8 : -.8);
            ChangeWindow(new(view.Start + delta, view.End + delta)); args.Handled = true;
        }
    }
    private double PointerTime(PointerRoutedEventArgs args) => FromDisplay(view.Time(args.GetCurrentPoint(track).Position.X, track.ActualWidth));
    private void ScrubPressed(object sender, PointerRoutedEventArgs args)
    {
        if (!args.GetCurrentPoint(slider).Properties.IsLeftButtonPressed) return;
        if (model is null || renderingBlocked || model.IsReadOnly) return;
        scrubbing = true; selecting = InputState.Down(VirtualKey.Control);
        slider.Focus(FocusState.Pointer); slider.CapturePointer(args.Pointer);
        if (selecting && model.Words.Count > 0) model.Select(TimelineLayout.WordAt(model.Words, PointerTime(args)));
        Scrub(args); args.Handled = true;
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
        if ((snapping.IsChecked == true || InputState.Down(VirtualKey.Shift)) && model is { Words.Count: > 0 }) source = model.Words[TimelineLayout.WordAt(model.Words, source)].Start;
        if (selecting && model is { Words.Count: > 0 }) model.Select(TimelineLayout.WordAt(model.Words, source), true);
        Seek(source);
    }
    private void ScrubReleased(object sender, PointerRoutedEventArgs args)
    {
        if (!scrubbing) return;
        Scrub(args); scrubbing = selecting = false; slider.ReleasePointerCapture(args.Pointer); args.Handled = true;
    }
    private void RestoreCut(object sender, DoubleTappedRoutedEventArgs args)
    {
        if (Edited || model?.State is not { } state || model.IsReadOnly || model.Busy) return;
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
            if (args.Key == VirtualKey.Escape && trimming) { CancelTrim(); Draw(); args.Handled = true; return; }
            if (args.Key is VirtualKey.Home or VirtualKey.End)
            {
                var range = ReadTrim(start);
                ChangeTrim(start, (int)(args.Key == VirtualKey.Home ? range.Minimum : range.Maximum)); args.Handled = true; return;
            }
            if (args.Key is not (VirtualKey.Left or VirtualKey.Right)) return;
            ChangeTrim(start, (int)ReadTrim(start).Value + (args.Key == VirtualKey.Right ? 1 : -1)); args.Handled = true;
        };
        handle.PointerPressed += (_, args) =>
        {
            if (model?.State?.ActiveClipId is not { } id || model.IsReadOnly || model.Busy || renderingBlocked || !args.GetCurrentPoint(handle).Properties.IsLeftButtonPressed) return;
            var clip = model.Clips.First(clip => clip.Id == id);
            trimId = id; trimFirst = model.Index(clip.Clip.StartWordId); trimLast = model.Index(clip.Clip.EndWordId);
            trimSnapshot = model.Project; trimming = true; trimStart = start; animation.Stop();
            handle.Focus(FocusState.Pointer); handle.CapturePointer(args.Pointer); args.Handled = true;
        };
        handle.PointerMoved += (_, args) =>
        {
            if (!trimming || trimStart != start || model is null || !ReferenceEquals(trimSnapshot, model.Project)) return;
            UpdateViewport(args.GetCurrentPoint(track).Position.X); args.Handled = true;
        };
        handle.PointerReleased += (_, args) =>
        {
            if (!trimming || trimStart != start) return;
            if (model is null || !ReferenceEquals(trimSnapshot, model.Project)) { CancelTrim(); Draw(); return; }
            UpdateViewport(args.GetCurrentPoint(track).Position.X);
            var id = trimId; var first = trimFirst; var last = trimLast;
            CancelTrim();
            if (id is not null) TimelineLayout.CommitTrim(model, id, first, last);
            Draw(); args.Handled = true;
        };
        handle.PointerCanceled += (_, _) => { CancelTrim(); Draw(); };
        handle.PointerCaptureLost += (_, _) => { if (trimming) { CancelTrim(); Draw(); } };
    }
    private TimelineRange ReadTrim(bool start)
    {
        return start ? frame.Start : frame.End;
    }
    private void ChangeTrim(bool start, int target)
    {
        if (model is null || model.IsReadOnly || model.Busy || renderingBlocked) return;
        if (model?.State?.ActiveClipId is not { } id || model.Clips.FirstOrDefault(clip => clip.Id == id) is not { } clip) return;
        var first = model.Index(clip.Clip.StartWordId); var last = model.Index(clip.Clip.EndWordId);
        (first, last) = TimelineLayout.Trim(first, last, target, model.Words.Count, start);
        TimelineLayout.CommitTrim(model, id, first, last);
    }
    private void CancelTrim()
    {
        trimming = false; trimSnapshot = null; trimId = null;
        startHandle.ReleasePointerCaptures(); endHandle.ReleasePointerCaptures();
    }

    private void Draw()
    {
        var width = track.ActualWidth;
        if (model is null || width <= 0 || plan is null) return;
        metrics = TimelineLayout.Tracks(heightPicker.SelectedIndex, model.Project.Media.Source.Video is not null, true, true);
        track.Height = canvas.Height = handles.Height = metrics.Height;
        MinHeight = PreferredPanelHeight;
        var heightChanged = preferredHeight != PreferredPanelHeight;
        preferredHeight = PreferredPanelHeight;
        // WinUI geometry is single-owner, including identical clips on separate layers.
        canvas.Clip = new RectangleGeometry { Rect = new(0, 0, width, metrics.Height) };
        handles.Clip = new RectangleGeometry { Rect = new(0, 0, width, metrics.Height) };
        canvas.Background = Brush("VcTimelineLaneBrush");
        leftDim.Fill = rightDim.Fill = Brush("VcTimelineScopeDimBrush");
        leftDim.Height = rightDim.Height = metrics.EffectsTop + metrics.EffectsHeight - metrics.VideoTop;
        Canvas.SetTop(leftDim, metrics.VideoTop); Canvas.SetTop(rightDim, metrics.VideoTop);
        slider.Margin = new(0, TimelineLayout.OverviewHeight, 0, 0);
        slider.Height = metrics.Height - TimelineLayout.OverviewHeight;
        playhead.Height = metrics.EffectsTop + metrics.EffectsHeight - TimelineLayout.OverviewHeight - 11;
        Canvas.SetTop(playhead, TimelineLayout.OverviewHeight + 11); Canvas.SetTop(head, TimelineLayout.OverviewHeight + 11);
        geometryBand.Height = 30; Canvas.SetTop(geometryBand, metrics.VideoTop);
        viewportTransform.ScaleY = (metrics.EffectsTop + metrics.EffectsHeight - metrics.VideoTop) / 30;
        Canvas.SetTop(audioDrawing, metrics.AudioTop); audioTransform.ScaleY = metrics.AudioHeight / 30;
        Canvas.SetTop(videoDrawing, metrics.VideoTop); videoTransform.ScaleY = metrics.VideoHeight / 30;
        videoDrawing.Visibility = filmstrip.Visibility = videoName.Visibility = metrics.VideoHeight > 0 ? Visibility.Visible : Visibility.Collapsed;
        Canvas.SetTop(filmstrip, metrics.VideoTop + 11); filmstrip.Height = Math.Max(0, metrics.VideoHeight - 11);
        Canvas.SetTop(videoName, metrics.VideoTop); Canvas.SetLeft(videoName, 4); videoName.Width = Math.Max(0, width - 8);
        videoName.Text = System.IO.Path.GetFileNameWithoutExtension(model.Project.Media.Source.AbsolutePath);
        Canvas.SetTop(fxHint, metrics.EffectsTop + 4); Canvas.SetLeft(fxHint, 6);
        play.IsEnabled = slider.IsEnabled = !renderingBlocked && !model.IsReadOnly;
        foreach (var button in transport.Children.OfType<Button>()) button.IsEnabled = play.IsEnabled;
        stateMessage.Text = renderingBlocked ? "Timeline preview isn't available for this edit. Your media and edits are safe." : model.IsReadOnly ? "Relink the source to preview this take."
            : waveformUnavailable ? "Waveform unavailable. Your media and edits are safe." : "";
        stateMessage.Visibility = stateMessage.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        laneDrawing.Visibility = renderingBlocked || model.IsReadOnly ? Visibility.Collapsed : Visibility.Visible;
        rendered = animation.IsEnabled ? new(Math.Min(view.Start, animationEnd.Start), Math.Max(view.End, animationEnd.End)) : view;
        scene.Build(model, plan, rendered, [], width, Edited);
        var tile = scene.Tiles.Get(plan, envelope, rendered, width, Edited);
        var data = MediaGeometry(tile);
        var namedPiece = tile.Video.FirstOrDefault(piece => piece.Width >= 60);
        videoName.Visibility = namedPiece.Width >= 60 && metrics.VideoHeight > 0 ? Visibility.Visible : Visibility.Collapsed;
        Canvas.SetLeft(videoName, namedPiece.X + 4); videoName.Width = Math.Max(0, namedPiece.Width - 8);
        for (var index = 0; index < mediaPaths.Length; index++) mediaPaths[index].Data = data.Paths[index];
        mediaPaths[0].Fill = Brush("VcTimelineAudioPieceBrush");
        mediaPaths[1].Fill = mediaPaths[2].Fill = Brush("VcTimelineWaveBrush"); mediaPaths[1].Opacity = .62;
        mediaPaths[3].Fill = mediaPaths[4].Fill = Brush("VcTimelineGhostWaveBrush");
        mediaPaths[5].Stroke = Brush("VcTimelineCutOutlineBrush"); mediaPaths[5].StrokeThickness = 1; mediaPaths[5].StrokeDashArray = [3, 3];
        mediaPaths[6].Fill = Brush("VcTimelineSeamBrush");
        mediaPaths[7].Stroke = mediaPaths[9].Stroke = Brush("VcTimelinePieceBrush"); mediaPaths[7].StrokeThickness = mediaPaths[9].StrokeThickness = 1;
        mediaPaths[8].Fill = Brush("VcTimelineVideoPieceBrush");
        videoSeams.Data = data.VideoSeams; videoSeams.Fill = Brush("VcTimelineSeamBrush");
        scrollThumb.Fill = Brush("VcTimelineScrollerBrush"); Canvas.SetTop(scrollThumb, metrics.Height - 6);
        scrollRange.Visibility = scrollThumb.Visibility = view.Duration + .001 < AxisDuration ? Visibility.Visible : Visibility.Collapsed;
        for (var index = 0; index < scene.Layers.Length; index++)
        {
            var path = (Microsoft.UI.Xaml.Shapes.Path)retained.Nodes[index];
            path.Visibility = index is 8 or 10 ? Visibility.Visible : Visibility.Collapsed;
            if (index is not (8 or 10)) continue;
            path.Data = Geometry(scene.Layers[index], false);
            path.Fill = Brush(index == 8 ? "VcTintDefaultBrush" : "VcAiTintBrush");
            path.Opacity = index == 8 ? .07 : .1;
        }
        DrawHeaders(); DrawOverview(width); DrawRuler(width); DrawCaptions(width);
        selectionLength.Text = model.HasSelection ? string.Create(System.Globalization.CultureInfo.InvariantCulture,
            $"{Math.Max(0, ToDisplay(model.Words[model.SelectionEnd].End) - ToDisplay(model.Words[model.SelectionStart].Start)):0.0} s selected") : "";
        updatingControls = true;
        zoom.Value = AxisDuration > .1 ? Math.Clamp(Math.Log(Math.Max(1, AxisDuration / view.Duration)) / Math.Log(AxisDuration / .1) * 100, 0, 100) : 0;
        updatingControls = false;
        if (!renderingBlocked && !model.IsReadOnly && metrics.VideoHeight > 0 && IsLoaded) RequestFilmstrip(tile, width);
        else ClearFilmstrip();
        UpdateViewport();
        if (heightChanged) PreferredPanelHeightChanged?.Invoke(this, preferredHeight);
    }
    private TimelineMediaGeometry<PathGeometry> MediaGeometry(TimelineMediaTile tile)
    {
        for (var node = geometryCache.First; node is not null; node = node.Next)
            if (ReferenceEquals(node.Value.Tile, tile))
            {
                var result = node.Value.Geometry; geometryCache.Remove(node); geometryCache.AddFirst(node); return result;
            }
        var data = new TimelineMediaGeometry<PathGeometry>(tile, (marks, rounded) => Geometry(marks, false, rounded));
        geometryCache.AddFirst((tile, data));
        if (geometryCache.Count > TimelineTileCache.Capacity) geometryCache.RemoveLast();
        return data;
    }
    private void DrawHeaders()
    {
        string[] ids = ["V1", "A1", "CC", "FX"];
        string[] names = ["Video", model?.Project.Media.Source.Audio is null ? "No audio" : "Voice", model?.Project.Captions.StyleId == "off" ? "Captions off" : "Captions", "Motion"];
        double[] tops = [metrics.VideoTop, metrics.AudioTop, metrics.CaptionTop, metrics.EffectsTop];
        for (var index = 0; index < 4; index++)
        {
            headerIds[index].Text = ids[index]; headerNames[index].Text = names[index];
            Canvas.SetTop(headerIds[index], tops[index] + 4); Canvas.SetTop(headerNames[index], tops[index] + 4);
            headerIds[index].Foreground = Brush("VcTextSecondaryBrush"); headerNames[index].Foreground = Brush("VcTextTertiaryBrush");
            headerIds[index].Visibility = headerNames[index].Visibility = index == 0 && metrics.VideoHeight == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
    }
    private void DrawOverview(double width)
    {
        if (model is null) return;
        var duration = Math.Max(.001, AxisDuration);
        var all = new List<TimelineMark>(); var active = new List<TimelineMark>(); var suggested = new List<TimelineMark>();
        double[] rowEnds = [0, 0];
        var badgeIndex = 0;
        Array.Clear(overviewBadgeVisible);
        foreach (var clip in model.Clips)
        {
            var first = model.Index(clip.Clip.StartWordId); var last = model.Index(clip.Clip.EndWordId);
            if (first < 0 || last < first || last >= model.Words.Count) continue;
            var left = Math.Clamp(ToDisplay(model.Words[first].Start) / duration * width, 0, width);
            var right = Math.Clamp(ToDisplay(model.Words[last].End) / duration * width, 0, width);
            if (right <= left) continue;
            var row = left >= rowEnds[0] ? 0 : 1;
            rowEnds[row] = Math.Max(rowEnds[row], right);
            var mark = new TimelineMark(left, 3 + row * 9, right - left, 8);
            (clip.IsSuggested ? suggested : clip.Id == model.State?.ActiveClipId ? active : all).Add(mark);
            if (right - left < 18 || badgeIndex >= TimelineRetainedPool<object>.Badges) continue;
            var badge = (Grid)retained.Nodes[TimelineRetainedPool<object>.Layers + badgeIndex];
            ((Rectangle)badge.Children[0]).Fill = null;
            var label = (TextBlock)badge.Children[1];
            label.Text = clip.Number.ToString(System.Globalization.CultureInfo.InvariantCulture);
            label.Foreground = Brush("VcTimelineClipBracketBrush"); label.FontSize = 9;
            badge.Height = 9; Canvas.SetTop(badge, mark.Y - 1); Canvas.SetLeft(badge, left);
            overviewBadgeLeft[badgeIndex] = left; overviewBadgeVisible[badgeIndex++] = true;
        }
        overviewClips.Data = Geometry(all, false); overviewActive.Data = Geometry(active, false); overviewSuggestions.Data = Geometry(suggested, false);
        overviewClips.Fill = overviewActive.Fill = overviewSuggestions.Stroke = Brush("VcTimelineClipBracketBrush");
        overviewClips.Opacity = .24; overviewActive.Opacity = .42;
        overviewWindow.Stroke = Brush("VcTextSecondaryBrush"); Canvas.SetTop(overviewWindow, 2);
        overviewHead.Fill = Brush("VcTintDefaultBrush"); Canvas.SetTop(overviewHead, 2);
        overview.Refresh();
    }
    private void DrawRuler(double width)
    {
        if (model is null) return;
        var marks = new List<TimelineMark>();
        var bounds = ClipBounds();
        double[] brackets = bounds is { } range ? [view.X(ToDisplay(range.Start), width), view.X(ToDisplay(range.End), width)] : [];
        var count = 0;
        var origin = Edited && bounds is { } clip ? ToDisplay(clip.Start) : 0;
        foreach (var tick in TimelineRuler.Ticks(new(rendered.Start - origin, rendered.End - origin), width / rendered.Duration))
        {
            var horizontal = rendered.X(tick.Time + origin, width);
            marks.Add(new(horizontal, TimelineLayout.OverviewHeight + (tick.Major ? 0 : 16), 0, tick.Major ? 22 : 6));
            if (!tick.Major || tick.Time < 0 || count >= ticks.Length) continue;
            var label = ticks[count];
            label.Text = EditorViewModel.Timecode(tick.Time); label.Foreground = Brush("VcTimelineRulerLabelBrush");
            label.Measure(new(double.PositiveInfinity, double.PositiveInfinity));
            if (TimelineRuler.LabelX(horizontal, label.DesiredSize.Width, brackets, brackets.Length > 0 ? brackets[0] : null, width) is not { } left) continue;
            label.Visibility = Visibility.Visible; Canvas.SetLeft(label, left); Canvas.SetTop(label, TimelineLayout.OverviewHeight - 2);
            tickTimes[count] = tick.Time + origin; tickOffsets[count] = left - horizontal; count++;
        }
        for (var index = count; index < ticks.Length; index++) ticks[index].Visibility = Visibility.Collapsed;
        tickCount = count;
        rulerTicks.Data = Geometry(marks, true); rulerTicks.Stroke = Brush("VcTimelineTickBrush");
        trimBrackets.Stroke = Brush("VcTimelineClipBracketBrush");
        selectionBar.Fill = Brush("VcTintDefaultBrush");
        Canvas.SetTop(selectionBar, TimelineLayout.OverviewHeight + TimelineLayout.RulerHeight - 3);
        if (model.HasSelection)
        {
            var left = Math.Clamp(view.X(ToDisplay(model.Words[model.SelectionStart].Start), width), 0, width);
            var right = Math.Clamp(view.X(ToDisplay(model.Words[model.SelectionEnd].End), width), 0, width);
            Canvas.SetLeft(selectionBar, left); selectionBar.Width = Math.Max(0, right - left);
        }
        else selectionBar.Width = 0;
    }
    private void DrawCaptions(double width)
    {
        var blocks = new List<TimelineMark>(); var cuts = new List<TimelineMark>();
        var indices = TimelineCaptions.Indices(captionCues, new(rendered.Start, rendered.End));
        var labelIndex = 0; var previousPixel = -1;
        var visible = model?.Project.Captions.StyleId != "off" && !renderingBlocked;
        for (var index = indices.Start.Value; visible && index < indices.End.Value; index++)
        {
            var cue = captionCues[index];
            var left = Math.Clamp(rendered.X(cue.Range.Start, width), 0, width);
            var right = Math.Clamp(rendered.X(cue.Range.End, width), 0, width);
            if (right <= left || (int)left == previousPixel) continue;
            previousPixel = (int)left;
            var span = Math.Max(1, right - left - 1);
            blocks.Add(new(left, metrics.CaptionTop + 2, span, metrics.CaptionHeight - 4));
            foreach (var cut in cue.Cuts)
            {
                var cutLeft = Math.Clamp(rendered.X(cut.Start, width), left, right);
                var cutRight = Math.Clamp(rendered.X(cut.End, width), cutLeft, right);
                cuts.Add(new(cutLeft, metrics.CaptionTop + 2, cutRight - cutLeft, metrics.CaptionHeight - 4));
            }
            if (span < 24 || labelIndex >= cueBlocks.Length) continue;
            var block = cueBlocks[labelIndex++];
            var text = (TextBlock)block.Child;
            double Measure(string candidate) { text.Text = candidate; text.Measure(new(double.PositiveInfinity, double.PositiveInfinity)); return text.DesiredSize.Width; }
            text.Text = TimelineLayout.FitWords(cue.Text, span, Measure);
            text.Foreground = Brush("VcTimelineCueTextBrush");
            block.Visibility = Visibility.Visible; block.Width = span; block.Height = metrics.CaptionHeight - 4;
            Canvas.SetLeft(block, left); Canvas.SetTop(block, metrics.CaptionTop + 2);
        }
        for (var index = labelIndex; index < cueBlocks.Length; index++) cueBlocks[index].Visibility = Visibility.Collapsed;
        cueBackgrounds.Data = Geometry(blocks, false, true); cueBackgrounds.Fill = Brush("VcTimelineCueBrush");
        cueCuts.Data = Geometry(cuts, false); cueCuts.Fill = Brush("VcTimelineLaneBrush"); cueCuts.Opacity = .42;
    }
    private void ChangeWindow(TimelineWindow next)
    {
        animation.Stop(); CancelTrim();
        view = TimelineLayout.Clamp(next, AxisDuration); Draw(); VisibleRangeChanged?.Invoke(this, VisibleRange);
    }
    private void WheelChanged(object sender, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(track);
        var delta = point.Properties.MouseWheelDelta;
        if (InputState.Down(VirtualKey.Control))
            ChangeWindow(TimelineLayout.Zoom(view, AxisDuration, Math.Pow(1.2, delta / 120.0), Math.Clamp(point.Position.X / Math.Max(1, track.ActualWidth), 0, 1)));
        else
        {
            var offset = -delta / 120.0 * view.Duration * .1;
            ChangeWindow(new(view.Start + offset, view.End + offset));
        }
        args.Handled = true;
    }
    private void OverviewPressed(object sender, PointerRoutedEventArgs args)
    {
        if (!args.GetCurrentPoint(overview).Properties.IsLeftButtonPressed) return;
        var time = Math.Clamp(args.GetCurrentPoint(track).Position.X / Math.Max(1, track.ActualWidth), 0, 1) * AxisDuration;
        overviewGrab = time >= view.Start && time <= view.End ? time - view.Start : view.Duration / 2;
        var target = (TimelineRangeControl)sender;
        overviewDragging = true; target.Focus(FocusState.Pointer); target.CapturePointer(args.Pointer);
        ChangeWindow(new(time - overviewGrab, time - overviewGrab + view.Duration)); args.Handled = true;
    }
    private void OverviewMoved(object sender, PointerRoutedEventArgs args)
    {
        if (!overviewDragging) return;
        var time = Math.Clamp(args.GetCurrentPoint(track).Position.X / Math.Max(1, track.ActualWidth), 0, 1) * AxisDuration;
        ChangeWindow(new(time - overviewGrab, time - overviewGrab + view.Duration)); args.Handled = true;
    }
    private void OverviewKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key is not (VirtualKey.Left or VirtualKey.Right or VirtualKey.Home or VirtualKey.End)) return;
        var start = args.Key switch { VirtualKey.Home => 0, VirtualKey.End => AxisDuration - view.Duration, VirtualKey.Left => view.Start - view.Duration / 10, _ => view.Start + view.Duration / 10 };
        ChangeWindow(new(start, start + view.Duration)); args.Handled = true;
    }
    private async void RequestFilmstrip(TimelineMediaTile tile, double width)
    {
        if (model is null) return;
        var source = model.Project.Media.Source;
        var service = App.Services.Thumbnails;
        var count = TimelineFilmstrip.Fill(thumbnailSlots, tile.Pieces, rendered, width, Edited ? TimelineAxis.Edited : TimelineAxis.Source);
        var changed = false;
        for (var index = 0; index < thumbnails.Length; index++)
        {
            var key = index < count ? service.TimelinePathFor(source.ContentKey, thumbnailSlots[index].SourceTime, source.Video?.RotationDegrees ?? 0) : null;
            if (thumbnailKeys[index] != key) changed = true;
        }
        if (changed || filmstripRequest is null) { filmstripRequest?.Cancel(); filmstripRequest?.Dispose(); filmstripRequest = new(); }
        var request = filmstripRequest;
        var jobs = new List<Task>();
        for (var index = 0; index < thumbnails.Length; index++)
        {
            var image = thumbnails[index];
            var key = index < count ? service.TimelinePathFor(source.ContentKey, thumbnailSlots[index].SourceTime, source.Video?.RotationDegrees ?? 0) : null;
            if (thumbnailKeys[index] != key)
            {
                image.Source = null; thumbnailLeases[index]?.Dispose(); thumbnailLeases[index] = null; thumbnailKeys[index] = key;
            }
            if (key is not null && request is not null && thumbnailLeases[index] is null && !ReferenceEquals(thumbnailLoading[index], request))
            { thumbnailLoading[index] = request; jobs.Add(LoadThumbnail(index, thumbnailSlots[index].SourceTime, key, source, service, request)); }
            image.Visibility = key is null ? Visibility.Collapsed : Visibility.Visible;
            if (index >= count) continue;
            Canvas.SetLeft(image, thumbnailSlots[index].X); image.Width = thumbnailSlots[index].Width; image.Height = Math.Max(0, metrics.VideoHeight - 11);
        }
        if (jobs.Count == 0) return;
        try { await Task.WhenAll(jobs); }
        finally
        {
            if (request is not null && !ReferenceEquals(filmstripRequest, request)) request.Dispose();
        }
    }
    private async Task LoadThumbnail(int index, double seconds, string key, MediaReference source, Thumbnails service, CancellationTokenSource request)
    {
        Thumbnails.FrameLease? lease = null;
        try
        {
            lease = await service.GetTimelineAsync(source.ContentKey, source.AbsolutePath, seconds, source.Video?.RotationDegrees ?? 0, request.Token);
            if (lease is null || disposed || request.IsCancellationRequested || !ReferenceEquals(filmstripRequest, request) ||
                model?.Project.Media.Source != source || model.IsReadOnly || renderingBlocked || thumbnailKeys[index] != key || !IsLoaded) return;
            var bitmap = new BitmapImage(new Uri(lease.Path));
            thumbnailLeases[index]?.Dispose(); thumbnailLeases[index] = lease; lease = null;
            thumbnails[index].Source = bitmap;
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is VoxClipException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            if (ReferenceEquals(filmstripRequest, request) && thumbnailKeys[index] == key) thumbnails[index].Source = null;
        }
        finally
        {
            lease?.Dispose();
            if (ReferenceEquals(thumbnailLoading[index], request)) thumbnailLoading[index] = null;
        }
    }
    private void ClearFilmstrip()
    {
        filmstripRequest?.Cancel(); filmstripRequest?.Dispose(); filmstripRequest = null;
        for (var index = 0; index < thumbnails.Length; index++)
        {
            thumbnails[index].Source = null; thumbnailKeys[index] = null;
            thumbnailLeases[index]?.Dispose(); thumbnailLeases[index] = null;
        }
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
        frameWidth = track.ActualWidth;
        frame.Compute(viewport, scene, plan, rendered, view, frameWidth, source ?? model.SourceTime, Edited,
            trimming, trimStart, trimId, trimFirst, trimLast, !model.IsReadOnly && !model.Busy, pointer);
        trimFirst = frame.First; trimLast = frame.Last;
        retained.Move(view);
        viewportTransform.ScaleX = frame.Scale;
        viewportTransform.TranslateX = frame.Translation;
        laneTransform.ScaleX = frame.Scale; laneTransform.TranslateX = frame.Translation;
        captionTransform.ScaleX = frame.Scale; captionTransform.TranslateX = frame.Translation;
        rulerTransform.ScaleX = frame.Scale; rulerTransform.TranslateX = frame.Translation;
        var bounds = ClipBounds();
        var inBracket = bounds is { } inside ? view.X(ToDisplay(inside.Start), frameWidth) : double.NegativeInfinity;
        var outBracket = bounds is { } outside ? view.X(ToDisplay(outside.End), frameWidth) : double.PositiveInfinity;
        for (var index = 0; index < tickCount; index++)
        {
            var position = view.X(tickTimes[index], frameWidth) + tickOffsets[index];
            var end = position + ticks[index].DesiredSize.Width;
            Canvas.SetLeft(ticks[index], position);
            ticks[index].Visibility = position >= 0 && end <= frameWidth + 6 &&
                !(position - 3 <= inBracket && inBracket <= end + 2) && !(position - 3 <= outBracket && outBracket <= end + 2) ? Visibility.Visible : Visibility.Collapsed;
        }
        leftDim.Width = frame.LeftDim; rightDim.Width = frame.RightDim; Canvas.SetLeft(rightDim, frame.RightEdge);
        bracketTransform.ScaleX = frame.BracketScale; bracketTransform.TranslateX = frame.BracketTranslation;
        startHandle.Visibility = frame.HasTrim && frame.StartVisible ? Visibility.Visible : Visibility.Collapsed;
        endHandle.Visibility = frame.HasTrim && frame.EndVisible ? Visibility.Visible : Visibility.Collapsed;
        if (frame.HasTrim)
        {
            startHandle.IsEnabled = endHandle.IsEnabled = frame.TrimEnabled && !renderingBlocked;
            Canvas.SetLeft(startHandle, frame.StartLeft); Canvas.SetLeft(endHandle, frame.EndLeft);
            Canvas.SetTop(startHandle, TimelineLayout.OverviewHeight - 5); Canvas.SetTop(endHandle, TimelineLayout.OverviewHeight - 5);
            startHandle.Refresh(); endHandle.Refresh();
        }
        var top = TimelineLayout.OverviewHeight;
        var left = frame.StartVisible ? frame.StartLeft + 16 : -10;
        var right = frame.EndVisible ? frame.EndLeft + 16 : frameWidth + 10;
        bracketFigures[0].StartPoint = new(left, top); bracketLines[0].Point = new(left, top + TimelineLayout.RulerHeight);
        bracketFigures[1].StartPoint = new(left, top); bracketLines[1].Point = new(left + 4, top);
        bracketFigures[2].StartPoint = new(right, top); bracketLines[2].Point = new(right, top + TimelineLayout.RulerHeight);
        bracketFigures[3].StartPoint = new(right, top); bracketLines[3].Point = new(right - 4, top);
        trimBrackets.Visibility = frame.HasTrim ? Visibility.Visible : Visibility.Collapsed;
        overviewWindow.Width = Math.Min(frameWidth, view.Duration / Math.Max(.001, AxisDuration) * frameWidth);
        Canvas.SetLeft(overviewWindow, view.Start / Math.Max(.001, AxisDuration) * frameWidth);
        scrollThumb.Width = overviewWindow.Width; Canvas.SetLeft(scrollThumb, view.Start / Math.Max(.001, AxisDuration) * frameWidth); scrollRange.Refresh();
        MovePlayhead();
    }
    private void MovePlayhead()
    {
        playheadTransform.X = frame.PlayheadLeft;
        headTransform.X = frame.HeadLeft;
        playhead.Visibility = head.Visibility = frame.PlayheadVisible && !renderingBlocked ? Visibility.Visible : Visibility.Collapsed;
        var source = frame.Source;
        var clock = Math.Max(0, ToDisplay(source) - (Edited && ClipBounds() is { } bounds ? ToDisplay(bounds.Start) : 0));
        SetClockRun(clockPrefix, viewport.DimClock(clock), ref shownClockPrefix);
        SetClockRun(elapsed, viewport.Clock(clock), ref shownElapsed);
        SetClockRun(clockFrames, viewport.Frames(clock), ref shownClockFrames);
        SetClockRun(sourceElapsed, viewport.SourceClock(source), ref shownSourceElapsed);
        SetClockRun(sourceFrames, viewport.Frames(source), ref shownSourceFrames);
        var overviewX = ToDisplay(source) / Math.Max(.001, AxisDuration) * frameWidth;
        Canvas.SetLeft(overviewHead, Math.Clamp(overviewX, 0, Math.Max(0, frameWidth - 1.5)));
        for (var index = 0; index < overviewBadgeVisible.Length; index++)
            retained.Nodes[TimelineRetainedPool<object>.Layers + index].Visibility = overviewBadgeVisible[index] && Math.Abs(overviewBadgeLeft[index] + 9 - overviewX) > 14 ? Visibility.Visible : Visibility.Collapsed;
        slider.Refresh();
    }
    private static void SetClockRun(Run run, string value, ref string shown)
    {
        if (ReferenceEquals(shown, value)) return;
        shown = value; run.Text = value;
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
                var radius = Math.Min(2, Math.Min(mark.Width, mark.Height) / 2);
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
