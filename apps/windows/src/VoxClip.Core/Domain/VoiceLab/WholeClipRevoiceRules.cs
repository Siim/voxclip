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

    /// <summary>The Fit step's verdict on the voice against the clip's rendered video (which already includes any clip speed).</summary>
    public abstract record Fit
    {
        private Fit() { }
        /// <summary>Within ±8%: the picture is retimed uniformly by <c>Factor</c> (voice ÷ video).</summary>
        public sealed record Matched(double Factor) : Fit;
        /// <summary>Outside it: ask for a wording of about <c>TargetWords</c> through the measured-wording round.</summary>
        public sealed record Reword(bool Shorter, int TargetWords) : Fit;
        /// <summary>No round is left: say so inline and offer a forward action.</summary>
        public sealed record CannotFit(double VoiceSeconds, double VideoSeconds) : Fit;
    }

    /// <summary><paramref name="round"/> counts the reword rounds already asked for.</summary>
    public static Fit FitVoice(double voiceSeconds, double videoSeconds, int words, int round)
    {
        if (!double.IsFinite(voiceSeconds) || !double.IsFinite(videoSeconds) || voiceSeconds <= 0 || videoSeconds <= 0)
            return new Fit.CannotFit(voiceSeconds, videoSeconds);
        var factor = voiceSeconds / videoSeconds;
        if (Math.Abs(factor - 1) <= FitTolerance + 1e-9) return new Fit.Matched(factor);
        if (round >= MaximumRewordRounds || words <= 0) return new Fit.CannotFit(voiceSeconds, videoSeconds);
        var target = Math.Max(1, (int)Math.Round(words / factor, MidpointRounding.AwayFromZero));
        return new Fit.Reword(factor > 1, target);
    }

    /// <summary>"video matched (−1.3%)": the voice's length against the video's, signed.</summary>
    public static string MatchedCopy(double factor)
    {
        var percent = (factor - 1) * 100;
        var rounded = Math.Round(percent * 10, MidpointRounding.AwayFromZero) / 10;
        var sign = rounded < 0 ? "−" : rounded > 0 ? "+" : "±";
        return "video matched (" + sign + Math.Abs(rounded).ToString("F1", CultureInfo.InvariantCulture) + "%)";
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
    /// transcript items.</summary>
    public IReadOnlyList<VoiceLabDiffHunk> Hunks(IReadOnlyList<TimedWord> words)
    {
        ArgumentNullException.ThrowIfNull(words);
        var spokenIndex = new Dictionary<string, int>(StringComparer.Ordinal);
        var spoken = 0;
        var items = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var offset = 0; offset < words.Count; offset++)
        {
            items.TryAdd(words[offset].Id, offset);
            if (words[offset].Kind == WordKind.Word) spokenIndex.TryAdd(words[offset].Id, spoken++);
        }
        var result = new List<VoiceLabDiffHunk>();
        foreach (var part in Parts)
        {
            var positions = part.SourceWordIds.Where(spokenIndex.ContainsKey).Select(id => spokenIndex[id]).ToArray();
            if (positions.Length == 0) continue;
            var itemPositions = part.SourceWordIds.Where(items.ContainsKey).Select(id => items[id]).ToArray();
            IReadOnlyList<string> absorbed = [];
            if (itemPositions.Length > 0 && itemPositions.Max() > itemPositions.Min())
                absorbed = words.Skip(itemPositions.Min() + 1).Take(itemPositions.Max() - itemPositions.Min() - 1)
                    .Where(word => word.Kind != WordKind.Word).Select(word => word.Id).ToArray();
            result.Add(new(VoiceLabDiffHunkKind.Voice, part.SourceWordIds, EditingAlgorithms.SplitWords(part.Text), [], absorbed, [],
                positions.Min(), positions.Max() + 1, null));
        }
        return result;
    }
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
