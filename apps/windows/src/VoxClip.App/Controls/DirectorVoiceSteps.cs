using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal sealed class DirectorVoiceSteps : UserControl
{
    internal DirectorVoiceSteps()
    {
        var body = Ui.Stack(12); body.Margin = new(16, 12, 16, 12);
        body.Children.Add(Ui.Text("Your voice · Beta", "BodyStrongTextBlockStyle"));
        var refusal = new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning,
            Message = VoiceLabCopy.SpeakerUnavailable };
        AutomationProperties.SetAutomationId(refusal, "Voice.WindowsPrerequisite");
        body.Children.Add(refusal);
        body.Children.Add(Ui.Text("The native speaker / ONNX check has not reached Windows parity. No clone, generation, model download or paid request can start here."));
        body.Children.Add(Ui.Text(VoiceLabCopy.ProviderConsent, "HelperText"));
        body.Children.Add(Ui.Text("Your source stays untouched. Local cuts, corrections and captions still work. Insertion, changed-video, non-unity fitting and lip sync are unavailable.", "HelperText"));
        var create = new Button { Content = "Create My Voice · unavailable", IsEnabled = false };
        var generate = new Button { Content = "Generate Takes · unavailable", IsEnabled = false };
        AutomationProperties.SetAutomationId(create, "Voice.CreateBlocked");
        AutomationProperties.SetAutomationId(generate, "Voice.GenerateBlocked");
        body.Children.Add(create); body.Children.Add(generate);
        body.Children.Add(Ui.Button("Voice Lab settings", () => App.OpenSettings("Voice Lab")));
        Content = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
}
