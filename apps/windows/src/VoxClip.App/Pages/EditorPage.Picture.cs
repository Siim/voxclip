using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using SkiaSharp;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using Windows.System;

namespace VoxClip.App.Pages;

/// <summary>The Picture tab's page side (looks spec §3.4, §3.7 and §7): the looks file and the remembered fold, the paused frame for the
/// tiles, the viewer's previews of a hovered look, Compare and a dragged value, the backslash key, and playback around a held Compare.</summary>
public sealed partial class EditorPage
{
    /// <summary>The backslash key (VK_OEM_5 on US layouts).</summary>
    private const VirtualKey Backslash = (VirtualKey)220;
    private CancellationTokenSource? picturePreviewWork;
    private bool resumeAfterCompare;
    private PixelBuffer? samplePicture;

    private void InitializePicture()
    {
        if (App.Services.Looks is { } looks)
            ViewModel.Picture.Services = new(looks)
            {
                Measure = MeasurePictureAsync,
                FineTuneOpen = App.Services.Get(PicturePanelModel.FineTuneSetting, false),
                RememberFineTune = open => _ = RunAsync(() => App.Services.SetAsync(PicturePanelModel.FineTuneSetting, open, lifetime.Token), "Picture"),
            };
        ViewModel.Picture.PreviewChanged += (_, _) => DispatcherQueue.TryEnqueue(() => _ = ShowPicturePreviewAsync());
        ViewModel.Picture.PlayRequested += (_, time) => _ = RunAsync(() => PlayMakeItAsync(time), "Preview");
        ViewModel.MakeItShowPictureRequested += (_, clip) => DispatcherQueue.TryEnqueue(() => ShowPicture(clip));
        if (rightContent is not { } column) return;
        var panel = column.Picture;
        panel.BeforeGrade = ct => preview is { } engine ? engine.StillBeforeGradeAsync(ct) : Task.FromException<PixelBuffer>(new InvalidOperationException("No preview."));
        panel.HoldCompare = HoldCompareAsync;
        panel.SamplePicture = SamplePicture;
    }

    /// <summary>Auto's measurement: the clip's sheet frames from the frame pass, or without one (no face models on this PC) the paused
    /// frame before the grade; null when neither can be read.</summary>
    private async Task<ClipColorFix?> MeasurePictureAsync(string clipId, CancellationToken ct)
    {
        if (await ViewModel.MeasurePictureFixAsync(clipId, ct) is { } measured) return measured;
        if (preview is not { } engine || engine.Position.IsPlaying || App.Services.Looks is not { } looks) return null;
        try
        {
            var still = await engine.StillBeforeGradeAsync(ct);
            return await Task.Run(() => VoxClip.Media.Frames.FrameLightSampling.Sample(still, looks.Measure.Auto.FrameSize, null) is { } sample
                ? ClipColorFix.Measure([sample], looks.Measure.Auto) : (ClipColorFix?)null, ct);
        }
        catch (Exception exception) when (exception is InvalidOperationException or NotSupportedException or IOException or Core.Domain.Shared.VoxClipException)
        {
            return null;
        }
    }

    /// <summary>Make it's "All looks in Picture ›" and the palette's Open Picture: the clip's Picture tab.</summary>
    private void ShowPicture(string? clipId = null)
    {
        if (disposed || rightContent is null) return;
        if (clipId is not null && ViewModel.Project.Edits.ActiveClipId != clipId) owner.ShowScope(clipId);
        SetViewerVisible(true);
        if (rightContent.ShowPicture()) rightContent.Picture.FocusTarget.Focus(FocusState.Programmatic);
    }

