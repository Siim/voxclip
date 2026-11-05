using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>What the creator asked Claude about (ai.md §18.1): selected words, a whole clip, or a time range on the timeline.
/// <see cref="ClipId"/> is the clip the answer's effects belong to: the clip of the tab or row, null for the full video. Twin of the
/// Mac <c>AskClaudeSelection</c>.</summary>
public sealed record AskClaudeSelection(AskClaudeSelection.Scope Kind, string? ClipId)
{
    /// <summary>Which part of the video was asked about.</summary>
    public abstract record Scope
    {
        /// <summary>Transcript word indices, inclusive.</summary>
        public sealed record Words(int First, int Last) : Scope;
        /// <summary>A whole clip.</summary>
        public sealed record Clip(string Id) : Scope;
        /// <summary>Source seconds.</summary>
        public sealed record Time(double Start, double End) : Scope;
    }
}

/// <summary>Something found on screen in the selection (ai.md §18.1): a face or a text box, with the source seconds it was seen over
/// and its rect in picture space. <see cref="Label"/> (D1, D2…) is how the request and the reply name it.</summary>
public sealed record AskClaudeDetection(string Label, AskClaudeDetectionKind Kind, double Start, double End, ClipEffectRect Rect, string? Text = null);

/// <summary>A detection's kind; its wire name is lower case.</summary>
public enum AskClaudeDetectionKind
{
    /// <summary>A face.</summary>
    Face,
    /// <summary>A line or block of text.</summary>
    Text
}

/// <summary>The selection resolved against the project: its word range (null when a time range holds no words), its source range
/// and its clip. Twin of the Mac <c>AskClaudeScope</c>.</summary>
public sealed record AskClaudeScope(WordSpan? Words, double Start, double End, string? ClipId, bool IsClip, bool IsTime)
{
    /// <summary>Resolves <paramref name="selection"/>; throws for an unknown clip, words outside the transcript, or a time range under 0.1 s.</summary>
    public static AskClaudeScope Resolve(AskClaudeSelection selection, Project project)
    {
        var words = project.Transcript?.Words ?? [];
        if (selection.ClipId is { } id && project.Edits.Clips.All(clip => clip.Id != id)) throw Invalid();
        switch (selection.Kind)
        {
            case AskClaudeSelection.Scope.Words range:
                if (range.First < 0 || range.Last >= words.Count || range.First > range.Last) throw Invalid();
                return new(new(range.First, range.Last), words[range.First].Start, words[range.Last].End, selection.ClipId, false, false);
            case AskClaudeSelection.Scope.Clip clip:
            {
                var found = project.Edits.Clips.FirstOrDefault(item => item.Id == clip.Id) ?? throw Invalid();
                var first = IndexOf(words, found.StartWordId);
                var last = IndexOf(words, found.EndWordId);
                if (first < 0 || last < 0 || first > last) throw Invalid();
                return new(new(first, last), words[first].Start, words[last].End, clip.Id, true, false);
            }
            case AskClaudeSelection.Scope.Time time:
            {
                var duration = project.Media.Source.DurationSeconds;
                var start = Math.Max(0, time.Start);
                var end = Math.Min(duration > 0 ? duration : time.End, time.End);
                if (!double.IsFinite(start) || !double.IsFinite(end) || end - start < 0.1) throw Invalid();
                var inside = Enumerable.Range(0, words.Count).Where(index => words[index].End > start && words[index].Start < end).ToArray();
                return new(inside.Length == 0 ? null : new WordSpan(inside[0], inside[^1]), start, end, selection.ClipId, false, true);
            }
            default: throw Invalid();
        }
    }

    internal static int IndexOf(IReadOnlyList<TimedWord> words, string id)
    {
        for (var index = 0; index < words.Count; index++) if (words[index].Id == id) return index;
        return -1;
    }

    internal static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
}

/// <summary>shared/prompts/ask-claude.json (ai.md §18.3). Pure: the same inputs give the same strings. Twin of the Mac
/// <c>AskClaudePrompt</c>.</summary>
public sealed class AskClaudePrompt
{
    /// <summary>The file, relative to the shared root.</summary>
    public const string Path = "prompts/ask-claude.json";

    private readonly JsonObject document;

    /// <summary>SHA-256 of the file's bytes with CRLF read as LF.</summary>
    public string Sha256 { get; }

    /// <summary>Parses the prompt; throws <c>SharedResourcesMissing</c> when it is not schema 1, prompt 1, with system text, an output
    /// schema and a toolbox.</summary>
    public AskClaudePrompt(JsonObject document, string sha256)
    {
        if (AiJson.Integer(document["schemaVersion"]) != 1 || AiJson.Integer(document["promptVersion"]) != 1 || AiJson.String(document["system"]) is null ||
            AiJson.Get(document["output"], "schema") is not JsonObject || AiJson.Array(document["toolbox"]).Count == 0) throw ClipAutopilotPrompt.Missing();
        this.document = document;
        Sha256 = sha256;
    }

    /// <summary>Reads the file under <paramref name="sharedRoot"/>.</summary>
    public static AskClaudePrompt Load(string sharedRoot)
    {
        var (document, sha) = ClipAutopilotPrompt.ReadShared(sharedRoot, Path);
        return new(document, sha);
    }

