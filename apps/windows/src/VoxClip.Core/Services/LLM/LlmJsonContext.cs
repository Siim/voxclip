using System.Text.Json.Serialization;
namespace VoxClip.Core.Services.LLM;

/// <summary>Reflection-free model-cache metadata, never prompt/body logging; architecture §2.3 and AI §9.</summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true, UseStringEnumConverter = true)]
[JsonSerializable(typeof(LlmModel[]))]
[JsonSerializable(typeof(LlmUsage))]
[JsonSerializable(typeof(CostEstimate))]
[JsonSerializable(typeof(LipsyncJob))]
public partial class LlmJsonContext : JsonSerializerContext;
