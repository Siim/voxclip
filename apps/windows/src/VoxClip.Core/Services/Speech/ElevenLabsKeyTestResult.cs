namespace VoxClip.Core.Services.Speech;

/// <summary>A valid key's account-read result; this never proves speech_to_text permission.</summary>
/// <param name="CanReadAccountDetails">Whether the key can read subscription details.</param>
/// <param name="Message">The exact Test-button copy from transcription §8.5.</param>
public sealed record ElevenLabsKeyTestResult(bool CanReadAccountDetails, string Message);
