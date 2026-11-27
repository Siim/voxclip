using System.Text.Json;
using System.Text.Json.Nodes;

namespace VoxClip.Core.Domain.Editing;

internal static class AgentPatchPath
{
    internal readonly record struct Token(string Name, bool Member = false);
    internal static readonly string[] Roots = ["edits", "captions", "clipStyle", "clipControls", "clipEffects", "music", "motionCues", "captionTranslations", "voiceLab", "export"];
    internal static readonly string[] OptionalCollections = ["clipControls", "clipEffects", "music", "motionCues", "captionTranslations"];
    internal static readonly string[] VoiceUses = ["segments", "cleanAudio", "wholeClipRevoices"];
    private static readonly Token Order = new("@order");
    private static readonly JsonElement Null = JsonSerializer.SerializeToElement((string?)null, AgentJsonStringContext.Default.String);

    internal static string Escape(string value) => value.Replace("~", "~0").Replace("/", "~1").Replace("[", "~2").Replace("]", "~3");

    private static string? Unescape(string value)
    {
        var decoded = value.Replace("~3", "]").Replace("~2", "[").Replace("~1", "/").Replace("~0", "~");
        return Escape(decoded) == value && decoded.Length > 0 ? decoded : null;
    }

    private static Token[]? Tokens(string path)
    {
        if (!path.StartsWith('/')) return null;
        var tokens = new List<Token>();
        foreach (var component in path[1..].Split('/'))
        {
            var parts = component.Split("[id=", StringSplitOptions.None);
            if (Unescape(parts[0]) is not { } key) return null;
            tokens.Add(new(key));
            if (parts.Length > 1)
            {
                if (parts.Length != 2 || !parts[1].EndsWith(']') || Unescape(parts[1][..^1]) is not { } id) return null;
                tokens.Add(new(id, Member: true));
            }
        }
        if (tokens.Count > 40 || !Roots.Contains(tokens[0].Name, StringComparer.Ordinal)) return null;
        if (tokens[0].Name == "voiceLab" && (tokens.Count < 2 || tokens[1].Member || !VoiceUses.Contains(tokens[1].Name, StringComparer.Ordinal))) return null;
        return tokens.ToArray();
    }

    private static string IdentityKey(ReadOnlySpan<Token> collection) => collection.Length == 1 && collection[0] == new Token("clipControls") ? "clipId" : "id";

    private static string? Id(JsonNode? node, string key) => node is JsonObject item && item[key] is JsonValue value &&
        value.TryGetValue<string>(out var id) && !string.IsNullOrEmpty(id) ? id : null;
    private static string? Id(JsonElement node, string key) => node.ValueKind == JsonValueKind.Object && node.TryGetProperty(key, out var id) &&
        id.ValueKind == JsonValueKind.String ? id.GetString() : null;

    internal static bool IsValid(AgentPatch patch)
    {
        if (patch.Path is null || Tokens(patch.Path) is not { } tokens || patch.BeforeMissing == false || patch.AfterMissing == false ||
            patch.Before.ValueKind == JsonValueKind.Undefined || patch.After.ValueKind == JsonValueKind.Undefined ||
            (patch.BeforeMissing == true && patch.Before.ValueKind != JsonValueKind.Null) ||
            (patch.AfterMissing == true && patch.After.ValueKind != JsonValueKind.Null) ||
            (patch.BeforeMissing == patch.AfterMissing && JsonElement.DeepEquals(patch.Before, patch.After))) return false;
        var last = tokens[^1];
        if (last.Member)
        {
            var key = IdentityKey(tokens.AsSpan(0, tokens.Length - 1));
            var addition = patch.BeforeMissing == true && patch.AfterMissing != true && Id(patch.After, key) == last.Name && patch.BeforeIndex is null && patch.AfterIndex >= 0;
            var removal = patch.AfterMissing == true && patch.BeforeMissing != true && Id(patch.Before, key) == last.Name && patch.AfterIndex is null && patch.BeforeIndex >= 0;
            return (addition || removal) && patch.PreviousId != last.Name && patch.NextId != last.Name;
        }
        var noPosition = patch.BeforeIndex is null && patch.AfterIndex is null && patch.PreviousId is null && patch.NextId is null;
        if (last == Order)
        {
            if (patch.Before.ValueKind != JsonValueKind.Array || patch.After.ValueKind != JsonValueKind.Array) return false;
            var before = patch.Before.EnumerateArray().ToArray();
            var after = patch.After.EnumerateArray().ToArray();
            return noPosition && before.Length == after.Length && before.Concat(after).All(item => item.ValueKind == JsonValueKind.String && item.GetString()!.Length > 0) &&
                before.Select(item => item.GetString()).ToHashSet(StringComparer.Ordinal) is { } ids && ids.Count == before.Length && ids.SetEquals(after.Select(item => item.GetString()));
        }
        return noPosition && !(tokens.Length > 1 && tokens[^2].Member && last == new Token(IdentityKey(tokens.AsSpan(0, tokens.Length - 2))));
    }

