using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.App.Controls;

internal static class RecordingShortcutRow
{
    internal static Button Action(string title, Action action, string? reason)
    {
        var button = Ui.Button(title, action);
        button.IsEnabled = reason is null;
        AutomationProperties.SetHelpText(button, reason ?? "");
        return button;
    }

    internal static string Time(EditorViewModel model, string first, string last, ProjectClock.Region region)
    {
        var offset = (double)region.OffsetSamples / model.RecordingClock!.SampleRate;
        return $"{EditorViewModel.RecordingTime(model.Words[model.Index(first)].Start - offset)}–{EditorViewModel.RecordingTime(model.Words[model.Index(last)].End - offset)}";
    }

    internal static FrameworkElement Solo(EditorViewModel model, TakeMatch.SoloRun run, bool inline,
        Action<RecordingAudition> play, Action<string> locate)
    {
        var region = model.RecordingRegions.First(item => item.Key == run.Key);
        var row = Ui.Stack(4);
        var quote = model.RecordingPlacementQuote(run);
        var after = model.RecordingPlacement(run);
        var anchor = after is null ? -1 : model.Index(after);
        var part = model.ClipParts.FirstOrDefault(part => part.First <= anchor && anchor <= part.Last);
        var reason = model.RecordingSoloDisabledReason(run);
        var editReason = model.CanEditParts ? null : "Editing isn't available right now.";
        var missing = model.RecordingUnavailable(run.Key);
        if (!inline)
        {
            row.Children.Add(RecordingStyle.Label(row, region, $"{region.Label} · {Time(model, run.StartWordId, run.EndWordId, region)}" +
                (run.SentenceCount > 1 ? $" · {run.SentenceCount} sentences" : "")));
            row.Children.Add(Ui.Text(string.Join(" ", model.Words.Skip(model.Index(run.StartWordId))
                .Take(model.Index(run.EndWordId) - model.Index(run.StartWordId) + 1).Select(model.DisplayText))));
        }
        var suffix = !inline && part is not null ? $" in part {part.Number}" : "";
        row.Children.Add(Ui.Text($"only in {region.Label}" + (quote is null ? "" : $" · fits after {quote}{suffix}"), "HelperText"));
        var listen = Action(inline ? "▶" : "▶ Play There", () => { if (model.RecordingSoloAudition(run) is { } audition) play(audition); }, reason);
        AutomationProperties.SetName(listen, "Play There");
        row.Children.Add(listen);
        row.Children.Add(Action("Insert There", () => model.InsertRecordingLine(run), reason ?? editReason));
        if (after is null) row.Children.Add(Action("Insert at End", () => model.InsertRecordingLine(run, atEnd: true), model.RecordingSoloDisabledReason(run, atEnd: true) ?? editReason));
        if (reason is not null || editReason is not null) row.Children.Add(Ui.Text(reason ?? editReason!, "HelperText"));
        if (missing is not null) row.Children.Add(Ui.Button("Locate…", () => locate(run.Key)));
        return row;
    }
}
