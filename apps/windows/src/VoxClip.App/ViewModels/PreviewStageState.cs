using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Media;

namespace VoxClip.App.ViewModels;

/// <summary>The stage's preview-failed state (design.md §5.4.4 g; Mac <c>EditorModel.previewFailed</c>, <c>stagePreviewError</c> and
/// <c>reloadPreview</c>): a preview that can't load or draw is never a silent black box. The page owns one per editor and gives it the
/// app log and the editor's one announcement channel.</summary>
internal sealed class PreviewStageState(Action<LogLevel, string, string> log, Action<string> announce)
{
    /// <summary>Stage copy (design.md §13 "Stage, preview failed").</summary>
    internal const string ReloadPreview = "Reload Preview";
    /// <summary>The log line when the display held a ready preview without showing it and was re-attached.</summary>
    internal const string DisplayStalledLine = "display stalled, layer reattached";
    /// <summary>The log category.</summary>
    internal const string Category = "preview";

    /// <summary>The line naming what failed, or null while the preview draws.</summary>
    internal string? PreviewError { get; private set; }

    /// <summary>The stage shows the video player rather than a stand-in: a readable video in a project that isn't the demo. The page keeps
    /// this current; a missing, corrupt, audio-only or demo stage has a stand-in (§5.4.4 c, e, f).</summary>
    internal bool ShowsPlayer { get; set; }

    /// <summary>The line the stage carries over the player, with Reload Preview; the transcript's notice steps aside while it shows.</summary>
    internal string? StagePreviewError => ShowsPlayer && !string.IsNullOrEmpty(PreviewError) ? PreviewError : null;

    /// <summary>The line the transcript's notice carries instead, when the stage shows a stand-in.</summary>
    internal string? TranscriptPreviewError => !ShowsPlayer && !string.IsNullOrEmpty(PreviewError) ? PreviewError : null;

    /// <summary>Raised whenever the line changes, so the page shows or hides the plate.</summary>
    internal event EventHandler? Changed;

    /// <summary>The preview's compositor failed a frame or left an overlay out: logged by its fixed tag, never user text or a path, shown
    /// and announced once. The engine reports each loaded preview's first reason only, so this runs once per load.</summary>
    internal void CompositorFailed(PreviewFailureReason reason)
    {
        log(LogLevel.Error, Category, "compositor reason=" + reason.Tag());
        var message = Message(reason);
        PreviewError = message;
        Changed?.Invoke(this, EventArgs.Empty);
        announce(message);
    }

    /// <summary>A load that fails with a compositor reason shows that reason's line; the safe error line otherwise (§13).</summary>
    internal void LoadFailed(Exception exception, string safeLine)
    {
        if (PreviewFailureReasons.Of(exception) is { } reason)
        {
            if (PreviewError is null) CompositorFailed(reason);
            return;
        }
        PreviewError = safeLine;
        Changed?.Invoke(this, EventArgs.Empty);
        announce(safeLine);
    }

    /// <summary>Reload Preview, or any load that works: the line is cleared.</summary>
    internal void Cleared()
    {
        if (PreviewError is null) return;
        PreviewError = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The display held a ready preview without showing a frame and was re-attached once (Mac <c>previewDisplayStalled</c>).</summary>
    internal void DisplayStalled() => log(LogLevel.Error, Category, DisplayStalledLine);

    /// <summary>The stage's line for a compositor failure (design.md §13 "Stage, preview failed").</summary>
    internal static string Message(PreviewFailureReason reason) => reason switch
    {
        PreviewFailureReason.CaptionLayout or PreviewFailureReason.CaptionRaster or PreviewFailureReason.Resources
            => "Captions couldn't be drawn, so the preview plays without them.",
        PreviewFailureReason.Title => "The title couldn't be drawn, so the preview plays without it.",
        PreviewFailureReason.Disclosure => "The AI voice label couldn't be drawn, so the preview stopped.",
        _ => "The preview couldn't draw the video."
    };
}

/// <summary>The display side of a black stage (Mac <c>PlayerDisplayWatch</c>): the preview is ready but the stage's image has shown no
/// frame for <see cref="Limit"/> ticks while on screen. Answers true once per item, when the image should be re-attached and the stall
/// logged. Items are held weakly, so a new item that reuses nothing of a freed one still gets its own chance.</summary>
internal struct PlayerDisplayWatch
{
    /// <summary>Ticks (one a second) before a stall is handled.</summary>
    internal const int Limit = 4;
    private WeakReference<object>? handled;
    private WeakReference<object>? counting;

    /// <summary>Whether the handled item is still alive; a freed one is never mistaken for a new item.</summary>
    internal readonly bool HandledIsAlive => handled is not null && handled.TryGetTarget(out _);

    /// <summary>Consecutive stalled ticks of the item being counted.</summary>
    internal int StalledTicks { get; private set; }

    /// <summary>One tick: true when <paramref name="item"/> has been ready without a frame on screen for <see cref="Limit"/> ticks and
    /// wasn't handled before.</summary>
    internal bool Tick(object? item, bool itemReady, bool layerReady, bool inWindow)
    {
        if (!inWindow || item is null || !itemReady || layerReady) { StalledTicks = 0; return false; }
        if (!Is(counting, item)) { counting = new(item); StalledTicks = 0; }
        StalledTicks++;
        if (StalledTicks < Limit || Is(handled, item)) return false;
        handled = new(item); StalledTicks = 0;
        return true;
    }

    private static bool Is(WeakReference<object>? reference, object item) => reference is not null && reference.TryGetTarget(out var target) && ReferenceEquals(target, item);
}
