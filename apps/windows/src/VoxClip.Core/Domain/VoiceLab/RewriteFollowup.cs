using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>A reply gives one new version; <see cref="Versions"/> ("3 more versions") gives alternatives.</summary>
public enum RewriteFollowupKind
{
    /// <summary>One new version of the change's words.</summary>
    Reply,
    /// <summary>Up to the prompt's <c>alternatives</c> new versions.</summary>
    Versions
}

/// <summary>One message to the AI about one change of a Rewrite proposal (design.md §6.3 "Talk back to Claude", ADR-R50): the
/// scope's transcript as the passage request sends it, the change's recorded words, every version of its new words so far and every
/// message the user wrote about it, in order. The newest message is the instruction. Twin of the Mac <c>RewriteFollowupRequest</c>.</summary>
/// <param name="Kind">A reply or "3 more versions".</param>
/// <param name="Scope">The scope as the source block names it: "passage", "clip" or "fullTake".</param>
/// <param name="Language">The transcript's language code.</param>
/// <param name="Source">The scope's words, joined by spaces, as Rewrite's passage request sends them.</param>
/// <param name="Ordinal">The change's ordinal, "Change 2" in the transcript and the change list.</param>
/// <param name="Recorded">The speaker's words the change replaces, as recorded (corrected spelling); empty for an insertion.</param>
/// <param name="Versions">Every version of the change's new words so far, oldest first; the last is in the text now.</param>
/// <param name="Messages">Every message the user sent about the change, oldest first; the last is the instruction.</param>
public sealed record RewriteFollowupRequest(RewriteFollowupKind Kind, string Scope, string Language, string Source, int Ordinal, string Recorded,
    IReadOnlyList<string> Versions, IReadOnlyList<string> Messages);

/// <summary>The AI's checked answer to a <see cref="RewriteFollowupRequest"/>: one new version (<see cref="Texts"/> holds one) or up to
/// the prompt's alternatives, its note and its own next steps. Twin of the Mac <c>RewriteFollowupReply</c>.</summary>
/// <param name="Texts">The new versions' spoken words, in order: one for a reply, up to three for "3 more versions".</param>
/// <param name="Note">One sentence on what changed, at most <see cref="RewriteFollowupPrompt.MaxNoteWords"/> words.</param>
/// <param name="NextSteps">The AI's next steps for this text, at most two of at most six words each: the thread's ✦ bubbles.</param>
public sealed record RewriteFollowupReply(IReadOnlyList<string> Texts, string Note, IReadOnlyList<string> NextSteps);

