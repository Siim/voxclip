using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.App.Pages;

/// <summary>Cut edges in the quiet (editing §5.10, design §6.8 "Cut edges"): the page hands the editor each recording's 10 ms levels
/// as its waveform loads and the Voice Lab folder paid Rewrite proposals are saved in, and keeps the ClipBar's Fix cut edges listed,
/// disabled with its reason. The timeline shows the inline row.</summary>
public sealed partial class EditorPage
{
    private void AttachCutEdges()
    {
        if (!demo) ViewModel.SetCutEdgePaidRoot(Path.Combine(App.Services.Data.Root, "VoiceLab"));
        ViewModel.CutEdgesChanged += CutEdgesChanged;
        UpdateFixCutEdgesCommand();
    }

    private void DetachCutEdges() => ViewModel.CutEdgesChanged -= CutEdgesChanged;

    private void CutEdgesChanged(object? sender, EventArgs args)
    {
        if (!disposed) UpdateFixCutEdgesCommand();
    }

    /// <summary>Fix cut edges is always in the ClipBar's overflow: enabled while old cuts could move into the quiet, otherwise disabled
    /// with "All cut edges are in the quiet", "Waveform still loading" or "Reconnect {recording} to fix its cut edges".</summary>
    private void UpdateFixCutEdgesCommand()
    {
        var enabled = !ViewModel.Busy && !ViewModel.IsLeaving && ViewModel.CanFixCutEdges;
        var reason = ViewModel.FixCutEdgesReason ?? (enabled ? null : "Finish the current task first.");
        FixCutEdgesCommand.IsEnabled = enabled;
        AutomationProperties.SetHelpText(FixCutEdgesCommand, reason ?? "");
        ToolTipService.SetToolTip(FixCutEdgesCommand, reason);
    }

    /// <summary>A recording's levels as the waveform load read them, for the seat; null when the load can't read its video.</summary>
    private async Task LoadCutEdgeLevelsAsync(MediaInfo recording, string key, CancellationTokenSource request)
    {
        AudioEnvelope? levels = recording.Audio is null ? null : await App.Services.Waveform.GetEnvelopeAsync(recording, key, request.Token);
        if (!disposed && !request.IsCancellationRequested && ReferenceEquals(waveformRequest, request)) ViewModel.SetCutEdgeLevels(key, levels);
    }

    /// <summary>A recording whose video can't be read: its cut edges say to reconnect it.</summary>
    private void CutEdgeLevelsUnreadable(string key, CancellationTokenSource request)
    {
        if (!disposed && !request.IsCancellationRequested && ReferenceEquals(waveformRequest, request)) ViewModel.SetCutEdgeLevels(key, null);
    }
}