    /// <summary>The prompt's own version.</summary>
    public int PromptVersion => AiJson.Integer(document["promptVersion"]) ?? 1;
    private int Limit(string key, int fallback) => AiJson.Integer(AiJson.Get(document["limits"], key)) ?? fallback;
#pragma warning disable CS1591
    public int MaxOps => Limit("maxOps", 12);
    public int ContextWords => Limit("contextWords", 20);
    public int MaxSelectionWords => Limit("maxSelectionWords", 400);
    public int MaxDetections => Limit("maxDetections", 24);
    public int MaxInstructionChars => Limit("maxInstructionChars", 500);
    public int MaxTextChars => Limit("maxTextChars", 80);
    public int MaxReasonChars => Limit("maxReasonChars", 120);
    public int MaxChoiceChars => Limit("maxChoiceChars", 120);
    public int MaxDetectionTextChars => Limit("maxDetectionTextChars", 60);
#pragma warning restore CS1591
    /// <summary>The system text.</summary>
    public string System => AiJson.String(document["system"]) ?? "";
    /// <summary>The reply schema's name.</summary>
    public string SchemaName => AiJson.String(AiJson.Get(document["output"], "name")) ?? "ask_claude_ops";
    /// <summary>The reply schema.</summary>
    public JsonObject Schema => document["output"]!["schema"]!.DeepClone().AsObject();
    /// <summary>The reply's output cap.</summary>
    public int MaxOutputTokens => AiJson.Integer(AiJson.Get(document["generation"], "maxOutputTokens")) ?? 4000;
    /// <summary>The stickers the prompt offers: the bundled emoji (shared/fonts/noto-emoji/png128), without variation selectors.</summary>
    public IReadOnlySet<string> Stickers => AiJson.Array(document["stickers"]).Select(AiJson.String).OfType<string>().ToHashSet(StringComparer.Ordinal);
    /// <summary>The toolbox kinds the prompt offers, in its order.</summary>
    public IReadOnlyList<string> Kinds => AiJson.Array(document["toolbox"]).Select(tool => AiJson.String(AiJson.Get(tool, "kind"))).OfType<string>().ToArray();

    private string Template(string key) => AiJson.String(AiJson.Get(document["request"], key)) ?? "";

    /// <summary>Replaces each <c>{key}</c> in turn, as the Mac's <c>fill</c> does.</summary>
    private static string Fill(string template, params (string Key, string Value)[] values)
    {
        foreach (var (key, value) in values) template = template.Replace("{" + key + "}", value, StringComparison.Ordinal);
        return template;
    }

    /// <summary>Seconds and normalized numbers in the request: two decimals, a point, no grouping, rounded half to even on the exact
    /// binary value as C's <c>%.2f</c> rounds (the Mac's <c>String(format:)</c>).</summary>
    public static string Number(double value)
    {
        if (!double.IsFinite(value)) return "0.00";
        var negative = value < 0 || value == 0 && double.IsNegative(value);
        var bits = BitConverter.DoubleToUInt64Bits(Math.Abs(value));
        var exponentBits = (int)((bits >> 52) & 2047);
        var mantissa = bits & ((1UL << 52) - 1);
        var exponent = exponentBits == 0 ? -1074 : exponentBits - 1075;
        if (exponentBits != 0) mantissa |= 1UL << 52;
        var scaled = new BigInteger(mantissa) * 100;
        BigInteger hundredths;
        if (exponent >= 0) hundredths = scaled << exponent;
        else
        {
            var shift = -exponent;
            hundredths = scaled >> shift;
            var remainder = scaled - (hundredths << shift);
            var half = BigInteger.One << (shift - 1);
            if (remainder > half || remainder == half && !hundredths.IsEven) hundredths += 1;
        }
        var digits = hundredths.ToString(CultureInfo.InvariantCulture).PadLeft(3, '0');
        return (negative ? "-" : "") + digits[..^2] + "." + digits[^2..];
    }

    private static string Text(IReadOnlyList<TimedWord> words, IReadOnlyDictionary<string, string> corrections, int index) =>
        corrections.TryGetValue(words[index].Id, out var fixedText) ? fixedText : words[index].Text;

