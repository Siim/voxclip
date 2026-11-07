using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

/// <summary>"Did matching help" (voice-lab.md §6.13; Mac <c>VoicePerVideoMatch</c>): how close a take's voice is to the creator's own speech
/// right beside it, with the production speaker model, on this PC. The original speech is the use-time guard's (§6.9): the transcript words
/// nearest the patch, in the patch speaker's turns. Nothing is sent. With no speaker check (the closed parity gate) there is no score.</summary>
public static class VoicePerVideoMatch
{
    /// <summary>The cosine between the take's trimmed speech and that original speech, or null when there is no speaker check or either has
    /// too little speech to embed.</summary>
    public static async Task<double?> ScoreAsync(VoiceLabTakeAudio take, VoiceLabTakeInput input, VoiceSpeakerProbe? probe, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(take);
        ArgumentNullException.ThrowIfNull(input);
        if (probe is null) return null;
        float[] original;
        try { original = VoiceLabTakeRun.GuardSpeech(input); }
        catch (Exception error) when (error is VoiceConsentException or VoiceLabException or ArgumentException) { return null; }
        return await ScoreAsync(take.Trimmed, take.SampleRate, original, probe, ct).ConfigureAwait(false);
    }

    /// <summary>The cosine between a take's <paramref name="speech"/> at <paramref name="sampleRate"/> and the original speech beside it (16 kHz),
    /// or null when either has too little speech to embed (Mac <c>score(speech:sampleRate:original:check:)</c>). A take being made and a take
    /// already accepted are scored the same way.</summary>
    public static async Task<double?> ScoreAsync(float[] speech, int sampleRate, float[] original, VoiceSpeakerProbe? probe, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(speech);
        ArgumentNullException.ThrowIfNull(original);
        if (probe is null || sampleRate <= 0 || speech.Length == 0 || original.Length == 0) return null;
        try
        {
            var take = sampleRate == 16_000 ? speech : VoiceConsentAudio.Resample(speech, sampleRate, 16_000);
            var generated = await probe.Embedding(take, ct).ConfigureAwait(false);
            var beside = await probe.Embedding(original, ct).ConfigureAwait(false);
            return SpeakerAudio.Cosine(generated, beside);
        }
        catch (Exception error) when (error is VoiceConsentException or VoiceLabException or ArgumentException) { return null; }
    }
}

/// <summary>The anchor's baseline (voice-lab.md §6.13 item 9; Mac <c>VoiceAnchorBaseline</c>): its takes already accepted into the owner's
/// projects on this PC, each scored as <see cref="VoicePerVideoMatch"/> scores a new take, so the first take with a video's own voice has
/// something to compare with. Read only: a project, its source media and its paid audio are read, never written; a paid file is read through a
/// private, hash-checked snapshot. At most <c>maximum</c> takes, newest first, and one project open at a time. Nothing is sent.</summary>
public static class VoiceAnchorBaseline
{
    /// <summary>A project as read from its file, with its source media resolved on this PC.</summary>
    public sealed record Opened(Project Project, string Media);

    /// <summary>Each scored take's cosine, newest first within a project.</summary>
    public sealed record Result(IReadOnlyList<double> Scores)
    {
        /// <summary>The mean, or null with no score.</summary>
        public double? Mean => Scores.Count == 0 ? null : Scores.Sum() / Scores.Count;
    }

    private sealed record Pick(int Project, string Segment, DateTimeOffset CreatedAt);

    /// <summary>JavaScript's Math.round, as the Mac's <c>jsRound</c>: half up.</summary>
    private static long JsRound(double value) => (long)Math.Floor(value + 0.5);

    /// <summary>Scores the newest <paramref name="maximum"/> of the anchor's takes across <paramref name="projects"/>. A take whose paid file or
    /// source media is missing or unreadable is skipped silently, as is labelled (AI-modified) media. <paramref name="open"/> reads one project;
    /// it is called for one project at a time, first to list each project's takes, then again for the projects whose takes are kept.</summary>
    public static Task<Result> MeasureAsync(IReadOnlyList<string> projects, string anchorId, string paidRoot, VoiceSpeakerProbe? probe,
        Func<string, CancellationToken, Task<Opened?>> open, int maximum = VoicePerVideo.MaximumBaselineTakes, string? scratchRoot = null,
        CancellationToken ct = default)
        => MeasureAsync(projects, anchorId, paidRoot, probe, open, VoiceLabSourceAudio.GuardSpeechAsync, maximum, scratchRoot, ct);

