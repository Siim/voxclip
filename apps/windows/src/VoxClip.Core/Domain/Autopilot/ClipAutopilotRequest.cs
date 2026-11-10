using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using TranscriptModel = VoxClip.Core.Domain.Transcript.Transcript;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>The creator's caption choices from the clip style. A set field is fixed: every plan uses it as it is.</summary>
public sealed record ClipAutopilotCaptionPreference(string? StyleId = null, ClipAutopilotFont? Font = null, ClipAutopilotCaptionCase? TextCase = null)
{
    /// <summary>Nothing fixed.</summary>
    public bool IsEmpty => StyleId is null && Font is null && TextCase is null;
}

/// <summary>The tone the planner writes a clip's words in (ai.md §16.3; design §6.6 Tone row).</summary>
public abstract record ClipAutopilotTone
{
    /// <summary>Claude picks one of <paramref name="Offered"/> per clip, or none.</summary>
    public sealed record Auto(IReadOnlyList<RewriteTone> Offered) : ClipAutopilotTone;
    /// <summary>The creator's own tone: no tone change.</summary>
    public sealed record AsSaid : ClipAutopilotTone;
    /// <summary>A catalogue or saved tone the creator fixed.</summary>
    public sealed record Fixed(RewriteTone Tone) : ClipAutopilotTone;
}

/// <summary>What to plan: one clip span, several clip spans, or a whole video (or a range of it) as a series.</summary>
public abstract record ClipAutopilotMode
{
    /// <summary>One clip.</summary>
    public sealed record Clip(WordSpan Span) : ClipAutopilotMode;
    /// <summary>Clips chosen already, such as the top suggestions; each is its own clip request.</summary>
    public sealed record Clips(IReadOnlyList<WordSpan> Spans) : ClipAutopilotMode;
    /// <summary>The whole transcript when null; two stages.</summary>
    public sealed record Series(WordSpan? Range) : ClipAutopilotMode;
}

/// <summary>A plan request (ai.md §16.3). Twin of the Mac <c>ClipAutopilotRequest</c>.</summary>
public sealed record ClipAutopilotRequest(TranscriptModel Transcript, ProjectEdits Edits, ClipAutopilotMode Mode)
{
    /// <summary>The creator's fixed caption choices.</summary>
    public ClipAutopilotCaptionPreference? CaptionPreference { get; init; }
    /// <summary>BCP 47; the transcript's language when null.</summary>
    public string? Language { get; init; }
    /// <summary>An optional note from the creator, sent as data.</summary>
    public string? Note { get; init; }
    /// <summary>The tone of each clip's words; null sends no tone line.</summary>
    public ClipAutopilotTone? Tone { get; init; }
    /// <summary>A <c>clips</c> request's spans as Find Clips described them, one per span in the same order (Claude mode): each clip's
    /// plan is told its rank, its title and idea, and the other clips of the series, as a series' second stage is (prompt version 7).
    /// Empty plans each span on its own.</summary>
    public IReadOnlyList<ClipAutopilotMoment> Moments { get; init; } = [];
    /// <summary>A series request.</summary>
    public bool IsSeries => Mode is ClipAutopilotMode.Series;
    /// <summary>The same request for one clip span.</summary>
    public ClipAutopilotRequest ForClip(WordSpan span) => this with { Mode = new ClipAutopilotMode.Clip(span) };
}

/// <summary>What the second stage of a series tells the clip plan about its moment: its rank, the caption styles of the others, and
/// the other moments of the series in rank order (their titles and where they start, prompt version 7).</summary>
internal sealed record ClipAutopilotMomentBrief(int Rank, int Count, ClipAutopilotMoment Moment, IReadOnlyList<string> OtherStyles, IReadOnlyList<ClipAutopilotMoment> Others);

