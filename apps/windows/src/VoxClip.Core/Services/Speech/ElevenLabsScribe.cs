namespace VoxClip.Core.Services.Speech;

/// <summary>The ElevenLabs Scribe model every new request sends; transcription §8. It must equal
/// <c>shared/catalog/transcription-models.json</c> (elevenlabs <c>modelId</c>) and the speechToText <c>model</c> in
/// <c>shared/catalog/voice-lab.json</c>; <c>ScribeV3Tests</c> fails when they drift. Twin of the Mac <c>ElevenLabsScribe</c>.</summary>
public static class ElevenLabsScribe
{
    /// <summary>The current Scribe model id.</summary>
    public const string ModelId = "scribe_v3";

    /// <summary>Models older projects, caches and remembered plans may name. They are read as recorded, never sent again.</summary>
    public static IReadOnlySet<string> LegacyModelIds { get; } = new HashSet<string>(StringComparer.Ordinal) { "scribe_v2" };

    /// <summary>Plans that name no model, the current one or a legacy one all run on the current model.</summary>
    public static bool Accepts(string? model) => model is null || model == ModelId || LegacyModelIds.Contains(model);

    /// <summary>The refusal for any other model, identical on both platforms.</summary>
    public const string ModelRequiredMessage = "ElevenLabs requires the " + ModelId + " model";
}
