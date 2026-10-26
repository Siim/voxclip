using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

public sealed class TimelineView : UserControl
{
    private readonly Canvas canvas = new() { Height = 28, IsHitTestVisible = false };
    private readonly Slider slider = new() { Minimum = 0, StepFrequency = 0.01, SmallChange = 0.1, IsTabStop = true, VerticalAlignment = VerticalAlignment.Top };
    private readonly TextBlock label = new() { FontSize = 11, Margin = new Thickness(0, 0, 0, 4) };
    private EditorViewModel? model;
    private bool updating;
    public event EventHandler<double>? SeekRequested;
    public TimelineView()
    {
        IsTabStop = false;
        var grid = new Grid { Padding = new Thickness(24, 0, 24, 0), Height = 56 };
        grid.RowDefinitions.Add(new() { Height = new GridLength(36) });
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
        grid.Children.Add(canvas);
        grid.Children.Add(slider);
        Grid.SetRow(label, 1); grid.Children.Add(label);
        Content = grid;
        slider.ValueChanged += (_, args) => { if (!updating) SeekRequested?.Invoke(this, args.NewValue); };
        SizeChanged += (_, _) => Draw();
        ActualThemeChanged += (_, _) => Draw();
    }
    public void Attach(EditorViewModel value) { model = value; model.Changed += Changed; Draw(); }
    internal Control FocusTarget => slider;
    public void Detach() { if (model is not null) model.Changed -= Changed; }
    private void Changed(object? sender, EventArgs args) => Draw();
    public void Position(double value)
    {
        updating = true; slider.Value = value; updating = false;
        if (model is not null) AutomationProperties.SetName(slider, $"Playhead, {value:0.0} seconds of {model.Project.Media.Source.DurationSeconds:0.0}, {model.Summary.CutWordCount + model.Summary.CutPauseCount} cuts");
    }
    private Brush Brush(string key) => Ui.ThemeBrush(this, key);
    private void Draw()
    {
        canvas.Children.Clear();
        if (model is null || ActualWidth <= 48) return;
        var width = ActualWidth - 48;
        var duration = Math.Max(0.01, model.Project.Media.Source.DurationSeconds);
        slider.Maximum = duration;
        void Rect(double start, double end, Brush brush, double top = 8, double height = 22)
        {
            var rectangle = new Rectangle { Width = Math.Max(1, (end - start) / duration * width), Height = height, Fill = brush, RadiusX = 2, RadiusY = 2 };
            Canvas.SetLeft(rectangle, start / duration * width); Canvas.SetTop(rectangle, top); canvas.Children.Add(rectangle);
        }
        void Hatch(double start, double end, string brush)
        {
            var left = start / duration * width;
            var right = end / duration * width;
            var band = new Canvas { Width = Math.Max(1, right - left), Height = 22, Clip = new RectangleGeometry { Rect = new(0, 0, Math.Max(1, right - left), 22) } };
            for (var offset = -22.0; offset < right - left; offset += 6)
                band.Children.Add(new Line { X1 = offset, Y1 = 22, X2 = offset + 22, Y2 = 0, Stroke = Brush(brush), StrokeThickness = 2 });
            Canvas.SetLeft(band, left); Canvas.SetTop(band, 8); canvas.Children.Add(band);
        }
        Rect(0, duration, Brush("VcTimelineTrackBrush"));
        foreach (var word in model.Words)
            if (model.State?.CutWordIds.Contains(word.Id) == true) Hatch(word.Start, word.End, "VcCutFillBrush");
            else Rect(word.Start, word.End, Brush("VcTimelineKeptBrush"));
        foreach (var pause in model.State?.Pauses ?? []) if (model.State!.CutPauseIds.Contains(pause.Id)) Hatch(pause.Start, pause.End, "VcCutPauseFillBrush");
        var number = 1;
        foreach (var clip in model.Clips)
        {
            var first = model.Index(clip.Clip.StartWordId);
            var last = model.Index(clip.Clip.EndWordId);
            if (first < 0 || last < 0) continue;
            var start = model.Words[first].Start;
            var end = model.Words[last].End;
            Rect(start, end, Brush("VcTimelineClipBracketBrush"), 3, 2);
            var badge = new TextBlock { Text = (number++).ToString(), FontSize = 10, Foreground = Brush("VcTextPrimaryBrush") };
            Canvas.SetLeft(badge, start / duration * width); Canvas.SetTop(badge, 0); canvas.Children.Add(badge);
        }
        label.Text = EditorViewModel.Timecode(duration) + " source · " + model.Status;
        Position(model.SourceTime);
    }
}
