using System.Text.Json.Serialization;
namespace VoxClip.Core.Services.Models;

/// <summary>Reflection-free installed-model and catalog metadata; architecture §2.3 and transcription §12.</summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true)]
[JsonSerializable(typeof(InstalledModel[]))]
[JsonSerializable(typeof(TranscriptionModel[]))]
public partial class ModelsJsonContext : JsonSerializerContext;
