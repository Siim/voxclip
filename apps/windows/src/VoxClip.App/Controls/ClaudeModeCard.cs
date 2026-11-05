using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App.Controls;

/// <summary>Claude mode's cards above the clip list (design §6.6, §6.7), twin of the Mac <c>ClipsModeCard</c> and <c>ClaudeModeCard</c>:
/// A "Who makes the clips?" (asked once), the blocked card with its one fix, C while Claude makes the clips (steps, progress, Stop,
/// and Continue · $x at the cap), and D once they are ready (Export all, Review). Inline, never a dialog.</summary>
internal sealed class ClaudeModeCard : Grid
{
    private static double Token(string key) => (double)Application.Current.Resources[key];

    internal ClaudeModeCard()
    {
        Padding = new Thickness(Token("VcSpacingCardPadding"));
        Margin = new Thickness(Token("VcSpacingRowGap"), Token("VcSpacingLabelGap"), Token("VcSpacingRowGap"), Token("VcSpacingLabelGap"));
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        Loaded += (_, _) => { Background = Ui.ThemeBrush(this, "VcBgSurfaceBrush"); BorderBrush = Ui.ThemeBrush(this, "VcAccentTextBrush"); };
        AutomationProperties.SetAutomationId(this, "ClaudeMode.Card");
    }

    /// <summary>True when there is a card to show for <paramref name="editor"/>.</summary>
    internal static bool Shows(EditorViewModel editor) => editor.ShowsClipsModeCard || editor.ShowsClaudeModeCard;

    internal void Show(EditorViewModel editor)
    {
        var stack = Ui.Stack(Token("VcSpacingRowGap"));
        if (editor.ShowsClipsModeCard) Choose(stack, editor);
        else if (editor.ClaudeMode.Phase == ClaudeModePhase.Blocked && editor.ClaudeMode.Blocker is { } blocker) Blocked(stack, editor, blocker);
        else if (editor.ClaudeMode.Phase is ClaudeModePhase.Done or ClaudeModePhase.Stopped) Finished(stack, editor);
        else Running(stack, editor);
        Children.Clear();
        Children.Add(stack);
    }