    /// <summary>The instruction for <paramref name="instruction"/> on <paramref name="scope"/>. <paramref name="current"/> are the lines
    /// naming what the stretch already has, <paramref name="detections"/> the on-screen findings (at most <see cref="MaxDetections"/>),
    /// <paramref name="aspect"/> the export shape.</summary>
    public string Instruction(string instruction, AskClaudeScope scope, Project project, IReadOnlyList<string> current,
        IReadOnlyList<AskClaudeDetection> detections, string aspect)
    {
        var words = project.Transcript?.Words ?? [];
        var corrections = project.Edits.Corrections;
        string Word(int index) => Text(words, corrections, index);
        string selection;
        if (scope.Words is { } span && !scope.IsTime)
            selection = Fill(Template(scope.IsClip ? "selectionClip" : "selectionWords"), ("first", Int(span.Start)), ("last", Int(span.End)),
                ("start", Number(scope.Start)), ("end", Number(scope.End)));
        else selection = Fill(Template("selectionTime"), ("start", Number(scope.Start)), ("end", Number(scope.End)));
        string lines, before, after;
        if (scope.Words is { } range)
        {
            lines = string.Join("\n", Enumerable.Range(range.Start, range.End - range.Start + 1).Take(MaxSelectionWords).Select(index =>
                Fill(Template("wordLine"), ("index", Int(index)), ("start", Number(words[index].Start)), ("end", Number(words[index].End)), ("text", Word(index)))));
            var lower = Math.Max(0, range.Start - ContextWords);
            before = lower < range.Start ? string.Join(" ", Enumerable.Range(lower, range.Start - lower).Select(Word)) : Template("noContext");
            var upper = Math.Min(words.Count, range.End + 1 + ContextWords);
            after = range.End + 1 < upper ? string.Join(" ", Enumerable.Range(range.End + 1, upper - range.End - 1).Select(Word)) : Template("noContext");
        }
        else { lines = Template("noWords"); before = Template("noContext"); after = Template("noContext"); }
        string clip;
        var found = scope.ClipId is { } id ? project.Edits.Clips.FirstOrDefault(item => item.Id == id) : null;
        var first = found is null ? -1 : AskClaudeScope.IndexOf(words, found.StartWordId);
        var last = found is null ? -1 : AskClaudeScope.IndexOf(words, found.EndWordId);
        if (found is not null && first >= 0 && last >= 0)
        {
            var title = ClipText.Trim(found.Title ?? "");
            clip = Fill(Template("clipLine"), ("title", title.Length == 0 ? "Untitled" : title), ("start", Number(words[first].Start)), ("end", Number(words[last].End)));
        }
        else clip = Template("noClip");
        var video = project.Media.Source.Video;
        var quarter = video is { RotationDegrees: 90 or 270 };
        var frame = Fill(Template("frameLine"), ("width", Int(video is null ? 1920 : quarter ? video.Height : video.Width)),
            ("height", Int(video is null ? 1080 : quarter ? video.Width : video.Height)), ("aspect", aspect));
        var detectionLines = detections.Take(MaxDetections).Select(detection =>
        {
            var reads = detection.Text is { } text ? Fill(Template("detectionText"), ("text", ClipText.Limit(ClipText.Trim(text), MaxDetectionTextChars))) : "";
            return Fill(Template("detectionLine"), ("label", detection.Label), ("kind", Wire(detection.Kind)), ("start", Number(detection.Start)),
                ("end", Number(detection.End)), ("x", Number(detection.Rect.X)), ("y", Number(detection.Rect.Y)), ("width", Number(detection.Rect.Width)),
                ("height", Number(detection.Rect.Height)), ("text", reads));
        }).ToArray();
        var tools = string.Join("\n", AiJson.Array(document["toolbox"]).Select(tool => Fill(Template("toolLine"),
            ("kind", AiJson.String(AiJson.Get(tool, "kind")) ?? ""), ("group", AiJson.String(AiJson.Get(tool, "group")) ?? ""),
            ("use", AiJson.String(AiJson.Get(tool, "use")) ?? ""), ("fields", AiJson.String(AiJson.Get(tool, "fields")) ?? ""))));
        return Fill(Template("instruction"),
            ("instruction", ClipText.Limit(ClipText.Trim(instruction), MaxInstructionChars)), ("selection", selection), ("words", lines),
            ("before", before), ("after", after), ("clip", clip), ("frame", frame),
            ("current", current.Count == 0 ? Template("nothingCurrent") : string.Join("\n", current)),
            ("detections", detectionLines.Length == 0 ? Template("noDetections") : string.Join("\n", detectionLines)),
            ("toolbox", tools));
    }

    /// <summary>The lines naming what the stretch already has: effects that overlap it, its clip's zooms in it, and corrections and
    /// cuts on its words.</summary>
    public IReadOnlyList<string> Current(AskClaudeScope scope, Project project)
    {
        var words = project.Transcript?.Words ?? [];
        string Line(string kind, double start, double end, string detail) =>
            Fill(Template("currentLine"), ("kind", kind), ("start", Number(start)), ("end", Number(end)), ("detail", detail));
        var lines = new List<string>();
        foreach (var effect in ClipEffects.Rendered(project, scope.ClipId).Where(effect => effect.End > scope.Start && effect.Start < scope.End))
        {
            var detail = effect.Text is { } text ? " \"" + text + "\"" : effect.Sound?.Id is { } sound ? " " + sound : "";
            lines.Add(Line(effect.Kind, effect.Start, effect.End, detail));
        }
        if (scope.ClipId is { } clip)
            foreach (var cue in project.MotionCues.Where(cue => cue.ClipID == clip && cue.SourceEnd > scope.Start && cue.SourceStart < scope.End))
                lines.Add(Line("zoom", cue.SourceStart, cue.SourceEnd, " " + Number(cue.Keyframes.Count == 0 ? 1 : cue.Keyframes.Max(frame => frame.Scale))));
        if (scope.Words is { } range)
        {
            var cut = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
            for (var index = range.Start; index <= range.End && index < words.Count; index++)
            {
                if (project.Edits.Corrections.TryGetValue(words[index].Id, out var fixedText))
                    lines.Add(Line("correction", words[index].Start, words[index].End, " [" + Int(index) + "] \"" + fixedText + "\""));
                if (cut.Contains(words[index].Id)) lines.Add(Line("jumpCut", words[index].Start, words[index].End, " [" + Int(index) + "]"));
            }
        }
        return lines;
    }

