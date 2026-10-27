using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

/// <summary>The one media tile (design §5.4) for Home tiles and sidebar rows. It draws what its <see cref="MediaTile"/>
/// decides: a real frame, else the caption card, else stage black, with the status chip and progress line on top. Media
/// is never recoloured, so the tile stays black in every theme, High Contrast included. The loading ladder (§5.4.5): for
/// 300 ms the tile holds stage black and its rim, and a frame that arrives then cuts in; after that the card shows, and a
/// later frame cross-fades over it in 150 ms. A stalled read sweeps one neutral sheen. Motion stops when Windows animations
/// are off. The tile is decorative: its row or grid item carries the name, and chips have none of their own.</summary>
public sealed partial class MediaThumbnail : UserControl
{
    public static readonly DependencyProperty MediaProperty = DependencyProperty.Register(nameof(Media), typeof(MediaTile), typeof(MediaThumbnail),
        new PropertyMetadata(null, (owner, _) => ((MediaThumbnail)owner).MediaChanged()));
    public static readonly DependencyProperty SurfaceProperty = DependencyProperty.Register(nameof(Surface), typeof(CardSurface), typeof(MediaThumbnail),
        new PropertyMetadata(CardSurface.Sidebar, (owner, _) => ((MediaThumbnail)owner).SurfaceChanged()));
    private const int HoldMilliseconds = 300;
    private readonly SolidColorBrush black = new(Colors.Black);
    private readonly Grid layers = new();
    private readonly Image card = new() { Stretch = Stretch.Fill, Visibility = Visibility.Collapsed };
    private readonly Image frame = new() { Stretch = Stretch.UniformToFill, Opacity = 0 };
    private readonly Border dots = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    private readonly Ellipse[] dot = [new(), new(), new()];
    private readonly Rectangle sheen = new() { HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed, RenderTransform = new TranslateTransform() };
    private readonly Border rim = new() { BorderThickness = new(1), IsHitTestVisible = false };
    private readonly Border chip = new() { Height = 24, MinWidth = 24, CornerRadius = new(4), BorderThickness = new(1), Margin = new(8), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
    private readonly StackPanel chipContent = new() { Orientation = Orientation.Horizontal, Spacing = 5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Grid chipGlyph = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly FontIcon chipIcon = new();
    private readonly Line chipStrike = new() { X1 = 1.5, Y1 = 1.5, StrokeThickness = 1.5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly TextBlock chipText = new() { FontSize = 12, LineHeight = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    private readonly Run chipLabel = new();
    private readonly Run chipNumber = new();
    private readonly Grid progress = new() { VerticalAlignment = VerticalAlignment.Bottom, Visibility = Visibility.Collapsed };
    private readonly Rectangle progressFill = new() { HorizontalAlignment = HorizontalAlignment.Left, RenderTransform = new TranslateTransform() };
    private readonly DispatcherQueueTimer hold;
    private readonly DispatcherQueueTimer resized;
    private Storyboard? sheenMotion, dotsMotion, progressMotion;
    private CompositionGeometricClip? clip;
    private CompositionRoundedRectangleGeometry? clipShape;
    private string? id;
    private long epoch;
    private bool cardShown;
    private string? requestedFrame;
    private string? shownFrame;
    private string? cardKey;
    private (int Width, int Height) cardPixels;
    private CancellationTokenSource? cardRender;

    public MediaThumbnail()
    {
        IsTabStop = false;
        AutomationProperties.SetAccessibilityView(this, AccessibilityView.Raw);
        layers.Background = black;
        var dotRow = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (item, opacity) in dot.Zip(new[] { 1, 0.55, 0.28 })) { item.Fill = new SolidColorBrush(Colors.White); item.Opacity = opacity; dotRow.Children.Add(item); }
        dots.Child = dotRow;
        sheen.Fill = new LinearGradientBrush
        {
            // One white 7.5% band at 105°, fading out on both sides.
            StartPoint = new(0, 0.37), EndPoint = new(1, 0.63),
            GradientStops =
            {
                new GradientStop { Color = Colors.Transparent, Offset = 0 },
                new GradientStop { Color = ColorHelper.FromArgb(0x13, 0xFF, 0xFF, 0xFF), Offset = 0.5 },
                new GradientStop { Color = Colors.Transparent, Offset = 1 }
            }
        };
        chipGlyph.Children.Add(chipIcon);
        chipGlyph.Children.Add(chipStrike);
        chipNumber.FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"];
        chipText.Inlines.Add(chipLabel);
        chipText.Inlines.Add(chipNumber);
        chipContent.Children.Add(chipGlyph);
        chipContent.Children.Add(chipText);
        chip.Child = chipContent;
        progress.Children.Add(progressFill);
        foreach (var layer in new UIElement[] { card, frame, dots, sheen, rim, chip, progress }) layers.Children.Add(layer);
        Content = layers;
        hold = DispatcherQueue.CreateTimer();
        hold.IsRepeating = false;
        hold.Interval = TimeSpan.FromMilliseconds(HoldMilliseconds);
        hold.Tick += (_, _) => Apply();
        resized = DispatcherQueue.CreateTimer();
        resized.IsRepeating = false;
        resized.Interval = TimeSpan.FromMilliseconds(150);
        resized.Tick += (_, _) => { RenderCard(); Apply(); };
        SizeChanged += (_, _) => { Shape(); resized.Start(); };
        Loaded += (_, _) => { Ui.EffectsChanged += EffectsChanged; Shape(); Apply(); };
        Unloaded += (_, _) => { Ui.EffectsChanged -= EffectsChanged; Stop(ref sheenMotion); Stop(ref dotsMotion); Stop(ref progressMotion); cardRender?.Cancel(); };
        ActualThemeChanged += (_, _) => Apply();
        RegisterPropertyChangedCallback(CornerRadiusProperty, (_, _) => Shape());
        SurfaceChanged();
    }

    /// <summary>The take's or clip's frame, card and status.</summary>
    public MediaTile? Media { get => (MediaTile?)GetValue(MediaProperty); set => SetValue(MediaProperty, value); }
    /// <summary>Home tiles carry chips and plates; sidebar and clip-row thumbnails are downscaled cards with neither.</summary>
    public CardSurface Surface { get => (CardSurface)GetValue(SurfaceProperty); set => SetValue(SurfaceProperty, value); }

    private void EffectsChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(Apply);

    private void SurfaceChanged()
    {
        var home = Surface == CardSurface.Home;
        var size = home ? 8 : 3;
        foreach (var item in dot) item.Width = item.Height = size;
        ((StackPanel)dots.Child).Spacing = home ? 5 : 2;
        // On Home the dots sit in a dark pill so they read on any backdrop; at sidebar sizes they stand alone.
        dots.Padding = home ? new(9, 7, 9, 7) : new(0);
        dots.CornerRadius = new(home ? 11 : 0);
        dots.Background = home ? new SolidColorBrush(ColorHelper.FromArgb(0x73, 0, 0, 0)) : null;
        rim.BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(home ? (byte)0x1A : (byte)0x1F, 0xFF, 0xFF, 0xFF));
        cardKey = null;
        RenderCard();
        Apply();
    }

    private void MediaChanged()
    {
        var media = Media;
        if (media?.Id != id)
        {
            // A new take, or a recycled container showing another one: restart the ladder from stage black.
            id = media?.Id;
            epoch = Environment.TickCount64;
            cardShown = false;
            requestedFrame = shownFrame = null;
            frame.OpacityTransition = null;
            frame.Opacity = 0;
            frame.Source = null;
            card.Source = null;
            cardKey = null;
            hold.Stop();
            if (id is not null) hold.Start();
        }
        LoadFrame(media?.FramePath);
        RenderCard();
        Apply();
    }

    private bool Held => Environment.TickCount64 - epoch < HoldMilliseconds;

    private async void LoadFrame(string? path)
    {
        if (path == requestedFrame) return;
        requestedFrame = path;
        if (path is null) { shownFrame = null; frame.Source = null; Apply(); return; }
        try
        {
            var (width, height) = Pixels();
            // Decode no larger than the tile: the long side of a landscape tile, the height of a portrait one.
            var bitmap = new BitmapImage();
            if (width > 0 && height > 0)
            {
                if (width >= height) bitmap.DecodePixelWidth = width;
                else bitmap.DecodePixelHeight = height;
            }
            using (var stream = File.OpenRead(path)) await bitmap.SetSourceAsync(stream.AsRandomAccessStream());
            if (requestedFrame != path) return;
            frame.Source = bitmap;
            shownFrame = path;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or COMException)
        {
            // A damaged or deleted cache file leaves the card in place; the next Home visit makes the frame again.
            if (requestedFrame == path) { frame.Source = null; shownFrame = null; }
        }
        Apply();
    }

    private async void RenderCard()
    {
        var source = Media?.Card;
        var pixels = Pixels();
        if (source is null || pixels.Width < 1 || pixels.Height < 1 || App.Services.Cards is not { } cards)
        {
            if (source is null) { card.Source = null; cardKey = null; }
            return;
        }
        if (cardKey == source.Key && cardPixels == pixels) return;
        cardRender?.Cancel();
        var render = cardRender = new CancellationTokenSource();
        try
        {
            var bitmap = await cards.RenderAsync(source, Surface, pixels.Width, pixels.Height, render.Token);
            if (render.IsCancellationRequested || Media?.Card?.Key != source.Key) return;
            if (bitmap is null) { card.Source = null; cardKey = null; }
            else
            {
                var image = new WriteableBitmap(bitmap.Width, bitmap.Height);
                using (var stream = image.PixelBuffer.AsStream()) stream.Write(bitmap.Pixels);
                image.Invalidate();
                card.Source = image;
                cardKey = source.Key;
                cardPixels = pixels;
            }
        }
        catch (OperationCanceledException) { return; }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            // No card: the tile keeps stage black and its status. The log names the failure, never the words.
            App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "thumbnail", $"action=Caption card code={exception.GetType().Name}");
            card.Source = null;
            cardKey = null;
        }
        Apply();
    }

