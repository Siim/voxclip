using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The switch rule, Claude mode's choice, the fit and the price (Mac <c>WholeClipRevoice.swift</c>; shared vectors
/// <c>whole-clip-revoice-cases.json</c>). Free and deterministic; nothing here is sent or spent.</summary>
public static partial class WholeClipRevoice
{
    /// <summary>(a) Revoice when the changed phrases re-voice at least this share of the clip's spoken words.</summary>
    public const int WordSharePercent = 40;
    /// <summary>(b) Revoice when at least this many phrases can't fit their slot (they would keep the original audio).</summary>
    public const int NoFitPhrases = 2;
    /// <summary>Measured-wording rounds the Fit step may ask for before it says the voice can't fit.</summary>
    public const int MaximumRewordRounds = 2;
    /// <summary>A part of the script is whole sentences spanning at most this much source time (a single longer sentence stays one part).</summary>
    public const double MaximumPartSeconds = 12.0;
    /// <summary>A script part never exceeds the text-to-speech route's limit.</summary>
    public const int MaximumPartCharacters = 1_000;
    /// <summary>Lip sync takes at most 300 s in one job (voice-lab §9.3).</summary>
    public const double MaximumClipSeconds = 300.0;

    /// <summary>What the rule reads from a Rewrite of one clip.</summary>
    /// <param name="SpokenWords">The clip's spoken words (transcript <c>word</c> items in its span, after its cuts).</param>
    /// <param name="RevoicedWords">The words the patch re-voices: every new word of the included voice changes.</param>
    /// <param name="NoFitPhrases">Phrases no video duration can carry, or, before takes, phrases the free fit keeps as recorded.</param>
    public readonly record struct RuleInputs(int SpokenWords, int RevoicedWords, int NoFitPhrases);

    /// <summary>Why patching would sound stitched.</summary>
    public abstract record Reason
    {
        private Reason() { }
        /// <summary>The changes re-voice at least 40% of the clip's spoken words.</summary>
        public sealed record ManyWords(int Revoiced, int Spoken) : Reason;
        /// <summary>At least two phrases can't fit their slot.</summary>
        public sealed record PhrasesCantFit(int Count) : Reason;
    }

    /// <summary>The rule (ADR-R46): (a) the changes re-voice at least 40% of the clip's spoken words, or (b) at least two phrases
    /// can't fit their slot. Integer arithmetic, so the edges are exact. Null keeps patching.</summary>
    public static Reason? ReasonFor(RuleInputs inputs)
    {
        if (inputs.SpokenWords > 0 && inputs.RevoicedWords > 0 && (long)inputs.RevoicedWords * 100 >= (long)inputs.SpokenWords * WordSharePercent)
            return new Reason.ManyWords(inputs.RevoicedWords, inputs.SpokenWords);
        return inputs.NoFitPhrases >= NoFitPhrases ? new Reason.PhrasesCantFit(inputs.NoFitPhrases) : null;
    }

    /// <summary>✦ Claude does it all's choice for a clip whose patch would sound stitched.</summary>
    public abstract record AutoChoice
    {
        private AutoChoice() { }
        /// <summary>Patch as before: the rule doesn't apply, or no price is known (nothing unpriced is ever spent or offered).</summary>
        public sealed record Patch : AutoChoice;
        /// <summary>Revoice the whole clip: its price fits what is left of the run's cap.</summary>
        public sealed record Revoice(decimal Price) : AutoChoice;
        /// <summary>Patch, and offer "Revoice the Whole Clip · ≈ $X" inline; nothing is spent until it is clicked.</summary>
        public sealed record PatchAndOffer(decimal Price) : AutoChoice;
    }

    /// <summary><paramref name="remaining"/> is what the run may still spend (null: no paid step may run).</summary>
    public static AutoChoice Choose(Reason? reason, decimal? price, decimal? remaining)
    {
        if (reason is null || price is not { } known || known <= 0) return new AutoChoice.Patch();
        if (remaining is not { } left || known > left) return new AutoChoice.PatchAndOffer(known);
        return new AutoChoice.Revoice(known);
    }