/// <summary>shared/prompts/rewrite-followup.json (ai.md §12.10). Pure: the same inputs give the same strings, which
/// shared/fixtures/rewrite-thread/request-cases.json pins. Twin of the Mac <c>RewriteFollowupPrompt</c>.</summary>
public sealed class RewriteFollowupPrompt
{
    /// <summary>The file, relative to the shared root.</summary>
    public const string Path = "prompts/rewrite-followup.json";
    private static readonly Regex LanguageCode = new(@"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Link = new("https?://", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
    private static readonly string[] Templates =
        ["sourceBlock", "changeBlock", "noRecorded", "versionsBlock", "versionLine", "messagesBlock", "messageLine", "returnLine", "versionsReturnLine"];
    private readonly JsonObject document;

    /// <summary>SHA-256 of the file's bytes with CRLF read as LF.</summary>
    public string Sha256 { get; }

    /// <summary>Parses the prompt; throws <c>SharedResourcesMissing</c> unless it is schema 1, prompt 1, with system text, every request
    /// template and both reply schemas.</summary>
    public RewriteFollowupPrompt(JsonObject document, string sha256)
    {
        if (AiJson.Integer(document["schemaVersion"]) != 1 || AiJson.Integer(document["promptVersion"]) != 1 || AiJson.String(document["system"]) is null ||
            Templates.Any(key => AiJson.String(AiJson.Get(document["request"], key)) is null) ||
            !IsObjectSchema(document["schema"]) || !IsObjectSchema(document["versionsSchema"])) throw ClipAutopilotPrompt.Missing();
        this.document = document;
        Sha256 = sha256;
    }

    /// <summary>Reads the file under <paramref name="sharedRoot"/>.</summary>
    public static RewriteFollowupPrompt Load(string sharedRoot)
    {
        var (document, sha) = ClipAutopilotPrompt.ReadShared(sharedRoot, Path);
        return new(document, sha);
    }

    private static bool IsObjectSchema(JsonNode? node) => node is JsonObject schema && AiJson.String(schema["type"]) == "object" && schema["properties"] is JsonObject;

    /// <summary>The prompt's own version.</summary>
    public int PromptVersion => AiJson.Integer(document["promptVersion"]) ?? 1;
    /// <summary>The system text.</summary>
    public string System => AiJson.String(document["system"]) ?? "";
    private int Limit(string key, int fallback) => AiJson.Integer(AiJson.Get(document["limits"], key)) ?? fallback;
#pragma warning disable CS1591
    public int MaxMessages => Limit("maxMessages", 24);
    public int MaxMessageChars => Limit("maxMessageChars", 1000);
    public int MaxVersions => Limit("maxVersions", 40);
    public int MaxTextChars => Limit("maxTextChars", 4000);
    public int MaxNoteWords => Limit("maxNoteWords", 20);
    public int MaxNextSteps => Limit("maxNextSteps", 2);
    public int MaxNextStepWords => Limit("maxNextStepWords", 6);
    public int Alternatives => Limit("alternatives", 3);
#pragma warning restore CS1591
    /// <summary>The reply's output cap.</summary>
    public int MaxOutputTokens => AiJson.Integer(document["maxOutputTokens"]) ?? 4000;
    /// <summary>The bubbles the thread always shows after the AI's own: "Shorter", "Closer to my words", "3 more versions".</summary>
    public IReadOnlyList<string> SteadyBubbles => AiJson.Array(document["steadyBubbles"]).Select(AiJson.String).OfType<string>().ToArray();
    /// <summary>"✓ That's it, keep it", the first bubble: exactly Keep.</summary>
    public string KeepBubble => AiJson.String(document["keepBubble"]) ?? "";
    /// <summary>The reply schema's name for <paramref name="kind"/>.</summary>
    public string SchemaName(RewriteFollowupKind kind) => AiJson.String(document[kind == RewriteFollowupKind.Reply ? "schemaName" : "versionsSchemaName"]) ?? "";
    /// <summary>The reply schema for <paramref name="kind"/>, a copy.</summary>
    public JsonObject Schema(RewriteFollowupKind kind) => document[kind == RewriteFollowupKind.Reply ? "schema" : "versionsSchema"]!.DeepClone().AsObject();
    /// <summary>The request's tag for <paramref name="kind"/>.</summary>
    public static string Tag(RewriteFollowupKind kind) => kind == RewriteFollowupKind.Reply ? "rewrite-followup" : "rewrite-followup-versions";

    private string Template(string key) => AiJson.String(AiJson.Get(document["request"], key)) ?? "";

    /// <summary>Characters as the Mac's <c>String.count</c> counts them: grapheme clusters.</summary>
    private static int Characters(string text) => new StringInfo(text).LengthInTextElements;

    /// <summary>The request is refused before anything is sent when it has no version or message, or more than the limits allow.</summary>
    public void Validate(RewriteFollowupRequest input)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (!Enum.IsDefined(input.Kind) || input.Ordinal < 1 || input.Versions is null || input.Messages is null || input.Recorded is null ||
            input.Source is null || input.Language is null || input.Scope is null ||
            input.Versions.Count == 0 || input.Versions.Count > MaxVersions || input.Messages.Count == 0 || input.Messages.Count > MaxMessages ||
            input.Messages.Any(message => message is null || EditingAlgorithms.JsTrim(message).Length == 0 || Characters(message) > MaxMessageChars) ||
            input.Versions.Any(version => version is null || Characters(version) > MaxTextChars) || Characters(input.Recorded) > MaxTextChars ||
            EditingAlgorithms.JsTrim(input.Source).Length == 0 || Encoding.UTF8.GetByteCount(input.Source) > 20_000 || !LanguageCode.IsMatch(input.Language))
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
    }

    /// <summary>The scope's transcript, sent as the cached block: the same for every message about the same proposal.</summary>
    public string CachedBlock(RewriteFollowupRequest input) =>
        // The words go in last, so they are never read as a placeholder.
        Template("sourceBlock").Replace("{scope}", input.Scope, StringComparison.Ordinal).Replace("{language}", input.Language, StringComparison.Ordinal)
            .Replace("{source}", input.Source, StringComparison.Ordinal);