/// <summary>Everything the validator checks a reply against (ai.md §16.5), built once per request.</summary>
public sealed record ClipAutopilotContext(IReadOnlyList<TimedWord> Words, IReadOnlyDictionary<string, string> Corrections, IReadOnlySet<string> CutWordIds,
    IReadOnlyList<Pause> Pauses, IReadOnlySet<string> CutPauseIds, double PauseKeepSeconds, WordSpan Scope, IReadOnlySet<string> StyleIds,
    IReadOnlyDictionary<ClipAutopilotFont, string> Fonts, ClipAutopilotCaptionPreference? Preference, ClipAutopilotPrompt Prompt, ClipAutopilotTone? Tone = null,
    ClipAutopilotFrames? Frames = null)
{
    /// <summary>The word as shown, corrections applied.</summary>
    public string Text(int index) => Corrections.TryGetValue(Words[index].Id, out var text) ? text : Words[index].Text;
    /// <summary>Inside the scope and not already cut.</summary>
    public bool IsListed(int index) => Scope.Contains(index) && index >= 0 && index < Words.Count && !CutWordIds.Contains(Words[index].Id);
    /// <summary>A listed item of kind word.</summary>
    public bool IsListedWord(int index) => IsListed(index) && Words[index].Kind == WordKind.Word;
    /// <summary>Whether a font may be used.</summary>
    public bool Allows(ClipAutopilotFont font) => Fonts.ContainsKey(font) || font == Prompt.Defaults.Font;
    /// <summary>The caption style the creator fixed, when it is a built-in style other than off.</summary>
    public string? FixedStyle => Preference?.StyleId is { } style && StyleIds.Contains(style) && style != "off" ? style : null;

    /// <summary>This context with the plan's corrections applied on top of the project's.</summary>
    internal ClipAutopilotContext Correcting(IReadOnlyList<ClipAutopilotPlan.Correction> plan)
    {
        if (plan.Count == 0) return this;
        var merged = new Dictionary<string, string>(Corrections, StringComparer.Ordinal);
        foreach (var correction in plan) merged[Words[correction.Word].Id] = correction.Text;
        return this with { Corrections = merged };
    }
}

/// <summary>The bundled caption fonts of shared/fonts/fonts.json: upright faces only, keyed by family and weight.</summary>
public static class ClipAutopilotFonts
{
    /// <summary>Reads the table; the first file of a family and weight wins.</summary>
    public static IReadOnlyDictionary<ClipAutopilotFont, string> Load(string sharedRoot)
    {
        JsonNode? document;
        try { document = JsonNode.Parse(File.ReadAllText(Path.Combine(sharedRoot, "fonts", "fonts.json"))); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Text.Json.JsonException) { throw ClipAutopilotPrompt.Missing(); }
        var fonts = new Dictionary<ClipAutopilotFont, string>();
        foreach (var entry in AiJson.Array(AiJson.Get(document, "fonts")))
        {
            if (entry?["italic"] is JsonValue italic && italic.GetValueKind() == System.Text.Json.JsonValueKind.True) continue;
            if (AiJson.String(entry?["family"]) is not { } family || AiJson.Number(entry?["weight"]) is not { } weight || AiJson.String(entry?["file"]) is not { } file) continue;
            fonts.TryAdd(new(family, (int)weight), file);
        }
        if (fonts.Count == 0) throw ClipAutopilotPrompt.Missing();
        return fonts;
    }
}

/// <summary>Renders the request text from the prompt file (ai.md §16.4). Pure. Twin of the Mac <c>ClipAutopilotRequestBuilder</c>.</summary>
public static partial class ClipAutopilotRequestBuilder
{
    /// <summary>The rendered cached block and instruction, and the scope they cover.</summary>
    public sealed record Rendered(string CachedBlock, string Instruction, WordSpan Scope, int ListedWords);

    internal const int MaxNames = 20;

    /// <summary>A clip span as given, or the series range (the whole transcript when null); null when empty, outside the
    /// transcript, or a <c>clips</c> request.</summary>
    public static WordSpan? Scope(ClipAutopilotRequest request)
    {
        var count = request.Transcript.Words.Count;
        if (count == 0) return null;
        WordSpan range;
        switch (request.Mode)
        {
            case ClipAutopilotMode.Clip clip: range = clip.Span; break;
            case ClipAutopilotMode.Series series: range = series.Range ?? new(0, count - 1); break;
            default: return null;
        }
        return range.Start >= 0 && range.End < count && range.Start <= range.End ? range : null;
    }

