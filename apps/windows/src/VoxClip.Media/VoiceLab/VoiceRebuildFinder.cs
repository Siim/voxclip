using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Media.VoiceLab;

/// <summary>Why the rebuild finder found no set (Mac <c>VoiceRebuildFinder.Failure</c>).</summary>
public enum VoiceRebuildFailureKind
{
    /// <summary>The voice, its speaker model or its language isn't available on this PC.</summary>
    Unavailable,
    /// <summary>Less verified speech than a voice needs; <see cref="VoiceRebuildFailedException.Noisy"/> stretches were under the floor.</summary>
    NotEnough
}

/// <summary>The rebuild finder found no set: why, how much speech it found and how many stretches were too noisy.</summary>
public sealed class VoiceRebuildFailedException(VoiceRebuildFailureKind kind, long milliseconds = 0, int noisy = 0) : Exception(kind.ToString())
{
    /// <summary>Why nothing was found.</summary>
    public VoiceRebuildFailureKind Kind { get; } = kind;
    /// <summary>The verified speech found (a per-video set: the video's own, the consent clip not counted).</summary>
    public long Milliseconds { get; } = milliseconds;
    /// <summary>Stretches under the clean-speech floor.</summary>
    public int Noisy { get; } = noisy;
}

/// <summary>"Rebuild from my videos" (voice-lab.md §6.12, ADR-R44; Mac <c>VoiceRebuildFinder</c>), on this PC and free: reads each of the
/// owner's projects, scores its cleanest transcribed stretches against the voice's own consent embedding (one hop, part by part), picks the
/// set with <see cref="VoiceRebuild.Pick"/> and cuts it into the training WAVs the attested creation route sends, the voice's own
/// <c>reference.wav</c> first. Nothing is sent here. Inert while <see cref="VoiceSpeakerCheck.WindowsNativeParityVerified"/> is false: there
/// is no probe, so every search is <see cref="VoiceRebuildFailureKind.Unavailable"/>.</summary>
public sealed class VoiceRebuildFinder
{
    /// <summary>A project and its readable source media.</summary>
    public sealed record Source(Project Project, string Media);

    /// <summary>What was found: the plan, the WAVs in send order (the kept reference sample first when there is one, then the plan's
    /// pieces), and how many videos were read or skipped (labelled AI modified, untranscribed, in another language or unreadable).</summary>
    public sealed record Found(VoiceRebuild.Plan Plan, IReadOnlyList<VoiceTrainingSample> Samples, int VideosChecked, int VideosSkipped);

    /// <summary>What a set must meet. <see cref="Rebuild"/> is §6.12's: the clean-speech floor, six candidates per video, 30 s in all with
    /// the kept clip. <see cref="PerVideo"/> is §6.13's (ADR-R45): one video, a lower floor because creation asks ElevenLabs to remove the
    /// background noise, more candidates from that one video, and at least <see cref="MinimumOwnMs"/> of the video's own speech beside the
    /// kept clip. Identity is one hop at τ whatever the rules.</summary>
    public sealed record Rules(double MinimumSnrDb, int CandidatesPerVideo, long MinimumOwnMs)
    {
        /// <summary>Rebuild from my videos.</summary>
        public static Rules Rebuild { get; } = new(VoiceRebuild.MinimumSnrDb, VoiceRebuild.CandidatesPerVideo, 0);
        /// <summary>A matching voice for one video.</summary>
        public static Rules PerVideo { get; } = new(VoicePerVideo.MinimumSnrDb, VoiceRebuild.MaximumFiles, VoicePerVideo.MinimumVideoMs);
    }

    private readonly VoiceConsentStore store;
    private readonly VoiceSpeakerProbe? probe;
    private readonly Func<string, int, CancellationToken, Task<VoiceTrainingTake>> analyze;
    private readonly Func<string, int, IReadOnlyList<VoiceTrainingSpan>, CancellationToken, Task<IReadOnlyList<VoiceTrainingSample>>> cut;
    private readonly Func<string, bool> labelled;

