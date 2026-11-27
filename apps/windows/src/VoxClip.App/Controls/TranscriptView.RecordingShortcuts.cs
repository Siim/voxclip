using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using Windows.System;
using Windows.UI.Text;

namespace VoxClip.App.Controls;

public sealed partial class TranscriptView
{
    internal Action<RecordingAudition>? RecordingAuditionRequested { get; set; }
    internal Action? StopRecordingAuditionRequested { get; set; }
    internal Action<string>? LocateRecordingRequested { get; set; }
    internal Func<string?>? TranscribingRecordingLabel { get; set; }
    private Button? recordingFoldClose;
    private Button? recordingReturnMarker;
    private string? recordingReturnLine;

    internal bool OtherRecordingVersionsAvailable(bool fromTimeline) => model?.RecordingVersionTarget(fromTimeline) is not null;

    internal bool ShowOtherRecordingVersions(bool fromTimeline)
    {
        if (model is null || CorrectionOpen || InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot))) return false;
        return model.RecordingVersionTarget(fromTimeline) is { } line && ShowRecordingVersions(line);
    }

    private bool ShowRecordingVersions(RecordingClipLine line)
    {
        if (model is null || !model.OpenRecordingVersions(line)) return false;
        recordingReturnLine = line.Id;
        recordingReturnMarker = null;
        recordingFoldClose = null;
        RebuildRealized();
        RevealWord(model.Index(line.LastId));
        DispatcherQueue.TryEnqueue(() => recordingFoldClose?.Focus(FocusState.Programmatic));
        return true;
    }

    private void CloseRecordingVersions()
    {
        model?.HandleRecordingVersionKey(RecordingVersionKey.Close, _ => { }, () => StopRecordingAuditionRequested?.Invoke());
        RebuildRealized();
        if (recordingReturnMarker?.Focus(FocusState.Programmatic) != true) Focus(FocusState.Programmatic);
    }

    private void UseRecordingVersion(RecordingClipLine line, string key)
    {
        if (model is null) return;
        var first = line.Span(key)?.StartWordId;
        if (!model.UseRecordingLineVersion(line, key) || first is null) return;
        StopRecordingAuditionRequested?.Invoke();
        RevealWord(model.Index(first));
        Focus(FocusState.Programmatic);
    }

    private void AddRecordingLineMarker(Paragraph paragraph, RecordingClipLine line)
    {
        var marker = Ui.Button($"⇄ {line.Alternatives.Count}", () => ShowRecordingVersions(line));
        if (recordingReturnLine == line.Id) recordingReturnMarker = marker;
        AutomationProperties.SetName(marker, model!.RecordingVersionsName(line));
        AutomationProperties.SetAcceleratorKey(marker, ShortcutPolicy.RecordingVersionsGesture);
        ToolTipService.SetToolTip(marker, "Show Other Versions of This Line (Ctrl+Shift+Y)");
        paragraph.Inlines.Add(new InlineUIContainer { Child = marker });
        paragraph.Inlines.Add(new Run { Text = "\u200b" });
    }

    private FrameworkElement RecordingVersionFold(RecordingClipLine line, double width)
    {
        var current = model!;
        var host = Ui.Stack(6);
        host.MaxWidth = width > 100 ? Math.Min(width - 16, 480) : 320;
        var count = line.Alternatives.Count;
        var heading = Ui.Text($"Line {line.Number} · {count} other version{(count == 1 ? "" : "s")}");
        heading.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        host.Children.Add(heading);
        var close = Ui.Button("Close Other Versions", CloseRecordingVersions);
        recordingFoldClose = close;
        host.Children.Add(close);
        var rows = new Dictionary<string, Border>();
        foreach (var take in new[] { line.Take }.Concat(line.Alternatives))
        {
            var region = current.RecordingRegions.First(item => item.Key == take.Key);
            var inClip = take.Key == line.Take.Key;
            var span = line.Span(take.Key);
            var reason = current.RecordingLineDisabledReason(line, take.Key);
            var editReason = !inClip && !current.CanEditParts ? "Editing isn't available right now." : null;
            var copy = reason is null && !inClip ? current.RecordingLineCopyReason(line, take.Key) : null;
            var row = Ui.Stack(3);
            var time = RecordingShortcutRow.Time(current, take.StartWordId, take.EndWordId, region);
            row.Children.Add(RecordingStyle.Label(host, region, $"{region.Label} · {time}" + (inClip ? $" · In {current.ActiveClipLabel}" : "")));
            var words = Ui.Text("");
            var first = current.Index(inClip ? line.FirstId : take.StartWordId);
            var last = current.Index(inClip ? line.LastId : take.EndWordId);
            var end = span is null ? last : current.Index(span.EndWordId);
            for (var index = first; index >= 0 && index <= last; index++)
            {
                var word = current.Words[index];
                words.Inlines.Add(new Run { Text = (index == first ? "" : " ") + current.DisplayText(word), TextDecorations = index > end
                    ? TextDecorations.Strikethrough : span?.ChangedWordIds.Contains(word.Id) == true ? TextDecorations.Underline : TextDecorations.None });
            }
            row.Children.Add(words);
            var signals = take.Signals;
            row.Children.Add(Ui.Text(FormattableString.Invariant($"{signals.Fillers} fillers · longest pause {signals.LongestPause:0.0} s · {Math.Round(signals.WordsPerMinute)} wpm"), "HelperText"));
            if (end >= 0 && end < last) row.Children.Add(Ui.Text($"Brings in only the words that line up, up to “{current.DisplayText(current.Words[end])}”.", "HelperText"));
            row.Children.Add(RecordingShortcutRow.Action("▶ Play in Place", () =>
            {
                current.SelectRecordingVersion(take.Key);
                PaintSelection();
                if (current.RecordingLineAudition(line, take.Key) is { } audition) RecordingAuditionRequested?.Invoke(audition);
            }, reason));
            if (!inClip) row.Children.Add(RecordingShortcutRow.Action(copy is null ? "Use This Version" : "Use in a Copy", () => UseRecordingVersion(line, take.Key),
                reason ?? editReason));
            if (copy is not null) row.Children.Add(Ui.Text(copy, "HelperText"));
            if ((reason ?? editReason) is { } disabled) row.Children.Add(Ui.Text(disabled, "HelperText"));
            if (current.RecordingUnavailable(take.Key) is not null)
                row.Children.Add(Ui.Button("Locate…", () => LocateRecordingRequested?.Invoke(take.Key)));
            var border = new Border { Child = row, Padding = new(6), CornerRadius = new(4) };
            rows.Add(take.Key, border);
            host.Children.Add(border);
        }
        if (TranscribingRecordingLabel?.Invoke() is { } pending)
            host.Children.Add(Ui.Text($"{pending}'s version of this line shows when transcribing finishes.", "HelperText"));
        PaintSelection();
        host.PreviewKeyDown += (_, args) =>
        {
            var focused = FocusManager.GetFocusedElement(XamlRoot);
            var modifier = InputState.Down(VirtualKey.Control) || InputState.Down(VirtualKey.Menu) || InputState.Down(VirtualKey.Shift);
            if (ShortcutPolicy.RecordingFoldKey(args.Key.ToString(), InputState.IsTextFocus(focused), CorrectionOpen, modifier) is not { } key) return;
            if (key == RecordingVersionKey.Close) CloseRecordingVersions();
            else if (key == RecordingVersionKey.Use && current.SelectedRecordingVersionKey is { } selected) UseRecordingVersion(line, selected);
            else current.HandleRecordingVersionKey(key, audition => RecordingAuditionRequested?.Invoke(audition), () => StopRecordingAuditionRequested?.Invoke());
            PaintSelection();
            args.Handled = true;
        };
        AutomationProperties.SetName(host, current.RecordingVersionsName(line));
        return host;

        void PaintSelection()
        {
            foreach (var (key, row) in rows)
            {
                var selected = key == current.SelectedRecordingVersionKey;
                row.Background = selected ? Brush("VcBgInputBrush") : null;
                AutomationProperties.SetItemStatus(row, selected ? "Selected" : "");
            }
        }
    }
}