    /// <summary>The callout over a large change, as the mockup's.</summary>
    public static string Callout(Reason reason) => reason switch
    {
        Reason.ManyWords many => $"These changes re-voice {many.Revoiced} words, a lot for a {many.Spoken}-word clip. Long stretches in your voice can sound stitched.",
        Reason.PhrasesCantFit cant => $"{cant.Count} phrases can't fit their places in the video, so they would keep your original audio. Revoicing the whole clip fits the picture to the voice.",
        _ => throw new ArgumentOutOfRangeException(nameof(reason))
    };

    /// <summary>The Fit step's verdict on the voice against the clip <b>as edited</b>: its cuts and tightened pauses applied, the
    /// length the user sees and the video the lip sync gets (ADR-R46, "One timeline"). Clip speed scales both alike.</summary>
    public abstract record Fit
    {
        private Fit() { }
        /// <summary>Within ±8%: the voice is laid out on the clip as edited (<c>Factor</c> = voice ÷ video).</summary>
        public sealed record Matched(double Factor) : Fit;
        /// <summary>Shorter than that: still laid out on the clip as edited, its sentence-end pauses within the pause bound, ending
        /// on the clip's own last pause with the picture after it trimmed. Never a longer wording.</summary>
        public sealed record LaidOut(double Factor) : Fit;
        /// <summary>Longer than the clip as edited can hold: ask for a <b>shorter</b> wording of about <c>TargetWords</c>.</summary>
        public sealed record Reword(int TargetWords) : Fit;
        /// <summary>No round is left: say so inline and offer a forward action.</summary>
        public sealed record CannotFit(double VoiceSeconds, double VideoSeconds) : Fit;
    }

    /// <summary><paramref name="voiceSeconds"/> is the voice as said, <paramref name="videoSeconds"/> the clip as edited and
    /// <paramref name="round"/> the reword rounds already asked for.</summary>
    public static Fit FitVoice(double voiceSeconds, double videoSeconds, int words, int round)
    {
        if (!double.IsFinite(voiceSeconds) || !double.IsFinite(videoSeconds) || voiceSeconds <= 0 || videoSeconds <= 0)
            return new Fit.CannotFit(voiceSeconds, videoSeconds);
        var factor = voiceSeconds / videoSeconds;
        if (Math.Abs(factor - 1) <= FitTolerance + 1e-9) return new Fit.Matched(factor);
        if (factor < 1) return new Fit.LaidOut(factor);
        if (round >= MaximumRewordRounds || words <= 0) return new Fit.CannotFit(voiceSeconds, videoSeconds);
        return new Fit.Reword(Math.Max(1, (int)Math.Round(words / factor, MidpointRounding.AwayFromZero)));
    }

    /// <summary>Check before paying: a reworded script is voiced only when its speaking-rate estimate, scaled by the measured
    /// voice, comes in at or under the clip as edited plus <see cref="FitTolerance"/>.</summary>
    public static bool RewordFits(double voiceSeconds, double estimateSeconds, double newEstimateSeconds, double videoSeconds) =>
        PredictedSeconds(voiceSeconds, estimateSeconds, newEstimateSeconds) is { } predicted && double.IsFinite(videoSeconds) && videoSeconds > 0 &&
        predicted <= videoSeconds * (1 + FitTolerance) + 1e-9;

    /// <summary>The new wording's predicted voice: the measured voice scaled by the estimates' ratio; null without a usable estimate.</summary>
    public static double? PredictedSeconds(double voiceSeconds, double estimateSeconds, double newEstimateSeconds)
    {
        if (!double.IsFinite(voiceSeconds) || voiceSeconds <= 0 || !double.IsFinite(estimateSeconds) || estimateSeconds <= 0 ||
            !double.IsFinite(newEstimateSeconds) || newEstimateSeconds <= 0) return null;
        return voiceSeconds * newEstimateSeconds / estimateSeconds;
    }

    /// <summary>"video matched (−1.3%)": the voice's length against the video's, signed.</summary>
    public static string MatchedCopy(double factor) => "video matched (" + SignedPercent(factor) + ")";

    /// <summary>"laid out on the clip's pauses (−14.0%)": a shorter voice, laid out on the clip as edited.</summary>
    public static string LaidOutCopy(double factor) => "laid out on the clip's pauses (" + SignedPercent(factor) + ")";