    private (int Width, int Height) Pixels()
    {
        var scale = XamlRoot?.RasterizationScale ?? 1;
        return ((int)Math.Round(ActualWidth * scale), (int)Math.Round(ActualHeight * scale));
    }

    /// <summary>Lay the stand-in, chip and progress line out for the current state; the ladder's timer calls back here.</summary>
    private void Apply()
    {
        var media = Media;
        var animate = Ui.AnimationsEnabled;
        var held = Held;
        var home = Surface == CardSurface.Home;
        var hasFrame = shownFrame is not null && shownFrame == media?.FramePath;
        if (hasFrame && frame.Opacity < 1)
        {
            // Cut in during the hold, cross-fade 150 ms over a card that was already showing.
            frame.OpacityTransition = cardShown && animate ? new ScalarTransition { Duration = TimeSpan.FromMilliseconds(150) } : null;
            frame.Opacity = 1;
        }
        else if (!hasFrame) { frame.OpacityTransition = null; frame.Opacity = 0; }
        var wantsCard = media is not null && (media.HasWords || media.ShowsDots) && card.Source is not null && !held;
        if (wantsCard && !hasFrame) cardShown = true;
        card.Visibility = wantsCard ? Visibility.Visible : Visibility.Collapsed;
        var showsDots = media?.ShowsDots == true && !hasFrame && !held;
        dots.Visibility = showsDots ? Visibility.Visible : Visibility.Collapsed;
        Animate(ref dotsMotion, showsDots && animate, DotsMotion);
        var stalled = media?.Status == MediaStatus.Loading && !held && animate;
        sheen.Visibility = stalled ? Visibility.Visible : Visibility.Collapsed;
        Animate(ref sheenMotion, stalled, SheenMotion);
        ApplyChip(media, home && !held);
        ApplyProgress(media, !held && (home || hasFrame), animate);
    }

