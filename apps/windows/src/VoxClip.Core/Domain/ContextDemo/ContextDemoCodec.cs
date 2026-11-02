#pragma warning disable CS1591
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.ContextDemo;

public sealed class ContextDemoTargetKindConverter : JsonConverter<ContextDemoTargetKind>
{
    public override ContextDemoTargetKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String) throw new JsonException("Expected a context target kind string.");
        return reader.GetString() switch
        {
            "desktopApp" => ContextDemoTargetKind.DesktopApp,
            "codeProject" => ContextDemoTargetKind.CodeProject,
            "webPage" => ContextDemoTargetKind.WebPage,
            _ => throw new JsonException("Unsupported context target kind.")
        };
    }

    public override void Write(Utf8JsonWriter writer, ContextDemoTargetKind value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            ContextDemoTargetKind.DesktopApp => "desktopApp",
            ContextDemoTargetKind.CodeProject => "codeProject",
            ContextDemoTargetKind.WebPage => "webPage",
            _ => throw new JsonException("Unsupported context target kind.")
        });
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, RespectRequiredConstructorParameters = true,
    RespectNullableAnnotations = true, Converters = new[] { typeof(UtcTimestampConverter) })]
[JsonSerializable(typeof(ContextDemoDocument))]
[JsonSerializable(typeof(ContextDemoCaptureRequest))]
public partial class ContextDemoJsonContext : JsonSerializerContext;

public static class ContextDemoCodec
{
    public static byte[] Encode(ContextDemoDocument document)
    {
        document.Validate();
        var data = JsonSerializer.SerializeToUtf8Bytes(document, ContextDemoJsonContext.Default.ContextDemoDocument);
        using var json = JsonDocument.Parse(data);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true })) WriteSorted(writer, json.RootElement);
        return stream.ToArray();
    }

    public static ContextDemoDocument Decode(ReadOnlySpan<byte> data)
    {
        ContextDemoValidation.Require(data.Length <= 4 * 1024 * 1024, ContextDemoError.InvalidRequest);
        var document = JsonSerializer.Deserialize(data, ContextDemoJsonContext.Default.ContextDemoDocument)
            ?? throw new ContextDemoException(ContextDemoError.InvalidRequest);
        document.Validate();
        return document;
    }

    private static void WriteSorted(Utf8JsonWriter writer, JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            writer.WriteStartObject();
            foreach (var property in value.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
            {
                writer.WritePropertyName(property.Name);
                WriteSorted(writer, property.Value);
            }
            writer.WriteEndObject();
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            writer.WriteStartArray();
            foreach (var item in value.EnumerateArray()) WriteSorted(writer, item);
            writer.WriteEndArray();
        }
        else value.WriteTo(writer);
    }
}
