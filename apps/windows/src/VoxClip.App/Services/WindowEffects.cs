using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.System;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.Logging;
using Windows.UI.ViewManagement;

namespace VoxClip.App.Services;

internal sealed class WindowEffects : IDisposable
{
    private readonly AccessibilityMonitor monitor;

    internal WindowEffects(WindowId window, DispatcherQueue dispatcher)
    {
        ThemeSettings? theme = null;
        UISettings? effects = null;
        monitor = new(action => dispatcher.TryEnqueue(() => action()),
            () => new(new(effects!.AnimationsEnabled, effects.AdvancedEffectsEnabled, theme!.HighContrast), theme.HighContrastScheme),
            Ui.SetEffects, Log);
        try
        {
            theme = ThemeSettings.CreateForWindowId(window);
            effects = new UISettings();
            monitor.Start(changed =>
            {
                void Handler(ThemeSettings sender, object args) => changed();
                theme.Changed += Handler;
                return () => theme.Changed -= Handler;
            }, changed =>
            {
                void Handler(UISettings sender, object args) => changed();
                effects.AdvancedEffectsEnabledChanged += Handler;
                return () => effects.AdvancedEffectsEnabledChanged -= Handler;
            }, changed =>
            {
                void Handler(UISettings sender, object args) => changed();
                effects.AnimationsEnabledChanged += Handler;
                return () => effects.AnimationsEnabledChanged -= Handler;
            });
        }
        catch (Exception exception) { Log(exception); }
    }

    private static void Log(Exception exception) => StartupDiagnostics.Log.Write(LogLevel.Warn, "accessibility",
        $"window effects unavailable type={exception.GetType().Name} hresult=0x{exception.HResult:X8}");

    public void Dispose() => monitor.Dispose();
}