    internal static bool Overlaps(AgentPatch first, AgentPatch second)
    {
        if (Tokens(first.Path) is not { } left || Tokens(second.Path) is not { } right) return false;
        var length = Math.Min(left.Length, right.Length);
        if (left.AsSpan(0, length).SequenceEqual(right.AsSpan(0, length))) return true;
        return left.Length == right.Length && left.AsSpan(0, length - 1).SequenceEqual(right.AsSpan(0, length - 1)) &&
            ((left[^1] == Order && right[^1].Member) || (right[^1] == Order && left[^1].Member));
    }

    internal static void Diff(JsonNode? before, bool hasBefore, JsonNode? after, bool hasAfter, string path, List<AgentPatch> patches)
    {
        if (hasBefore == hasAfter && JsonNode.DeepEquals(before, after)) return;
        if (before is JsonObject oldObject && after is JsonObject newObject)
        {
            foreach (var key in oldObject.Select(pair => pair.Key).Union(newObject.Select(pair => pair.Key), StringComparer.Ordinal).Order(StringComparer.Ordinal))
                Diff(oldObject[key], oldObject.ContainsKey(key), newObject[key], newObject.ContainsKey(key), $"{path}/{Escape(key)}", patches);
        }
        else if (before is JsonArray oldArray && after is JsonArray newArray &&
            Identities(oldArray, path == "/clipControls" ? "clipId" : "id") is { } oldIds &&
            Identities(newArray, path == "/clipControls" ? "clipId" : "id") is { } newIds)
        {
            var order = oldIds.ToList();
            var oldPositions = oldIds.Index().ToDictionary(item => item.Item, item => item.Index, StringComparer.Ordinal);
            var newNames = newIds.ToHashSet(StringComparer.Ordinal);
            for (var index = oldIds.Length - 1; index >= 0; index--)
            {
                var id = oldIds[index];
                if (newNames.Contains(id)) continue;
                patches.Add(new($"{path}[id={Escape(id)}]", Element(oldArray[index]), Null, AfterMissing: true,
                    BeforeIndex: index, PreviousId: index > 0 ? order[index - 1] : null, NextId: index + 1 < order.Count ? order[index + 1] : null));
                order.RemoveAt(index);
            }
            for (var index = 0; index < newIds.Length; index++)
            {
                var id = newIds[index];
                var member = $"{path}[id={Escape(id)}]";
                if (oldPositions.TryGetValue(id, out var oldIndex)) Diff(oldArray[oldIndex], true, newArray[index], true, member, patches);
                else
                {
                    var position = Math.Min(index, order.Count);
                    patches.Add(new(member, Null, Element(newArray[index]), BeforeMissing: true, AfterIndex: position,
                        PreviousId: position > 0 ? order[position - 1] : null, NextId: position < order.Count ? order[position] : null));
                    order.Insert(position, id);
                }
            }
            if (!order.SequenceEqual(newIds, StringComparer.Ordinal)) patches.Add(new($"{path}/@order", Element(Names(order)), Element(Names(newIds))));
        }
        else patches.Add(new(path, Element(before), Element(after), hasBefore ? null : true, hasAfter ? null : true));
    }