    /// <summary>A shorter voice first speeds the clip's picture up evenly, to at most this (the user, 2026-11-08); the pause layout
    /// and the trim take what is left (ADR-R46, "Your own pace"). The voice itself is never stretched.</summary>
    public const double MaximumPictureSpeed = 1.2;

    /// <summary>The picture's even speed-up for a voice on the clip as edited: the clip's length ÷ the voice's, from 1 to
    /// <see cref="MaximumPictureSpeed"/>; 1 for an unusable input.</summary>
    public static double PictureSpeed(double voiceSeconds, double videoSeconds)
    {
        if (!double.IsFinite(voiceSeconds) || !double.IsFinite(videoSeconds) || voiceSeconds <= 0 || videoSeconds <= 0) return 1;
        return Math.Min(MaximumPictureSpeed, Math.Max(1, videoSeconds / voiceSeconds));
    }

    /// <summary>"picture 1.20× and laid out on the clip's pauses", or "picture 1.12× to fit" when the speed-up alone fills the clip.</summary>
    public static string SpedCopy(double speed, bool laidOut) =>
        "picture " + SpeedLabel(speed) + (laidOut ? " and laid out on the clip's pauses" : " to fit");

    /// <summary>"1.20×": the factor to two decimals.</summary>
    public static string SpeedLabel(double speed) => (double.IsFinite(speed) ? speed : 1).ToString("F2", CultureInfo.InvariantCulture) + "×";

    /// <summary>The record's <c>videoRetime</c>: the picture's speed, from the fit tolerance's slowest to <see cref="MaximumPictureSpeed"/>.</summary>
    public static bool ValidRetime(double value) =>
        double.IsFinite(value) && value >= 1 - FitTolerance - 1e-9 && value <= MaximumPictureSpeed + 1e-9;

    private static string SignedPercent(double factor)
    {
        var percent = (factor - 1) * 100;
        var rounded = Math.Round(percent * 10, MidpointRounding.AwayFromZero) / 10;
        var sign = rounded < 0 ? "−" : rounded > 0 ? "+" : "±";
        return sign + Math.Abs(rounded).ToString("F1", CultureInfo.InvariantCulture) + "%";
    }

    /// <summary>The layout's pause bound: a sentence-end pause grows to at most the project's pause threshold (a longer one is a
    /// pause the clip's own Tighten would cut), never under the punctuated floor; the voice's last pause holds the same.</summary>
    public static double LayoutPauseBound(double pauseThresholdSeconds) =>
        double.IsFinite(pauseThresholdSeconds) ? Math.Max(VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, pauseThresholdSeconds) : VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT;

    /// <summary>The clip's own cuts inside a source window: every stretch of the window the clip's output plan (with no voice in
    /// it) doesn't play.</summary>
    public static IReadOnlyList<VoiceLabVideoCut> EditedCuts(VoiceLabOutputPlan plan, long startSample, long endSample)
    {
        if (endSample <= startSample) return [];
        var cuts = new List<VoiceLabVideoCut>();
        var cursor = startSample;
        foreach (var piece in plan.Pieces.OrderBy(piece => piece.SourceStartSample))
        {
            if (piece.SourceEndSample <= startSample || piece.SourceStartSample >= endSample) continue;
            var lower = Math.Max(piece.SourceStartSample, startSample);
            if (lower > cursor) cuts.Add(new(cursor, lower));
            cursor = Math.Max(cursor, Math.Min(piece.SourceEndSample, endSample));
        }
        if (cursor < endSample) cuts.Add(new(cursor, endSample));
        return cuts;
    }

    /// <summary>The clip as edited inside a source window, in seconds: the window without its edited cuts.</summary>
    public static double EditedSeconds(IReadOnlyList<VoiceLabVideoCut> cuts, long startSample, long endSample, double sampleRate)
    {
        var removed = cuts.Sum(cut => Math.Max(0, cut.EndSample - cut.StartSample));
        return Math.Max(0, endSample - startSample - removed) / sampleRate;
    }