    /// <summary>Compare held or released; a hold during playback pauses it and the release plays on (looks spec §3.4).</summary>
    private async Task HoldCompareAsync(bool down)
    {
        if (down)
        {
            if (ViewModel.Picture.CompareReason is not null) return;
            if (preview is { Position.IsPlaying: true } engine)
            {
                resumeAfterCompare = true;
                await SourceTransportAsync(token => engine.PauseAsync(token));
                ViewModel.Picture.SetPlaying(false);
            }
            ViewModel.Picture.BeginCompare();
            return;
        }
        ViewModel.Picture.EndCompare();
        if (!resumeAfterCompare) return;
        resumeAfterCompare = false;
        if (preview is { } playing && !ViewModel.IsReadOnly) await SourceTransportAsync(token => playing.PlayAsync(token));
    }

    /// <summary>Backslash held anywhere in the editor but a text field shows As filmed until it's released.</summary>
    private bool PictureCompareKey(KeyRoutedEventArgs args, bool down)
    {
        if (args.Key != Backslash || InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot)) || InputState.Down(VirtualKey.Control) ||
            InputState.Down(VirtualKey.Menu) || !ViewModel.Picture.IsAvailable || ViewModel.Picture.ClipId is null) return false;
        if (!down || !args.KeyStatus.WasKeyDown) _ = RunAsync(() => HoldCompareAsync(down), "Compare");
        args.Handled = true;
        return true;
    }

    /// <summary>The playhead or playback changed: hover previews wait for a pause, and the tiles follow a rested playhead.</summary>
    private void PicturePositionChanged(PreviewPosition position, bool moved)
    {
        ViewModel.Picture.SetPlaying(position.IsPlaying);
        if (moved && !position.IsPlaying && rightContent is { ShowsPicture: true } column) column.Picture.PlayheadMoved();
    }

    /// <summary>The viewer shows the preview's still over the player (the same rect), with its badge; nothing reloads.</summary>
    private async Task ShowPicturePreviewAsync()
    {
        picturePreviewWork?.Cancel();
        if (disposed || ViewModel.Picture.Preview is not { } shown || preview is not { } engine || engine.Position.IsPlaying)
        {
            PicturePreviewImage.Visibility = Visibility.Collapsed;
            PicturePreviewImage.Source = null;
            PicturePreviewBadge.Visibility = Visibility.Collapsed;
            return;
        }
        var work = picturePreviewWork = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        try
        {
            var still = await engine.StillAsync(shown.Colour, work.Token);
            if (work.IsCancellationRequested || !ReferenceEquals(ViewModel.Picture.Preview, shown)) return;
            PicturePreviewImage.Source = PicturePanel.Bitmap(still);
            PicturePreviewImage.Visibility = Visibility.Visible;
            PicturePreviewBadgeText.Text = shown.Badge ?? "";
            PicturePreviewBadge.Visibility = shown.Badge is null ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is InvalidOperationException or NotSupportedException or IOException or Core.Domain.Shared.VoxClipException)
        {
            // A still that can't be drawn leaves the player's own frame; Compare and hover are previews only.
            UiError.WriteFailure(exception, "Picture preview");
            PicturePreviewImage.Visibility = Visibility.Collapsed;
            PicturePreviewBadge.Visibility = Visibility.Collapsed;
        }
    }

    /// <summary>shared/looks/test-card.png as the tiles' sample picture (looks spec §7.7); null when it can't be read.</summary>
    private PixelBuffer? SamplePicture()
    {
        if (samplePicture is not null || App.Services.SharedRoot is not { } root) return samplePicture;
        try
        {
            using var bitmap = SKBitmap.Decode(Path.Combine(root, "looks", "test-card.png"));
            if (bitmap is null) return null;
            using var converted = bitmap.Copy(SKColorType.Bgra8888);
            if (converted is null) return null;
            samplePicture = new(converted.Bytes, converted.Width, converted.Height, converted.RowBytes);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { UiError.WriteFailure(exception, "Look tiles"); }
        return samplePicture;
    }

    /// <summary>The palette's Compare with As Filmed: on until chosen again.</summary>
    private void TogglePictureCompare() => _ = RunAsync(() => HoldCompareAsync(!ViewModel.Picture.Comparing), "Compare");
}
