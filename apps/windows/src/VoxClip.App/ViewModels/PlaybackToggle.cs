namespace VoxClip.App.ViewModels;

/// <summary>Play/Pause with an inline correction open (design §4.2). Every transport action ends an open correction first,
/// and saving it refreshes the preview, which pauses and resumes playback while it swaps the plan. So Play/Pause reads the
/// playing state from before the save, and after any refresh an edit started has settled: Pause pressed with the field open
/// during playback saves the text and stays paused, as on the Mac (EditorModel.transport).</summary>
internal sealed class PlaybackToggle
{
    private Task refresh = Task.CompletedTask;

    /// <summary>The preview refresh an edit started. A toggle waits for it, so it never reads the paused state the refresh
    /// shows while it swaps the plan.</summary>
    internal void Refreshing(Task update) => refresh = update;

    /// <summary>Whether Play/Pause pauses: true when <paramref name="playing"/> reads true once the last refresh has settled
    /// and before the open correction, if any, is saved; the correction is then ended and saved.</summary>
    internal async Task<bool> PausesAsync(EditorViewModel model, Func<bool> playing)
    {
        await SettleAsync();
        var wasPlaying = playing();
        await EndCorrectionAsync(model);
        return wasPlaying;
    }
    /// <summary>Finish the save and the preview refresh before a transport command is issued.</summary>
    internal async Task EndCorrectionAsync(EditorViewModel model)
    {
        model.EndCorrection();
        await SettleAsync();
    }

    private async Task SettleAsync()
    {
        Task pending;
        do { pending = refresh; await pending; } while (!ReferenceEquals(pending, refresh));
    }
}
