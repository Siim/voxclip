using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Reflection-free persisted project and caption serialization; architecture §2.3 and editing §10.1.</summary>
[JsonSourceGenerationOptions(NewLine = JsonFormatting.NewLine, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, RespectRequiredConstructorParameters = true, RespectNullableAnnotations = true,
    Converters = new[] { typeof(UtcTimestampConverter) })]
[JsonSerializable(typeof(Project))]
[JsonSerializable(typeof(TimedWord))]
[JsonSerializable(typeof(CaptionStyle))]
[JsonSerializable(typeof(ExportPreset))]
[JsonSerializable(typeof(EditPlan))]
[JsonSerializable(typeof(CaptionTrack))]
[JsonSerializable(typeof(AiResult))]
[JsonSerializable(typeof(RawClip[]))]
[JsonSerializable(typeof(ClipCandidate[]))]
[JsonSerializable(typeof(TranscriptLine[]))]
public partial class ProjectJsonContext : JsonSerializerContext;

/// <summary>RFC3339 UTC timestamps always ending in Z, through <see cref="UtcTimestamp"/>; project schema $defs/timestamp.</summary>
public sealed class UtcTimestampConverter : JsonConverter<DateTimeOffset>
{
    /// <inheritdoc />
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => UtcTimestamp.TryParse(reader.GetString(), out var value) ? value : throw new JsonException("Expected an RFC3339 UTC timestamp ending in Z.");
    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
        => writer.WriteStringValue(UtcTimestamp.Format(value));
}
