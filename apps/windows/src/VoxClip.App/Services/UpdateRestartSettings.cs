namespace VoxClip.App.Services;

internal sealed class UpdateRestartSettings : IUpdateRestartSettings
{
    public RestartPreparation Freeze()
    {
        var result = App.Settings?.PrepareForRestart() ?? RestartPreparation.Ready;
        if (result == RestartPreparation.Ready) App.Services.FreezeSettings();
        return result;
    }

    public Task DrainAsync(CancellationToken ct) => App.Services.DrainSettingsAsync(ct);
    public Task FlushAsync(CancellationToken ct) => App.Services.FlushSettingsAsync(ct);
    public void Resume()
    {
        App.Services.ResumeSettings();
        App.Settings?.ResumeAfterRestart();
    }
}
