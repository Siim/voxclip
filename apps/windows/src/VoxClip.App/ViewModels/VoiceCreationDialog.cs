namespace VoxClip.App.ViewModels;

internal sealed record VoiceCreationDialog(string Title, string Message, string Primary, string Close, bool PrimaryDefault)
{
    internal static VoiceCreationDialog Create(VoiceCreationQuote quote) => new("Create voice",
        VoiceLabCopy.ProviderConsent + "\n\nChecks your plan, then sends the consent recording and " +
        (quote.Project is { } project ? VoiceLabCopy.Seconds(project.Seconds) + " s of speech from " + project.Name : "training audio") +
        " to create your own voice. No video is sent. " +
        (quote.Cost.Kind == VoxClip.Core.Domain.VoiceLab.VoiceLabCostPresentationKind.Inline && quote.Cost.Text.Length == 0 ? "This action is free." : quote.Cost.Text),
        "Continue", "Cancel", true);
    internal static VoiceCreationDialog Leave { get; } = new("Stop creating your voice?",
        "Stop creating your voice? The recording is deleted from this PC.", "Stop", "Keep going", false);
    internal static VoiceCreationDialog Verify(string cost) => new("Verify statement",
        VoiceLabCopy.ProviderConsent + "\n\nSends only the statement recording to ElevenLabs Scribe v2. No video is sent. " + cost,
        "Verify statement", "Cancel", true);
}
