using VoxClip.Core.Services.Speech;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>How a phrase's speech matched the owner: against the consent record's own embedding (the statement, or the attested
/// reference sample) when <see cref="ContentKey"/> is null, else against the reference learned from that project.</summary>
public sealed record VoiceSpeakerMatch(double Score, string? ContentKey = null)
{
    /// <summary>True when the match came through a learned reference.</summary>
    public bool ViaReference => ContentKey is not null;
}

/// <summary>Why a learning step changed nothing.</summary>
public enum VoiceReferenceRefusal
{
    /// <summary>The speech doesn't pass against the record's own embedding: it is never stored (one hop).</summary>
    NotTheOwner,
    /// <summary>Another speaker model made it.</summary>
    OtherModel,
    /// <summary>This project already has a reference that scores at least as well.</summary>
    NotBetter
}

/// <summary>A learning step that changed nothing, and why.</summary>
public sealed class VoiceReferenceRefusedException(VoiceReferenceRefusal reason) : Exception(reason.ToString())
{
    /// <summary>Why nothing was learned.</summary>
    public VoiceReferenceRefusal Reason { get; } = reason;
}

/// <summary>"Let a video teach your voice" (voice-lab.md §6.9, ADR-R41; Mac <c>VoiceSpeakerReferences</c>, replayed by both Cores from
/// shared/fixtures/voice-lab/voice-references-cases.json). The use-time guard accepts a phrase whose speech matches the consent record's
/// own embedding, or matches a reference learned from the owner's own videos. Every reference passed against the record's own embedding
/// when it was learned and still does: one hop, never a chain. τ never changes.</summary>
public static class VoiceSpeakerReferences
{
    /// <summary>At most this many references per voice; one per project content key.</summary>
    public const int Bound = 16;
    /// <summary>The longest content key a reference keeps (a SHA-256 hex is 64).</summary>
    public const int MaximumContentKey = 128;

    /// <summary>A content key a reference may carry: ASCII letters, digits, '-' and '_', 1 to 128 of them.</summary>
    public static bool ContentKeyValid(string key) =>
        key.Length is >= 1 and <= MaximumContentKey && key.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_');

    /// <summary>The structure <see cref="VoiceConsentRecord.Validate"/> requires of the references. A reference from another speaker model
    /// is well-formed and kept on disk until the next learning drops it; it is never used.</summary>
    internal static void Validate(VoiceConsentSpeaker speaker)
    {
        if (speaker.References is not { } references) return;
        if (references.Length is 0 or > Bound || references.Select(reference => reference.ContentKey).Distinct(StringComparer.Ordinal).Count() != references.Length ||
            VoiceConsentRecord.DecodeEmbedding(speaker.Embedding) is not { } owner) throw Invalid();
        foreach (var reference in references)
            if (reference is null || !ContentKeyValid(reference.ContentKey) || string.IsNullOrEmpty(reference.Model) ||
                !VoiceConsentRecord.TimestampValid(reference.AddedAt) || !double.IsFinite(reference.StatementScore) || reference.StatementScore > 1.00001 ||
                VoiceConsentRecord.DecodeEmbedding(reference.Embedding) is not { } embedding ||
                reference.Model == speaker.Model && embedding.Length != owner.Length) throw Invalid();
    }

    /// <summary>The references the guard may use: from the record's own speaker model, and passing against the record's own embedding when
    /// re-checked now. The stored score is not trusted on its own.</summary>
    public static IReadOnlyList<(string ContentKey, float[] Embedding)> Usable(VoiceConsentSpeaker speaker)
    {
        if (VoiceConsentRecord.DecodeEmbedding(speaker.Embedding) is not { } owner) return [];
        List<(string, float[])> usable = [];
        foreach (var reference in speaker.References ?? [])
        {
            if (reference.Model != speaker.Model || reference.StatementScore < speaker.Threshold ||
                VoiceConsentRecord.DecodeEmbedding(reference.Embedding) is not { } embedding || embedding.Length != owner.Length) continue;
            double hop;
            try { hop = SpeakerAudio.Cosine(owner, embedding); }
            catch (VoiceConsentException) { continue; }
            if (hop >= speaker.Threshold) usable.Add((reference.ContentKey, embedding));
        }
        return usable;
    }

    /// <summary>The guard's rule: <paramref name="candidate"/> matches the record's own embedding, or any usable reference, at the record's
    /// τ. Null when nothing matches. The statement is tried first, so a phrase that passes on its own is said to.</summary>
    public static VoiceSpeakerMatch? Match(IReadOnlyList<float> candidate, VoiceConsentSpeaker speaker)
    {
        var owner = VoiceConsentRecord.DecodeEmbedding(speaker.Embedding) ?? throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        var statement = SpeakerAudio.Cosine(owner, candidate);
        if (statement >= speaker.Threshold) return new(statement);
        VoiceSpeakerMatch? best = null;
        foreach (var (contentKey, embedding) in Usable(speaker))
        {
            var score = SpeakerAudio.Cosine(embedding, candidate);
            if (score >= speaker.Threshold && score > (best?.Score ?? -1)) best = new(score, contentKey);
        }
        return best;
    }

    /// <summary>The speaker block after learning <paramref name="embedding"/> from the project <paramref name="contentKey"/>, or a
    /// <see cref="VoiceReferenceRefusedException"/>:
    /// it must pass against the record's own embedding at τ (a reference is never checked against another reference);
    /// references from another speaker model are dropped (a model change drops them all);
    /// one per project, the better-scoring of the old and new is kept;
    /// over the bound, the most redundant reference goes: the one closest to another (diversity), then the lower score, then the older.</summary>
    public static VoiceConsentSpeaker Learning(IReadOnlyList<float> embedding, string contentKey, string model, DateTimeOffset at, VoiceConsentSpeaker speaker)
    {
        if (model != speaker.Model) throw new VoiceReferenceRefusedException(VoiceReferenceRefusal.OtherModel);
        if (!ContentKeyValid(contentKey)) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        if (VoiceConsentRecord.DecodeEmbedding(speaker.Embedding) is not { } owner || embedding.Count != owner.Length)
            throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        var normalized = SpeakerAudio.Normalized(embedding);
        var score = SpeakerAudio.Cosine(owner, normalized);
        if (score < speaker.Threshold) throw new VoiceReferenceRefusedException(VoiceReferenceRefusal.NotTheOwner);
        var kept = (speaker.References ?? []).Where(reference => reference.Model == speaker.Model).ToList();
        if (kept.FirstOrDefault(reference => reference.ContentKey == contentKey) is { } existing)
        {
            if (!(score > existing.StatementScore)) throw new VoiceReferenceRefusedException(VoiceReferenceRefusal.NotBetter);
            kept.RemoveAll(reference => reference.ContentKey == contentKey);
        }
        kept.Add(new(VoiceConsentRecord.EncodeEmbedding(normalized), contentKey, VoiceConsentRecord.Timestamp(at), score, model));
        while (kept.Count > Bound) kept.RemoveAt(MostRedundant(kept));
        return speaker.ReplacingReferences(kept);
    }

    /// <summary>The reference closest to any other (ties: the lower statement score, then the oldest).</summary>
    internal static int MostRedundant(IReadOnlyList<VoiceConsentReference> references)
    {
        var vectors = references.Select(reference => VoiceConsentRecord.DecodeEmbedding(reference.Embedding) ?? []).ToArray();
        var worst = 0;
        (double Closeness, double Score, string Added) worstKey = (double.NegativeInfinity, double.PositiveInfinity, "");
        for (var index = 0; index < vectors.Length; index++)
        {
            var closest = double.NegativeInfinity;
            for (var other = 0; other < vectors.Length; other++)
                if (other != index) closest = Math.Max(closest, SpeakerAudio.Cosine(vectors[index], vectors[other]));
            var key = (Closeness: closest, Score: references[index].StatementScore, Added: references[index].AddedAt);
            var worse = key.Closeness != worstKey.Closeness ? key.Closeness > worstKey.Closeness
                : key.Score != worstKey.Score ? key.Score < worstKey.Score : string.CompareOrdinal(key.Added, worstKey.Added) < 0;
            if (worse) { worst = index; worstKey = key; }
        }
        return worst;
    }

    /// <summary>The number of the owner's videos the guard has learned from (usable references only).</summary>
    public static int LearnedCount(VoiceConsentSpeaker speaker) => Usable(speaker).Count;

    private static VoiceConsentException Invalid() => new(VoiceConsentError.InvalidRecord);
}
