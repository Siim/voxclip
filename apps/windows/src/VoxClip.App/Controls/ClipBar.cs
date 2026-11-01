using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace VoxClip.App.Controls;

public sealed partial class ClipBar : CommandBar
{
    public ClipBar()
    {
        DefaultLabelPosition = CommandBarDefaultLabelPosition.Right;
        IsDynamicOverflowEnabled = true;
        AutomationProperties.SetName(this, "Clip actions");
    }
}