    /// <summary>The picture under a laid-out voice: the clip's own cuts changed to remove exactly <paramref name="removedSamples"/>
    /// of the window. More trims the picture's end, latest first; less gives cut picture back from the latest cut, each from its
    /// start. Null when nothing would be left or the cuts are not inside the window and apart (Mac <c>layoutCuts</c>).</summary>
    public static IReadOnlyList<VoiceLabVideoCut>? LayoutCuts(IReadOnlyList<VoiceLabVideoCut> cuts, long startSample, long endSample, long removedSamples)
    {
        var span = endSample - startSample;
        if (span <= 0 || removedSamples < 0 || removedSamples >= span ||
            !cuts.All(cut => cut.StartSample >= startSample && cut.EndSample <= endSample && cut.EndSample > cut.StartSample)) return null;
        var ordered = cuts.OrderBy(cut => cut.StartSample).ToList();
        for (var index = 1; index < ordered.Count; index++) if (ordered[index - 1].EndSample > ordered[index].StartSample) return null;
        var removed = ordered.Sum(cut => cut.EndSample - cut.StartSample);
        if (removedSamples <= removed)
        {
            var giveBack = removed - removedSamples;
            var result = ordered.ToList();
            for (var index = result.Count - 1; index >= 0 && giveBack > 0; index--)
            {
                var take = Math.Min(giveBack, result[index].EndSample - result[index].StartSample);
                result[index] = new(result[index].StartSample + take, result[index].EndSample);
                giveBack -= take;
            }
            return result.Where(cut => cut.EndSample > cut.StartSample).ToList();
        }
        var kept = new List<(long Start, long End)>();
        var cursor = startSample;
        foreach (var cut in ordered)
        {
            if (cut.StartSample > cursor) kept.Add((cursor, cut.StartSample));
            cursor = cut.EndSample;
        }
        if (cursor < endSample) kept.Add((cursor, endSample));
        var extra = removedSamples - removed;
        for (var index = kept.Count - 1; index >= 0 && extra > 0; index--)
        {
            var take = Math.Min(extra, kept[index].End - kept[index].Start);
            kept[index] = (kept[index].Start, kept[index].End - take);
            extra -= take;
        }
        kept.RemoveAll(stretch => stretch.End <= stretch.Start);
        if (extra != 0 || kept.Count == 0) return null;
        var trimmed = new List<VoiceLabVideoCut>();
        cursor = startSample;
        foreach (var stretch in kept)
        {
            if (stretch.Start > cursor) trimmed.Add(new(cursor, stretch.Start));
            cursor = stretch.End;
        }
        if (cursor < endSample) trimmed.Add(new(cursor, endSample));
        return trimmed;
    }

    /// <summary>The whole clip's price before anything is sent: the voice for every script character, and the lip sync for the clip's
    /// video seconds. Both come from the pricing tables; a null <see cref="Usd"/> when either row is missing.</summary>
    public sealed record Price(CostEstimate Voice, CostEstimate Lipsync)
    {
        /// <summary>The sum, or null when either part is unpriced.</summary>
        public decimal? Usd => Voice.Usd is { } voice && Lipsync.Usd is { } lipsync ? voice + lipsync : null;
    }

    /// <summary>The voice and lip-sync price from the catalog.</summary>
    public static Price PriceFor(int characters, string ttsModel, double videoSeconds, WholeClipLipsync lipsync, VoiceLabPriceCatalog catalog)
    {
        var voice = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsTextToSpeech, ttsModel, characters, 1, null, catalog);
        return new(voice, LipsyncPrice(videoSeconds, lipsync, catalog));
    }

    /// <summary>The lip sync's price for the clip's video seconds.</summary>
    public static CostEstimate LipsyncPrice(double videoSeconds, WholeClipLipsync lipsync, VoiceLabPriceCatalog catalog)
        => VoiceLabPricing.Estimate(VoiceLabPricedOperation.FalLipsync(lipsync.Endpoint()), lipsync.Model(), videoSeconds, 1, null, catalog);
}

/// <summary>The clip's words with every edit and rewrite applied, in transcript order (the Script step; free).</summary>
public sealed class WholeClipScript
{
    /// <summary>One sentence of the script, with the source words it is said over.</summary>
    public sealed record Sentence(IReadOnlyList<string> Tokens, IReadOnlyList<string> SourceWordIds, double Start, double End)
    {
        /// <summary>The tokens joined by spaces.</summary>
        public string Text => string.Join(' ', Tokens);
    }

    /// <summary>One part of the voice: whole sentences said in one request, over the source words they replace.</summary>
    public sealed record Part(string Text, int Words, IReadOnlyList<string> SourceWordIds, double Start, double End);

