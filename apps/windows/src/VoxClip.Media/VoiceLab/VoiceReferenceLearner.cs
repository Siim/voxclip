using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Media.VoiceLab;

/// <summary>The speaker check a free local Voice Lab step uses (Learn from my videos, the rebuild and per-video finders): its model,
/// calibrated τ and language, and the embedder. Made only from an available <see cref="VoiceSpeakerCheck"/>, so it is null while
/// <see cref="VoiceSpeakerCheck.WindowsNativeParityVerified"/> is false and every such step reports itself unavailable.</summary>
public sealed class VoiceSpeakerProbe
{
    /// <summary>The speaker model's id, as consent records store it.</summary>
    public string ModelId { get; }
    /// <summary>The calibrated τ for <see cref="Language"/>.</summary>
    public double Threshold { get; }
    /// <summary>The language the threshold is calibrated for.</summary>
    public string Language { get; }
    internal Func<float[], CancellationToken, Task<float[]>> Embedding { get; }
    internal Func<float[], CancellationToken, Task<(float[] Whole, float[][] Parts)>> PartEmbeddings { get; }
    internal Action ValidateAvailability { get; }
    internal VoiceSpeakerProbe(string modelId, double threshold, string language, Func<float[], CancellationToken, Task<float[]>> embedding,
        Func<float[], CancellationToken, Task<(float[] Whole, float[][] Parts)>> partEmbeddings, Action? validate = null)
    {
        ModelId = modelId; Threshold = threshold; Language = language; Embedding = embedding; PartEmbeddings = partEmbeddings;
        ValidateAvailability = validate ?? (() => { });
    }
    /// <summary>The probe of an available check; null otherwise (today always, behind the closed parity gate).</summary>
    public static VoiceSpeakerProbe? From(VoiceSpeakerCheck check) =>
        check.Available && check.ModelId is { } model && check.Threshold is { } threshold && check.Language is { } language
            ? new(model, threshold, language, check.EmbeddingAsync, check.PartEmbeddingsAsync, check.ValidateAvailability) : null;
    /// <summary>The record's own speaker block can be checked with this probe: same model, same τ, same language.</summary>
    internal bool Fits(VoiceConsentRecord record) => record.Language == Language && record.Speaker.Model == ModelId && record.Speaker.Threshold == Threshold;
}

/// <summary>What learning from one project did (Mac <c>VoiceReferenceLearner.Outcome</c>).</summary>
public enum VoiceReferenceLearnerOutcome
{
    /// <summary>This project's reference was added or replaced with a better one.</summary>
    Learned,
    /// <summary>Its speech passes, and the project's reference already scores at least as well.</summary>
    Kept,
    /// <summary>None of its speech passes against the voice's own consent embedding: nothing is stored.</summary>
    NotTheOwner,
    /// <summary>Too little transcribed speech, an untranscribed project, or media that can't be read.</summary>
    NoSpeech,
    /// <summary>The media is labelled AI modified: it never teaches the voice.</summary>
    Generated,
    /// <summary>The speaker check, the voice or its language isn't available here.</summary>
    Unavailable
}

/// <summary>One project's learning outcome, with the learned score.</summary>
public sealed record VoiceReferenceLearning(VoiceReferenceLearnerOutcome Outcome, double? Score = null);

/// <summary>"Learn from my videos" (voice-lab.md §6.9, ADR-R41; Mac <c>VoiceReferenceLearner</c>): a project's clean speech, verified one
/// hop against the voice's own consent embedding, becomes that project's reference. On this PC, free; nothing is sent anywhere. Inert while
/// <see cref="VoiceSpeakerCheck.WindowsNativeParityVerified"/> is false: there is no probe, so every project is <see cref="VoiceReferenceLearnerOutcome.Unavailable"/>.</summary>
public sealed class VoiceReferenceLearner
{
    /// <summary>Candidate stretches of speech per project.</summary>
    public const int Candidates = 6;
    /// <summary>The least speech a candidate holds, so the embedding has enough voiced windows.</summary>
    public const double MinimumSeconds = 6;

    private readonly VoiceConsentStore store;
    private readonly VoiceSpeakerProbe? probe;
    private readonly Func<string, long, int, VoiceLabGuardSpeech, CancellationToken, Task<float[]>> decode;
    private readonly Func<string, bool> labelled;
    private readonly TimeProvider clock;

