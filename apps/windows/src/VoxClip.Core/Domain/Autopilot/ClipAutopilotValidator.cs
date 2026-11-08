using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>Checks a planner reply item by item (ai.md §16.5). Nothing in a reply refuses the whole plan: an invalid item is
/// repaired when one safe repair exists, otherwise dropped, and every change is listed in <c>Repairs</c>. Twin of the Mac
/// <c>ClipAutopilotValidator</c>; shared/fixtures/autopilot pins both.</summary>
public static partial class ClipAutopilotValidator
{
    private sealed class Log
    {
        internal readonly List<ClipAutopilotPlan.Repair> Repairs = [];
        internal void Drop(string field, string detail) => Repairs.Add(new(field, true, detail));
        internal void Repair(string field, string detail) => Repairs.Add(new(field, false, detail));
    }

    private static string N(int value) => value.ToString(CultureInfo.InvariantCulture);
    private static string D(double value) => value.ToString("R", CultureInfo.InvariantCulture);

    /// <summary>One clip reply. A span that cannot be read falls back to the whole scope; null only when the scope has no word.</summary>
    public static ClipAutopilotPlan? Plan(JsonNode? value, ClipAutopilotContext context)
    {
        var log = new Log();
        if (Span(value, context, false, log) is not { } span) return null;
        var checkedCorrections = Corrections(AiJson.Get(value, "corrections"), span, context, log);
        var corrected = context.Correcting(checkedCorrections.Select(item => item.Correction).ToArray());
        var rewrites = Rewrites(AiJson.Get(value, "rewrites"), span, corrected, log);
        var cuts = Cuts(AiJson.Get(value, "cuts"), span, rewrites, corrected, log);
        var corrections = checkedCorrections.Where(item =>
        {
            if (!cuts.Any(cut => cut.StartWord <= item.Correction.Word && item.Correction.Word <= cut.EndWord)) return true;
            log.Drop(item.Field, "the plan cuts that word");
            return false;
        }).Select(item => item.Correction).ToArray();
        var pauseCuts = PauseCuts(AiJson.Get(value, "pauseCuts"), span, rewrites, corrected, log);
        var captions = Captions(value, corrected, log);
        var look = Look(value, corrected, log);
        var speed = Speed(value, corrected, log);
        var (music, pick) = Music(value, corrected, log);
        var zooms = Zooms(AiJson.Get(value, "zooms"), span, cuts, corrected, log);
        var limits = corrected.Prompt.Limits;
        var fallbackTitle = EditingAlgorithms.ClipTitle(span.Indices.Where(corrected.IsListedWord).Select(corrected.Text)) ?? "";
        var title = Text(AiJson.Get(value, "title"), Math.Min(limits.MaxTitleScalars, EditingLimits.MaxClipTitleCodePoints), "title", log);
        var score = Score(AiJson.Get(value, "score"), corrected, "score", log);
        var verdict = Verdict(AiJson.Get(value, "verdict"), score, "verdict", log);
        var cutIds = corrected.CutWordIds.Concat(cuts.SelectMany(cut => new WordSpan(cut.StartWord, cut.EndWord).Indices.Select(index => corrected.Words[index].Id)))
            .ToHashSet(StringComparer.Ordinal);
        var seconds = ClipAutopilotMapping.EditedSeconds(span, corrected.Words, cutIds, corrected.Pauses, pauseCuts.Select(pause => pause.AfterWord).ToHashSet(),
            corrected.CutPauseIds, corrected.PauseKeepSeconds) / (speed?.Rate ?? 1);
        var lengthReason = Text(AiJson.Get(value, "lengthReason"), limits.MaxReasonScalars, "lengthReason", log);
        var tone = Tone(value, corrected, log);
        var frames = Frames(value, corrected, log);
        var hook = Text(AiJson.Get(value, "hook"), limits.MaxHookScalars, "hook", log);
        var postText = Text(AiJson.Get(value, "postText"), limits.MaxPostScalars, "postText", log);
        var scoreReason = Text(AiJson.Get(value, "scoreReason"), limits.MaxReasonScalars, "scoreReason", log);
        var questions = Questions(AiJson.Get(value, "questions"), corrected, log);
        return new ClipAutopilotPlan
        {
            StartWord = span.Start, EndWord = span.End, Title = title.Length == 0 ? fallbackTitle : title, Hook = hook, Cuts = cuts, PauseCuts = pauseCuts,
            Corrections = corrections, Rewrites = rewrites, CaptionChoice = captions, ClipLookChoice = look, SpeedChoice = speed, MusicChoices = music,
            MusicPick = pick, Zooms = zooms, PostText = postText, Score = score, Verdict = verdict, ScoreReason = scoreReason, LengthReason = lengthReason,
            Seconds = seconds, Questions = questions, Repairs = log.Repairs.ToArray(), Flags = Flags(seconds, lengthReason, limits), ToneChoice = tone,
            Frames = frames
        };
    }

