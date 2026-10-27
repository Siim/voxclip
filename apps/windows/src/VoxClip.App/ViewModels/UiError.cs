using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

public static class UiError
{
    public static string Message(Exception exception, string action)
    {
        if (exception is OperationCanceledException) return "";
        if (exception is VoiceLabProjectException voice)
            return voice.Code switch
            {
                VoiceLabProjectErrorCode.UnsupportedRendering or VoiceLabProjectErrorCode.NeedsVoiceLabUpgrade =>
                    "This Voice Lab project needs a reviewed v3 render recipe before preview or export. Your video and edits are still here.",
                VoiceLabProjectErrorCode.VideoModeUnsupported =>
                    "This Voice Lab video timing or mode is not supported in this build. Your generated audio and edits are saved.",
                VoiceLabProjectErrorCode.UnsupportedAssetFormat =>
                    "This Windows build cannot read this generated audio format. Keep the paid file for a supported build.",
                VoiceLabProjectErrorCode.CleanAudioUnsupported =>
                    "This Voice Lab Clean audio edit cannot be rendered in this build. Your video and edits are saved.",
                VoiceLabProjectErrorCode.StaleRenderContract =>
                    "The Voice Lab preview or export request changed. Rebuild it from the current project and try again.",
                _ => "This Voice Lab render recipe cannot be used here (" + voice.Code + "). Your generated audio and edits are saved."
            };
        if (exception is VoiceLabAssetException or VoiceLabTempoException) return exception.Message;
        if (exception is MediaException media) return $"{action} stopped while {media.Operation} ({media.NativeError}). Your edits are saved.";
        if (exception is VoxClipException known)
        {
            return known.Code switch
            {
                VoxClipErrorCode.NotImplemented => $"{action} isn't available in this development build. Your video and edits are still here.",
                VoxClipErrorCode.EverythingCut => "Keep at least one word before exporting.",
                VoxClipErrorCode.NoAudioTrack => "This video has no audio track, so there is nothing to transcribe.",
                VoxClipErrorCode.NoSpeech => "We didn't hear any words. Check the audio track or choose the language.",
                VoxClipErrorCode.Offline => "You're offline. On-device transcription and editing still work.",
                VoxClipErrorCode.EncoderUnavailable => "No H.264 encoder is available on this PC. Install the Media Feature Pack or update your graphics driver.",
                VoxClipErrorCode.ProjectTooNew => "This project was saved by a newer VoxClip. Update VoxClip to open it. Your video and edits are still here.",
                VoxClipErrorCode.SharedResourcesMissing => "VoxClip is missing some of its files. Reinstall VoxClip. Your video and edits are still here.",
                _ => string.IsNullOrWhiteSpace(known.Message) ? $"{action} stopped. Your video and edits are still here. Try again." : known.Message
            };
        }
        // Core's AI messages already end "Your edits are saved." (architecture §10.1 rule 1); never say it twice.
        if (exception is LlmException llm) return llm.Error.Kind == LlmErrorKind.Cancelled ? ""
            : llm.Error.UserMessage.EndsWith("Your edits are saved.", StringComparison.Ordinal) ? llm.Error.UserMessage : llm.Error.UserMessage + " Your edits are saved.";
        if (exception is IOException or UnauthorizedAccessException) return $"{action} couldn't access the file. Your video and edits are still here.";
        return $"{action} stopped. Your video and edits are still here. Try again.";
    }
}

public static class ShortcutPolicy
{
    public static bool EditorMayHandle(bool textFocus, bool correctionOpen, bool control, bool alt, bool editorFocus) =>
        editorFocus && !textFocus && !correctionOpen && !alt;

    /// <summary>The editor shortcuts that also act while focus is in the sidebar pane (design §11.1), written as gestures. The
    /// window forwards them to the attached editor; single-letter keys stay with the editor.</summary>
    public static IReadOnlyList<string> PaneGestures { get; } =
        ["Ctrl+Z", "Ctrl+Y", "Ctrl+Shift+Z", "Ctrl+K", "Ctrl+R", "Ctrl+E", "Ctrl+Shift+K", "Ctrl+Shift+I", "Ctrl+Shift+U", "Ctrl+Shift+P", "Ctrl+Shift+R", "F1"];

    /// <summary>"Ctrl+Shift+K" for K with Control and Shift.</summary>
    public static string Gesture(string key, bool control, bool shift) => (control ? "Ctrl+" : "") + (shift ? "Shift+" : "") + key;

    public static bool PaneForwards(string gesture) => PaneGestures.Contains(gesture, StringComparer.Ordinal);

    /// <summary>[ and ] on the Full take, a clip or a suggestion row step to the previous or next kept clip (design §11.1 and
    /// §6.2: from Full take, ] selects clip 1): -1 or 1, and 0 where the key doesn't act, which is any other row or with a
    /// modifier held.</summary>
    public static int RowClipStep(char key, SidebarKind row, bool modifier) =>
        modifier || row is not (SidebarKind.FullTake or SidebarKind.Clip or SidebarKind.Suggestion) ? 0 : key switch { '[' => -1, ']' => 1, _ => 0 };
}
