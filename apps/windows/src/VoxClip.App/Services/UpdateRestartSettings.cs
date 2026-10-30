namespace VoxClip.App.Services;

internal sealed class UpdateRestartSettings : IUpdateRestartSettings
{
    public Task<RestartPreparation> PrepareAsync() => App.Settings?.PrepareForRestartAsync()
        ?? Task.FromResult(RestartPreparation.Ready);
    public RestartPreparation Freeze() { App.Services.FreezeSettings(); return RestartPreparation.Ready; }

    public Task DrainAsync(CancellationToken ct) => App.Services.DrainSettingsAsync(ct);
    public Task FlushAsync(CancellationToken ct) => App.Services.FlushSettingsAsync(ct);
    public void Resume()
    {
        App.Services.ResumeSettings();
        App.Settings?.ResumeAfterRestart();
    }
}
