using System.Text.Json.Serialization;
namespace VoxClip.Core.Services.Settings;

/// <summary>Reflection-free flat settings; architecture §2.3 and §2.5, shared/schemas/settings.schema.json.</summary>
[JsonSourceGenerationOptions(NewLine = VoxClip.Core.Domain.Shared.JsonFormatting.NewLine, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true, RespectRequiredConstructorParameters = true)]
[JsonSerializable(typeof(AppSettings))]
public partial class SettingsJsonContext : JsonSerializerContext;