    // A: who makes the clips.
    private static void Choose(StackPanel stack, EditorViewModel editor)
    {
        AutomationProperties.SetName(stack, "Who makes the clips?");
        stack.Children.Add(Heading("Who makes the clips?"));
        stack.Children.Add(Wrapped("✦ Claude does it all: every new video, best moments, cuts, rewording in your voice, captions and shape. You review and Export."));
        stack.Children.Add(Secondary(editor.ClaudeModeMeta));
        stack.Children.Add(Wrapped("I'll pick: Claude suggests clips; you press ✦ Make it postable on the ones you want."));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Token("VcSpacingRowGap") };
        var claude = Ui.Button(editor.ClaudeModeButtonTitle, () => _ = editor.ChooseClipsModeAsync(ClipsMode.Claude), accent: true);
        AutomationProperties.SetAutomationId(claude, "ClipsMode.Claude");
        var pick = Ui.Button("I'll pick", () => _ = editor.ChooseClipsModeAsync(ClipsMode.Pick));
        AutomationProperties.SetAutomationId(pick, "ClipsMode.Pick");
        buttons.Children.Add(claude); buttons.Children.Add(pick);
        stack.Children.Add(buttons);
        stack.Children.Add(Secondary("Next: choose one. Change it any time: the status bar's mode item, or Settings › Clips."));
    }

    private static void Blocked(StackPanel stack, EditorViewModel editor, ClaudeModeBlocker blocker)
    {
        AutomationProperties.SetName(stack, "Claude does it all");
        stack.Children.Add(Heading("✦ Claude does it all"));
        stack.Children.Add(Wrapped(blocker.Reason));
        var fix = Ui.Button(blocker.Action, editor.FixClaudeModeBlocker, accent: true);
        AutomationProperties.SetAutomationId(fix, "ClaudeMode.Fix");
        stack.Children.Add(fix);
        stack.Children.Add(Secondary("Next: " + blocker.Action.TrimEnd('…') + "."));
    }

    // C: running by itself.
    private static void Running(StackPanel stack, EditorViewModel editor)
    {
        AutomationProperties.SetName(stack, "Claude does it all");
        var header = new Grid { ColumnSpacing = Token("VcSpacingRowGap") };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Heading(editor.ClaudeModeTitle));
        if (editor.ClaudeMode.Running)
        {
            var stop = Ui.Button("Stop", editor.StopClaudeMode);
            AutomationProperties.SetAutomationId(stop, "ClaudeMode.Stop");
            Grid.SetColumn(stop, 1);
            header.Children.Add(stop);
        }
        stack.Children.Add(header);
        foreach (var step in editor.ClaudeModeSteps) stack.Children.Add(Step(step));
        if (editor.ClaudeMode.Running)
        {
            var bar = new ProgressBar { Minimum = 0, Maximum = 100, Value = editor.ClaudeModeProgress * 100 };
            AutomationProperties.SetName(bar, "Progress");
            stack.Children.Add(bar);
        }
        if (editor.ClaudeMode.Budget?.Needed is { } needed)
        {
            stack.Children.Add(Wrapped("Needs about " + MakeItController.Dollars(needed) + " more"));
            var go = Ui.Button("Continue · " + MakeItController.Dollars(needed), editor.ContinueClaudeMode, accent: true);
            AutomationProperties.SetAutomationId(go, "ClaudeMode.Continue");
            stack.Children.Add(go);
            stack.Children.Add(Secondary($"Continue approves exactly {MakeItController.Dollars(needed)} more for voice on this video."));
        }
        stack.Children.Add(Secondary(editor.ClaudeModeFooter));
    }

    // D: done or stopped.
    private static void Finished(StackPanel stack, EditorViewModel editor)
    {
        AutomationProperties.SetName(stack, "Claude does it all");
        stack.Children.Add(Heading(editor.ClaudeModeDoneTitle));
        foreach (var step in editor.ClaudeModeSteps.Where(step => step.Id is not ("transcribed" or "found"))) stack.Children.Add(Step(step));
        stack.Children.Add(Secondary(editor.ClaudeModeSummary));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Token("VcSpacingRowGap") };
        if (editor.ClaudeModeReady.Count > 0)
        {
            var export = Ui.Button(editor.ClaudeExportAllTitle, () => _ = editor.ClaudeExportAllAsync(), accent: true);
            export.IsEnabled = editor.CanClaudeExportAll;
            AutomationProperties.SetAutomationId(export, "ClaudeMode.ExportAll");
            buttons.Children.Add(export);
        }
        if (editor.ClaudeModeRuns.Count > 0)
        {
            var review = Ui.Button("Review", editor.ReviewClaudeMode);
            AutomationProperties.SetAutomationId(review, "ClaudeMode.Review");
            buttons.Children.Add(review);
        }
        stack.Children.Add(buttons);
        if (editor.ClaudeExporting) stack.Children.Add(new ProgressBar { IsIndeterminate = true });
        foreach (var problem in editor.ClaudeExportProblems) stack.Children.Add(Wrapped("⚠ " + problem));
        stack.Children.Add(Secondary(editor.ClaudeModeNextStep));
    }

    private static FrameworkElement Step(ClaudeModeStep step)
    {
        var glyph = step.State switch { ClaudeModeStepState.Done => "✓", ClaudeModeStepState.Now => "✦", ClaudeModeStepState.Todo => "○", _ => "!" };
        var text = Wrapped($"{glyph} {step.Text}" + (step.Detail.Length > 0 ? " · " + step.Detail : ""));
        AutomationProperties.SetAutomationId(text, "ClaudeMode.Step." + step.Id);
        return text;
    }

    private static TextBlock Heading(string text)
    {
        var block = Ui.Text(text, "BodyStrongTextBlockStyle");
        block.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetHeadingLevel(block, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level3);
        return block;
    }

    private static TextBlock Wrapped(string text)
    {
        var block = Ui.Text(text);
        block.TextWrapping = TextWrapping.Wrap;
        return block;
    }

    private static TextBlock Secondary(string text)
    {
        var block = Ui.Text(text, "CaptionTextBlockStyle");
        block.TextWrapping = TextWrapping.Wrap;
        return block;
    }
}
