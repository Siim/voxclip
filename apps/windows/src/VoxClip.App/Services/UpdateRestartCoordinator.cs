namespace VoxClip.App.Services;

internal enum RestartResult { Dispatched, AlreadyPreparing, Busy, TransitionActive, SaveFailed, Cancelled, SettingsFailed, UpdateFailed }
internal enum RestartPreparation { Ready, Busy, TransitionActive, SaveFailed }

internal interface IUpdateRestartWindow
{
    bool IsBusyForRestart { get; }
    Task<RestartPreparation> PrepareForRestartAsync();
    void ResumeAfterRestart();
}

internal interface IUpdateRestartSettings
{
    RestartPreparation Freeze();
    Task DrainAsync(CancellationToken ct);
    Task FlushAsync(CancellationToken ct);
    void Resume();
}

/// <summary>Runs only on the WinUI thread. Preparation stays active until dispatch returns or fails.</summary>
internal sealed class UpdateRestartCoordinator(Func<IReadOnlyList<IUpdateRestartWindow>> openWindows)
{
    public bool IsPreparing { get; private set; }

    public async Task<RestartResult> RunAsync(IUpdateRestartSettings settings,
        Func<CancellationToken, Task> dispatch, CancellationToken ct)
    {
        if (IsPreparing) return RestartResult.AlreadyPreparing;
        IsPreparing = true; // Set before the first await: activation, close and navigation observe this gate.
        var prepared = new List<IUpdateRestartWindow>();
        try
        {
            ct.ThrowIfCancellationRequested();
            var windows = openWindows();
            if (windows.Any(window => window.IsBusyForRestart)) return RestartResult.Busy;
            RestartPreparation settingsResult;
            try { settingsResult = settings.Freeze(); }
            catch (Exception) { return RestartResult.SettingsFailed; }
            if (settingsResult != RestartPreparation.Ready) return settingsResult switch
            {
                RestartPreparation.Busy => RestartResult.Busy,
                RestartPreparation.TransitionActive => RestartResult.TransitionActive,
                _ => RestartResult.SettingsFailed
            };
            try { await settings.DrainAsync(ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return RestartResult.Cancelled; }
            catch (Exception) { return RestartResult.SettingsFailed; }
            foreach (var window in windows)
            {
                ct.ThrowIfCancellationRequested();
                RestartPreparation result;
                try { result = await window.PrepareForRestartAsync(); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { return RestartResult.Cancelled; }
                catch (Exception) { return RestartResult.SaveFailed; }
                if (result != RestartPreparation.Ready) return result switch
                {
                    RestartPreparation.Busy => RestartResult.Busy,
                    RestartPreparation.TransitionActive => RestartResult.TransitionActive,
                    _ => RestartResult.SaveFailed
                };
                prepared.Add(window);
            }
            ct.ThrowIfCancellationRequested();
            if (windows.Any(window => window.IsBusyForRestart)) return RestartResult.Busy;
            try { await settings.FlushAsync(ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return RestartResult.Cancelled; }
            catch (Exception) { return RestartResult.SettingsFailed; }
            ct.ThrowIfCancellationRequested();
            try { await dispatch(ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return RestartResult.Cancelled; }
            catch (Exception) { return RestartResult.UpdateFailed; }
            return RestartResult.Dispatched;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { return RestartResult.Cancelled; }
        finally
        {
            Exception? resumeFailure = null;
            try
            {
                for (var index = prepared.Count - 1; index >= 0; index--)
                {
                    try { prepared[index].ResumeAfterRestart(); }
                    catch (Exception exception) { resumeFailure ??= exception; }
                }
            }
            finally
            {
                try { settings.Resume(); }
                finally { IsPreparing = false; }
            }
            if (resumeFailure is not null) throw new InvalidOperationException("Could not resume every project after update preparation.", resumeFailure);
        }
    }
}
