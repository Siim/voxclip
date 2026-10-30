namespace VoxClip.App.ViewModels;

internal sealed record VoiceCreationDialog(string Title, string Message, string Primary, string Close, bool PrimaryDefault)
{
    internal static VoiceCreationDialog Leave { get; } = new("Stop creating your voice?",
        "Stop creating your voice? The recording is deleted from this PC.", "Stop", "Keep going", false);
    internal static VoiceCreationDialog Verify(string cost) => new("Verify statement",
        VoiceLabCopy.ProviderConsent + "\n\nSends only the statement recording to ElevenLabs Scribe v2. No video is sent. " + cost,
        "Verify statement", "Cancel", true);
}