    private WholeClipScript(IReadOnlyList<Sentence> sentences) => Sentences = sentences;

    /// <summary>The script's sentences.</summary>
    public IReadOnlyList<Sentence> Sentences { get; }
    /// <summary>Every sentence joined by spaces.</summary>
    public string Text => string.Join(' ', Sentences.Select(sentence => sentence.Text));
    /// <summary>Every token.</summary>
    public int Words => Sentences.Sum(sentence => sentence.Tokens.Count);
    /// <summary>Unicode scalars in <see cref="Text"/>.</summary>
    public int Characters => Text.EnumerateRunes().Count();

    /// <summary><paramref name="words"/> are the clip's transcript items in order (their text already corrected); <paramref name="cutWordIds"/>
    /// the project's cuts; <paramref name="voiceHunks"/> the Rewrite's included voice changes. A change replaces its source words where its
    /// first one stood; a change with no source words (an insertion, which the prompts forbid, ADR-R42) is left out. Null when nothing is said.</summary>
    public static WholeClipScript? Assemble(IReadOnlyList<TimedWord> words, IReadOnlySet<string> cutWordIds, IReadOnlyList<VoiceLabDiffHunk> voiceHunks)
    {
        ArgumentNullException.ThrowIfNull(words); ArgumentNullException.ThrowIfNull(cutWordIds); ArgumentNullException.ThrowIfNull(voiceHunks);
        var spoken = words.Where(word => word.Kind == WordKind.Word).ToArray();
        var byId = new Dictionary<string, TimedWord>(StringComparer.Ordinal);
        foreach (var word in spoken) byId.TryAdd(word.Id, word);
        var owner = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < voiceHunks.Count; index++)
        {
            if (voiceHunks[index].Kind != VoiceLabDiffHunkKind.Voice) continue;
            foreach (var id in voiceHunks[index].SourceWordIds)
                if (byId.ContainsKey(id)) owner.TryAdd(id, index);
        }
        var units = new List<(IReadOnlyList<string> Tokens, IReadOnlyList<string> Sources)>();
        var emitted = new HashSet<int>();
        foreach (var word in spoken)
        {
            if (owner.TryGetValue(word.Id, out var index))
            {
                if (!emitted.Add(index)) continue;
                var sources = voiceHunks[index].SourceWordIds.Where(byId.ContainsKey).ToArray();
                units.Add((voiceHunks[index].NewTokens.Where(token => token.Length > 0).ToArray(), sources));
            }
            else if (!cutWordIds.Contains(word.Id)) units.Add((EditingAlgorithms.SplitWords(word.Text), [word.Id]));
        }
        var sentences = new List<Sentence>();
        var tokens = new List<string>();
        var sourceIds = new List<string>();
        void Close()
        {
            var said = tokens.ToArray(); var from = sourceIds.ToArray();
            tokens.Clear(); sourceIds.Clear();
            if (said.Length == 0) return;
            var times = from.Where(byId.ContainsKey).Select(id => byId[id]).ToArray();
            if (times.Length == 0)
            {
                // A sentence made only of new words with no source left (every source word re-owned): join the previous.
                if (sentences.Count > 0)
                {
                    var last = sentences[^1];
                    sentences[^1] = last with { Tokens = last.Tokens.Concat(said).ToArray() };
                }
                return;
            }
            sentences.Add(new(said, from, times.Min(word => word.Start), times.Max(word => word.End)));
        }
        foreach (var (unitTokens, unitSources) in units)
        {
            foreach (var id in unitSources) if (!sourceIds.Contains(id, StringComparer.Ordinal)) sourceIds.Add(id);
            foreach (var token in unitTokens)
            {
                tokens.Add(token);
                if (token.Length > 0 && token[^1] is '.' or '!' or '?' or '…') Close();
            }
        }
        Close();
        return sentences.Count == 0 ? null : new WholeClipScript(sentences);
    }

    /// <summary>The script split at sentence boundaries into parts of at most <see cref="WholeClipRevoice.MaximumPartSeconds"/> of source
    /// time and <see cref="WholeClipRevoice.MaximumPartCharacters"/>; one voice says every part.</summary>
    public IReadOnlyList<Part> Parts
    {
        get
        {
            var parts = new List<Part>();
            var group = new List<Sentence>();
            void Flush()
            {
                if (group.Count == 0) return;
                var tokens = group.SelectMany(sentence => sentence.Tokens).ToArray();
                parts.Add(new(string.Join(' ', tokens), tokens.Length, group.SelectMany(sentence => sentence.SourceWordIds).ToArray(), group[0].Start, group[^1].End));
                group.Clear();
            }
            foreach (var sentence in Sentences)
            {
                if (group.Count > 0)
                {
                    var seconds = sentence.End - group[0].Start;
                    var characters = string.Join(' ', group.Select(item => item.Text).Append(sentence.Text)).EnumerateRunes().Count();
                    if (seconds > WholeClipRevoice.MaximumPartSeconds || characters > WholeClipRevoice.MaximumPartCharacters) Flush();
                }
                group.Add(sentence);
            }
            Flush();
            return parts;
        }
    }

    /// <summary>The parts as Rewrite voice changes, so each goes through the existing take path. <paramref name="words"/> are the clip's
    /// transcript items; <paramref name="cutWordIds"/> and <paramref name="cutPauseIds"/> the project's cuts. Every spoken word is replaced,
    /// so the parts tile the clip (voice-lab §8.14 item 3): the first starts at the clip's first item, the last ends at its last. Between two
    /// parts, from the last kept source word of one to the first kept source word of the next, the items go to the side of the widest gap
    /// (the earliest on a tie), so both windows seam in that gap; a cut pause counts as no gap. When the widest gap is narrower than
    /// <c>SEAM_MIN_GAP</c> the two parts become one change. Two parts whose kept words touch keep their split. A hunk's source IDs are its
    /// parts' source words in its span with the items it takes at its edges; its absorbed IDs are the non-word items in its span; its spoken
    /// indices tile the clip's spoken words.</summary>
    public IReadOnlyList<VoiceLabDiffHunk> Hunks(IReadOnlyList<TimedWord> words, IReadOnlySet<string> cutWordIds, IReadOnlySet<string> cutPauseIds)
    {
        ArgumentNullException.ThrowIfNull(words); ArgumentNullException.ThrowIfNull(cutWordIds); ArgumentNullException.ThrowIfNull(cutPauseIds);
        var items = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var offset = 0; offset < words.Count; offset++) items.TryAdd(words[offset].Id, offset);
        var tiles = new List<Tile>();
        foreach (var part in Parts)
        {
            var positions = part.SourceWordIds.Where(items.ContainsKey).Select(id => items[id]).ToArray();
            if (positions.Length == 0) continue;
            var kept = positions.Where(position => words[position].Kind == WordKind.Word && !cutWordIds.Contains(words[position].Id)).ToArray();
            tiles.Add(new Tile(part.SourceWordIds.ToList(), EditingAlgorithms.SplitWords(part.Text).ToList(), positions.Min(), positions.Max(),
                kept.Length > 0 ? kept.Min() : positions.Min(), kept.Length > 0 ? kept.Max() : positions.Max(), positions.Min(), positions.Max()));
        }
        if (tiles.Count == 0) return [];
        // Where the silence after item j begins: the latest end of the items up to it.
        var reached = new double[words.Count];
        for (var index = 0; index < words.Count; index++) reached[index] = index == 0 ? words[0].End : Math.Max(reached[index - 1], words[index].End);
        var joined = new List<Tile> { tiles[0] };
        foreach (var next in tiles.Skip(1))
        {
            var current = joined[^1];
            joined.RemoveAt(joined.Count - 1);
            int left = current.KeptLast, right = next.KeptFirst;
            if (current.Last < next.First && right > left)
            {
                int split = left; var widest = double.PositiveInfinity;
                if (right > left + 1)
                {
                    widest = double.NegativeInfinity;
                    for (var j = left; j < right; j++)
                    {
                        var gap = cutPauseIds.Contains("pause-after-" + words[j].Id) ? 0.0 : words[j + 1].Start - reached[j];
                        if (gap > widest) { widest = gap; split = j; }
                    }
                }
                if (widest >= VoiceLabPatchConstants.SEAM_MIN_GAP)
                {
                    joined.Add(current with { Upper = split });
                    joined.Add(next with { Lower = split + 1 });
                    continue;
                }
            }
            // No seam fits between them, or their sources interleave: one change.
            var sources = current.Sources.Concat(next.Sources.Where(id => !current.Sources.Contains(id))).ToList();
            joined.Add(current with
            {
                Sources = sources, Tokens = current.Tokens.Concat(next.Tokens).ToList(), First = Math.Min(current.First, next.First),
                Last = Math.Max(current.Last, next.Last), KeptFirst = Math.Min(current.KeptFirst, next.KeptFirst),
                KeptLast = Math.Max(current.KeptLast, next.KeptLast), Upper = Math.Max(current.Upper, next.Upper),
            });
        }
        joined[0] = joined[0] with { Lower = 0 };
        joined[^1] = joined[^1] with { Upper = words.Count - 1 };
        var spokenBefore = new int[words.Count + 1];
        for (var index = 0; index < words.Count; index++) spokenBefore[index + 1] = spokenBefore[index] + (words[index].Kind == WordKind.Word ? 1 : 0);
        var result = new List<VoiceLabDiffHunk>();
        foreach (var tile in joined)
        {
            var inSpan = tile.Sources.Where(id => items.TryGetValue(id, out var position) && position >= tile.Lower && position <= tile.Upper).ToArray();
            var first = inSpan.Length > 0 ? inSpan.Min(id => items[id]) : tile.Lower;
            var last = inSpan.Length > 0 ? inSpan.Max(id => items[id]) : tile.Upper;
            var leading = words.Skip(tile.Lower).Take(first - tile.Lower).Select(word => word.Id);
            var trailing = words.Skip(last + 1).Take(tile.Upper - last).Select(word => word.Id);
            var absorbed = words.Skip(tile.Lower).Take(tile.Upper - tile.Lower + 1).Where(word => word.Kind != WordKind.Word).Select(word => word.Id).ToArray();
            result.Add(new(VoiceLabDiffHunkKind.Voice, leading.Concat(inSpan).Concat(trailing).ToArray(), tile.Tokens.ToArray(), [], absorbed, [],
                spokenBefore[tile.Lower], spokenBefore[tile.Upper + 1], null));
        }
        return result;
    }

    /// <summary>A part's source items (<c>First</c>, <c>Last</c>), its kept ones (its source items when it has none) and its span.</summary>
    private sealed record Tile(List<string> Sources, List<string> Tokens, int First, int Last, int KeptFirst, int KeptLast, int Lower, int Upper);
}