    /// <summary>The change, its versions, the messages and the return line, each block filled on its own so text from one is never read as
    /// another's placeholder.</summary>
    public string Instruction(RewriteFollowupRequest input)
    {
        string Lines(IReadOnlyList<string> items, string key) => string.Join("\n", items.Select((text, offset) => Template(key)
            .Replace("{index}", (offset + 1).ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("{text}", EditingAlgorithms.JsTrim(text), StringComparison.Ordinal)));
        var recorded = EditingAlgorithms.JsTrim(input.Recorded) is { Length: > 0 } words ? words : Template("noRecorded");
        var change = Template("changeBlock").Replace("{ordinal}", input.Ordinal.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("{recorded}", recorded, StringComparison.Ordinal);
        var versions = Template("versionsBlock").Replace("{versions}", Lines(input.Versions, "versionLine"), StringComparison.Ordinal);
        var messages = Template("messagesBlock").Replace("{messages}", Lines(input.Messages, "messageLine"), StringComparison.Ordinal);
        var ask = input.Kind == RewriteFollowupKind.Reply ? Template("returnLine")
            : Template("versionsReturnLine").Replace("{count}", Alternatives.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);
        return string.Join("\n\n", change, versions, messages, ask);
    }

    /// <summary>The request <c>RewriteFollowupService</c> sends, at Rewrite's effort (ai.md §2.1); throws <c>InvalidInput</c> for a request
    /// <see cref="Validate"/> refuses.</summary>
    public LlmRequest Request(RewriteFollowupRequest input, TimeSpan timeout, int? maxOutputTokens = null)
    {
        Validate(input);
        return new(LlmFeature.VoiceRewrite, System, CachedBlock(input), Instruction(input), SchemaName(input.Kind), Schema(input.Kind),
            maxOutputTokens ?? MaxOutputTokens, EffortLevel.Decision, timeout, input.Language, Tag(input.Kind));
    }

    /// <summary>A reply's spoken words, checked as a Rewrite passage is (voice-lab §8.9.1): plain spoken words with no link, markup or
    /// control characters; null when they are not.</summary>
    public string? Spoken(string raw)
    {
        var text = EditingAlgorithms.JsTrim(VoiceLabAudioTags.SanitizedRequest(raw, ""));
        if (text.Length == 0 || Characters(text) > MaxTextChars || Link.IsMatch(text) ||
            text.Any(character => char.GetUnicodeCategory(character) == UnicodeCategory.Control)) return null;
        return text;
    }

    /// <summary>The checked reply to <paramref name="input"/>: its spoken words (one, or up to <see cref="Alternatives"/> new ones for "3
    /// more versions", none repeating a version so far), the note cut to <see cref="MaxNoteWords"/> words, and at most
    /// <see cref="MaxNextSteps"/> next steps of at most <see cref="MaxNextStepWords"/> words that are not a steady or keep bubble. Throws
    /// <c>InvalidOutput</c> when no new words are usable.</summary>
    public RewriteFollowupReply Reply(JsonObject reply, RewriteFollowupRequest input)
    {
        ArgumentNullException.ThrowIfNull(reply);
        ArgumentNullException.ThrowIfNull(input);
        List<string> texts = [];
        if (input.Kind == RewriteFollowupKind.Reply)
        {
            if (AiJson.String(reply["text"]) is not { } raw || Spoken(raw) is not { } text)
                throw LlmErrors.Create(LlmErrorKind.InvalidOutput, "", "", LlmFeature.VoiceRewrite, detail: "The new words are not a plain spoken passage.");
            texts.Add(text);
        }
        else
        {
            var seen = input.Versions.Select(Key).ToHashSet(StringComparer.Ordinal);
            foreach (var raw in AiJson.Array(reply["alternatives"]).Select(AiJson.String).OfType<string>())
            {
                if (texts.Count >= Alternatives || Spoken(raw) is not { } text || !seen.Add(Key(text))) continue;
                texts.Add(text);
            }
            if (texts.Count == 0) throw LlmErrors.Create(LlmErrorKind.InvalidOutput, "", "", LlmFeature.VoiceRewrite, detail: "The reply has no new version.");
        }
        var words = EditingAlgorithms.SplitWords(EditingAlgorithms.JsTrim(AiJson.String(reply["note"]) ?? ""));
        var note = words.Count > MaxNoteWords ? string.Join(" ", words.Take(MaxNoteWords)) + "…" : string.Join(" ", words);
        var steady = SteadyBubbles.Append(KeepBubble).Select(Key).ToHashSet(StringComparer.Ordinal);
        List<string> steps = [];
        var seenSteps = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in AiJson.Array(reply["nextSteps"]).Select(AiJson.String).OfType<string>())
        {
            var step = string.Join(" ", EditingAlgorithms.SplitWords(EditingAlgorithms.JsTrim(raw)));
            var count = EditingAlgorithms.SplitWords(step).Count;
            if (steps.Count >= MaxNextSteps || count < 1 || count > MaxNextStepWords || steady.Contains(Key(step)) ||
                !seenSteps.Add(Key(step)) || Spoken(step) is null) continue;
            steps.Add(step);
        }
        return new(texts, note, steps);
    }

    /// <summary>Words compared as the thread compares versions: case, spacing and the punctuation around words aside.</summary>
    public static string Key(string text) => string.Join(" ", EditingAlgorithms.SplitWords(text.ToLowerInvariant())
        .Select(word => word.Trim(PunctuationAround(word))).Where(word => word.Length > 0));

    private static char[] PunctuationAround(string word) => word.Where(char.IsPunctuation).Distinct().ToArray();
}
