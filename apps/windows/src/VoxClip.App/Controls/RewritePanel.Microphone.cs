using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

/// <summary>The Say it myself segment of a phrase card (design.md §6.3.8, voice-lab.md §8.13; Mac <c>PhraseMicrophoneRow</c>,
/// <c>OwnTakeRow</c>), inline: [● Record] with the words to say, the level meter, time against the gap and [Stop] while recording,
/// then each own take's line with Play, [Use your take] (or Use anyway) and [Record again]. Denied access shows its guidance with a
/// Settings link; with no microphone, Record is hidden. No dialogs.</summary>
internal sealed partial class RewritePanel
{
    private readonly StackPanel microphoneBox = Ui.Stack(6);

    private void BuildMicrophone() => AutomationProperties.SetAutomationId(microphoneBox, "Rewrite.Microphone");

    private void RenderMicrophone(RewriteGeneration generation, int index, bool shown)
    {
        microphoneBox.Children.Clear();
        microphoneBox.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (!shown) return;
        if (session.PhraseMicrophone is not { } microphone)
        {
            microphoneBox.Children.Add(Wrapped(PhraseMicrophoneCopy.NoMicrophone));
            return;
        }
        var active = microphone.Phrase == index;
        var busy = generation.IsRunning || session.IsGeneratingBatch;
        if (active && microphone.State is RewritePhraseMicrophone.MicrophoneState.Recording or RewritePhraseMicrophone.MicrophoneState.Cueing)
            microphoneBox.Children.Add(RecordingRow(microphone, index));
        else if (active && microphone.State == RewritePhraseMicrophone.MicrophoneState.Checking)
            microphoneBox.Children.Add(Wrapped("Checking your take on this PC…"));
        else if (microphone.Access == PhraseMicrophoneAccess.NoMicrophone)
            microphoneBox.Children.Add(Wrapped(PhraseMicrophoneCopy.NoMicrophone));
        else if (microphone.Access == PhraseMicrophoneAccess.Denied)
        {
            microphoneBox.Children.Add(Themed(Wrapped(PhraseMicrophoneCopy.Denied), TextBlock.ForegroundProperty, "VcStatusWarningBrush"));
            var settings = new HyperlinkButton { Content = PhraseMicrophoneCopy.OpenSettings, NavigateUri = new Uri(VoiceLabCopy.MicrophoneSettingsUri) };
            AutomationProperties.SetAutomationId(settings, "Rewrite.MicrophoneSettings");
            microphoneBox.Children.Add(settings);
        }
        else if (!busy && microphone.State == RewritePhraseMicrophone.MicrophoneState.Idle)
        {
            var again = microphone.LastTake(index) is { } last && generation.Rows.Any(row => row.Id == last);
            var title = again ? "Record again" : "● Record";
            var record = Ui.Button(title, () => _ = session.RecordPhraseAsync(index));
            AutomationProperties.SetAutomationId(record, "Rewrite.MicrophoneRecord");
            SetName(record, again ? $"Record phrase {index + 1} again" : $"Record phrase {index + 1}");
            ToolTipService.SetToolTip(record, "Say the phrase in your own voice. It stops by itself at the gap plus 1.5 s.");
            microphoneBox.Children.Add(record);
            var say = Themed(Wrapped($"Say: “{session.CurrentWording(index)}”"), TextBlock.ForegroundProperty, "VcTextTertiaryBrush");
            AutomationProperties.SetAutomationId(say, "Rewrite.MicrophoneSay");
            microphoneBox.Children.Add(say);
        }
        if (active && microphone.Problem.Length > 0)
        {
            var problem = Themed(Wrapped(microphone.Problem), TextBlock.ForegroundProperty, "VcStatusWarningBrush");
            AutomationProperties.SetAutomationId(problem, "Rewrite.MicrophoneProblem");
            microphoneBox.Children.Add(problem);
        }
        foreach (var row in generation.Rows.Where(row => generation.IsRecorded(row.Id)))
            microphoneBox.Children.Add(OwnTakeRow(generation, microphone, index, row, busy));
        var next = Themed(Wrapped(PhraseWordingCopy.MicrophoneFooter), TextBlock.ForegroundProperty, "VcTextTertiaryBrush");
        AutomationProperties.SetAutomationId(next, "Rewrite.MicrophoneNext");
        microphoneBox.Children.Add(next);
    }

