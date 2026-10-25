using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

public static class UiError
{
    public static string Message(Exception exception, string action)
    {
        if (exception is OperationCanceledException) return "";
        if (exception is VoiceLabProjectException { Code: VoiceLabProjectErrorCode.UnsupportedRendering })
            return "This build cannot preview or export generated voice segments yet. Your video and edits are still here.";
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
        if (exception is LlmException llm) return llm.Error.Kind == LlmErrorKind.Cancelled ? "" : llm.Error.UserMessage + " Your edits are saved.";
        if (exception is IOException or UnauthorizedAccessException) return $"{action} couldn't access the file. Your video and edits are still here.";
        return $"{action} stopped. Your video and edits are still here. Try again.";
    }
}

public static class ShortcutPolicy
{
    public static bool EditorMayHandle(bool textFocus, bool correctionOpen, bool control, bool alt, bool editorFocus) =>
        editorFocus && !textFocus && !correctionOpen && !(control && alt);
}
