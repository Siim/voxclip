using System.Text.Json;

namespace VoxClip.Core.Domain.Shared;

/// <summary>Platform-independent JSON text formatting; editing §10.1 and architecture §9.3.</summary>
public static class JsonFormatting
{
    /// <summary>The line ending used inside and after persisted JSON documents.</summary>
    public const string NewLine = "\n";

    /// <summary>Copy serializer settings without inheriting the host's line ending.</summary>
    public static JsonSerializerOptions CreateOptions(JsonSerializerOptions? options = null)
        => options is null ? new() { NewLine = NewLine } : new(options) { NewLine = NewLine };

    /// <summary>Preserve writer settings while fixing the JSON line ending.</summary>
    public static JsonWriterOptions CreateWriterOptions(JsonWriterOptions options = default)
        => options with { NewLine = NewLine };
}
