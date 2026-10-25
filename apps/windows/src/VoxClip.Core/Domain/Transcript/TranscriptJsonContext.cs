using System.Text.Json.Serialization;
namespace VoxClip.Core.Domain.Transcript;

/// <summary>Reflection-free raw transcription cache metadata; architecture §2.3 and transcription §14.2.</summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true, UseStringEnumConverter = true, DefaultIgnoreCondition = JsonIgnoreCondition.Never)]
[JsonSerializable(typeof(RawTranscript))]
[JsonSerializable(typeof(RawWord[]))]
[JsonSerializable(typeof(TranscriptionOptions))]
public partial class TranscriptJsonContext : JsonSerializerContext;
