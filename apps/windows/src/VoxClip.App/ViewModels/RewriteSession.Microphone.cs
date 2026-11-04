using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Say it myself on the phrase card (design.md §6.3.8, voice-lab.md §8.13): the session's one microphone, which records one
/// phrase at a time, and the storage its free takes are written to.</summary>
internal sealed partial class RewriteSession
{
    internal const string AiDisclosureLine = "Exports show AI MODIFIED on the video and in the post.";
    internal const string OwnTakeDisclosureLine = "Your own take is used as recorded: no AI label.";
    /// <summary>The footer's label line (Mac <c>takesFooter</c>): the user's own takes are real speech, so only generated takes
    /// carry the AI label.</summary>
    internal string DisclosureLine => generationWindows.Any(window => !window.LeftOut && window.Selected is { Selectable: true }) &&
        generationWindows.Where(window => !window.LeftOut && window.Selected is { Selectable: true }).All(window => window.UsesOwnTake)
        ? OwnTakeDisclosureLine : AiDisclosureLine;

    /// <summary>The microphone, once the editor configured one; null hides Record.</summary>
    internal RewritePhraseMicrophone? PhraseMicrophone { get; private set; }
    /// <summary>Where the user's own takes are written: the project's Voice Lab folders.</summary>
    internal VoiceLabTakeStorage? RecordedStorage { get; private set; }

    internal void ConfigureMicrophone(RewritePhraseMicrophone microphone, VoiceLabTakeStorage storage)
    {
        if (PhraseMicrophone is { } previous) { previous.Changed -= MicrophoneChanged; previous.Cancel(); }
        PhraseMicrophone = microphone; RecordedStorage = storage;
        microphone.Changed += MicrophoneChanged;
    }
    private void MicrophoneChanged(object? sender, EventArgs args) { if (IsOpen) Changed?.Invoke(this, EventArgs.Empty); }

    /// <summary>[● Record] / [Record again] for phrase <paramref name="index"/>: Say it myself becomes its wording.</summary>
    internal async Task RecordPhraseAsync(int index)
    {
        if (PhraseMicrophone is not { } microphone || generationWindows.ElementAtOrDefault(index) is null) return;
        if (Wording(index) != PhraseWording.Microphone) await ChooseWordingAsync(PhraseWording.Microphone, index);
        await microphone.RecordAsync(this, index);
    }
    internal Task StopPhraseRecordingAsync() => PhraseMicrophone?.StopAsync(this) ?? Task.CompletedTask;

    /// <summary>Leaving Say it myself: a recording of this phrase in progress is dropped; its takes are kept.</summary>
    private void CancelPhraseMicrophone(int? index = null)
    {
        if (PhraseMicrophone is { Busy: true } microphone && (index is null || microphone.Phrase == index)) microphone.Cancel();
    }
}
