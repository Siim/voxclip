using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Domain.Editing;

/// <summary>One validated word-anchored timeline command.</summary>
public sealed class TimelineEditRequest
{
    internal const int Maximum = 30;
    private readonly JsonElement wire;
    internal string Op => Text("op");

    internal TimelineEditRequest(JsonElement wire)
    {
        this.wire = wire.Clone();
        _ = Command(name => new(TimelineItemType.Effect, name), (index, _) => index);
    }

    internal static TimelineEditRequest[] ProviderEdits(JsonNode? value)
    {
        if (value is not JsonArray edits || edits.Count is < 1 or > Maximum) throw Invalid();
        return edits.Select(entry =>
        {
            if (entry is not JsonObject fields || fields["op"] is not JsonValue op || !op.TryGetValue<string>(out var operation)) throw Invalid();
            var keys = new HashSet<string>(StringComparer.Ordinal) { "op" };
            keys.UnionWith(operation switch
            {
                "move" => ["toWord"], "trim" => ["edge", "toWord"], "split" or "splitAll" => ["atWord"],
                "fade" => ["edge", "seconds"], "setGain" => ["db"], "setTrackGain" => ["track", "db"],
                "dipGain" => ["startWord", "endWord", "byDb"], "addGainPoint" => ["atWord", "db"],
                "moveGainPoint" => ["fromSeconds", "toWord", "db"], "removeGainPoint" => ["atSeconds"],
                "slip" => ["bySeconds"], "setLoop" => ["enabled"], "setDuck" => ["track", "db"],
                "nudge" => fields.ContainsKey("words") && (!fields.ContainsKey("frames") ||
                    fields["words"] is not JsonValue words || !words.TryGetValue<double>(out var count) || count != 0) ? ["words"] : ["frames"],
                "duplicate" when fields["toWord"] is JsonValue word && word.TryGetValue<double>(out var target) && target >= 0 => ["toWord"],
                _ => [],
            });
            if (operation is not ("splitAll" or "setDuck" or "setTrackGain"))
                keys.Add(fields["item"] is JsonValue item && item.TryGetValue<string>(out var itemId) && itemId is { Length: > 0 } ? "item" : "items");
            var projected = new JsonObject();
            foreach (var (key, field) in fields) if (keys.Contains(key)) projected[key] = field?.DeepClone();
            using var document = JsonDocument.Parse(projected.ToJsonString());
            return new TimelineEditRequest(document.RootElement);
        }).ToArray();
    }

    /// <summary>Resolve live item ids and anchors, and use the editor reducer.</summary>
    public TimelineEditResult.Applied Apply(Project project, string? scope)
    {
        var plan = RenderCallerInputs.PlacementPlan(project, scope);
        var items = TimelineItems.Layout(project, plan, scope, TimelineAxis.Edited).Items;
        var words = ProjectClock.Build(project).Words;
        var command = Command(name =>
        {
            var exact = items.FirstOrDefault(item => TimelineDecisions.Id(item.Id, project, scope) == name);
            if (exact is not null) return exact.Id;
            var matches = items.Where(item => item.Id.Value == name).Take(2).ToArray();
            if (matches.Length != 1) throw new HarnessTimelineEditException("Select an item on this timeline.");
            return matches[0].Id;
        }, (index, end) => index < words.Count ? (end ? words[index].End : words[index].Start) :
            throw new HarnessTimelineEditException("Enter a valid time."));
        return TimelineEdits.Apply(command, project, plan, scope) switch
        {
            TimelineEditResult.Applied applied => applied,
            TimelineEditResult.Refused refused => throw new HarnessTimelineEditException(refused.Refusal.Copy),
            _ => throw new InvalidOperationException()
        };
    }

    private static HarnessException Invalid() => new("Invalid timeline edit. Use an operation and its supported fields.");

    private JsonElement Field(string key) => wire.ValueKind == JsonValueKind.Object && wire.TryGetProperty(key, out var value) ? value : default;
    private string Text(string key) => Field(key) is { ValueKind: JsonValueKind.String } value && value.GetString() is { Length: > 0 } text
        ? text : throw Invalid();
    private double Number(string key, bool unsigned = false) => Field(key) is { ValueKind: JsonValueKind.Number } value &&
        value.TryGetDouble(out var number) && double.IsFinite(number) && (!unsigned || number >= 0) ? number : throw Invalid();
    private int Integer(string key, bool unsigned = false) => Number(key, unsigned) is var number && number == Math.Truncate(number) &&
        number is >= int.MinValue and <= int.MaxValue ? (int)number : throw Invalid();