    /// <summary>The frame choices (prompt version 8, ai.md §19.6), checked against the candidates the request listed. Null when the
    /// request carried no frames. A blur id that names no candidate, or names one twice, is ignored (a repair); a candidate the reply
    /// leaves out stays sharp. A cover id that names no candidate falls back to the local best, <c>C1</c> (a repair when the reply named
    /// another); a reply without <c>frames</c> (one from before version 8) has no blur and that cover.</summary>
    private static ClipAutopilotPlan.FrameChoices? Frames(JsonNode? value, ClipAutopilotContext context, Log log)
    {
        if (context.Frames is not { } listed) return null;
        var reply = AiJson.Get(value, "frames");
        var limit = context.Prompt.Limits.MaxReasonScalars;
        var decided = new Dictionary<string, ClipAutopilotPlan.FrameChoices.Blur>(StringComparer.Ordinal);
        var items = AiJson.Array(AiJson.Get(reply, "blur"));
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = $"frames.blur[{N(index)}]";
            var id = (AiJson.String(AiJson.Get(item, "id")) ?? "").Trim().ToUpperInvariant();
            if (listed.BlurCandidateFor(id) is null || decided.ContainsKey(id) || AiJson.Get(item, "blur") is not JsonValue flag || !flag.TryGetValue<bool>(out var blur))
            {
                log.Drop(field, id.Length == 0 ? "no screen named" : $"“{id}” is not a listed screen, or was named twice");
                continue;
            }
            decided[id] = new(id, blur, Text(AiJson.Get(item, "reason"), limit, field + ".reason", log));
        }
        var choices = listed.Blur.Select(candidate => decided.GetValueOrDefault(candidate.Id)).OfType<ClipAutopilotPlan.FrameChoices.Blur>().ToArray();
        if (listed.Cover.FirstOrDefault() is not { } best) return new(choices, null);
        var cover = AiJson.Get(reply, "cover");
        var named = (AiJson.String(AiJson.Get(cover, "id")) ?? "").Trim().ToUpperInvariant();
        if (listed.CoverCandidateFor(named) is not null)
            return new(choices, new(named, Text(AiJson.Get(cover, "reason"), limit, "frames.cover.reason", log)));
        if (reply is not null) log.Repair("frames.cover", named.Length == 0 ? $"no cover named; {best.Id}, the best measured" : $"“{named}” is not a candidate; {best.Id}");
        return new(choices, new(best.Id, "", true));
    }

    /// <summary>The tone the words were written in (prompt version 6, ai.md §16.5).</summary>
    private static ClipAutopilotPlan.Tone? Tone(JsonNode? value, ClipAutopilotContext context, Log log)
    {
        if (context.Tone is not { } requested) return null;
        var raw = EditingAlgorithms.JsTrim(AiJson.String(AiJson.Get(value, "tone")) ?? "");
        var key = raw.ToLowerInvariant().Replace(" ", "-", StringComparison.Ordinal);
        var none = key.Length == 0 || key == "none" || key == "as-said";
        string Summary() => Text(AiJson.Get(value, "toneSummary"), context.Prompt.Limits.MaxToneSummaryScalars, "toneSummary", log);
        switch (requested)
        {
            case ClipAutopilotTone.Fixed item:
                if (key != item.Tone.Id) log.Repair("tone", "the creator fixed " + item.Tone.Id + (raw.Length == 0 ? "" : "; “" + raw + "” replaced"));
                return new(item.Tone.Id, item.Tone.Title, Summary());
            case ClipAutopilotTone.Auto auto:
                if (none) return null;
                if (auto.Offered.FirstOrDefault(tone => tone.Id == key) is not { } chosen)
                {
                    log.Repair("tone", "unknown tone “" + raw + "”; none");
                    return null;
                }
                return new(chosen.Id, chosen.Title, Summary());
            default:
                if (!none) log.Repair("tone", "the creator keeps their own tone; “" + raw + "” dropped");
                return null;
        }
    }

    /// <summary>The flags a finished length earns: over the reasoned limit, or over the target with no reason.</summary>
    internal static IReadOnlyList<ClipAutopilotPlan.Flag> Flags(double seconds, string lengthReason, ClipAutopilotLimits limits)
    {
        var values = limits.TemplateValues();
        if (seconds > limits.MaxReasonedSeconds)
            return [new("overLength", "runs " + EditingFormat.ToFixed1(seconds) + " s, over the " + values["maxReasonedSeconds"] + " s limit")];
        if (seconds > limits.MaxTargetSeconds && lengthReason.Length == 0)
            return [new("longWithoutReason", "runs " + EditingFormat.ToFixed1(seconds) + " s, past " + values["maxTargetSeconds"] + " s with no reason")];
        return [];
    }

    /// <summary>The first stage of a series: its moments in the reply's rank order, each span checked as a series clip's, then any
    /// moment overlapping a better-ranked one left out, up to <c>maxClips</c>. Only the first <c>postFirst</c> keeps that verdict.</summary>
    public static (IReadOnlyList<ClipAutopilotMoment> Moments, IReadOnlyList<ClipAutopilotPlan.Repair> Repairs) Moments(JsonNode? value, ClipAutopilotContext context)
    {
        var moments = new List<ClipAutopilotMoment>();
        var log = new Log();
        var limits = context.Prompt.Limits;
        var items = AiJson.Array(AiJson.Get(value, "clips"));
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = "clips[" + N(index) + "]";
            if (moments.Count >= limits.MaxClips) { log.Drop(field, "more than " + N(limits.MaxClips) + " clips"); continue; }
            if (Span(item, context, true, new Log()) is not { } span) { log.Drop(field, "the clip's span is unreadable, too short or too long"); continue; }
            var earlier = moments.FindIndex(moment => moment.StartWord <= span.End && span.Start <= moment.EndWord);
            if (earlier >= 0) { log.Drop(field, "overlaps clip " + N(earlier + 1)); continue; }
            var fallbackTitle = EditingAlgorithms.ClipTitle(span.Indices.Where(context.IsListedWord).Select(context.Text)) ?? "";
            var title = Text(AiJson.Get(item, "title"), Math.Min(limits.MaxTitleScalars, EditingLimits.MaxClipTitleCodePoints), field + ".title", log);
            var score = Score(AiJson.Get(item, "score"), context, field + ".score", log);
            var verdict = Verdict(AiJson.Get(item, "verdict"), score, field + ".verdict", log);
            if (verdict == ClipAutopilotVerdict.PostFirst && moments.Any(moment => moment.Verdict == ClipAutopilotVerdict.PostFirst))
            {
                verdict = ClipAutopilotVerdict.Post;
                log.Repair(field + ".verdict", "only the best clip posts first; post");
            }
            var style = CaptionStyle(AiJson.Get(item, "captionStyle"), context, field + ".captionStyle", log);
            var idea = Text(AiJson.Get(item, "idea"), limits.MaxReasonScalars, field + ".idea", log);
            var scoreReason = Text(AiJson.Get(item, "scoreReason"), limits.MaxReasonScalars, field + ".scoreReason", log);
            var captionReason = Text(AiJson.Get(item, "captionReason"), limits.MaxReasonScalars, field + ".captionReason", log);
            moments.Add(new(span.Start, span.End, title.Length == 0 ? fallbackTitle : title, idea, score, verdict, scoreReason, style, captionReason));
        }
        return (moments, log.Repairs);
    }

    /// <summary>A series from its checked plans (null where a plan failed): ranked by score, best first, ties in order. Only the
    /// best <c>postFirst</c> keeps that verdict.</summary>
    internal static ClipAutopilotSeries Series(IReadOnlyList<ClipAutopilotPlan?> plans, IReadOnlyList<ClipAutopilotMoment> moments,
        IReadOnlyDictionary<int, string> failures, IReadOnlyList<ClipAutopilotPlan.Repair> repairs)
    {
        var all = repairs.ToList();
        for (var index = 0; index < plans.Count; index++)
            if (plans[index] is null) all.Add(new("plans[" + N(index) + "]", true, failures.TryGetValue(index, out var reason) ? reason : "the plan has no words of the clip"));
        var ranked = plans.Select((plan, order) => (plan, order)).Where(item => item.plan is not null)
            .OrderByDescending(item => item.plan!.Score).ThenBy(item => item.order).Select(item => item.plan!).ToList();
        var first = false;
        for (var index = 0; index < ranked.Count; index++)
        {
            if (ranked[index].Verdict != ClipAutopilotVerdict.PostFirst) continue;
            if (first) ranked[index] = ranked[index] with { Verdict = ClipAutopilotVerdict.Post, Repairs = ranked[index].Repairs.Append(new("verdict", false, "another clip posts first; post")).ToArray() };
            first = true;
        }
        return new(ranked, moments, all);
    }

    /// <summary>Text shown to the creator: trimmed, without control characters other than newlines, cut to <paramref name="limit"/>
    /// Unicode scalars.</summary>
    private static string Text(JsonNode? value, int limit, string field, Log log)
    {
        if (AiJson.String(value) is not { } raw)
        {
            if (value is not null) log.Repair(field, "not text");
            return "";
        }
        var cleaned = string.Concat(raw.EnumerateRunes().Where(rune => rune.Value == '\n' || Rune.GetUnicodeCategory(rune) != UnicodeCategory.Control).Select(rune => rune.ToString()));
        var trimmed = EditingAlgorithms.JsTrim(cleaned);
        if (trimmed.EnumerateRunes().Count() <= limit) return trimmed;
        log.Repair(field, "cut to " + N(limit) + " characters");
        return EditingAlgorithms.JsTrim(string.Concat(trimmed.EnumerateRunes().Take(limit).Select(rune => rune.ToString())));
    }

    /// <summary>The plan's span: the reply's span inside the scope, its ends moved inward to listed words.</summary>
    private static WordSpan? Span(JsonNode? value, ClipAutopilotContext context, bool isSeries, Log log)
    {
        var scope = context.Scope;
        int? start = AiJson.Integer(AiJson.Get(value, "startWord")), end = AiJson.Integer(AiJson.Get(value, "endWord"));
        if (start is null || end is null || start > end || end < scope.Start || start > scope.End)
        {
            if (isSeries) return null;
            log.Repair("startWord", "the span was unreadable; the whole clip is used");
            start = scope.Start; end = scope.End;
        }
        else if (start < scope.Start || end > scope.End)
        {
            log.Repair("startWord", "the span was moved inside the clip");
            start = Math.Max(start.Value, scope.Start); end = Math.Min(end.Value, scope.End);
        }
        int first = start.Value, last = end.Value;
        while (first <= last && !context.IsListedWord(first)) first++;
        while (last >= first && !context.IsListedWord(last)) last--;
        if (first > last)
        {
            if (isSeries) return null;
            var listed = scope.Indices.Where(context.IsListedWord).ToArray();
            if (listed.Length == 0) return null;
            log.Repair("startWord", "the span held no words; the whole clip is used");
            return new(listed[0], listed[^1]);
        }
        if (isSeries)
        {
            var seconds = context.Words[last].End - context.Words[first].Start;
            if (seconds < context.Prompt.Limits.MinClipSeconds || seconds > context.Prompt.Limits.MaxClipSeconds) return null;
        }
        return new(first, last);
    }

    /// <summary>Rewrites (voice-lab §8.4 bridge words): 2 to <c>maxRewriteWords</c> listed items inside the span, starting and ending on
    /// a word, overlapping no other rewrite, whose spoken text keeps both bridge words, changes something, and holds no link,
    /// control character or bracket tag.</summary>
    private static IReadOnlyList<ClipAutopilotPlan.Rewrite> Rewrites(JsonNode? value, WordSpan span, ClipAutopilotContext context, Log log)
    {
        var limits = context.Prompt.Limits;
        var accepted = new List<ClipAutopilotPlan.Rewrite>();
        var items = AiJson.Array(value);
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = "rewrites[" + N(index) + "]";
            if (accepted.Count >= limits.MaxRewrites) { log.Drop(field, "more than " + N(limits.MaxRewrites) + " rewrites"); continue; }
            if (AiJson.Integer(AiJson.Get(item, "startWord")) is not { } start || AiJson.Integer(AiJson.Get(item, "endWord")) is not { } end || start >= end ||
                !span.Contains(start) || !span.Contains(end)) { log.Drop(field, "its words are not inside the clip"); continue; }
            var range = new WordSpan(start, end);
            if (!range.Indices.All(context.IsListed) || !context.IsListedWord(start) || !context.IsListedWord(end) || range.Count > limits.MaxRewriteWords)
            { log.Drop(field, "its range is not a short run of the clip's words"); continue; }
            if (accepted.Any(other => new WordSpan(other.StartWord, other.EndWord).Overlaps(range))) { log.Drop(field, "overlaps another rewrite"); continue; }
            if (AiJson.String(AiJson.Get(item, "text")) is not { } raw) { log.Drop(field, "no text"); continue; }
            var spoken = EditingAlgorithms.JsTrim(raw.Replace("\n", " ", StringComparison.Ordinal));
            var tokens = EditingAlgorithms.SplitWords(spoken);
            if (tokens.Count == 0 || tokens.Count > limits.MaxRewriteTextWords || !IsSafePhrase(spoken)) { log.Drop(field, "its text is not a short spoken phrase"); continue; }
            var leading = context.Text(start);
            var trailing = context.Text(end);
            if (!VoiceLabTakeProcessing.KeepsBridgeWords(spoken, ([leading], [trailing])))
            { log.Drop(field, "its text drops the bridge words “" + leading + "” and “" + trailing + "”"); continue; }
            var original = string.Join(" ", range.Indices.Where(position => context.Words[position].Kind == WordKind.Word).Select(context.Text));
            if (VoiceLabTakeQuality.Tokens(original).SequenceEqual(VoiceLabTakeQuality.Tokens(spoken))) { log.Drop(field, "changes nothing"); continue; }
            accepted.Add(new(start, end, spoken, Text(AiJson.Get(item, "reason"), limits.MaxReasonScalars, field + ".reason", log)));
        }
        return accepted;
    }

    /// <summary>No bracket tag, link or control character.</summary>
    private static bool IsSafePhrase(string text) =>
        text == VoiceLabAudioTags.SanitizedRequest(text, "") && !Link().IsMatch(text) &&
        !text.EnumerateRunes().Any(rune => Rune.GetUnicodeCategory(rune) == UnicodeCategory.Control);

    [GeneratedRegex("https?://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Link();

    /// <summary>Cuts: listed items inside the span, never inside a rewrite (a cut is trimmed around one), merged where they touch, and
    /// never every word of the clip.</summary>
    private static IReadOnlyList<ClipAutopilotPlan.Cut> Cuts(JsonNode? value, WordSpan span, IReadOnlyList<ClipAutopilotPlan.Rewrite> rewrites,
        ClipAutopilotContext context, Log log)
    {
        var limits = context.Prompt.Limits;
        var protectedSpans = rewrites.Select(rewrite => new WordSpan(rewrite.StartWord, rewrite.EndWord)).ToArray();
        var pieces = new List<ClipAutopilotPlan.Cut>();
        var items = AiJson.Array(value);
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = "cuts[" + N(index) + "]";
            if (pieces.Count >= limits.MaxCuts) { log.Drop(field, "more than " + N(limits.MaxCuts) + " cuts"); continue; }
            if (AiJson.Integer(AiJson.Get(item, "startWord")) is not { } start || AiJson.Integer(AiJson.Get(item, "endWord")) is not { } end) { log.Drop(field, "no word range"); continue; }
            if (start > end) { (start, end) = (end, start); log.Repair(field, "its range was reversed"); }
            if (start > span.End || end < span.Start) { log.Drop(field, "outside the clip"); continue; }
            if (start < span.Start || end > span.End) { start = Math.Max(start, span.Start); end = Math.Min(end, span.End); log.Repair(field, "trimmed to the clip"); }
            var kind = ClipAutopilotWire.CutKind(AiJson.String(AiJson.Get(item, "kind")));
            if (kind is null) log.Repair(field + ".kind", "unknown kind; other");
            var cutKind = kind ?? ClipAutopilotCutKind.Other;
            var reason = Text(AiJson.Get(item, "reason"), limits.MaxReasonScalars, field + ".reason", log);
            var run = new List<int>();
            var trimmed = false;
            var before = pieces.Count;
            void Close()
            {
                if (run.Count > 0) pieces.Add(new(run[0], run[^1], cutKind, reason.Length == 0 ? cutKind.Name() : reason));
                run.Clear();
            }
            for (var position = start; position <= end; position++)
            {
                if (protectedSpans.Any(range => range.Contains(position))) { trimmed = true; Close(); continue; }
                if (context.IsListed(position)) run.Add(position);
            }
            Close();
            if (pieces.Count == before) { log.Drop(field, trimmed ? "inside a rewrite" : "no words of the clip"); continue; }
            if (trimmed) log.Repair(field, "trimmed around a rewrite");
        }
        // Merge cuts that overlap or touch in listed order; the first one's kind and reason name the merge.
        var listed = span.Indices.Where(context.IsListed).ToArray();
        var order = listed.Select((position, offset) => (position, offset)).ToDictionary(pair => pair.position, pair => pair.offset);
        var merged = new List<ClipAutopilotPlan.Cut>();
        foreach (var cut in pieces.OrderBy(cut => cut.StartWord))
        {
            if (merged.Count > 0 && order.TryGetValue(merged[^1].EndWord, out var lastEnd) && order.TryGetValue(cut.StartWord, out var startOrder) && startOrder <= lastEnd + 1)
                merged[^1] = merged[^1] with { EndWord = Math.Max(merged[^1].EndWord, cut.EndWord) };
            else merged.Add(cut);
        }
        var kept = listed.Where(position => context.Words[position].Kind == WordKind.Word && !merged.Any(cut => cut.StartWord <= position && position <= cut.EndWord));
        if (!kept.Any())
        {
            log.Drop("cuts", "they removed every word of the clip");
            return [];
        }
        return merged;
    }

    /// <summary>Pause cuts: a detected, uncut pause after a listed word, both of its words inside the span and outside every rewrite.</summary>
    private static IReadOnlyList<ClipAutopilotPlan.PauseCut> PauseCuts(JsonNode? value, WordSpan span, IReadOnlyList<ClipAutopilotPlan.Rewrite> rewrites,
        ClipAutopilotContext context, Log log)
    {
        var accepted = new List<ClipAutopilotPlan.PauseCut>();
        var items = AiJson.Array(value);
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = "pauseCuts[" + N(index) + "]";
            if (accepted.Count >= context.Prompt.Limits.MaxPauseCuts) { log.Drop(field, "too many pause cuts"); continue; }
            if (AiJson.Integer(AiJson.Get(item, "afterWord")) is not { } after || !span.Contains(after) || !span.Contains(after + 1) || !context.IsListed(after) ||
                context.Pauses.FirstOrDefault(pause => pause.AfterIndex == after) is not { } pause || context.CutPauseIds.Contains(pause.Id))
            { log.Drop(field, "no pause the editor can tighten follows that word"); continue; }
            if (rewrites.Any(rewrite => rewrite.StartWord <= after && after < rewrite.EndWord)) { log.Drop(field, "inside a rewrite"); continue; }
            if (accepted.Any(other => other.AfterWord == after)) { log.Drop(field, "repeats another pause cut"); continue; }
            accepted.Add(new(after, Text(AiJson.Get(item, "reason"), context.Prompt.Limits.MaxReasonScalars, field + ".reason", log)));
        }
        return accepted;
    }

    /// <summary>Captions: a built-in style other than off, a bundled or default font, a known case and words per caption in range.
    /// What the creator fixed always wins.</summary>
    private static ClipAutopilotPlan.Captions Captions(JsonNode? value, ClipAutopilotContext context, Log log)
    {
        var defaults = context.Prompt.Defaults;
        var limits = context.Prompt.Limits;
        var style = CaptionStyle(AiJson.Get(value, "captionStyle"), context, "captionStyle", log);
        var font = new ClipAutopilotFont(AiJson.String(AiJson.Get(value, "captionFont")) is { } family ? EditingAlgorithms.JsTrim(family) : "",
            AiJson.Integer(AiJson.Get(value, "captionWeight")) ?? -1);
        // "Roboto 900" in the family field: the weight belongs in captionWeight.
        if (!context.Allows(font) && FamilyWithWeight().Match(font.Family) is { Success: true } match &&
            context.Allows(new(match.Groups[1].Value, int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture))))
        {
            font = new(match.Groups[1].Value, int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture));
            log.Repair("captionFont", "the weight was in the family name");
        }
        if (context.Preference?.Font is { } fixedFont && context.Allows(fixedFont))
        {
            if (font != fixedFont) log.Repair("captionFont", "the creator fixed the font; " + fixedFont.Family + " " + N(fixedFont.Weight));
            font = fixedFont;
        }
        else if (!context.Allows(font))
        {
            log.Repair("captionFont", "unknown font “" + font.Family + " " + N(font.Weight) + "”; " + defaults.Font.Family + " " + N(defaults.Font.Weight));
            font = defaults.Font;
        }
        var replyCase = ClipAutopilotWire.CaptionCase(AiJson.String(AiJson.Get(value, "captionCase")));
        ClipAutopilotCaptionCase textCase;
        if (context.Preference?.TextCase is { } fixedCase)
        {
            if (replyCase != fixedCase) log.Repair("captionCase", "the creator fixed the case; " + fixedCase.Name());
            textCase = fixedCase;
        }
        else if (replyCase is { } read) textCase = read;
        else
        {
            textCase = defaults.TextCase;
            log.Repair("captionCase", "unknown case; " + textCase.Name());
        }
        var words = AiJson.Integer(AiJson.Get(value, "wordsPerCaption")) ?? defaults.WordsPerCaption;
        if (words < limits.MinWordsPerCaption || words > limits.MaxWordsPerCaption)
        {
            words = Math.Clamp(words, limits.MinWordsPerCaption, limits.MaxWordsPerCaption);
            log.Repair("wordsPerCaption", "clamped to " + N(words));
        }
        return new(style, font, textCase, words, Text(AiJson.Get(value, "captionReason"), limits.MaxReasonScalars, "captionReason", log));
    }

    [GeneratedRegex("\\A(.+?)\\s+([1-9]00)\\z", RegexOptions.CultureInvariant)]
    private static partial Regex FamilyWithWeight();

    /// <summary>The creator's fixed style, else a built-in style other than off, else the default (or the first style).</summary>
    private static string CaptionStyle(JsonNode? value, ClipAutopilotContext context, string field, Log log)
    {
        var reply = AiJson.String(value) ?? "";
        if (context.FixedStyle is { } fixedStyle)
        {
            if (reply != fixedStyle) log.Repair(field, "the creator fixed the style; " + fixedStyle);
            return fixedStyle;
        }
        if (context.StyleIds.Contains(reply) && reply != "off") return reply;
        var defaults = context.Prompt.Defaults;
        var fallback = context.StyleIds.Contains(defaults.StyleId) ? defaults.StyleId
            : context.StyleIds.Where(id => id != "off").OrderBy(id => id, StringComparer.Ordinal).FirstOrDefault() ?? defaults.StyleId;
        log.Repair(field, "unknown style “" + reply + "”; " + fallback);
        return fallback;
    }

    private static string LettersLower(string text) => string.Concat(text.ToLowerInvariant().EnumerateRunes().Where(Rune.IsLetter).Select(rune => rune.ToString()));

    /// <summary>The look, read ignoring case and non-letters ("B&amp;W" is bw), with its reason.</summary>
    private static ClipAutopilotPlan.Look Look(JsonNode? value, ClipAutopilotContext context, Log log)
    {
        var node = AiJson.Get(value, "look");
        if (node is null) return ClipAutopilotPlan.Look.Original;
        var key = LettersLower(AiJson.String(node) ?? "");
        var id = ClipAutopilotWire.Look(key) ?? key switch
        {
            "blackandwhite" or "blackwhite" or "monochrome" => ClipLook.Bw,
            "none" => ClipLook.Original,
            _ => (ClipLook?)null
        };
        if (id is null)
        {
            log.Repair("look", "unknown look “" + (AiJson.String(node) ?? "") + "”; original");
            return ClipAutopilotPlan.Look.Original;
        }
        return new(id.Value, Text(AiJson.Get(value, "lookReason"), context.Prompt.Limits.MaxReasonScalars, "lookReason", log));
    }

    /// <summary>A finite rate other than 1 (within 0.005), clamped to the limits (a repair), with its reason.</summary>
    private static ClipAutopilotPlan.Speed? Speed(JsonNode? value, ClipAutopilotContext context, Log log)
    {
        var limits = context.Prompt.Limits;
        var node = AiJson.Get(value, "speed");
        if (node is null) return null;
        if (AiJson.Number(node) is not { } rate || !double.IsFinite(rate) || rate <= 0) { log.Drop("speed", "not a positive number"); return null; }
        if (Math.Abs(rate - 1) < 0.005) return null;
        var clamped = rate;
        if (rate < limits.MinSpeed || rate > limits.MaxSpeed)
        {
            clamped = Math.Clamp(rate, limits.MinSpeed, limits.MaxSpeed);
            log.Repair("speed", "clamped to " + D(clamped));
        }
        return new(clamped, Text(AiJson.Get(value, "speedReason"), limits.MaxReasonScalars, "speedReason", log));
    }

    private static string LettersAndNumbersLower(string text) =>
        string.Concat(text.ToLowerInvariant().EnumerateRunes().Where(ClipAutopilotRequestBuilder.IsLetterOrNumber).Select(rune => rune.ToString()));

    /// <summary>Corrections (ai.md §16.5): a listed word inside the span that reads as <c>heard</c>, or the nearest one within 3
    /// positions that does (a repair); one per word; a short spelling that keeps the word's punctuation and changes it.</summary>
    private static IReadOnlyList<(string Field, ClipAutopilotPlan.Correction Correction)> Corrections(JsonNode? value, WordSpan span, ClipAutopilotContext context, Log log)
    {
        var limits = context.Prompt.Limits;
        var accepted = new List<(string Field, ClipAutopilotPlan.Correction Correction)>();
        var items = AiJson.Array(value);
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = "corrections[" + N(index) + "]";
            if (accepted.Count >= limits.MaxCorrections) { log.Drop(field, "more than " + N(limits.MaxCorrections) + " corrections"); continue; }
            if (AiJson.Integer(AiJson.Get(item, "word")) is not { } word) { log.Drop(field, "no word index"); continue; }
            var heardRaw = AiJson.String(AiJson.Get(item, "heard")) ?? "";
            var heard = LettersAndNumbersLower(heardRaw);
            if (heard.Length == 0) { log.Drop(field, "no heard word"); continue; }
            bool Reads(int position) => span.Contains(position) && context.IsListedWord(position) && LettersAndNumbersLower(context.Text(position)) == heard;
            var position = word;
            if (!Reads(word))
            {
                var near = Enumerable.Range(1, 3).SelectMany(offset => new[] { word - offset, word + offset }).Cast<int?>().FirstOrDefault(candidate => Reads(candidate!.Value));
                if (near is null) { log.Drop(field, "word " + N(word) + " does not read “" + heardRaw + "”"); continue; }
                position = near.Value;
                log.Repair(field, "moved to word " + N(position) + ", which reads “" + context.Text(position) + "”");
            }
            if (accepted.Any(other => other.Correction.Word == position)) { log.Drop(field, "repeats another correction"); continue; }
            var spelled = EditingAlgorithms.JsTrim((AiJson.String(AiJson.Get(item, "text")) ?? "").Replace("\n", " ", StringComparison.Ordinal));
            var tokens = EditingAlgorithms.SplitWords(spelled);
            if (tokens.Count == 0 || tokens.Count > limits.MaxCorrectionWords || spelled.EnumerateRunes().Count() > EditingLimits.MaxCorrectionCodePoints || !IsSafePhrase(spelled))
            { log.Drop(field, "its text is not a short spelling"); continue; }
            var shown = context.Text(position);
            var fixedText = Punctuated(spelled, shown);
            if (fixedText == shown || fixedText.EnumerateRunes().Count() > EditingLimits.MaxCorrectionCodePoints) { log.Drop(field, "changes nothing"); continue; }
            accepted.Add((field, new(position, shown, fixedText, Text(AiJson.Get(item, "reason"), limits.MaxReasonScalars, field + ".reason", log))));
        }
        return accepted;
    }

    /// <summary><paramref name="text"/> with <paramref name="shown"/>'s leading and trailing punctuation where it has none of its own.</summary>
    internal static string Punctuated(string text, string shown)
    {
        static bool IsMark(Rune rune) => !ClipAutopilotRequestBuilder.IsLetterOrNumber(rune);
        var runes = shown.EnumerateRunes().ToArray();
        var leading = string.Concat(runes.TakeWhile(IsMark).Select(rune => rune.ToString()));
        var trailing = string.Concat(runes.Reverse().TakeWhile(IsMark).Reverse().Select(rune => rune.ToString()));
        if (runes.TakeWhile(IsMark).Count() >= runes.Length) return text;
        var result = text;
        var own = result.EnumerateRunes().ToArray();
        if (own.Length > 0 && !IsMark(own[0])) result = leading + result;
        own = result.EnumerateRunes().ToArray();
        if (own.Length > 0 && !IsMark(own[^1])) result += trailing;
        return result;
    }

    /// <summary>Music: up to <c>maxMusic</c> suggestions with a title and a prompt, made instrumental with the level clamped; the
    /// pick falls back to the first suggestion.</summary>
    private static (IReadOnlyList<ClipAutopilotPlan.Music>, int?) Music(JsonNode? value, ClipAutopilotContext context, Log log)
    {
        var limits = context.Prompt.Limits;
        var defaults = context.Prompt.Defaults;
        var accepted = new List<ClipAutopilotPlan.Music>();
        var replyIndex = new List<int>();
        var items = AiJson.Array(AiJson.Get(value, "music"));
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = "music[" + N(index) + "]";
            if (accepted.Count >= limits.MaxMusic) { log.Drop(field, "more than " + N(limits.MaxMusic) + " suggestions"); continue; }
            var title = Text(AiJson.Get(item, "title"), limits.MaxTitleScalars, field + ".title", log);
            var prompt = Text(AiJson.Get(item, "prompt"), limits.MaxMusicPromptScalars, field + ".prompt", log).Replace("\n", " ", StringComparison.Ordinal);
            if (title.Length == 0 || prompt.Length == 0) { log.Drop(field, "no title or prompt"); continue; }
            if (!prompt.Contains("instrumental", StringComparison.OrdinalIgnoreCase))
            {
                prompt += context.Prompt.InstrumentalSuffix;
                log.Repair(field + ".prompt", "made instrumental");
            }
            var level = AiJson.Number(AiJson.Get(item, "underVoiceDb")) ?? double.NaN;
            if (!double.IsFinite(level)) { level = defaults.UnderVoiceDb; log.Repair(field + ".underVoiceDb", "unreadable; " + D(level)); }
            else if (level < limits.MinUnderVoiceDb || level > limits.MaxUnderVoiceDb)
            {
                level = Math.Clamp(level, limits.MinUnderVoiceDb, limits.MaxUnderVoiceDb);
                log.Repair(field + ".underVoiceDb", "clamped to " + D(level));
            }
            var mood = Text(AiJson.Get(item, "mood"), limits.MaxTitleScalars, field + ".mood", log);
            var reason = Text(AiJson.Get(item, "reason"), limits.MaxReasonScalars, field + ".reason", log);
            accepted.Add(new(title, mood, prompt, reason, level));
            replyIndex.Add(index);
        }
        if (accepted.Count == 0)
        {
            if (items.Count > 0) log.Drop("music", "no usable suggestion");
            return ([], null);
        }
        if (AiJson.Integer(AiJson.Get(value, "musicPick")) is { } wanted && replyIndex.IndexOf(wanted) is var position and >= 0) return (accepted, position);
        log.Repair("musicPick", "unknown pick; the first suggestion");
        return (accepted, 0);
    }

    /// <summary>Zooms: a listed, uncut word to an <c>untilWord</c> at or after it (shortened to <c>maxZoomSeconds</c>), a clamped scale,
    /// never overlapping an earlier zoom.</summary>
    private static IReadOnlyList<ClipAutopilotPlan.Zoom> Zooms(JsonNode? value, WordSpan span, IReadOnlyList<ClipAutopilotPlan.Cut> cuts, ClipAutopilotContext context, Log log)
    {
        var limits = context.Prompt.Limits;
        bool IsKept(int position) => context.IsListedWord(position) && !cuts.Any(cut => cut.StartWord <= position && position <= cut.EndWord);
        var accepted = new List<ClipAutopilotPlan.Zoom>();
        var items = AiJson.Array(value);
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = "zooms[" + N(index) + "]";
            if (accepted.Count >= limits.MaxZooms) { log.Drop(field, "more than " + N(limits.MaxZooms) + " zooms"); continue; }
            if (AiJson.Integer(AiJson.Get(item, "word")) is not { } word || !span.Contains(word) || !IsKept(word)) { log.Drop(field, "not on a kept word of the clip"); continue; }
            var until = AiJson.Integer(AiJson.Get(item, "untilWord")) ?? word;
            if (until < word || !span.Contains(until)) { until = Math.Min(Math.Max(until, word), span.End); log.Repair(field + ".untilWord", "moved inside the clip"); }
            var start = context.Words[word].Start;
            var wanted = until;
            while (until > word && (context.Words[until].End - start > limits.MaxZoomSeconds || !context.IsListedWord(until))) until--;
            if (context.Words[until].End - start > limits.MaxZoomSeconds) { log.Drop(field, "its word is longer than a zoom"); continue; }
            if (until != wanted) log.Repair(field + ".untilWord", "shortened to end on word " + N(until));
            var end = until;
            if (accepted.Any(other => other.Word <= end && word <= other.UntilWord)) { log.Drop(field, "overlaps another zoom"); continue; }
            var scale = AiJson.Number(AiJson.Get(item, "scale")) ?? double.NaN;
            if (!double.IsFinite(scale)) { scale = context.Prompt.Defaults.ZoomScale; log.Repair(field + ".scale", "unreadable; " + D(scale)); }
            else if (scale < limits.MinZoomScale || scale > limits.MaxZoomScale)
            {
                scale = Math.Clamp(scale, limits.MinZoomScale, limits.MaxZoomScale);
                log.Repair(field + ".scale", "clamped to " + D(scale));
            }
            accepted.Add(new(word, until, scale, Text(AiJson.Get(item, "reason"), limits.MaxReasonScalars, field + ".reason", log)));
        }
        return accepted.OrderBy(zoom => zoom.Word).ToArray();
    }

    private static int Score(JsonNode? value, ClipAutopilotContext context, string field, Log log)
    {
        if (AiJson.Number(value) is not { } number || !double.IsFinite(number))
        {
            log.Repair(field, "unreadable; " + N(context.Prompt.Defaults.Score));
            return context.Prompt.Defaults.Score;
        }
        var rounded = (int)Math.Min(10, Math.Max(1, Math.Round(number, MidpointRounding.AwayFromZero)));
        if (rounded != number) log.Repair(field, "clamped to " + N(rounded));
        return rounded;
    }

    /// <summary>The verdict, read ignoring case, spaces, hyphens and underscores; otherwise the one the score implies.</summary>
    private static ClipAutopilotVerdict Verdict(JsonNode? value, int score, string field, Log log)
    {
        var key = LettersLower(AiJson.String(value) ?? "");
        foreach (var verdict in Enum.GetValues<ClipAutopilotVerdict>())
            if (verdict.Name().ToLowerInvariant() == key) return verdict;
        var implied = ClipAutopilotWire.Implied(score);
        log.Repair(field, "unknown verdict; " + implied.Name());
        return implied;
    }

    private static IReadOnlyList<ClipAutopilotPlan.Question> Questions(JsonNode? value, ClipAutopilotContext context, Log log)
    {
        var limits = context.Prompt.Limits;
        var accepted = new List<ClipAutopilotPlan.Question>();
        var items = AiJson.Array(value);
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var field = "questions[" + N(index) + "]";
            if (accepted.Count >= limits.MaxQuestions) { log.Drop(field, "more than " + N(limits.MaxQuestions) + " questions"); continue; }
            var question = Text(AiJson.Get(item, "question"), limits.MaxReasonScalars, field, log);
            var answer = Text(AiJson.Get(item, "answer"), limits.MaxReasonScalars, field + ".answer", log);
            if (question.Length == 0 || answer.Length == 0) { log.Drop(field, "no question or answer"); continue; }
            var options = new List<string>();
            foreach (var option in AiJson.Array(AiJson.Get(item, "options")))
            {
                var shown = Text(option, limits.MaxTitleScalars, field + ".options", log);
                if (shown.Length > 0 && !options.Contains(shown) && options.Count < limits.MaxOptions) options.Add(shown);
            }
            accepted.Add(new(question, answer, options));
        }
        return accepted;
    }
}
