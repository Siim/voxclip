using Microsoft.UI.Xaml;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;

namespace VoxClip.App.Pages;

/// <summary>The stage's preview-failed state (design.md §5.4.4 g): the engine's compositor reason is logged and shown over the player with
/// Reload Preview, and the display watch re-attaches a stage that holds a ready preview without showing it.</summary>
public sealed partial class EditorPage
{
    private PreviewStageState previewStage = null!;
    /// <summary>The snapshot the open preview loaded: the display watch's item.</summary>
    private ComposeSnapshot? loadedSnapshot;

    private void Hook(IPreviewEngine engine)
    {
        engine.PlaybackFaulted += PlaybackFaulted;
        engine.AudioStatusChanged += AudioStatusChanged;
        engine.CompositorFailed += CompositorFailed;
    }

    private void Unhook(IPreviewEngine engine)
    {
        engine.PlaybackFaulted -= PlaybackFaulted;
        engine.AudioStatusChanged -= AudioStatusChanged;
        engine.CompositorFailed -= CompositorFailed;
    }

    /// <summary>Raised on the engine owner thread, once per loaded preview.</summary>
    private void CompositorFailed(object? sender, PreviewFailureReason reason)
        => DispatcherQueue.TryEnqueue(() => { if (!disposed) previewStage.CompositorFailed(reason); });

    /// <summary>Shows or hides the plate; with a stand-in on the stage, the transcript's notice carries the line instead.</summary>
    private void ShowPreviewStage()
    {
        if (disposed || ViewModel is null) return;
        previewStage.ShowsPlayer = !demo && mediaState == EditorMediaState.Ready && !ViewModel.IsReadOnly;
        var line = previewStage.StagePreviewError;
        PreviewFailureLine.Text = line ?? "";
        PreviewFailurePlate.Visibility = line is null ? Visibility.Collapsed : Visibility.Visible;
        if (previewStage.TranscriptPreviewError is { } notice) ViewModel.Notice = notice;
        PositionStageMessage();
    }

    /// <summary>Reload Preview: the preview is built and loaded again; a load that works clears the line.</summary>
    private async Task ReloadPreviewAsync()
    {
        await previewChanges.WaitAsync(lifetime.Token);
        try
        {
            if (preview is not null) Unhook(preview);
            if (presenter is not null) await presenter.DisposeAsync(); else if (preview is not null) await preview.DisposeAsync();
            presenter = null; preview = null; loadedSnapshot = null;
            PreviewImage.Source = null;
        }
        finally { previewChanges.Release(); }
        await UpdatePreviewAsync();
    }

    /// <summary>The display watch's view of the stage: on screen only while the stage shows the player with no plate over it.</summary>
    private PreviewDisplayHooks PreviewDisplay() => new(
        () => !disposed && previewStage.StagePreviewError is null && PreviewStandIn.Visibility == Visibility.Collapsed,
        () => previewStage.DisplayStalled());
}
