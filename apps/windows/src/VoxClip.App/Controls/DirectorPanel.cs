using Microsoft.UI.Xaml.Controls;

namespace VoxClip.App.Controls;

internal sealed class DirectorPanel : ContentControl
{
    internal DirectorPanel()
    {
        HorizontalContentAlignment = Microsoft.UI.Xaml.HorizontalAlignment.Stretch;
        VerticalContentAlignment = Microsoft.UI.Xaml.VerticalAlignment.Stretch;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(this, "Director.JobHost");
    }
    internal Control? FocusTarget => Microsoft.UI.Xaml.Input.FocusManager.FindFirstFocusableElement(this) as Control;
    internal void Show(object? job) => Content = job;
}