    /// <summary>A finder with the production decoder and label check.</summary>
    public VoiceRebuildFinder(VoiceConsentStore store, VoiceSpeakerProbe? probe)
        : this(store, probe, VoiceTrainingAudio.AnalyzeAsync, VoiceTrainingAudio.ProjectSpansAsync, VoiceLabDisclosureWriter.IsLabelled) { }
    internal VoiceRebuildFinder(VoiceConsentStore store, VoiceSpeakerProbe? probe, Func<string, int, CancellationToken, Task<VoiceTrainingTake>> analyze,
        Func<string, int, IReadOnlyList<VoiceTrainingSpan>, CancellationToken, Task<IReadOnlyList<VoiceTrainingSample>>> cut, Func<string, bool> labelled)
    { this.store = store; this.probe = probe; this.analyze = analyze; this.cut = cut; this.labelled = labelled; }

    /// <summary>Finds the rebuild set for the voice <paramref name="recordId"/> across <paramref name="sources"/>.
    /// <paramref name="progress"/>(i, n) reports the video being read. Throws <see cref="VoiceRebuildFailedException"/>.</summary>
    public async Task<Found> FindAsync(string recordId, IReadOnlyList<Source> sources, Rules? rules = null, Func<int, int, Task>? progress = null,
        CancellationToken ct = default)
    {
        rules ??= Rules.Rebuild;
        VoiceConsentRecord record;
        float[] owner;
        try
        {
            if (probe is null) throw Unavailable();
            record = store.Load(recordId);
            if (record.Status != VoiceConsentStatus.Active || !probe.Fits(record) || VoiceConsentRecord.DecodeEmbedding(record.Speaker.Embedding) is not { } decoded)
                throw Unavailable();
            probe.ValidateAvailability();
            owner = decoded;
        }
        catch (Exception error) when (error is VoiceConsentException or VoiceLabException or IOException or UnauthorizedAccessException) { throw Unavailable(); }
        // The attested route's reference sample is the consent embedding itself: sending it first keeps the statement the same, so the new
        // voice's embedding equals the old one's and the learned references still apply.
        var kept = record.ProjectConsent is null ? null : KeptSample(recordId);
        List<VoiceRebuild.Candidate> candidates = [];
        var places = new Dictionary<string, (string Media, int Rate)>(StringComparer.Ordinal);
        int checkedVideos = 0, skipped = 0, noisy = 0;
        for (var index = 0; index < sources.Count; index++)
        {
            ct.ThrowIfCancellationRequested();
            if (progress is not null) await progress(index + 1, sources.Count).ConfigureAwait(false);
            var source = sources[index];
            var key = source.Project.Media.Source.ContentKey;
            if (key.Length == 0 || places.ContainsKey(key) || source.Project.Transcript is null ||
                source.Project.Transcript.Language is { } language && language != record.Language || labelled(source.Media)) { skipped++; continue; }
            (int Rate, IReadOnlyList<VoiceRebuild.Candidate> Candidates, int Noisy) found;
            try { found = await VideoCandidatesAsync(source, owner, rules, ct).ConfigureAwait(false); }
            catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException) { skipped++; continue; }
            checkedVideos++;
            places[key] = (source.Media, found.Rate);
            candidates.AddRange(found.Candidates);
            noisy += found.Noisy;
        }
        long? keptMs = kept is null ? null : (long)Math.Floor(kept.Seconds * 1000 + 0.5);
        var plan = VoiceRebuild.Pick(candidates, record.Speaker.Threshold, keptMs, rules.MinimumSnrDb);
        var own = plan.TotalMs - (keptMs ?? 0);
        if (!plan.Enough || own < rules.MinimumOwnMs)
            throw new VoiceRebuildFailedException(VoiceRebuildFailureKind.NotEnough, rules.MinimumOwnMs > 0 ? own : plan.TotalMs, noisy);
        List<VoiceTrainingSample> samples = kept is null ? [] : [kept];
        foreach (var piece in plan.Pieces)
        {
            ct.ThrowIfCancellationRequested();
            if (!places.TryGetValue(piece.Video, out var place)) throw Unavailable();
            samples.AddRange(await cut(place.Media, place.Rate, [new(piece.StartMs, piece.EndMs, piece.SnrDb)], ct).ConfigureAwait(false));
        }
        if (samples.Any(sample => sample.Wav.Length > VoiceRebuild.MaximumBytes)) throw Unavailable();
        return new(plan, samples, checkedVideos, skipped);
    }

    /// <summary>The cleanest §6.5.1 spans of one video at the rules' floor, each scored as its lowest part against the owner. Below the
    /// §6.5.1 floor the spans also include the pieces it rejected only as <c>lowSnr</c> (already split to 5–30 s within one speaker's run,
    /// ended by any event such as music), never a short or unsplittable one.</summary>
    internal async Task<(int Rate, IReadOnlyList<VoiceRebuild.Candidate> Candidates, int Noisy)> VideoCandidatesAsync(Source source, float[] owner, Rules rules,
        CancellationToken ct)
    {
        var rate = source.Project.Media.Source.Audio?.SampleRate ?? throw Unavailable();
        var take = await analyze(source.Media, rate, ct).ConfigureAwait(false);
        var inputs = VoiceTrainingSpans.Inputs(source.Project);
        var selection = VoiceTrainingSpans.Select(inputs.Items, inputs.Excluded, take.FrameDb, take.Duration);
        var spans = selection.Qualifying.Concat(RelaxedSpans(selection, rules.MinimumSnrDb))
            .OrderByDescending(span => span.SnrDb).ThenBy(span => span.StartMs).Take(rules.CandidatesPerVideo).ToArray();
        List<VoiceRebuild.Candidate> result = [];
        foreach (var span in spans)
        {
            ct.ThrowIfCancellationRequested();
            (float[] Whole, float[][] Parts) embedded;
            try
            {
                var sample = (await cut(source.Media, rate, [span], ct).ConfigureAwait(false))[0];
                embedded = await probe!.PartEmbeddings(VoiceConsentAudio.Pcm16k(sample.Wav), ct).ConfigureAwait(false);
            }
            catch (Exception error) when (error is VoiceConsentException or VoiceLabException) { continue; }
            var score = embedded.Parts.Aggregate(SpeakerAudio.Cosine(owner, embedded.Whole), (lowest, part) => Math.Min(lowest, SpeakerAudio.Cosine(owner, part)));
            result.Add(new(source.Project.Media.Source.ContentKey, span.StartMs, span.EndMs, span.SnrDb, score, embedded.Whole));
        }
        var noisy = selection.Rejected.Count(piece => piece.Reason == VoiceTrainingRejectionReason.LowSnr && !(piece.SnrDb >= rules.MinimumSnrDb));
        return (rate, result, noisy);
    }

    /// <summary>The pieces §6.5.1 rejected only for their SNR that reach <paramref name="minimumSnrDb"/>, as spans; none at or above its own
    /// floor.</summary>
    internal static IReadOnlyList<VoiceTrainingSpan> RelaxedSpans(VoiceTrainingSpanSelection selection, double minimumSnrDb) =>
        minimumSnrDb >= VoiceRebuild.MinimumSnrDb ? [] : selection.Rejected
            .Where(piece => piece.Reason == VoiceTrainingRejectionReason.LowSnr && piece.SnrDb is { } snr && double.IsFinite(snr) && snr >= minimumSnrDb &&
                piece.EndMs - piece.StartMs is >= VoiceRebuild.MinimumPieceMs and <= VoiceRebuild.MaximumPieceMs)
            .Select(piece => new VoiceTrainingSpan(piece.StartMs, piece.EndMs, piece.SnrDb!.Value)).ToArray();

    /// <summary>The voice's stored reference sample as a training sample.</summary>
    private VoiceTrainingSample? KeptSample(string recordId)
    {
        try
        {
            var wav = store.ReferenceAudio(recordId);
            if (wav.Length > VoiceRebuild.MaximumBytes) return null;
            var format = VoiceConsentAudio.ValidateWav(wav);
            var seconds = format.Frames / (double)format.Rate;
            if (seconds is < 5 or > 30) return null;
            return new(wav, seconds, "project", VoiceTrainingAudio.SnrDb(VoiceConsentAudio.Pcm16k(wav), 16000));
        }
        catch (Exception error) when (error is VoiceConsentException or VoiceLabException or IOException or UnauthorizedAccessException) { return null; }
    }

    private static VoiceRebuildFailedException Unavailable() => new(VoiceRebuildFailureKind.Unavailable);
}