    /// <summary>The request: feature <c>askClaude</c>, the system text, the instruction, the strict reply schema, at extra high effort.</summary>
    public LlmRequestParts Request(string instruction, AskClaudeScope scope, Project project, IReadOnlyList<AskClaudeDetection> detections, string aspect) =>
        new(System, Instruction(instruction, scope, project, Current(scope, project), detections, aspect), SchemaName, Schema, MaxOutputTokens);

    internal static string Int(int value) => value.ToString(CultureInfo.InvariantCulture);
    /// <summary>A detection kind's wire name.</summary>
    public static string Wire(AskClaudeDetectionKind kind) => kind == AskClaudeDetectionKind.Face ? "face" : "text";
}

/// <summary>The provider-independent parts of an Ask Claude request; the service adds the feature, effort, timeout and language.</summary>
public sealed record LlmRequestParts(string System, string Instruction, string SchemaName, JsonObject Schema, int MaxOutputTokens);

/// <summary>Claude's checked answer (ai.md §18.4): one operation per row, in reply order, with the choice Claude made where the
/// instruction was ambiguous and what the validator repaired.</summary>
public sealed record AskClaudeAnswer(string Summary, IReadOnlyList<ClipAutopilotOperation> Operations, IReadOnlyDictionary<string, string> Choices, IReadOnlyList<string> Repairs)
{
    /// <summary>The rows that need a paid click before they run: a voice rewrite, music.</summary>
    public IReadOnlyList<ClipAutopilotOperation> Paid => Operations.Where(operation => operation.Action is ClipAutopilotAction.Rewrite or ClipAutopilotAction.Music).ToArray();
}

