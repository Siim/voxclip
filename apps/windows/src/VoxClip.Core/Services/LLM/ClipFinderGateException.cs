namespace VoxClip.Core.Services.LLM;

/// <summary>Feature gates from AI §11.1, never provider failures.</summary>
public enum ClipFinderGateKind
{
    /// <summary>The take contains no words.</summary>
    NoWords,
    /// <summary>The custom preset needs instructions.</summary>
    NeedInstructions
}

/// <summary>An actionable prompt-file message from AI §11.1 gates 1–2.</summary>
public sealed class ClipFinderGateException(ClipFinderGateKind kind, string userMessage) : Exception(userMessage)
{
    /// <summary>The feature gate that failed.</summary>
    public ClipFinderGateKind Kind { get; } = kind;
    /// <summary>The exact message from clip-finder.json.</summary>
    public string UserMessage { get; } = userMessage;
}
