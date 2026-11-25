using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.Controls;

internal sealed class DirectorVoiceSteps : UserControl
{
    internal bool ShowsStory { get; }

    internal DirectorVoiceSteps(EditorViewModel editor)
    {
        var body = Ui.Stack(12); body.Margin = new(16, 12, 16, 12);
        Content = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        if (editor.IsStoryClip)
        {
            ShowsStory = true;
            VoiceLabPriceCatalog? prices = null;
            try { prices = VoiceLabPrices.Load(App.Services.SharedRoot); }
            catch (VoxClipException) { }
            AddStoryActions(body, editor, prices);
            return;
        }
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
    }

    private void AddStoryActions(StackPanel body, EditorViewModel editor, VoiceLabPriceCatalog? prices)
    {
        var rewrite = new Button { Content = "Rewrite as ▾", IsEnabled = false };
        var revoice = new Button { IsEnabled = false };
        var lipSync = new Button { IsEnabled = false };
        var makePart = Ui.Button("Make Clip of Part 1", () => editor.MakeClipsOfParts(editor.SelectedPart?.Id));
        var makeAll = Ui.Button("Make Clips of All Parts", () => editor.MakeClipsOfParts());
        var lipSyncReason = Ui.Text("", "HelperText");
        body.Children.Add(rewrite);
        body.Children.Add(Ui.Text(EditorViewModel.StoryRewriteReason, "HelperText"));
        body.Children.Add(lipSync);
        body.Children.Add(revoice);
        body.Children.Add(lipSyncReason);
        body.Children.Add(makePart); body.Children.Add(makeAll);
        body.Children.Add(Ui.Text("Phrases you already revoiced still play in their parts.", "HelperText"));
        AutomationProperties.SetHelpText(rewrite, EditorViewModel.StoryRewriteReason);

        void Update(object? sender, EventArgs args)
        {
            if (editor.StoryVoice(prices: prices) is not { } story) return;
            revoice.Content = EditorViewModel.StoryVoicePrice("Revoice Whole Clip", story.VoiceAndLipSync);
            lipSync.Content = EditorViewModel.StoryVoicePrice("Lip Sync", story.LipSync);
            lipSyncReason.Text = story.LipSyncReason;
            AutomationProperties.SetHelpText(revoice, story.LipSyncReason);
            AutomationProperties.SetHelpText(lipSync, story.LipSyncReason);
            makePart.Content = story.MakeSelected; makeAll.Content = story.MakeAll;
            makePart.IsEnabled = makeAll.IsEnabled = editor.CanEditParts;
        }
        void PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if (args.PropertyName is nameof(EditorViewModel.Busy) or nameof(EditorViewModel.CanFindClips)) Update(sender, EventArgs.Empty);
        }
        Loaded += (_, _) =>
        {
            editor.Changed += Update; editor.SelectionChanged += Update; editor.PropertyChanged += PropertyChanged;
            Update(this, EventArgs.Empty);
        };
        Unloaded += (_, _) => { editor.Changed -= Update; editor.SelectionChanged -= Update; editor.PropertyChanged -= PropertyChanged; };
        Update(this, EventArgs.Empty);
    }
}
