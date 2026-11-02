namespace VoxClip.App.ViewModels;

internal enum EditorFocusRegion { Pane, Tabs, CommandBar, Transcript, Viewer, Captions, Timeline, Status }
internal static class FocusCycle
{
    internal static bool RestoreRewriteFocus(bool insidePanel, bool explicitClose, bool disposed) => !disposed && (insidePanel || explicitClose);
    internal static IReadOnlyList<EditorFocusRegion> Regions(bool viewer) => viewer
        ? [EditorFocusRegion.Pane, EditorFocusRegion.Tabs, EditorFocusRegion.CommandBar, EditorFocusRegion.Transcript, EditorFocusRegion.Viewer, EditorFocusRegion.Captions, EditorFocusRegion.Timeline, EditorFocusRegion.Status]
        : [EditorFocusRegion.Pane, EditorFocusRegion.Tabs, EditorFocusRegion.CommandBar, EditorFocusRegion.Transcript, EditorFocusRegion.Timeline, EditorFocusRegion.Status];
    internal static IEnumerable<int> NextIndices(int current, int count, bool reverse)
    {
        if (count <= 0) yield break;
        current = Math.Clamp(current, 0, count - 1);
        for (var tried = 1; tried <= count; tried++) yield return ((current + (reverse ? -tried : tried)) % count + count) % count;
    }
}
internal static class KeyboardHelp
{
    internal static string Text(bool enabled, bool betaNoticeAccepted) => BaseText.Replace("{rewrite}", "Ctrl+R  Rewrite\n", StringComparison.Ordinal);
    private const string BaseText = "Space  Play / pause\nShift+Space  Play from caret\nJ  Back 3 seconds\nK  Stop\nL  Play\nP  Preview This Cut (2 seconds before and after selection)\nDelete / Backspace  Cut or restore selected words\nShift+Backspace  Restore selection\nEnter / C  Correct spelling\nCtrl+Z / Ctrl+Y / Ctrl+Shift+Z  Undo / redo\nCtrl+K  Commands\nCtrl+Alt+K  Make clip\nCtrl+Shift+K  Find clips\n{rewrite}Ctrl+Shift+I  Show or hide viewer\nCtrl+1 / Alt+Left  Home\nCtrl+2  Full take\n[ / ]  Previous / next kept clip\nEscape in transcript  Back to Full take\nCtrl+Enter on suggestion  Keep\nDelete on suggestion  Dismiss\nF2 on kept clip  Rename\nDelete on kept clip  Remove\nI / O  Set clip start / end at caret\nCtrl+Shift+U  Cut fillers\nCtrl+Shift+P  Tighten pauses\nCtrl+Shift+R  Restore cuts\nCtrl+Alt+C  Show cuts\nCtrl+J  Show or hide timeline\nCtrl+B  Show or hide Explorer\nCtrl+Tab / Ctrl+Shift+Tab  Next / previous tab\nCtrl+W  Close tab (Full take: close project)\nCtrl+E  Export\nCtrl+F  Find\nCtrl+= / Ctrl+- / Ctrl+0  Transcript text size\nCtrl+,  Settings\nShift+F10 / Menu  Selection bar\nF6 / Shift+F6  Next / previous region\nCtrl+/ or F1  Keyboard shortcuts\n\nForward 3 seconds is a viewer button, not a key. Editor shortcuts never run while typing in a text field.";
}