    private void ApplyChip(MediaTile? media, bool visible)
    {
        var status = media?.Status ?? MediaStatus.None;
        if (!visible || status is MediaStatus.None or MediaStatus.Loading) { chip.Visibility = Visibility.Collapsed; return; }
        var opaque = !Ui.TransparencyEnabled;
        chip.Background = Ui.ThemeBrush(this, opaque ? "VcChipMediaBackgroundOpaqueBrush" : "VcChipMediaBackgroundBrush");
        chip.BorderBrush = Ui.ThemeBrush(this, opaque ? "VcChipMediaStrokeOpaqueBrush" : "VcChipMediaStrokeBrush");
        var foreground = Ui.ThemeBrush(this, "VcChipMediaForegroundBrush");
        var warning = Ui.ThemeBrush(this, "VcChipMediaWarningGlyphBrush");
        chipText.Foreground = foreground;
        // Missing and unreadable chips are icon-only: the meta line beside the tile carries the words.
        var iconOnly = status is MediaStatus.Missing or MediaStatus.Unreadable;
        chip.Width = iconOnly ? 24 : double.NaN;
        chip.Padding = iconOnly ? new(0) : status == MediaStatus.AudioOnly ? new(6, 0, 8, 0) : new(8, 0, 8, 0);
        chipGlyph.Visibility = status is MediaStatus.Missing or MediaStatus.Unreadable or MediaStatus.AudioOnly ? Visibility.Visible : Visibility.Collapsed;
        chipText.Visibility = iconOnly ? Visibility.Collapsed : Visibility.Visible;
        // Segoe Fluent Icons has no video-off glyph, so the missing chip strikes through Video.
        chipIcon.Glyph = status switch { MediaStatus.Missing => "", MediaStatus.Unreadable => "", _ => "" };
        chipIcon.FontSize = iconOnly ? 16 : 14;
        chipIcon.Foreground = iconOnly ? warning : foreground;
        chipGlyph.Width = chipGlyph.Height = chipIcon.FontSize;
        chipStrike.Visibility = status == MediaStatus.Missing ? Visibility.Visible : Visibility.Collapsed;
        chipStrike.X2 = chipStrike.Y2 = chipIcon.FontSize - 1.5;
        chipStrike.Stroke = warning;
        var transcription = media?.Transcription ?? new TranscriptionStatus(TranscriptionStep.Transcribing, null);
        chipLabel.Text = status switch
        {
            MediaStatus.Transcribing => Ui.AnimationsEnabled || transcription.Fraction is not null ? transcription.Label : "Transcribing",
            MediaStatus.Demo => "Demo",
            MediaStatus.AudioOnly => "Audio only",
            _ => ""
        };
        chipNumber.Text = status == MediaStatus.Transcribing ? transcription.Percent : "";
        chip.Visibility = Visibility.Visible;
    }

