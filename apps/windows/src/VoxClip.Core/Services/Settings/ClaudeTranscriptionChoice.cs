namespace VoxClip.Core.Services.Settings;

/// <summary>Claude mode's confirming engine and its clip style copy.</summary>
/// <param name="Confirmation">Transcript engine identifier.</param>
/// <param name="Label">Clip style card value.</param>
public sealed record ClaudeTranscriptionChoice(string Confirmation, string Label)
{
    /// <summary>Windows has no Apple Speech pass. Scribe stays an explicit, approved selection.</summary>
    public static ClaudeTranscriptionChoice ForWindows(string mode) => mode switch
    {
        "elevenlabs" => new("elevenlabs", "Scribe (approval required)"),
        "ask" => new("whispercpp", "Ask before transcribing"),
        _ => new("whispercpp", "Whisper on this device")
    };
}