    private static JsonElement Element(JsonNode? value)
    {
        if (value is null) return Null;
        using var document = JsonDocument.Parse(value.ToJsonString());
        return document.RootElement.Clone();
    }

    private static string[]? Identities(JsonArray array, string key)
    {
        var ids = array.Select(item => Id(item, key)).OfType<string>().ToArray();
        return ids.Length == array.Count && ids.Distinct(StringComparer.Ordinal).Count() == ids.Length ? ids : null;
    }

    private static JsonArray Names(IEnumerable<string> values) => new(values.Select(value => (JsonNode?)JsonValue.Create(value)).ToArray());

    internal static void Apply(AgentPatch patch, JsonObject document, bool reverse, bool force = false)
    {
        if (!IsValid(patch) || Tokens(patch.Path) is not { } tokens) throw new AgentTurnException(AgentTurnError.InvalidPatch, patch.Path);
        var expected = reverse ? patch.After : patch.Before;
        var expectedMissing = (reverse ? patch.AfterMissing : patch.BeforeMissing) == true;
        var desired = reverse ? patch.Before : patch.After;
        var desiredMissing = (reverse ? patch.BeforeMissing : patch.AfterMissing) == true;
        AgentTurnException Conflict() => new(AgentTurnError.Conflict, patch.Path);
        void Check(JsonNode? value, bool found)
        {
            if (!force && (found == expectedMissing || (found && !JsonElement.DeepEquals(Element(value), expected)))) throw Conflict();
        }
        JsonNode? Desired() => JsonNode.Parse(desired.GetRawText());

        void Replace(JsonNode? node, int position)
        {
            var token = tokens[position];
            var last = position == tokens.Length - 1;
            if (node is JsonObject obj && !token.Member)
            {
                var found = obj.TryGetPropertyValue(token.Name, out var current);
                if (!last) { Replace(current, position + 1); return; }
                Check(current, found);
                if (desiredMissing) obj.Remove(token.Name);
                else obj[token.Name] = Desired();
                return;
            }
            if (node is not JsonArray array || Identities(array, IdentityKey(tokens.AsSpan(0, position))) is not { } ids) throw Conflict();
            if (last && token == Order)
            {
                Check(Names(ids), true);
                var items = ids.Index().ToDictionary(item => item.Item, item => array[item.Index], StringComparer.Ordinal);
                var wanted = desired.EnumerateArray().Select(item => item.GetString()!).ToArray();
                if (wanted.Length != array.Count || !wanted.All(items.ContainsKey)) throw Conflict();
                array.Clear();
                foreach (var id in wanted) array.Add(items[id]);
                return;
            }
            if (!token.Member) throw Conflict();
            var index = Array.IndexOf(ids, token.Name);
            if (!last)
            {
                if (index < 0) throw Conflict();
                Replace(array[index], position + 1);
                return;
            }
            Check(index < 0 ? null : array[index], index >= 0);
            if (index >= 0)
            {
                if (desiredMissing) array.RemoveAt(index);
                else array[index] = Desired();
                return;
            }
            if (desiredMissing || (reverse ? patch.BeforeIndex : patch.AfterIndex) is not { } fallback) throw Conflict();
            var next = Array.IndexOf(ids, patch.NextId);
            var previous = Array.IndexOf(ids, patch.PreviousId);
            array.Insert(next >= 0 ? next : previous >= 0 ? previous + 1 : Math.Min(fallback, array.Count), Desired());
        }
        Replace(document, 0);
    }
}

[System.Text.Json.Serialization.JsonSerializable(typeof(string))]
internal partial class AgentJsonStringContext : System.Text.Json.Serialization.JsonSerializerContext;
