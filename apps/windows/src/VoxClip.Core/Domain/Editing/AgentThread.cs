#pragma warning disable CS1591
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VoxClip.Core.Domain.Editing;

[JsonConverter(typeof(AgentEnumConverter<AgentMode>))]
public enum AgentMode { Propose, Claude, AskFirst }
[JsonConverter(typeof(AgentEnumConverter<AgentTurnKind>))]
public enum AgentTurnKind { Agent, Run, Outside }
[JsonConverter(typeof(AgentEnumConverter<AgentTurnState>))]
public enum AgentTurnState { Running, Pending, Kept, Undone, Partial, Stopped, Failed }
[JsonConverter(typeof(AgentEnumConverter<AgentContextKind>))]
public enum AgentContextKind { Clip, Part, Recording, Words, Line, Panel }
[JsonConverter(typeof(AgentEnumConverter<AgentChangeState>))]
public enum AgentChangeState { Applied, Undone }
[JsonConverter(typeof(AgentEnumConverter<AgentOfferKind>))]
public enum AgentOfferKind { GenerateMusic, Revoice, Illustration, LipSync, MakeItPostable }
[JsonConverter(typeof(AgentEnumConverter<AgentOfferState>))]
public enum AgentOfferState { Offered, Bought, Declined, Failed }
[JsonConverter(typeof(AgentEnumConverter<AgentEventKind>))]
public enum AgentEventKind { Hand, Keep, Undo, Redo, Bought }

public sealed record AgentThread(string Id, AgentMode Mode, IReadOnlyList<AgentTurn> Turns);
public sealed record AgentTurn(string Id, AgentTurnKind Kind, DateTimeOffset CreatedAt, AgentRequest Request,
    string Connector, string Model, string Summary, IReadOnlyList<AgentStep> Steps, AgentTurnState State,
    IReadOnlyList<AgentChange> Changes, IReadOnlyList<AgentOffer> Offers, IReadOnlyList<AgentEvent> Events,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? RevisionOf = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] AgentCheck? Check = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? WasKept = null)
{
    [JsonIgnore]
    public bool IsPending => State == AgentTurnState.Pending ||
        ((State is AgentTurnState.Partial or AgentTurnState.Stopped) && WasKept != true && Changes.Any(change => change.State == AgentChangeState.Applied));
}

public sealed record AgentRequest(string Text, IReadOnlyList<AgentContext> Context);
public sealed record AgentContext(AgentContextKind Kind,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ClipId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Part = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? SourceKey = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? StartWordId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? EndWordId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Line = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Panel = null);
public sealed record AgentStep(string Tool, bool Ok, string Digest, int Ms);
public sealed record AgentChange(string Id, string Label, string UndoName, AgentChangeState State, IReadOnlyList<AgentPatch> Patch);
public sealed record AgentPatch(string Path, JsonElement Before, JsonElement After,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? BeforeMissing = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? AfterMissing = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? BeforeIndex = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? AfterIndex = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? PreviousId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? NextId = null);
public sealed record AgentOffer(string Id, AgentOfferKind Kind, string Label,
    [property: JsonPropertyName("quoteUSD")] string QuoteUSD, AgentOfferState State,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? AssetId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Target = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Brief = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? Words = null);
public sealed record AgentCheck(bool Ok, IReadOnlyList<string> Lines);
public sealed record AgentEvent(AgentEventKind Kind, string UndoName, string Target, DateTimeOffset At,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<AgentPatch>? Patch = null);

internal sealed class AgentEnumConverter<T> : JsonConverter<T> where T : struct, Enum
{
    private static readonly Dictionary<string, T> Names = Enum.GetValues<T>()
        .ToDictionary(value => JsonNamingPolicy.CamelCase.ConvertName(value.ToString()), StringComparer.Ordinal);

    public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String && Names.TryGetValue(reader.GetString()!, out var value)
            ? value : throw new JsonException($"Invalid {typeof(T).Name}.");

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
    {
        if (!Enum.IsDefined(value)) throw new JsonException($"Invalid {typeof(T).Name}.");
        writer.WriteStringValue(JsonNamingPolicy.CamelCase.ConvertName(value.ToString()));
    }
}