    private static string Fixed1(double value) => EditingFormat.ToFixed1(value);
    private static string Whole(double value) => ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);
    private static Dictionary<string, string> Values(params (string Key, string Value)[] pairs) => pairs.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);

    internal static Rendered Render(ClipAutopilotRequest request, ClipAutopilotPrompt prompt, IReadOnlyList<CaptionStyle> styles,
        IReadOnlyDictionary<ClipAutopilotFont, string> fonts, IReadOnlyList<Pause> pauses, ClipAutopilotMomentBrief? moment = null, ClipAutopilotFrames? frames = null)
    {
        if (Scope(request) is not { } scope) throw Invalid();
        var words = request.Transcript.Words;
        var cut = request.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var listed = scope.Indices.Where(index => !cut.Contains(words[index].Id)).ToArray();
        if (!listed.Any(index => words[index].Kind == WordKind.Word) || listed.Length > prompt.Limits.MaxTranscriptWords) throw Invalid();
        if (request.Note is { } note && Encoding.UTF8.GetByteCount(note) > prompt.Limits.MaxNoteBytes) throw Invalid();
        var language = request.Language ?? request.Transcript.Language ?? "en";
        if (!LanguageTag().IsMatch(language)) throw Invalid();
        var cutPauses = request.Edits.CutPauseIds.ToHashSet(StringComparer.Ordinal);
        var uncutPauses = pauses.Where(pause => !cutPauses.Contains(pause.Id)).ToArray();
        var transcriptText = TranscriptBlock(words, listed, request.Edits.Corrections, uncutPauses, prompt);
        var styleLines = styles.Where(style => style.Id != "off").Select(style => prompt.Request("styleLine", Values(("id", style.Id), ("name", style.Name), ("description", style.Description))));
        var defaultFont = prompt.Defaults.Font;
        var fontLines = new[] { prompt.Request("defaultFontLine", Values(("family", defaultFont.Family), ("weight", defaultFont.Weight.ToString(CultureInfo.InvariantCulture)))) }
            .Concat(fonts.Keys.Where(font => font != defaultFont).OrderBy(font => font.Family, StringComparer.Ordinal).ThenBy(font => font.Weight)
                .Select(font => prompt.Request("fontLine", Values(("family", font.Family), ("weight", font.Weight.ToString(CultureInfo.InvariantCulture))))));
        var first = words[listed[0]];
        var last = words[listed[^1]];
        var seconds = request.IsSeries ? request.Transcript.DurationSeconds : last.End - first.Start;
        var spoken = SpokenTime(words, listed, request.Edits.Corrections, uncutPauses, request.Edits.PauseKeepSeconds);
        var rate = spoken.Seconds > 0 ? spoken.Words / spoken.Seconds : 0;
        var limits = prompt.Limits;
        var values = limits.TemplateValues();
        var block = prompt.Request("contextBlock", Values(("language", language), ("seconds", Fixed1(Math.Max(0, seconds))),
            ("wordsPerMinute", Whole(rate * 60)), ("minTargetSeconds", values["minTargetSeconds"]), ("maxTargetSeconds", values["maxTargetSeconds"]),
            ("wordsMin", Whole(rate * limits.MinTargetSeconds)), ("wordsMax", Whole(rate * limits.MaxTargetSeconds)),
            ("captionPreference", PreferenceLine(request.CaptionPreference, prompt)), ("styles", string.Join("\n", styleLines)),
            ("fonts", string.Join("\n", fontLines)), ("transcript", transcriptText)));
        string instruction;
        if (request.IsSeries)
        {
            instruction = prompt.Request("seriesInstruction", Values(("maxClips", limits.MaxClips.ToString(CultureInfo.InvariantCulture))));
        }
        else
        {
            var estimate = Math.Max(0, spoken.Seconds);
            var excess = estimate - limits.MaxTargetSeconds;
            var lengthHint = excess > 0 ? prompt.Request("lengthOver", Values(("excess", ((long)Math.Ceiling(excess)).ToString(CultureInfo.InvariantCulture))))
                                        : prompt.Request("lengthFits", Values());
            instruction = prompt.Request("clipInstruction", Values(("startWord", listed[0].ToString(CultureInfo.InvariantCulture)),
                ("endWord", listed[^1].ToString(CultureInfo.InvariantCulture)), ("seconds", Fixed1(Math.Max(0, last.End - first.Start))),
                ("estimate", Fixed1(estimate)), ("minTargetSeconds", values["minTargetSeconds"]), ("maxTargetSeconds", values["maxTargetSeconds"]),
                ("lengthHint", lengthHint)));
            var elsewhere = Names(words, scope, request.Edits.Corrections);
            if (elsewhere.Count > 0) instruction += prompt.Request("names", Values(("names", string.Join(", ", elsewhere))));
            if (frames is not null) instruction += FramesBlock(frames, prompt);
            if (request.Tone is { } tone) instruction += ToneLine(tone, prompt);
            if (moment is not null)
            {
                // Find Clips' moments carry no caption style: the plan picks one, told only the other clips (Claude mode).
                var fixedStyle = request.CaptionPreference?.StyleId is not null || moment.Moment.CaptionStyle.Length == 0;
                var caption = fixedStyle ? "" : prompt.Request("momentCaption", Values(("style", moment.Moment.CaptionStyle),
                    ("reason", moment.Moment.CaptionReason.Length == 0 ? "picked for the series" : moment.Moment.CaptionReason),
                    ("others", moment.OtherStyles.Count == 0 ? "none" : string.Join(", ", moment.OtherStyles))));
                var others = moment.Others.Where(other => other.StartWord >= 0 && other.StartWord < words.Count)
                    .Select(other => $"“{other.Title}” at {ClipText.Time(words[other.StartWord].Start)}").ToArray();
                var series = others.Length == 0 ? "" : prompt.Request("momentOthers", Values(("others", string.Join("; ", others))));
                instruction = prompt.Request("momentInstruction", Values(("rank", moment.Rank.ToString(CultureInfo.InvariantCulture)),
                    ("count", moment.Count.ToString(CultureInfo.InvariantCulture)), ("title", moment.Moment.Title), ("idea", moment.Moment.Idea),
                    ("caption", caption))) + series + "\n\n" + instruction;
            }
        }
        if (request.Note is { } creatorNote && EditingAlgorithms.JsTrim(creatorNote) is { Length: > 0 } trimmed)
            instruction += "\n\n" + prompt.Request("creatorNote", Values(("instruction", trimmed)));
        return new(block, instruction, scope, listed.Length);
    }

    internal static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);

    /// <summary>Names written elsewhere in the recording (ai.md §16.3): each word outside <paramref name="scope"/> that starts with a
    /// capital letter but not a sentence, of at least 3 characters once trimmed of punctuation, other than "I" contractions, in
    /// transcript order without repeats, at most <see cref="MaxNames"/>.</summary>
    internal static IReadOnlyList<string> Names(IReadOnlyList<TimedWord> words, WordSpan scope, IReadOnlyDictionary<string, string> corrections)
    {
        var names = new List<string>();
        var sentenceStart = true;
        for (var index = 0; index < words.Count; index++)
        {
            var word = words[index];
            if (word.Kind != WordKind.Word) continue;
            var shown = corrections.TryGetValue(word.Id, out var corrected) ? corrected : word.Text;
            var wasStart = sentenceStart;
            sentenceStart = EndsSentence(shown);
            if (scope.Contains(index) || wasStart) continue;
            var core = TrimToLettersAndNumbers(shown);
            if (core.Length == 0 || !Rune.IsUpper(Rune.GetRuneAt(core, 0)) || TextElements(core) < 3 || core.StartsWith("I'", StringComparison.Ordinal) ||
                core.StartsWith("I’", StringComparison.Ordinal) || names.Contains(core)) continue;
            names.Add(ClipText.Limit(core, 40));
            if (names.Count == MaxNames) break;
        }
        return names;
    }

    internal static bool EndsSentence(string shown) => shown.EndsWith('.') || shown.EndsWith('!') || shown.EndsWith('?') || shown.EndsWith('…');

    internal static bool IsLetterOrNumber(Rune rune) => Rune.IsLetter(rune) || Rune.IsNumber(rune);

    internal static string TrimToLettersAndNumbers(string text)
    {
        var runes = text.EnumerateRunes().ToList();
        var start = runes.FindIndex(IsLetterOrNumber);
        if (start < 0) return "";
        var end = runes.FindLastIndex(IsLetterOrNumber);
        return string.Concat(runes.Skip(start).Take(end - start + 1).Select(rune => rune.ToString()));
    }

    internal static int TextElements(string text) => new StringInfo(text).LengthInTextElements;

    /// <summary>The clip's frames (prompt version 8, ADR-R48): the sheet's summary, the screens to judge for blur (<c>B1…</c>) and the
    /// cover candidates (<c>C1…</c>), and a line naming the images when they go too. A request without frames adds nothing, so it is the
    /// same text as before version 8.</summary>
    public static string FramesBlock(ClipAutopilotFrames frames, ClipAutopilotPrompt prompt)
    {
        var blur = frames.Blur.Select(candidate => prompt.Request("blurCandidate", Values(("id", candidate.Id), ("start", ClipAutopilotFrames.Seconds(candidate.Start)),
            ("end", ClipAutopilotFrames.Seconds(candidate.End)), ("rect", ClipAutopilotFrames.RectText(candidate.Rect)),
            ("frames", candidate.Frames.ToString(CultureInfo.InvariantCulture))))).ToArray();
        var cover = frames.Cover.Select(candidate => prompt.Request("coverCandidate", Values(("id", candidate.Id),
            ("frame", candidate.Frame.ToString(CultureInfo.InvariantCulture)), ("time", ClipAutopilotFrames.Seconds(candidate.Time))))).ToArray();
        var block = prompt.Request("frames", Values(
            ("summary", frames.Summary.Length == 0 ? "Frames measured on this computer: none could be read." : frames.Summary),
            ("blur", blur.Length == 0 ? prompt.Request("noBlurCandidates", Values()) : string.Join("\n", blur)),
            ("cover", cover.Length == 0 ? prompt.Request("noCoverCandidates", Values()) : string.Join("\n", cover))));
        return block + (frames.SendsImages ? prompt.Request("framesSent", Values()) : "");
    }

    /// <summary>The clip instruction's tone line (prompt version 6).</summary>
    internal static string ToneLine(ClipAutopilotTone tone, ClipAutopilotPrompt prompt) => tone switch
    {
        ClipAutopilotTone.Fixed item => prompt.Request("toneFixed", Values(("title", item.Tone.Title), ("id", item.Tone.Id), ("instruction", item.Tone.Instruction))),
        ClipAutopilotTone.Auto { Offered.Count: > 0 } auto => prompt.Request("toneAuto", Values(("tones", string.Join("\n", auto.Offered.Select(item =>
            prompt.Request("toneLine", Values(("id", item.Id), ("title", item.Title), ("descriptor", item.Descriptor), ("instruction", item.Instruction)))))))),
        _ => prompt.Request("toneAsSaid", Values())
    };

    /// <summary>The caption preference line: only the fields the creator fixed, or <c>noCaptionPreference</c>.</summary>
    internal static string PreferenceLine(ClipAutopilotCaptionPreference? preference, ClipAutopilotPrompt prompt)
    {
        if (preference is null || preference.IsEmpty) return prompt.Request("noCaptionPreference", Values());
        var parts = new List<string>();
        if (preference.StyleId is { } style) parts.Add(prompt.Request("preferenceStyle", Values(("style", style))));
        if (preference.Font is { } font) parts.Add(prompt.Request("preferenceFont", Values(("family", font.Family), ("weight", font.Weight.ToString(CultureInfo.InvariantCulture)))));
        if (preference.TextCase is { } textCase) parts.Add(prompt.Request("preferenceCase", Values(("case", textCase.Name()))));
        return prompt.Request("captionPreference", Values(("parts", string.Join("; ", parts))));
    }

    /// <summary>The listed words that are not fillers, and the time they take once fillers and pauses are cut (ai.md §16.3).</summary>
    internal static (int Words, double Seconds) SpokenTime(IReadOnlyList<TimedWord> words, IReadOnlyList<int> listed, IReadOnlyDictionary<string, string> corrections,
        IReadOnlyList<Pause> pauses, double keepSeconds)
    {
        if (listed.Count == 0) return (0, 0);
        var spoken = 0;
        var seconds = words[listed[^1]].End - words[listed[0]].Start;
        foreach (var index in listed)
        {
            var word = words[index];
            if (word.Kind == WordKind.Word && !EditingAlgorithms.IsFillerText(corrections.TryGetValue(word.Id, out var text) ? text : word.Text)) spoken++;
            else seconds -= word.End - word.Start;
        }
        foreach (var pause in pauses.Where(pause => pause.AfterIndex >= listed[0] && pause.AfterIndex < listed[^1]))
            seconds -= Math.Max(0, pause.End - pause.Start - keepSeconds);
        return (spoken, seconds);
    }

    /// <summary>The <c>voxclip-indexed-words-v1</c> transcript.</summary>
    internal static string TranscriptBlock(IReadOnlyList<TimedWord> words, IReadOnlyList<int> listed, IReadOnlyDictionary<string, string> corrections,
        IReadOnlyList<Pause> pauses, ClipAutopilotPrompt prompt)
    {
        string wordTemplate = prompt.TranscriptTemplate("word"), fillerTemplate = prompt.TranscriptTemplate("filler"), eventTemplate = prompt.TranscriptTemplate("event"),
            lineTemplate = prompt.TranscriptTemplate("line"), pauseTemplate = prompt.TranscriptTemplate("pause");
        var listedSet = listed.ToHashSet();
        var pauseAfter = new Dictionary<int, Pause>();
        foreach (var pause in pauses.Where(pause => listedSet.Contains(pause.AfterIndex))) pauseAfter.TryAdd(pause.AfterIndex, pause);
        var lines = new List<string>();
        var current = new List<string>();
        double? lineStart = null;
        void Flush()
        {
            if (current.Count == 0 || lineStart is not { } start) return;
            lines.Add(ClipAutopilotPrompt.Fill(lineTemplate, Values(("time", ClipText.Time(start)), ("words", string.Join(" ", current)))));
            current.Clear();
            lineStart = null;
        }
        foreach (var index in listed)
        {
            var word = words[index];
            var shown = ClipText.Limit(corrections.TryGetValue(word.Id, out var corrected) ? corrected : word.Text, 100);
            var position = index.ToString(CultureInfo.InvariantCulture);
            string token;
            if (word.Kind == WordKind.Word)
                token = ClipAutopilotPrompt.Fill(EditingAlgorithms.IsFillerText(shown) ? fillerTemplate : wordTemplate, Values(("index", position), ("text", shown)));
            else
            {
                var label = shown.Trim('[', ']', '(', ')');
                token = ClipAutopilotPrompt.Fill(eventTemplate, Values(("index", position), ("text", label.Length == 0 ? "…" : label)));
            }
            lineStart ??= word.Start;
            current.Add(token);
            var sentenceEnd = word.Kind == WordKind.Word && EndsSentence(shown);
            if (pauseAfter.TryGetValue(index, out var pause))
            {
                Flush();
                lines.Add(ClipAutopilotPrompt.Fill(pauseTemplate, Values(("seconds", Fixed1(pause.End - pause.Start)), ("index", position))));
            }
            else if (sentenceEnd || current.Count >= prompt.LineWords) Flush();
        }
        Flush();
        return prompt.TranscriptTemplate("prefix") + string.Join("\n", lines) + prompt.TranscriptTemplate("suffix");
    }

    [GeneratedRegex("\\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\\z", RegexOptions.CultureInvariant)]
    private static partial Regex LanguageTag();
}
