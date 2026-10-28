using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal static class Ui
{
    private static AccessibilitySnapshot snapshot = AccessibilitySnapshot.Default;
    internal static bool HighContrast => snapshot.Effects.HighContrast;
    internal static string HighContrastScheme => snapshot.Scheme;
    /// <summary>Windows "Animation effects": off means Reduce Motion (design §5.4.9).</summary>
    internal static bool AnimationsEnabled => snapshot.Effects.Animations;
    /// <summary>Windows "Transparency effects": off selects the opaque media chips (design §5.4.9).</summary>
    internal static bool TransparencyEnabled => snapshot.Effects.AdvancedEffects;
    internal static AccessibilityEffects EffectPolicy => snapshot.Effects;
    /// <summary>Window-owned system settings changed. Raised on the UI thread.</summary>
    internal static event EventHandler? EffectsChanged;

    internal static void SetEffects(AccessibilitySnapshot value)
    {
        if (snapshot == value) return;
        snapshot = value;
        EffectsChanged?.Invoke(null, EventArgs.Empty);
    }
    internal static void Announce(FrameworkElement owner, string text, string activity)
    {
        if (text.Length == 0) return;
        FrameworkElementAutomationPeer.CreatePeerForElement(owner)?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted,
            AutomationNotificationProcessing.MostRecent, text, activity);
    }
    internal static void ApplyFlyoutEffects(Flyout flyout, FrameworkElement owner)
    {
        flyout.AreOpenCloseAnimationsEnabled = EffectPolicy.Animations;
        if (!EffectPolicy.OpaqueTransientSurfaces) { flyout.FlyoutPresenterStyle = null; return; }
        var style = new Style(typeof(FlyoutPresenter));
        style.Setters.Add(new Setter(Control.BackgroundProperty, ThemeBrush(owner, "VcBgElevatedBrush")));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, ThemeBrush(owner, "VcLineStrongBrush")));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        flyout.FlyoutPresenterStyle = style;
    }
    internal static Brush ThemeBrush(FrameworkElement owner, string key)
    {
        var themeKey = HighContrast ? "HighContrast" : owner.ActualTheme == ElementTheme.Light ? "Light" : "Default";
        foreach (var dictionary in Application.Current.Resources.MergedDictionaries.Reverse())
            if (dictionary.ThemeDictionaries.TryGetValue(themeKey, out var resource) && resource is ResourceDictionary theme && theme.TryGetValue(key, out var value) && value is Brush brush) return brush;
        return (Brush)Application.Current.Resources[key];
    }
    internal static TextBlock Text(string text, string? style = null) => new()
    {
        Text = text, TextWrapping = TextWrapping.Wrap,
        Style = style is null ? null : (Style)Application.Current.Resources[style]
    };
    internal static StackPanel Stack(double spacing = 12) => new() { Spacing = spacing, HorizontalAlignment = HorizontalAlignment.Stretch };
    internal static Button Button(string label, Action action, bool accent = false)
    {
        var button = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Left };
        if (accent) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        AutomationProperties.SetName(button, label);
        button.Click += (_, _) =>
        {
            try { action(); }
            catch (Exception exception) { App.Windows.FirstOrDefault()?.ShowError(exception, label); }
        };
        return button;
    }
    internal static ComboBox Choice(string label, IEnumerable<string> items, int selected = 0)
    {
        var choice = new ComboBox { Header = label, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var item in items) choice.Items.Add(item);
        choice.SelectedIndex = choice.Items.Count == 0 ? -1 : Math.Clamp(selected, 0, choice.Items.Count - 1);
        AutomationProperties.SetName(choice, label);
        return choice;
    }
    internal static RadioButtons Radios(string label, IEnumerable<string> items, int selected = 0)
    {
        var choices = new RadioButtons { Header = label, MaxColumns = 4 };
        foreach (var item in items) choices.Items.Add(item);
        choices.SelectedIndex = selected;
        AutomationProperties.SetName(choices, label);
        return choices;
    }
    internal static InfoBar Notice() => new() { IsOpen = false, IsClosable = true, Severity = InfoBarSeverity.Informational };
    internal static async Task RunAsync(InfoBar notice, Func<Task> action, string feature)
    {
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception exception)
        {
            var message = UiError.Message(exception, feature);
            if (message.Length == 0) return;
            notice.Message = message; notice.Severity = InfoBarSeverity.Error; notice.IsOpen = true;
        }
    }
    internal static void Show(InfoBar notice, string message, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        notice.Message = message; notice.Severity = severity; notice.IsOpen = true;
    }
    internal static async Task<bool> ConfirmAsync(XamlRoot root, string title, string text, string action)
    {
        var dialog = new ContentDialog { XamlRoot = root, Title = title, Content = Text(text), PrimaryButtonText = action, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}
