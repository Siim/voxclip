using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>One reasoned effect proposal anchored to an inclusive span of transcript items.</summary>
public sealed class ClipPlanEffect
{
    /// <summary>Maximum proposals per plan.</summary>
    public const int MaximumEntries = 12;
    /// <summary>The shared effect kind.</summary>
    public string Kind { get; }
    /// <summary>The first spoken word's transcript index.</summary>
    public int StartWord { get; }
    /// <summary>The last spoken word's transcript index.</summary>
    public int EndWord { get; }
    /// <summary>Why the effect helps on that beat.</summary>
    public string Reason { get; }
    private readonly string payloadKey;
    private readonly JsonNode payload;

    private ClipPlanEffect(string kind, int startWord, int endWord, string reason, string payloadKey, JsonNode payload)
    {
        Kind = kind; StartWord = startWord; EndWord = endWord; Reason = reason;
        this.payloadKey = payloadKey; this.payload = payload.DeepClone();
    }

    private static string? PayloadKey(string? kind) => kind switch
    {
        "zoom" or "punchIn" => "scale",
        "motionTitle" or "lowerThird" or "emojiPop" => "text",
        "motionTemplate" => "template",
        "soundEffect" => "query", "illustration" => "prompt", "colourLook" => "look", "speedForPart" => "rate",
        _ => null
    };

    /// <summary>The canonical plan entry, with just the payload for its kind.</summary>
    public JsonObject ToJson() => new()
    {
        ["kind"] = Kind, ["startWord"] = StartWord, ["endWord"] = EndWord, ["reason"] = Reason, [payloadKey] = payload.DeepClone()
    };

    private static string? Line(JsonNode? value, int limit) => AiJson.String(value) is { Length: > 0 } text && text == text.Trim() &&
        text.EnumerateRunes().Count() <= limit && !text.EnumerateRunes().Any(rune => Rune.GetUnicodeCategory(rune) is
            UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator) ? text : null;

    /// <summary>Reads a valid canonical entry, or null for a malformed proposal.</summary>
    public static ClipPlanEffect? Read(JsonNode? raw)
    {
        if (raw is not JsonObject { Count: 5 } item || AiJson.String(item["kind"]) is not { } kind ||
            PayloadKey(kind) is not { } key || item[key] is not { } payload ||
            AiJson.Integer(item["startWord"]) is not { } start || start < 0 ||
            AiJson.Integer(item["endWord"]) is not { } end || end < start || Line(item["reason"], 240) is not { } reason) return null;
        var valid = kind switch
        {
            "zoom" or "punchIn" => AiJson.Number(payload) is >= 1.05 and <= ClipAutopilotMapping.MaximumZoomScale,
            "motionTitle" or "lowerThird" => Line(payload, 80) is not null,
            "emojiPop" => Line(payload, 16) is not null,
            "motionTemplate" => MotionTemplate.Read(payload) is not null,
            "soundEffect" => Line(payload, 120) is not null,
            "illustration" => Line(payload, 500) is not null,
            "colourLook" => AiJson.String(payload) is "original" or "muted" or "warm" or "bw",
            "speedForPart" => AiJson.Number(payload) is >= 0.5 and <= 2,
            _ => false
        };
        return valid ? new(kind, start, end, reason, key, payload) : null;
    }

    internal static ClipPlanEffect? ProviderEntry(JsonNode? raw)
    {
        if (raw is not JsonObject item || AiJson.String(item["kind"]) is not ("zoom" or "punchIn" or "motionTitle" or "lowerThird" or "emojiPop") ||
            PayloadKey(AiJson.String(item["kind"])) is not { } key) return null;
        var projected = new JsonObject();
        foreach (var name in new[] { "kind", "startWord", "endWord", "reason", key }) projected[name] = item[name]?.DeepClone();
        return Read(projected);
    }

    /// <summary>Resolves kept words to a local, reviewable render operation; reserved entries never run.</summary>
    public ClipAutopilotOperation? Operation(string id, string clipId, WordSpan scope,
        Func<int, (double Start, double End)?> anchor, Func<int, bool> isCut, IReadOnlySet<string> stickers)
    {
        if (Kind is not ("zoom" or "punchIn" or "motionTitle" or "lowerThird" or "emojiPop" or "motionTemplate") ||
            StartWord < scope.Start || EndWord > scope.End || anchor(StartWord) is not { } first || anchor(EndWord) is not { } last ||
            Enumerable.Range(StartWord, EndWord - StartWord + 1).Any(isCut) ||
            !double.IsFinite(first.Start) || !double.IsFinite(last.End) || first.Start < 0 || last.End - first.Start is not (>= 0.1 and <= 5)) return null;

        if (Kind is "zoom" or "punchIn")
        {
            var scale = AiJson.Number(payload)!.Value;
            MotionKeyframe Frame(double progress, double amount = 1) => new(progress, amount, 0.5, 0.5);
            MotionKeyframe[] frames = Kind == "zoom" ? [Frame(0), Frame(0.28, scale), Frame(0.7, scale), Frame(1)] : [Frame(0, scale), Frame(1, scale)];
            return new(id, ClipAutopilotDecision.Zoom, new ClipAutopilotAction.Motion(new(id, clipId, first.Start, last.End, frames)), Reason);
        }
        var overlay = new JsonObject { ["id"] = id, ["clipId"] = clipId, ["start"] = first.Start, ["end"] = last.End };
        if (Kind == "motionTemplate")
        {
            overlay["kind"] = Kind;
            overlay["template"] = payload.DeepClone();
        }
        else
        {
            var text = AiJson.String(payload)!;
            if (Kind == "emojiPop" && !stickers.Contains(text)) return null;
            var (kind, position, animation) = Kind switch
            {
                "motionTitle" => ("title", "top", "rise"), "lowerThird" => ("lowerThird", "bottom", "rise"), _ => ("sticker", "topRight", "pop")
            };
            overlay["kind"] = kind; overlay["text"] = text; overlay["position"] = position; overlay["animation"] = animation;
            if (kind == "sticker") overlay["scale"] = 1;
        }
        using var stored = JsonDocument.Parse(overlay.ToJsonString());
        return new(id, ClipAutopilotDecision.Overlay, new ClipAutopilotAction.Effect(stored.RootElement.Clone()), Reason);
    }

    internal ClipAutopilotOperation? Operation(string id, string clipId, WordSpan scope, IReadOnlyList<TimedWord> words,
        IReadOnlySet<string> cut, IReadOnlySet<int> tightenedAfter, IReadOnlySet<string> stickers)
    {
        if (EndWord >= words.Count || tightenedAfter.Any(index => StartWord <= index && index < EndWord)) return null;
        return Operation(id, clipId, scope, index => words[index] is { Kind: WordKind.Word } word &&
            double.IsFinite(word.Start) && double.IsFinite(word.End) && word.End > word.Start ? (word.Start, word.End) : null,
            index => cut.Contains(words[index].Id), stickers);
    }
}