    private void Check(string[] required, params string[] optional)
    {
        var fields = wire.EnumerateObject().ToArray();
        if (fields.Any(field => field.Value.ValueKind == JsonValueKind.Null ||
                (field.Name != "op" && !required.Contains(field.Name) && !optional.Contains(field.Name))) ||
            required.Any(key => Field(key).ValueKind == JsonValueKind.Undefined)) throw Invalid();
    }

    private TimelineEdit Command(Func<string, TimelineItemId> itemId, Func<int, bool, double> time)
    {
        var hasSingle = Field("item").ValueKind != JsonValueKind.Undefined;
        var selected = hasSingle ? "item" : "items";
        TimelineItemId Item() => itemId(Text("item"));
        TimelineItemId[] Items(bool empty = false)
        {
            if (hasSingle) return [Item()];
            var value = Field("items");
            if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() < (empty ? 0 : 1) || value.GetArrayLength() > Maximum)
                throw Invalid();
            var names = value.EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String && item.GetString() is { Length: > 0 } name
                ? name : throw Invalid()).ToArray();
            if (names.Distinct(StringComparer.Ordinal).Count() != names.Length) throw Invalid();
            return names.Select(itemId).ToArray();
        }
        double Anchor(string key, bool end = false) => time(Integer(key, unsigned: true), end);
        switch (Op)
        {
            case "move":
                Check([selected, "toWord"]);
                return new TimelineEdit.Move(Items(), Anchor("toWord"));
            case "nudge":
                var unit = Field("frames").ValueKind == JsonValueKind.Undefined ? "words" : "frames";
                Check([selected, unit]);
                return new TimelineEdit.Nudge(Items(), unit == "frames" ? TimelineNudge.Frames : TimelineNudge.Words, Integer(unit));
            case "trim":
                Check(["item", "edge", "toWord"]);
                var edge = Text("edge") switch { "start" => TimelineEdge.Start, "end" => TimelineEdge.End, _ => throw Invalid() };
                return new TimelineEdit.Trim(Item(), edge, Anchor("toWord", edge == TimelineEdge.End));
            case "split":
                Check([selected, "atWord"]);
                return new TimelineEdit.Split(Items(empty: true), Anchor("atWord"));
            case "splitAll":
                Check(["atWord"]);
                return new TimelineEdit.SplitAll(Anchor("atWord"));
            case "fade":
                Check(["item", "edge", "seconds"]);
                var fade = Text("edge") switch { "in" => TimelineEdge.Start, "out" => TimelineEdge.End, _ => throw Invalid() };
                return new TimelineEdit.Fade(Item(), fade, Number("seconds", unsigned: true));
            case "setGain":
                Check(["item", "db"]);
                return new TimelineEdit.SetGain(Item(), Number("db"));
            case "setTrackGain":
                Check(["track", "db"]);
                return new TimelineEdit.SetTrackGain(Text("track"), Number("db"));
            case "dipGain":
                Check(["item", "startWord", "endWord", "byDb"]);
                return new TimelineEdit.DipGain(Item(), Anchor("startWord"), Anchor("endWord", end: true), Number("byDb"));
            case "addGainPoint":
                Check(["item", "atWord", "db"]);
                return new TimelineEdit.AddGainPoint(Item(), Anchor("atWord"), Number("db"));
            case "moveGainPoint":
                Check(["item", "fromSeconds", "toWord", "db"]);
                return new TimelineEdit.MoveGainPoint(Item(), Number("fromSeconds", unsigned: true), Anchor("toWord"), Number("db"));
            case "removeGainPoint":
                Check(["item", "atSeconds"]);
                return new TimelineEdit.RemoveGainPoint(Item(), Number("atSeconds", unsigned: true));
            case "slip":
                Check(["item", "bySeconds"]);
                return new TimelineEdit.Slip(Item(), Number("bySeconds"));
            case "setLoop":
                Check(["item", "enabled"]);
                return new TimelineEdit.SetLoop(Item(), Field("enabled").ValueKind switch
                { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw Invalid() });
            case "setDuck":
                Check(["track", "db"]);
                return new TimelineEdit.SetDuck(Text("track"), Number("db"));
            case "duplicate":
                Check([selected], "toWord");
                return new TimelineEdit.Duplicate(Items(), Field("toWord").ValueKind == JsonValueKind.Undefined ? null : Anchor("toWord"));
            case "delete":
                Check([selected]);
                return new TimelineEdit.Delete(Items());
            default: throw Invalid();
        }
    }
}