    private UIElement RecordingRow(RewritePhraseMicrophone microphone, int index)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        SetName(row, $"Recording phrase {index + 1}");
        AutomationProperties.SetAutomationId(row, "Rewrite.MicrophoneRecording");
        row.Children.Add(Themed(new Ellipse { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center }, Shape.FillProperty, "VcStatusErrorBrush"));
        var meter = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 1, Height = 18, Width = 120, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(meter, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        foreach (var level in microphone.Levels.TakeLast(60))
            meter.Children.Add(Themed(new Rectangle { Width = 1, Height = Math.Max(1, level * 18), VerticalAlignment = VerticalAlignment.Center },
                Shape.FillProperty, "VcTextSecondaryBrush"));
        row.Children.Add(meter);
        var time = Small(microphone.State == RewritePhraseMicrophone.MicrophoneState.Cueing ? "Get ready…"
            : $"{PhraseMicrophoneCopy.Seconds(microphone.Seconds)} / gap {PhraseMicrophoneCopy.Seconds(microphone.Limit - RewritePhraseMicrophone.ExtraSeconds)}");
        time.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(time, "Rewrite.MicrophoneTime");
        row.Children.Add(time);
        // Stop shows once recording starts; during the count-in or lead-in it could not act yet.
        if (microphone.State == RewritePhraseMicrophone.MicrophoneState.Recording)
        {
            var stop = Ui.Button("Stop", () => _ = session.StopPhraseRecordingAsync());
            AutomationProperties.SetAutomationId(stop, "Rewrite.MicrophoneStop"); SetName(stop, $"Stop recording phrase {index + 1}");
            row.Children.Add(stop);
        }
        return row;
    }

    /// <summary>One of the user's own takes: "Your take · “recognized words” · fits 1.4 s ✓ · free", with Play, [Use your take] (or Use
    /// anyway) and [Record again]; a misfit shows its measured length and Record again.</summary>
    private UIElement OwnTakeRow(RewriteGeneration generation, RewritePhraseMicrophone microphone, int index, Core.Domain.VoiceLab.VoiceLabTakeRow row, bool busy)
    {
        var box = Ui.Stack(4);
        var words = generation.RecordedTake(row.Id)?.Text ?? "";
        var carried = generation.DurationAvailable(row);
        var line = RewritePhraseMicrophone.TakeLine(row, words, generation.Slot(row) ?? 0, generation.LengthFits(row), carried);
        var text = Themed(Wrapped(line, small: false), TextBlock.ForegroundProperty, row.Selectable && carried ? "VcTextPrimaryBrush" : "VcStatusWarningBrush");
        AutomationProperties.SetAutomationId(text, "Rewrite.OwnTake" + (row.Index + 1));
        box.Children.Add(text);
        if (busy || microphone.State != RewritePhraseMicrophone.MicrophoneState.Idle) return box;
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var playing = generation.Audition is { IsPlaying: true } audition && audition.TakeId == row.Id;
        var play = Ui.Button(playing ? "Pause" : "Play", () => _ = generation.PlayTakeAsync(row.Id));
        AutomationProperties.SetAutomationId(play, "Rewrite.OwnTakePlay" + (row.Index + 1)); SetName(play, (playing ? "Pause" : "Play") + " your take");
        play.IsEnabled = generation.CanPlayTake(row.Id);
        actions.Children.Add(play);
        if (generation.SelectedTakeId != row.Id && row.Selectable && carried)
        {
            var title = row.RequiresJoinAdvisoryAcceptance || !generation.LengthFits(row) ? "Use anyway" : "Use your take";
            var use = Ui.Button(title, () => _ = row.RequiresJoinAdvisoryAcceptance ? generation.UseTakeAnywayAsync(row.Id) : generation.SelectTakeAsync(row.Id));
            AutomationProperties.SetAutomationId(use, "Rewrite.OwnTakeUse" + (row.Index + 1)); SetName(use, title + " for phrase " + (index + 1));
            actions.Children.Add(use);
        }
        if (microphone.Access == PhraseMicrophoneAccess.Allowed)
        {
            var again = Ui.Button("Record again", () => _ = session.RecordPhraseAsync(index));
            AutomationProperties.SetAutomationId(again, "Rewrite.OwnTakeAgain" + (row.Index + 1)); SetName(again, $"Record phrase {index + 1} again");
            actions.Children.Add(again);
        }
        box.Children.Add(actions);
        return box;
    }
}