    private void ApplyProgress(MediaTile? media, bool visible, bool animate)
    {
        var fraction = media?.Transcription is { Step: TranscriptionStep.Transcribing, Fraction: { } value } ? value : (double?)null;
        // The indeterminate segment slides; under Reduce Motion the line is hidden and the chip reads "Transcribing".
        visible = visible && media?.Status == MediaStatus.Transcribing && (fraction is not null || animate);
        progress.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible) { Animate(ref progressMotion, false, ProgressMotion); return; }
        var contrast = Ui.HighContrast;
        var opaque = !Ui.TransparencyEnabled;
        progress.Height = contrast ? 4 : 2;
        progress.Background = contrast ? Ui.ThemeBrush(this, "VcMediaProgressTrackBrush") : opaque ? black : Ui.ThemeBrush(this, "VcMediaProgressTrackBrush");
        progressFill.Fill = contrast ? Ui.ThemeBrush(this, "VcMediaProgressFillBrush") : opaque ? new SolidColorBrush(Colors.White) : Ui.ThemeBrush(this, "VcMediaProgressFillBrush");
        progressFill.Width = Math.Max(0, ActualWidth * (fraction ?? 0.3));
        if (fraction is not null) ((TranslateTransform)progressFill.RenderTransform).X = 0;
        Animate(ref progressMotion, fraction is null, ProgressMotion);
    }

    /// <summary>Round the tile's corners for every layer, frames and overlays alike, with a composition clip.</summary>
    private void Shape()
    {
        var visual = ElementCompositionPreview.GetElementVisual(layers);
        if (clip is null)
        {
            clipShape = visual.Compositor.CreateRoundedRectangleGeometry();
            clip = visual.Compositor.CreateGeometricClip(clipShape);
            visual.Clip = clip;
        }
        clipShape!.Size = new((float)ActualWidth, (float)ActualHeight);
        clipShape.CornerRadius = new((float)CornerRadius.TopLeft, (float)CornerRadius.TopLeft);
        rim.CornerRadius = CornerRadius;
        sheen.Width = ActualWidth * 0.4;
        sheen.Height = ActualHeight;
        if (sheenMotion is not null) { Stop(ref sheenMotion); Apply(); }
        if (progressMotion is not null) { Stop(ref progressMotion); Apply(); }
    }

    private Storyboard SheenMotion()
    {
        // 2.4 s ease-in-out sweep, then a 0.6 s rest.
        var sweep = new DoubleAnimationUsingKeyFrames { RepeatBehavior = RepeatBehavior.Forever };
        sweep.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.Zero), Value = -sheen.Width });
        sweep.KeyFrames.Add(new EasingDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(2.4)), Value = ActualWidth, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } });
        sweep.KeyFrames.Add(new DiscreteDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(3)), Value = ActualWidth });
        return Motion(sweep, sheen.RenderTransform, "X");
    }

    private Storyboard ProgressMotion()
    {
        // A 30% segment slides across in 1.6 s.
        var slide = new DoubleAnimation { From = -progressFill.Width, To = ActualWidth, Duration = new Duration(TimeSpan.FromSeconds(1.6)), RepeatBehavior = RepeatBehavior.Forever };
        return Motion(slide, progressFill.RenderTransform, "X");
    }

    private Storyboard DotsMotion()
    {
        // The brightest dot steps along the row; each keeps the white 100/55/28% ladder.
        var storyboard = new Storyboard { RepeatBehavior = RepeatBehavior.Forever };
        double[] levels = [1, 0.55, 0.28];
        for (var index = 0; index < dot.Length; index++)
        {
            var pulse = new DoubleAnimationUsingKeyFrames();
            for (var step = 0; step <= 3; step++)
                pulse.KeyFrames.Add(new LinearDoubleKeyFrame { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(step * 0.4)), Value = levels[((index - step) % 3 + 3) % 3] });
            Storyboard.SetTarget(pulse, dot[index]);
            Storyboard.SetTargetProperty(pulse, "Opacity");
            storyboard.Children.Add(pulse);
        }
        return storyboard;
    }

    private static Storyboard Motion(Timeline animation, DependencyObject target, string property)
    {
        var storyboard = new Storyboard();
        Storyboard.SetTarget(animation, target);
        Storyboard.SetTargetProperty(animation, property);
        storyboard.Children.Add(animation);
        return storyboard;
    }

    private void Animate(ref Storyboard? motion, bool running, Func<Storyboard> create)
    {
        if (running && motion is null && IsLoaded && ActualWidth > 0) { motion = create(); motion.Begin(); }
        else if (!running) Stop(ref motion);
    }

    private static void Stop(ref Storyboard? motion)
    {
        motion?.Stop();
        motion = null;
    }
}
