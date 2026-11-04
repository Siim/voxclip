using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Services.LLM;

/// <summary>One clip as the caption pick request shows it: C1, C2… in clip order; AI §15.</summary>
public sealed record CaptionPickClip(string Id, string? Title, double Seconds, string Text);

/// <summary>shared/prompts/caption-pick.json rendered into one request; AI §15. Pure: the same inputs give the same
/// strings on both platforms (shared/fixtures/llm/caption-pick.json).</summary>
public sealed class CaptionPickPrompt
{
    private readonly JsonObject document;

    /// <summary>Wraps a caption-pick.json document after checking its versions.</summary>
    public CaptionPickPrompt(JsonObject document)
    {
        if (document["schemaVersion"]?.GetValue<int>() != 1 || document["promptVersion"]?.GetValue<int>() != 1 || document["system"] is null || document["output"]?["schema"] is null)
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "caption-pick.json");
        this.document = document;
    }

    /// <summary>Reads shared/prompts/caption-pick.json.</summary>
    public static CaptionPickPrompt Load(string sharedRoot) => new(JsonNode.Parse(File.ReadAllText(Path.Combine(sharedRoot, "prompts", "caption-pick.json")))!.AsObject());

    /// <summary>At most this many clips are sent.</summary>
    public int MaxClips => document["limits"]!["maxClips"]!.GetValue<int>();
    private int MaxClipChars => document["limits"]!["maxClipChars"]!.GetValue<int>();
    private int MaxReasonChars => document["limits"]!["maxReasonChars"]!.GetValue<int>();

    /// <summary>The label a clip carries in the request and the reply: C1 for the first clip.</summary>
    public static string Label(int index) => "C" + (index + 1).ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>A clip's length in the request: whole seconds, halves rounded up; 0 for a negative or non-finite length.</summary>
    public static int WholeSeconds(double seconds) => double.IsFinite(seconds) && seconds > 0 && seconds < 1e9 ? (int)Math.Floor(seconds + 0.5) : 0;

    /// <summary>The instruction for <paramref name="clips"/> and the styles the AI may choose from.</summary>
    public string Instruction(IReadOnlyList<CaptionPickClip> clips, IReadOnlyList<CaptionStyle> candidates, string presetLabel)
    {
        var request = document["request"]!;
        var styleLine = request["styleLine"]!.GetValue<string>();
        var clipLine = request["clipLine"]!.GetValue<string>();
        var styles = string.Join("\n", candidates.Select(style => styleLine.Replace("{id}", style.Id, StringComparison.Ordinal)
            .Replace("{name}", style.Name, StringComparison.Ordinal).Replace("{description}", style.Description, StringComparison.Ordinal)));
        var lines = string.Join("\n", clips.Take(MaxClips).Select((clip, index) =>
        {
            var title = ClipText.Trim(clip.Title ?? "");
            return clipLine.Replace("{clip}", Label(index), StringComparison.Ordinal)
                .Replace("{seconds}", WholeSeconds(clip.Seconds).ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal)
                .Replace("{title}", title.Length == 0 ? "Untitled" : title, StringComparison.Ordinal)
                .Replace("{text}", ClipText.Limit(ClipText.Trim(clip.Text), MaxClipChars), StringComparison.Ordinal);
        }));
        return request["instruction"]!.GetValue<string>().Replace("{preset}", presetLabel, StringComparison.Ordinal)
            .Replace("{styles}", styles, StringComparison.Ordinal).Replace("{clips}", lines, StringComparison.Ordinal);
    }

    /// <summary>The canonical request, at decision (extra high) effort.</summary>
    public LlmRequest Request(IReadOnlyList<CaptionPickClip> clips, IReadOnlyList<CaptionStyle> candidates, string presetLabel, TimeSpan timeout, string? language) =>
        new(LlmFeature.CaptionPick, document["system"]!.GetValue<string>(), null, Instruction(clips, candidates, presetLabel),
            document["output"]!["name"]!.GetValue<string>(), document["output"]!["schema"]!.DeepClone().AsObject(),
            document["generation"]!["maxOutputTokens"]!.GetValue<int>(), EffortLevel.Decision, timeout, language,
            $"caption-pick {Math.Min(clips.Count, MaxClips)} clips");

    /// <summary>The reply's valid picks by clip id. A pick is dropped when its clip label is unknown or repeated, or
    /// its style is not a candidate; a reason keeps its first 120 Unicode scalars.</summary>
    public (IReadOnlyDictionary<string, ClipCaptionPick> Picks, int Dropped) Picks(JsonObject reply, IReadOnlyList<CaptionPickClip> clips, IReadOnlySet<string> candidates)
    {
        var labels = clips.Take(MaxClips).Select((clip, index) => (Label(index), clip.Id)).ToDictionary(item => item.Item1, item => item.Id, StringComparer.Ordinal);
        var picks = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal);
        var dropped = 0;
        foreach (var item in reply["picks"]?.AsArray() ?? [])
        {
            var label = Text(item?["clip"]); var style = Text(item?["style"]);
            if (label is null || style is null || !labels.TryGetValue(ClipText.Trim(label), out var id) || picks.ContainsKey(id)
                || !candidates.Contains(ClipText.Trim(style)) || ClipText.Trim(style) == "auto") { dropped++; continue; }
            var reason = ClipText.Trim(Text(item?["reason"]) ?? "");
            picks[id] = new(ClipText.Trim(style), string.Concat(reason.EnumerateRunes().Take(MaxReasonChars).Select(rune => rune.ToString())));
        }
        return (picks, dropped);
    }

    private static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}

/// <summary>Asks the chosen connector for a caption style per clip while the clip style's captions are Auto
/// (design §6.9). A style the user fixed is never sent and never overridden.</summary>
public sealed class CaptionPicker(LlmRunner runner, CaptionPickPrompt prompt, LlmCatalog catalog)
{
    /// <summary><paramref name="style"/> with the AI's picks recorded, or unchanged when its captions are not Auto (no
    /// request is sent) or there are no clips or candidates.</summary>
    public async Task<(ClipStyle Style, int Dropped)> PickAsync(ClipStyle style, IReadOnlyList<CaptionPickClip> clips, IEnumerable<CaptionStyle> library,
        ClipStyleCatalog styles, ILlmConnector connector, string model, string? language, CancellationToken ct)
    {
        if (!style.CaptionsAuto || clips.Count == 0) return (style, 0);
        var candidates = styles.CaptionCandidates(library, style);
        if (candidates.Count == 0) return (style, 0);
        var timeout = catalog.Timeout(connector.Id switch { ConnectorId.ClaudeCode or ConnectorId.Codex => "cli", ConnectorId.Ollama or ConnectorId.LmStudio => "localServer", ConnectorId.AppleFoundation => "appleFoundation", _ => "cloud" });
        var request = prompt.Request(clips, candidates, styles.Find(style.Preset).Label, timeout, language);
        var result = await runner.RunAsync(request, connector, model, ct).ConfigureAwait(false);
        var parsed = prompt.Picks(result.Object, clips, candidates.Select(candidate => candidate.Id).ToHashSet(StringComparer.Ordinal));
        return (style.Pruned(clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal)).Recording(parsed.Picks), parsed.Dropped + result.DroppedItems);
    }
}