/// <summary>What a whole-clip run has paid for, keyed by what it was paid for. A step whose key matches is reused instead of paid again:
/// Try Again after a failed or cancelled lip sync keeps the voice, and the sync-3 upgrade re-runs only the lip sync.</summary>
public sealed class WholeClipRevoiceLedger
{
    /// <summary>The voice: the script, the voice record and the text-to-speech model it was said in.</summary>
    public sealed record VoiceKey(string Script, string RecordId, string Model);
    /// <summary>A lip sync: the voice it was made over, the picture's retime and the model.</summary>
    public sealed record LipsyncKey(VoiceKey Voice, double Retime, WholeClipLipsync Model);

    private readonly Dictionary<VoiceKey, decimal> voices = [];
    private readonly Dictionary<LipsyncKey, decimal> lipsyncs = [];

    /// <summary>Whether this voice was paid for.</summary>
    public bool Paid(VoiceKey key) => voices.ContainsKey(key);
    /// <summary>Whether this lip sync was paid for.</summary>
    public bool Paid(LipsyncKey key) => lipsyncs.ContainsKey(key);
    /// <summary>Records a paid voice.</summary>
    public void Record(VoiceKey key, decimal usd) => voices[key] = usd;
    /// <summary>Records a paid lip sync.</summary>
    public void Record(LipsyncKey key, decimal usd) => lipsyncs[key] = usd;
    /// <summary>Everything paid so far.</summary>
    public decimal Total => voices.Values.Sum() + lipsyncs.Values.Sum();
    /// <summary>What is still to pay for these steps: a step already paid costs nothing again.</summary>
    public decimal Remaining(VoiceKey voice, decimal voiceUsd, LipsyncKey? lipsync, decimal lipsyncUsd)
        => (Paid(voice) ? 0 : voiceUsd) + (lipsync is not null && Paid(lipsync) ? 0 : lipsyncUsd);
}