/// <summary>Checks a reply op by op, as the planner's validator does: a field outside its range is clamped, a missing one takes the
/// selection's value or a default, and an op that cannot act is dropped with a repair line (ai.md §18.4). Twin of the Mac
/// <c>AskClaudeValidator</c>.</summary>
public sealed partial class AskClaudeValidator(AskClaudePrompt prompt, AskClaudeScope scope, Project project, IReadOnlyList<AskClaudeDetection> detections)
{
    /// <summary>Bundled sound lengths in seconds; shared/data/sfx/&lt;id&gt;.wav holds exactly these.</summary>
    public static readonly IReadOnlyDictionary<string, double> SoundSeconds = new Dictionary<string, double>(StringComparer.Ordinal)
    {
        ["whoosh"] = 0.45, ["pop"] = 0.12, ["ding"] = 0.8
    };
    private static readonly IReadOnlyDictionary<string, string> SoundAliases = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["swoosh"] = "whoosh", ["swish"] = "whoosh", ["woosh"] = "whoosh", ["click"] = "pop", ["boop"] = "pop", ["bloop"] = "pop",
        ["bell"] = "ding", ["chime"] = "ding", ["ping"] = "ding", ["ding-dong"] = "ding"
    };
    /// <summary>A sound effect's level.</summary>
    public const double DefaultSoundGainDb = -6;
    private const double StickerScale = 1;
    private const double ZoomScale = 1.2;
    private const double MinimumZoomSeconds = 0.1;
    private const double MaximumFreezeSeconds = 5;
    private const int MaximumCorrectionScalars = 200;
    private static readonly string[] Positions = ["top", "center", "bottom", "topLeft", "topRight", "bottomLeft", "bottomRight"];

    private IReadOnlyList<TimedWord> Words => project.Transcript?.Words ?? [];

    /// <summary>The checked answer for one reply object.</summary>
    public AskClaudeAnswer Answer(JsonNode? reply)
    {
        var operations = new List<ClipAutopilotOperation>();
        var choices = new Dictionary<string, string>(StringComparer.Ordinal);
        var repairs = new List<string>();
        var summary = ClipText.Limit(ClipText.Trim(AiJson.String(AiJson.Get(reply, "summary")) ?? ""), 200);
        var effectIds = project.ClipEffects.Select(effect => effect.GetProperty("id").GetString()!).ToHashSet(StringComparer.Ordinal);
        var cutSoFar = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var corrected = new HashSet<string>(StringComparer.Ordinal);
        var raw = AiJson.Array(AiJson.Get(reply, "ops"));
        if (raw.Count > prompt.MaxOps) repairs.Add($"Kept the first {prompt.MaxOps} of {raw.Count} changes.");
        for (var index = 0; index < Math.Min(raw.Count, prompt.MaxOps); index++)
        {
            var item = raw[index];
            var kind = ClipText.Trim(AiJson.String(AiJson.Get(item, "kind")) ?? "");
            var reason = Scalars(ClipText.Trim(AiJson.String(AiJson.Get(item, "reason")) ?? ""), prompt.MaxReasonChars);
            var choice = Scalars(ClipText.Trim(AiJson.String(AiJson.Get(item, "choice")) ?? ""), prompt.MaxChoiceChars);
            var id = "ask-" + AskClaudePrompt.Int(index + 1) + "-" + (kind.Length == 0 ? "op" : kind);
            string? note = choice.Length == 0 ? null : choice;
            void Add(ClipAutopilotDecision decision, ClipAutopilotAction action)
            {
                operations.Add(new(id, decision, action, reason));
                if (note is not null) choices[id] = note;
            }
            void Drop(string why) => repairs.Add("Left out " + (kind.Length == 0 ? "a change" : kind) + ": " + why + ".");
            JsonElement? Effect(string effectKind, Action<JsonObject> build)
            {
                if (TimeRange(item, effectKind) is not { } range) return null;
                var value = Entry(Next(effectKind), effectKind, range.Start, range.End);
                build(value);
                var element = Element(value);
                if (!ClipEffects.IsValidEntry(element, project.Id)) return null;
                effectIds.Add(value["id"]!.GetValue<string>());
                return element;
            }
            string Next(string effectKind) => ClipEffects.NextId(effectKind, effectIds);
            switch (kind)
            {
                case "bleep" or "mute":
                {
                    if (WordRange(item) is not { } range || SpokenIds(range) is not { Count: > 0 } ids) { Drop("no words of the selection"); continue; }
                    var value = Entry(Next(kind), kind, Words[range.Start].Start, Words[range.End].End);
                    value["wordIds"] = new JsonArray(ids.Select(word => (JsonNode)JsonValue.Create(word)!).ToArray());
                    effectIds.Add(value["id"]!.GetValue<string>());
                    Add(ClipAutopilotDecision.Bleep, new ClipAutopilotAction.Effect(Element(value)));
                    break;
                }
                case "blur" or "pixelate":
                {
                    var target = Region(item);
                    if (target.Chosen && note is null) note = target.Note;
                    if (target.Rect is not { } rect) { Drop("no region to cover"); continue; }
                    var tracking = TrackingMode(item, target);
                    if (Effect(kind, value => { value["rect"] = RectNode(rect); value["tracking"] = tracking; value["track"] = new JsonArray(); }) is not { } built)
                    { Drop("no time in the selection"); continue; }
                    Add(ClipAutopilotDecision.Blur, new ClipAutopilotAction.Effect(built));
                    break;
                }
                case "title" or "lowerThird":
                {
                    var text = Scalars(ClipText.Trim(AiJson.String(AiJson.Get(item, "text")) ?? "").Replace("\n", " ", StringComparison.Ordinal), prompt.MaxTextChars);
                    if (text.Length == 0) { Drop("no text"); continue; }
                    var position = PositionValue(item, kind == "title" ? ["top", "center", "bottom"] : ["bottomLeft", "bottomRight"], kind == "title" ? "top" : "bottomLeft");
                    if (Effect(kind, value => { value["text"] = text; value["position"] = position; }) is not { } built) { Drop("no time in the selection"); continue; }
                    Add(ClipAutopilotDecision.Overlay, new ClipAutopilotAction.Effect(built));
                    break;
                }
                case "sticker":
                {
                    var text = WithoutVariationSelectors(ClipText.Trim(AiJson.String(AiJson.Get(item, "text")) ?? ""));
                    if (!prompt.Stickers.Contains(text)) { Drop("not one of the bundled emoji"); continue; }
                    var position = PositionValue(item, ["topLeft", "topRight", "bottomLeft", "bottomRight", "center"], "topRight");
                    var scale = Clamp(AiJson.Number(AiJson.Get(item, "scale")), 0.5, 3, StickerScale);
                    if (Effect("sticker", value => { value["text"] = text; value["position"] = position; value["scale"] = scale; }) is not { } built)
                    { Drop("no time in the selection"); continue; }
                    Add(ClipAutopilotDecision.Overlay, new ClipAutopilotAction.Effect(built));
                    break;
                }
                case "arrow" or "circle":
                {
                    var target = Region(item);
                    if (target.Chosen && note is null) note = target.Note;
                    if (target.Rect is not { } rect) { Drop("nothing to point at"); continue; }
                    if (Effect(kind, value => value["rect"] = RectNode(rect)) is not { } built) { Drop("no time in the selection"); continue; }
                    Add(ClipAutopilotDecision.Overlay, new ClipAutopilotAction.Effect(built));
                    break;
                }
                case "progress":
                {
                    var position = PositionValue(item, ["top", "bottom"], "bottom");
                    if (Effect("progress", value => value["position"] = position) is not { } built) { Drop("no time in the selection"); continue; }
                    Add(ClipAutopilotDecision.Overlay, new ClipAutopilotAction.Effect(built));
                    break;
                }
                case "freeze":
                {
                    if (TimeRange(item, "freeze") is not { } range) { Drop("no time in the selection"); continue; }
                    var length = Math.Min(MaximumFreezeSeconds, Math.Max(0.3, range.End - range.Start));
                    var value = Entry(Next("freeze"), "freeze", range.Start, range.Start + length);
                    effectIds.Add(value["id"]!.GetValue<string>());
                    Add(ClipAutopilotDecision.Freeze, new ClipAutopilotAction.Effect(Element(value)));
                    break;
                }
                case "sound":
                {
                    var named = ClipText.Trim(AiJson.String(AiJson.Get(item, "sound")) ?? "").ToLowerInvariant();
                    var sound = SoundSeconds.ContainsKey(named) ? named : SoundAliases.GetValueOrDefault(named) ?? "whoosh";
                    if (sound != named && note is null) note = "a " + sound;
                    var start = Math.Max(scope.Start, Math.Min(scope.End, Seconds(AiJson.Get(item, "start")) ?? scope.Start));
                    var length = SoundSeconds.GetValueOrDefault(sound, 0.45);
                    var value = Entry(Next("sound"), "sound", start, start + length);
                    value["sound"] = new JsonObject
                    {
                        ["source"] = "bundled", ["id"] = sound, ["durationSeconds"] = length,
                        ["title"] = char.ToUpperInvariant(sound[0]) + sound[1..], ["license"] = "cc0"
                    };
                    value["gainDb"] = DefaultSoundGainDb;
                    effectIds.Add(value["id"]!.GetValue<string>());
                    Add(ClipAutopilotDecision.Sound, new ClipAutopilotAction.Effect(Element(value)));
                    break;
                }
                case "speed":
                {
                    if (TimeRange(item, null) is not { } range) { Drop("no time in the selection"); continue; }
                    var rate = Clamp(AiJson.Number(AiJson.Get(item, "rate")), 0.5, 2, 1);
                    if (Math.Abs(rate - 1) <= 0.01) { Drop("the same speed"); continue; }
                    Add(ClipAutopilotDecision.Stretch, new ClipAutopilotAction.Stretch(scope.ClipId, range.Start, range.End, rate));
                    break;
                }
                case "jumpCut":
                {
                    if (WordRange(item) is not { } range) { Drop("no words of the selection"); continue; }
                    var ids = range.Indices.Select(position => Words[position].Id).Where(word => !cutSoFar.Contains(word)).ToArray();
                    if (ids.Length == 0) { Drop("those words are already cut"); continue; }
                    cutSoFar.UnionWith(ids);
                    Add(ClipAutopilotDecision.Cut, new ClipAutopilotAction.Edit(new EditOperation.CutSelection(ids)));
                    break;
                }
                case "zoom":
                {
                    if ((scope.ClipId ?? ClipContaining()) is not { } clip) { Drop("a zoom needs a clip"); continue; }
                    if (TimeRange(item, null) is not { } range || range.End - range.Start < MinimumZoomSeconds) { Drop("no time in the selection"); continue; }
                    var scale = Clamp(AiJson.Number(AiJson.Get(item, "scale")), 1.05, ClipAutopilotMapping.MaximumZoomScale, ZoomScale);
                    var cueIds = project.MotionCues.Select(cue => cue.Id).Concat(operations.Select(operation => operation.Action)
                        .OfType<ClipAutopilotAction.Motion>().Select(motion => motion.Cue.Id)).ToHashSet(StringComparer.Ordinal);
                    var cueIndex = 1;
                    while (cueIds.Contains(clip + "-ask-" + AskClaudePrompt.Int(cueIndex))) cueIndex++;
                    var cue = new MotionCue(clip + "-ask-" + AskClaudePrompt.Int(cueIndex), clip, range.Start, range.End,
                        [new MotionKeyframe(0, scale, 0.5, 0.5), new MotionKeyframe(1, scale, 0.5, 0.5)]);
                    Add(ClipAutopilotDecision.Zoom, new ClipAutopilotAction.Motion(cue));
                    break;
                }
                case "correction":
                {
                    if (WordRange(item) is not { } range) { Drop("no word of the selection"); continue; }
                    var word = Words[range.Start];
                    var text = ClipText.Trim(AiJson.String(AiJson.Get(item, "text")) ?? "");
                    if (word.Kind != WordKind.Word || corrected.Contains(word.Id) || text.Length == 0 || text.EnumerateRunes().Count() > MaximumCorrectionScalars ||
                        text == (project.Edits.Corrections.GetValueOrDefault(word.Id) ?? word.Text)) { Drop("no new spelling"); continue; }
                    corrected.Add(word.Id);
                    Add(ClipAutopilotDecision.Correction, new ClipAutopilotAction.Edit(new EditOperation.Correct(word.Id, EditingAlgorithms.Nfc(text))));
                    break;
                }
                case "rewrite":
                {
                    if (WordRange(item) is not { } range) { Drop("no words of the selection"); continue; }
                    var text = ClipText.Trim(AiJson.String(AiJson.Get(item, "text")) ?? "");
                    if (text.Length == 0) { Drop("no new wording"); continue; }
                    Add(ClipAutopilotDecision.Rewrite, new ClipAutopilotAction.Rewrite(range, text));
                    break;
                }
                case "translate":
                {
                    if (WordRange(item) is not { } range) { Drop("no words of the selection"); continue; }
                    var language = ClipText.Trim(AiJson.String(AiJson.Get(item, "language")) ?? "").ToLowerInvariant();
                    var text = ClipText.Trim(AiJson.String(AiJson.Get(item, "text")) ?? "");
                    if (!LanguageTag().IsMatch(language) || text.Length == 0) { Drop("no language or translation"); continue; }
                    Add(ClipAutopilotDecision.Translate, new ClipAutopilotAction.TranslateCaptions(scope.ClipId, range.Start, range.End, language, text));
                    break;
                }
                case "music":
                {
                    if ((scope.ClipId ?? ClipContaining()) is not { } clip) { Drop("music needs a clip"); continue; }
                    var mood = Scalars(ClipText.Trim(AiJson.String(AiJson.Get(item, "text")) ?? ""), 200);
                    if (mood.Length == 0) { Drop("no mood"); continue; }
                    var music = new ClipAutopilotPlan.Music(Scalars(mood, 60), mood, "Instrumental background music, " + mood + ", sits under a voice", reason, -20);
                    Add(ClipAutopilotDecision.Music, new ClipAutopilotAction.Music(new(clip, music, [], Math.Max(1, scope.End - scope.Start))));
                    break;
                }
                case "duck":
                {
                    if (project.Music.All(entry => entry.ClipId != scope.ClipId)) { Drop("there is no music to duck"); continue; }
                    Add(ClipAutopilotDecision.Duck, new ClipAutopilotAction.MusicDucking(scope.ClipId, true));
                    break;
                }
                default: Drop("not in the toolbox"); break;
            }
        }
        return new(summary, operations, choices, repairs);
    }

    // MARK: Fields

    [GeneratedRegex("\\A[a-z]{2,3}(-[a-z0-9]{2,8})*\\z", RegexOptions.CultureInvariant)]
    private static partial Regex LanguageTag();

    /// <summary>The first <paramref name="limit"/> Unicode scalars of <paramref name="text"/>.</summary>
    internal static string Scalars(string text, int limit) => string.Concat(text.EnumerateRunes().Take(limit).Select(rune => rune.ToString()));
    private static double? Seconds(JsonNode? value) => AiJson.Number(value) is { } number && double.IsFinite(number) && number >= 0 ? number : null;
    private static int Integer(JsonNode? value) => AiJson.Number(value) is { } number && double.IsFinite(number) ? (int)Math.Clamp(Math.Truncate(number), int.MinValue, int.MaxValue) : -1;
    private static double Clamp(double? value, double lower, double upper, double fallback) =>
        value is { } number && double.IsFinite(number) && number != 0 ? Math.Min(upper, Math.Max(lower, number)) : fallback;
    private static string WithoutVariationSelectors(string text) => new(text.Where(unit => unit is not '️' and not '︎').ToArray());

    private JsonObject Entry(string id, string kind, double start, double end) => new()
    {
        ["id"] = id, ["clipId"] = scope.ClipId, ["kind"] = kind, ["start"] = start, ["end"] = end
    };
    private static JsonElement Element(JsonObject value)
    {
        using var document = JsonDocument.Parse(value.ToJsonString());
        return document.RootElement.Clone();
    }
    private static JsonObject RectNode(ClipEffectRect rect) => new() { ["x"] = rect.X, ["y"] = rect.Y, ["width"] = rect.Width, ["height"] = rect.Height };

    /// <summary>The reply's word range clamped to the selection; the whole selection when the reply gives none or an empty one.</summary>
    private WordSpan? WordRange(JsonNode? item)
    {
        if (scope.Words is not { } selection) return null;
        var start = Integer(AiJson.Get(item, "startWord"));
        var end = Integer(AiJson.Get(item, "endWord"));
        if (start < 0 && end < 0)
        {
            if (Seconds(AiJson.Get(item, "start")) is { } first && Seconds(AiJson.Get(item, "end")) is { } last && last > first)
            {
                var inside = selection.Indices.Where(index => Words[index].End > first && Words[index].Start < last).ToArray();
                if (inside.Length > 0) return new(inside[0], inside[^1]);
            }
            return selection;
        }
        var lower = Math.Max(selection.Start, start < 0 ? end : start);
        var upper = Math.Min(selection.End, end < 0 ? start : end);
        return lower <= upper ? new(lower, upper) : null;
    }

    /// <summary>Spoken word ids in <paramref name="range"/> (no events), for a bleep.</summary>
    private IReadOnlyList<string> SpokenIds(WordSpan range) => range.Indices.Where(index => Words[index].Kind == WordKind.Word).Select(index => Words[index].Id).ToArray();

    /// <summary>The reply's seconds clamped to the selection; its words' times when it gives none; the selection otherwise. A freeze
    /// with no end holds 1 s.</summary>
    private (double Start, double End)? TimeRange(JsonNode? item, string? kind)
    {
        var start = Seconds(AiJson.Get(item, "start"));
        var end = Seconds(AiJson.Get(item, "end"));
        if (start is null && end is null && Integer(AiJson.Get(item, "startWord")) >= 0 && WordRange(item) is { } words)
        {
            start = Words[words.Start].Start;
            end = Words[words.End].End;
        }
        var lower = Math.Max(scope.Start, Math.Min(scope.End, start ?? scope.Start));
        var upper = Math.Min(scope.End, end ?? (kind == "freeze" ? lower + 1 : scope.End));
        if (kind == "freeze" && upper <= lower) upper = Math.Min(scope.End, lower + 1);
        return upper - lower >= 0.05 ? (lower, upper) : null;
    }

    private static string PositionValue(JsonNode? item, string[] allowed, string fallback)
    {
        var raw = ClipText.Trim(AiJson.String(AiJson.Get(item, "position")) ?? "");
        var value = Positions.Contains(raw) ? raw
            : Positions.FirstOrDefault(position => position.ToLowerInvariant() == raw.ToLowerInvariant().Replace(" ", "", StringComparison.Ordinal));
        return value is not null && allowed.Contains(value) ? value : fallback;
    }

    private sealed record RegionChoice(ClipEffectRect? Rect, AskClaudeDetection? Detection, bool Chosen, string? Note);

    /// <summary>The region an op covers: a detection label, "face" or "screen", or the reply's rect. Without any, the largest face (or
    /// text box) seen in the selection is pre-picked and named, so the row reads "Claude chose …".</summary>
    private RegionChoice Region(JsonNode? item)
    {
        var target = ClipText.Trim(AiJson.String(AiJson.Get(item, "target")) ?? "");
        var seen = detections.Where(detection => detection.End >= scope.Start && detection.Start <= scope.End).ToArray();
        if (seen.FirstOrDefault(detection => string.Equals(detection.Label, target, StringComparison.OrdinalIgnoreCase)) is { } found)
            return new(found.Rect, found, false, null);
        var explicitRect = new ClipEffectRect(AiJson.Number(AiJson.Get(item, "x")) ?? 0, AiJson.Number(AiJson.Get(item, "y")) ?? 0,
            AiJson.Number(AiJson.Get(item, "width")) ?? 0, AiJson.Number(AiJson.Get(item, "height")) ?? 0);
        var lowered = target.ToLowerInvariant();
        if (lowered == "screen")
            return new(explicitRect.Width > 0 && explicitRect.Height > 0 ? Clamped(explicitRect) : new ClipEffectRect(0, 0, 1, 1), null, false, null);
        var wantsFace = lowered == "face";
        if (!wantsFace && explicitRect.Width > 0 && explicitRect.Height > 0 && double.IsFinite(explicitRect.X) && double.IsFinite(explicitRect.Y))
            return new(Clamped(explicitRect), null, false, null);
        var faces = seen.Where(detection => detection.Kind == AskClaudeDetectionKind.Face)
            .OrderByDescending(detection => detection.Rect.Width * detection.Rect.Height).ToArray();
        var pool = wantsFace ? faces : faces.Length == 0 ? seen.Where(detection => detection.Kind == AskClaudeDetectionKind.Text).ToArray() : faces;
        if (pool.Length == 0) return new(null, null, false, null);
        var pick = pool[0];
        var middle = pick.Rect.X + pick.Rect.Width / 2;
        var side = middle < 0.4 ? " at the left" : middle > 0.6 ? " at the right" : "";
        var name = pick.Kind == AskClaudeDetectionKind.Face ? "the face" + side : "the text \"" + Scalars(pick.Text ?? "", 30) + "\"";
        return new(pick.Rect, pick, pool.Length > 1 || !wantsFace, name);
    }

    /// <summary>A rect kept inside the frame, each side at least 0.01 (Mac <c>Rect.clamped</c>).</summary>
    public static ClipEffectRect Clamped(ClipEffectRect rect)
    {
        const double side = 0.01;
        var width = Math.Min(1, Math.Max(side, double.IsFinite(rect.Width) ? rect.Width : side));
        var height = Math.Min(1, Math.Max(side, double.IsFinite(rect.Height) ? rect.Height : side));
        var x = Math.Min(1 - width, Math.Max(0, double.IsFinite(rect.X) ? rect.X : 0));
        var y = Math.Min(1 - height, Math.Max(0, double.IsFinite(rect.Y) ? rect.Y : 0));
        return new(x, y, width, height);
    }

    private static string TrackingMode(JsonNode? item, RegionChoice target)
    {
        var mode = ClipText.Trim(AiJson.String(AiJson.Get(item, "tracking")) ?? "");
        if (mode is "none" or "face" or "saliency") return mode;
        return target.Detection?.Kind == AskClaudeDetectionKind.Face ? "face" : "none";
    }

    /// <summary>The clip whose words hold the whole selection, for a zoom or music asked on the full video.</summary>
    private string? ClipContaining()
    {
        var words = Words;
        return project.Edits.Clips.FirstOrDefault(clip =>
        {
            var first = AskClaudeScope.IndexOf(words, clip.StartWordId);
            var last = AskClaudeScope.IndexOf(words, clip.EndWordId);
            return first >= 0 && last >= 0 && words[first].Start <= scope.Start + 1e-6 && words[last].End >= scope.End - 1e-6;
        })?.Id;
    }
}