    /// <summary>A learner with the production decoder and label check.</summary>
    public VoiceReferenceLearner(VoiceConsentStore store, VoiceSpeakerProbe? probe, TimeProvider? clock = null)
        : this(store, probe, (media, frames, rate, selection, ct) => VoiceLabSourceAudio.GuardSpeechAsync(media, frames, rate, selection, ct),
            VoiceLabDisclosureWriter.IsLabelled, clock) { }
    internal VoiceReferenceLearner(VoiceConsentStore store, VoiceSpeakerProbe? probe,
        Func<string, long, int, VoiceLabGuardSpeech, CancellationToken, Task<float[]>> decode, Func<string, bool> labelled, TimeProvider? clock = null)
    { this.store = store; this.probe = probe; this.decode = decode; this.labelled = labelled; this.clock = clock ?? TimeProvider.System; }

    /// <summary>Up to <paramref name="count"/> guard selections spread evenly through the transcript, each the words nearest one centre
    /// word, in that word's speaker's turns only, up to 10 s. Selections shorter than <see cref="MinimumSeconds"/> are skipped.</summary>
    public static IReadOnlyList<VoiceLabGuardSpeech> Selections(IReadOnlyList<TimedWord> words, int sampleRate, long totalFrames, int count = Candidates)
    {
        var spoken = words.Where(word => word.Kind == WordKind.Word && word.End > word.Start).ToArray();
        if (spoken.Length == 0 || count <= 0 || sampleRate <= 0) return [];
        var minimum = (long)(MinimumSeconds * sampleRate);
        List<VoiceLabGuardSpeech> chosen = [];
        for (var slot = 0; slot < count; slot++)
        {
            var index = Math.Min(spoken.Length - 1, (int)((slot + 0.5) * spoken.Length / count));
            var selection = VoiceLabGuardSpeech.Select(words, spoken[index].Start, spoken[index].End, sampleRate, totalFrames);
            if (selection.Frames >= minimum && !chosen.Contains(selection)) chosen.Add(selection);
        }
        return chosen;
    }

    /// <summary>Learns <paramref name="project"/>'s reference for the voice <paramref name="recordId"/> from its source <paramref name="media"/>.</summary>
    public async Task<VoiceReferenceLearning> LearnAsync(Project project, string media, string recordId, CancellationToken ct = default)
    {
        var source = project.Media.Source;
        if (project.Transcript?.Words is not { Count: > 0 } words || source.Audio is not { } audio || source.ContentKey.Length == 0)
            return new(VoiceReferenceLearnerOutcome.NoSpeech);
        if (labelled(media)) return new(VoiceReferenceLearnerOutcome.Generated);
        VoiceConsentRecord record;
        float[] owner;
        try
        {
            if (probe is null) return new(VoiceReferenceLearnerOutcome.Unavailable);
            record = store.Load(recordId);
            if (record.Status != VoiceConsentStatus.Active || project.Transcript.Language is { } language && language != record.Language || !probe.Fits(record) ||
                VoiceConsentRecord.DecodeEmbedding(record.Speaker.Embedding) is not { } decoded) return new(VoiceReferenceLearnerOutcome.Unavailable);
            probe.ValidateAvailability();
            owner = decoded;
        }
        catch (Exception error) when (error is VoiceConsentException or VoiceLabException or IOException or UnauthorizedAccessException)
        { return new(VoiceReferenceLearnerOutcome.Unavailable); }
        var frames = checked((long)Math.Floor(source.DurationSeconds * audio.SampleRate + 0.5));
        (double Score, float[] Embedding)? best = null;
        var embedded = false;
        foreach (var selection in Selections(words, audio.SampleRate, frames))
        {
            ct.ThrowIfCancellationRequested();
            double score;
            float[] embedding;
            try
            {
                var speech = await decode(media, frames, audio.SampleRate, selection, ct).ConfigureAwait(false);
                embedding = await probe.Embedding(speech.Take(160_000).ToArray(), ct).ConfigureAwait(false);
                score = SpeakerAudio.Cosine(owner, embedding);
            }
            catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException) { continue; }
            embedded = true;
            if (score >= record.Speaker.Threshold && score > (best?.Score ?? -1)) best = (score, embedding);
        }
        if (best is not { } found) return new(embedded ? VoiceReferenceLearnerOutcome.NotTheOwner : VoiceReferenceLearnerOutcome.NoSpeech);
        try
        {
            store.LearnReference(recordId, found.Embedding, source.ContentKey, probe.ModelId, clock.GetUtcNow());
            return new(VoiceReferenceLearnerOutcome.Learned, found.Score);
        }
        catch (VoiceReferenceRefusedException refused) when (refused.Reason == VoiceReferenceRefusal.NotBetter) { return new(VoiceReferenceLearnerOutcome.Kept); }
        catch (Exception error) when (error is VoiceReferenceRefusedException or VoiceConsentException or VoiceLabException or IOException or UnauthorizedAccessException)
        { return new(VoiceReferenceLearnerOutcome.Unavailable); }
    }
}