    /// <summary>As the public overload, reading the source's guard speech through <paramref name="guardSpeech"/> (tests read a synthetic source
    /// without FFmpeg).</summary>
    internal static async Task<Result> MeasureAsync(IReadOnlyList<string> projects, string anchorId, string paidRoot, VoiceSpeakerProbe? probe,
        Func<string, CancellationToken, Task<Opened?>> open, Func<string, long, int, VoiceLabGuardSpeech, CancellationToken, Task<float[]>> guardSpeech,
        int maximum = VoicePerVideo.MaximumBaselineTakes, string? scratchRoot = null, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(projects);
        ArgumentNullException.ThrowIfNull(open);
        if (probe is null || maximum <= 0) return new([]);
        var picks = new List<Pick>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < projects.Count; index++)
        {
            if (ct.IsCancellationRequested) return new([]);
            if (await open(projects[index], ct).ConfigureAwait(false) is not { } opened || !File.Exists(opened.Media) ||
                VoiceLabDisclosureWriter.IsLabelled(opened.Media)) continue;
            foreach (var (segment, asset) in VoicePerVideo.AnchorTakes(opened.Project, anchorId))
                if (File.Exists(Path.Combine(paidRoot, asset.File)) && seen.Add(opened.Project.Id + "/" + segment.Id))
                    picks.Add(new(index, segment.Id, segment.Provenance.CreatedAt));
            picks = picks.OrderByDescending(pick => pick.CreatedAt).ThenBy(pick => pick.Project).ThenBy(pick => pick.Segment, StringComparer.Ordinal)
                .Take(maximum).ToList();
        }
        var scores = new List<double>();
        foreach (var index in picks.Select(pick => pick.Project).Distinct().Order())
        {
            if (ct.IsCancellationRequested) break;
            var kept = picks.Where(pick => pick.Project == index).Select(pick => pick.Segment).ToHashSet(StringComparer.Ordinal);
            if (await open(projects[index], ct).ConfigureAwait(false) is not { } opened) continue;
            foreach (var (segment, asset) in VoicePerVideo.AnchorTakes(opened.Project, anchorId))
            {
                if (ct.IsCancellationRequested) break;
                if (!kept.Contains(segment.Id)) continue;
                if (await ScoreAsync(segment, asset, opened, paidRoot, scratchRoot ?? Path.GetTempPath(), probe, guardSpeech, ct).ConfigureAwait(false) is { } score)
                    scores.Add(score);
            }
        }
        return new(scores);
    }

    /// <summary>One accepted take against the guard's speech beside its window in the source media.</summary>
    internal static async Task<double?> ScoreAsync(VoiceLabSegment segment, VoiceLabAsset asset, Opened opened, string paidRoot, string scratchRoot,
        VoiceSpeakerProbe probe, Func<string, long, int, VoiceLabGuardSpeech, CancellationToken, Task<float[]>> guardSpeech, CancellationToken ct)
    {
        var project = opened.Project;
        if (project.Media.Source.Audio?.SampleRate is not ({ } rate and > 0)) return null;
        (float[] Samples, int SampleRate) take;
        try { take = await TakeSpeechAsync(segment, asset, project.Id, paidRoot, scratchRoot, ct).ConfigureAwait(false); }
        catch (Exception error) when (error is VoiceLabAssetException or VoiceLabException or IOException or UnauthorizedAccessException) { return null; }
        double sampleRate = rate;
        var frames = JsRound(project.Media.Source.DurationSeconds * sampleRate);
        var startSample = JsRound(segment.Replace.Start * sampleRate);
        var endSample = JsRound(segment.Replace.End * sampleRate);
        var selection = VoiceLabGuardSpeech.ForTake(project.Transcript?.Words ?? [], segment.Replace.Start, segment.Replace.End, startSample, endSample, rate, frames);
        float[] original;
        try { original = await guardSpeech(opened.Media, frames, rate, selection, ct).ConfigureAwait(false); }
        catch (Exception error) when (error is not OperationCanceledException) { return null; }
        return await VoicePerVideoMatch.ScoreAsync(take.Samples, take.SampleRate, original, probe, ct).ConfigureAwait(false);
    }

    /// <summary>The take's speech as Rewrite measured it: the paid file (hash-checked, through a private snapshot that is deleted after) mixed
    /// to mono, through the segment's tone match from the first frame, cut to the segment's trim.</summary>
    internal static async Task<(float[] Samples, int SampleRate)> TakeSpeechAsync(VoiceLabSegment segment, VoiceLabAsset asset, string projectId,
        string paidRoot, string scratchRoot, CancellationToken ct)
    {
        await using var prepared = await VoiceLabAssets.PreparePaidAsync(asset, projectId, paidRoot, scratchRoot, ct).ConfigureAwait(false);
        var wave = VoiceLabWavePcm.Parse(await File.ReadAllBytesAsync(prepared.Path, ct).ConfigureAwait(false));
        var mono = new float[wave.Frames];
        for (var frame = 0; frame < wave.Frames; frame++)
        {
            double sum = 0;
            for (var channel = 0; channel < wave.Channels; channel++) sum += wave.Sample(frame, channel);
            mono[frame] = (float)(sum / wave.Channels);
        }
        var sections = VoiceLabTilt.Sections(segment.Audio.TiltDbPerOctave ?? 0, wave.Rate);
        if (sections.Count > 0) mono = VoiceLabTilt.Apply(mono, sections);
        double rate = wave.Rate;
        var lower = Math.Max(0, (int)JsRound(segment.Audio.TrimStart * rate));
        var upper = Math.Min(mono.Length, (int)JsRound(segment.Audio.TrimEnd * rate));
        if (upper <= lower) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        return (mono[lower..upper], wave.Rate);
    }
}
