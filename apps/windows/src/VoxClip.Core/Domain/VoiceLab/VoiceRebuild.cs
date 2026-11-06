namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>"Rebuild from my videos" (voice-lab.md §6.12, ADR-R44; Mac <c>VoiceRebuild</c>, replayed by both Cores from
/// shared/fixtures/voice-lab/voice-rebuild-cases.json): the owner-verified speech across the user's projects that a rebuilt clone is made
/// from. Pure; the Media finder supplies the candidates and the enrollment sends the result.
///
/// The limits are the existing ones: the attested project route (§6.7) sends 1–24 training WAVs of 5–30 s, 30–120 s in total, each at most
/// 16 MiB, inside the client's 1–25 files and 10–240 s. ElevenLabs recommends 1–2 minutes for an instant clone (§6.5 step 3), so the
/// rebuild aims at the full 120 s.</summary>
public static class VoiceRebuild
{
    /// <summary>At most this many training files, the kept consent clip included.</summary>
    public const int MaximumFiles = 24;
    /// <summary>The least speech a rebuild sends, the kept clip included.</summary>
    public const long MinimumTotalMs = VoiceTrainingSpans.TotalMinMs;
    /// <summary>The most speech a rebuild sends, the kept clip included.</summary>
    public const long MaximumTotalMs = VoiceTrainingSpans.TotalMaxMs;
    /// <summary>The shortest piece.</summary>
    public const long MinimumPieceMs = VoiceTrainingSpans.SpanMinMs;
    /// <summary>The longest piece.</summary>
    public const long MaximumPieceMs = VoiceTrainingSpans.SpanMaxMs;
    /// <summary>The largest training WAV.</summary>
    public const int MaximumBytes = 16 * 1_024 * 1_024;
    /// <summary>Clean speech only: the §6.5.1 SNR floor.</summary>
    public const double MinimumSnrDb = VoiceTrainingSpans.MinSnrDb;
    /// <summary>The candidates the finder embeds per video: its cleanest qualifying spans.</summary>
    public const int CandidatesPerVideo = 6;
    /// <summary>The setting Use the new voice for Rewrite writes: the consent record id Rewrite's voice choice starts with when that voice is
    /// listed (a preference, not a binding: a removed or inactive record falls back to the first listed voice). No default.</summary>
    public const string RewriteVoiceKey = "voiceLab.rewriteVoice";

    /// <summary>One stretch of a project's own speech, scored against the voice's own consent embedding. <see cref="Video"/> is the
    /// project's media content key; <see cref="Score"/> the lowest of the piece's part scores and its whole score against the record's own
    /// embedding (§6.6 project span parts), so another voice inside it can't pass on the mean; <see cref="Embedding"/> the piece's whole
    /// embedding, L2-normalised, used for diversity only.</summary>
    public sealed record Candidate(string Video, long StartMs, long EndMs, double SnrDb, double Score, float[] Embedding)
    {
        /// <summary>The piece's length.</summary>
        public long DurationMs => EndMs - StartMs;
        /// <summary>Value equality, embedding included (Mac <c>Candidate</c> is Equatable).</summary>
        public bool Same(Candidate other) => Video == other.Video && StartMs == other.StartMs && EndMs == other.EndMs && SnrDb.Equals(other.SnrDb) &&
            Score.Equals(other.Score) && Embedding.AsSpan().SequenceEqual(other.Embedding);
    }

    /// <summary>Why a candidate was left out.</summary>
    public enum Rejection
    {
        /// <summary>It doesn't pass against the voice's own consent embedding at τ (one hop, never through a reference).</summary>
        NotTheOwner,
        /// <summary>Below the clean-speech floor, or no SNR.</summary>
        Noisy,
        /// <summary>Not 5–30 s.</summary>
        Length,
        /// <summary>Fine, but the set was already full (files or seconds).</summary>
        Full
    }

    /// <summary>The pieces in the order they are sent (after the kept clip when there is one), the kept clip's length, and the counts left out.</summary>
    public sealed record Plan(IReadOnlyList<Candidate> Pieces, long? KeptMs, IReadOnlyDictionary<Rejection, int> Rejected)
    {
        /// <summary>The speech sent, the kept clip included.</summary>
        public long TotalMs => (KeptMs ?? 0) + Pieces.Sum(piece => piece.DurationMs);
        /// <summary>The videos the pieces come from.</summary>
        public int VideoCount => Pieces.Select(piece => piece.Video).Distinct(StringComparer.Ordinal).Count();
        /// <summary>The training files sent, the kept clip included.</summary>
        public int FileCount => Pieces.Count + (KeptMs is null ? 0 : 1);
        /// <summary>Enough to make a voice (30 s).</summary>
        public bool Enough => TotalMs >= MinimumTotalMs;
    }

    /// <summary>Picks the rebuild's pieces:
    /// 1. one hop: only candidates scoring ≥ <paramref name="threshold"/> against the voice's own embedding, never via a reference;
    /// 2. clean: SNR ≥ <paramref name="minimumSnrDb"/>, 5–30 s;
    /// 3. each video once first: the cleanest piece of each video (SNR, then score, then the earlier start), the videos in order of that
    ///    piece's score;
    /// 4. then the most different: each further piece is the one whose highest cosine to any piece already chosen is lowest (ties: SNR,
    ///    score, video, start), until 24 files or 120 s; a piece that would pass 120 s is skipped and a later, shorter one may still fit.
    /// <paramref name="keptMs"/> (the existing reference sample, the statement itself) counts toward both limits. The floor is cleanliness
    /// only: a per-video voice (§6.13) lowers it; identity is still one hop at τ.</summary>
    public static Plan Pick(IReadOnlyList<Candidate> candidates, double threshold, long? keptMs = null, double minimumSnrDb = MinimumSnrDb)
    {
        var rejected = new Dictionary<Rejection, int>();
        List<Candidate> pool = [];
        foreach (var candidate in candidates)
        {
            Rejection? rejection = !(double.IsFinite(candidate.Score) && candidate.Score >= threshold) ? Rejection.NotTheOwner
                : !(double.IsFinite(candidate.SnrDb) && candidate.SnrDb >= minimumSnrDb) ? Rejection.Noisy
                : candidate.DurationMs is < MinimumPieceMs or > MaximumPieceMs ? Rejection.Length : null;
            if (rejection is { } reason) rejected[reason] = rejected.GetValueOrDefault(reason) + 1;
            else pool.Add(candidate);
        }
        List<Candidate> chosen = [];
        var total = keptMs ?? 0;
        var files = keptMs is null ? 0 : 1;
        bool Fits(Candidate candidate) => files < MaximumFiles && total + candidate.DurationMs <= MaximumTotalMs;
        void Take(Candidate candidate) { chosen.Add(candidate); total += candidate.DurationMs; files++; }
        // Round 1: the cleanest piece of every video.
        var firsts = pool.GroupBy(candidate => candidate.Video, StringComparer.Ordinal).Select(group => group.OrderBy(candidate => candidate, Cleaner).First())
            .OrderByDescending(candidate => candidate.Score).ThenBy(candidate => candidate, Cleaner).ToArray();
        foreach (var candidate in firsts) if (Fits(candidate)) Take(candidate);
        // Round 2: the most different remaining piece, again and again.
        var remaining = pool.Where(candidate => !chosen.Any(other => other.Same(candidate))).ToList();
        while (remaining.Count > 0)
        {
            (int Index, double Closeness)? best = null;
            for (var index = 0; index < remaining.Count; index++)
            {
                var candidate = remaining[index];
                if (!Fits(candidate)) continue;
                var closeness = chosen.Count == 0 ? -1 : chosen.Max(other => Closeness(other.Embedding, candidate.Embedding));
                if (best is not { } current || closeness < current.Closeness ||
                    closeness == current.Closeness && Cleaner.Compare(candidate, remaining[current.Index]) < 0) best = (index, closeness);
            }
            if (best is not { } next) break;
            Take(remaining[next.Index]);
            remaining.RemoveAt(next.Index);
        }
        if (remaining.Count > 0) rejected[Rejection.Full] = rejected.GetValueOrDefault(Rejection.Full) + remaining.Count;
        return new(chosen, keptMs, rejected);
    }

    /// <summary>SNR descending, then score descending, then video, then start.</summary>
    private static readonly Comparer<Candidate> Cleaner = Comparer<Candidate>.Create((a, b) =>
        a.SnrDb != b.SnrDb ? b.SnrDb.CompareTo(a.SnrDb) : a.Score != b.Score ? b.Score.CompareTo(a.Score)
        : a.Video != b.Video ? string.CompareOrdinal(a.Video, b.Video) : a.StartMs.CompareTo(b.StartMs));

    private static double Closeness(float[] left, float[] right)
    {
        try { return SpeakerAudio.Cosine(left, right); }
        catch (VoiceConsentException) { return 1; }
    }

    /// <summary>"2 min", "1 min 8 s", "27 s": whole seconds, as minutes and seconds.</summary>
    public static string Amount(long milliseconds)
    {
        var seconds = Math.Max(0, milliseconds) / 1000;
        var minutes = seconds / 60;
        var rest = seconds % 60;
        if (minutes == 0) return $"{rest} s";
        return rest == 0 ? $"{minutes} min" : $"{minutes} min {rest} s";
    }

    /// <summary>The line shown before any click: how much speech, from how many videos ("2 min from 9 videos and your consent clip").</summary>
    public static string Summary(Plan plan) =>
        $"{Amount(plan.TotalMs)} from {(plan.VideoCount == 1 ? "1 video" : $"{plan.VideoCount} videos")}{(plan.KeptMs is null ? "" : " and your consent clip")}";
}
