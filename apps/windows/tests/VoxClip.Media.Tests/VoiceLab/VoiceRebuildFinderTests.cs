using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>Rebuild from my videos, the finder and the creation (voice-lab.md §6.12, ADR-R44; Mac <c>VoiceRebuildTests</c> and
/// <c>VoiceRebuildFlowTests</c>): each video's cleanest §6.5.1 spans are scored one hop by their lowest part against the voice's own
/// embedding, the voice's own <c>reference.wav</c> is sent first, and the attested creation then makes a voice whose embedding is the old
/// one's, with the old voice's learned references carried over one hop. A scripted embedder and a stub ElevenLabs; nothing is sent.</summary>
public sealed partial class VoiceEnrollmentPlanTests
{
    /// <summary>Words every 0.5 s in three runs (0–20 s, 23–45 s, 48–60 s), each word -20 dBFS over a -70 dBFS room.</summary>
    private static (Project Project, VoiceTrainingTake Take) Video(string key, string? language = "en", bool transcribed = true, double room = -70)
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/interview-take.voxclip"));
        List<TimedWord> words = [];
        for (var at = 0.0; at < 60; at += 0.5)
            if (at is not (>= 20 and < 23) and not (>= 45 and < 48))
                words.Add(new("w" + words.Count, "word", WordKind.Word, at, at + 0.4, null, null, 1, null, TimingSource.Native));
        var frames = Enumerable.Range(0, 6000).Select(frame =>
        {
            var seconds = frame / 100.0;
            return words.Any(word => seconds >= word.Start && seconds < word.End) ? -20.0 : room;
        }).ToArray();
        project = project with
        {
            Transcript = transcribed ? project.Transcript! with { Words = words, Language = language } : null,
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 60, Audio = new(48000, 1), ContentKey = key } }
        };
        return (project, new VoiceTrainingTake(48000, 48000L * 60, frames, 60_000));
    }

    /// <summary>A cut span as a project sample whose sign says whose voice it is (the scripted embedder reads the first sample).</summary>
    private static IReadOnlyList<VoiceTrainingSample> Cut(IReadOnlyList<VoiceTrainingSpan> spans, Func<VoiceTrainingSpan, bool> owner) => spans.Select(span =>
    {
        var count = (int)((span.EndMs - span.StartMs) * 48);
        var samples = Enumerable.Range(0, count).Select(index => (float)((owner(span) ? 0.1 : -0.1) * (1 + 0.5 * Math.Sin(index * 0.01)))).ToArray();
        return new VoiceTrainingSample(VoiceTrainingAudio.Wav(samples, 48000), count / 48000.0, "project", span.SnrDb);
    }).ToArray();

    private static VoiceSpeakerProbe Probe() => new("fixture-calibrated", 0.8, "en",
        (pcm, _) => Task.FromResult(pcm[0] > 0 ? new float[] { 1, 0 } : [0, 1]),
        (pcm, _) => { float[] whole = pcm[0] > 0 ? [1, 0] : [0, 1]; return Task.FromResult((whole, new[] { whole })); });

    private static async Task<VoiceConsentRecord> CreateOld(Fixture fixture)
    {
        var plan = await PrepareProject(fixture);
        return await fixture.Service.ExecuteAsync(plan, true, true, "test", Token);
    }

    [Fact]
    public async Task TheFinderSendsTheVoicesOwnClipFirstThenOnlyItsOwnersCleanSpeech()
    {
        using var fixture = new Fixture();
        var old = await CreateOld(fixture);
        var (a, take) = Video("video-a");
        var (labelled, _) = Video("video-b");
        var (other, _) = Video("video-c", language: "de");
        var (untranscribed, _) = Video("video-d", transcribed: false);
        var cuts = 0;
        // video-a's 23–45 s run is someone else's voice.
        var finder = new VoiceRebuildFinder(fixture.Store, Probe(), (_, _, _) => Task.FromResult(take),
            (_, _, spans, _) => { cuts++; return Task.FromResult(Cut(spans, span => span.StartMs is < 21_000 or > 46_000)); }, media => media == "/b.mp4");
        List<(int, int)> progress = [];
        var found = await finder.FindAsync(old.RecordId, [new(a, "/a.mp4"), new(labelled, "/b.mp4"), new(other, "/c.mp4"), new(untranscribed, "/d.mp4")],
            progress: (index, count) => { progress.Add((index, count)); return Task.CompletedTask; }, ct: Token);
        Assert.Equal([(1, 4), (2, 4), (3, 4), (4, 4)], progress);
        Assert.Equal((1, 3), (found.VideosChecked, found.VideosSkipped));
        // The voice's own reference.wav is the first file, so the new record's embedding is the old one's.
        Assert.Equal(fixture.Store.ReferenceAudio(old.RecordId), found.Samples[0].Wav);
        Assert.Equal(15000, found.Plan.KeptMs);
        Assert.NotEmpty(found.Plan.Pieces);
        Assert.All(found.Plan.Pieces, piece => Assert.True(piece.StartMs is < 21_000 or > 46_000, $"{piece.StartMs}"));
        Assert.True(found.Plan.Rejected.GetValueOrDefault(VoiceRebuild.Rejection.NotTheOwner) > 0);
        Assert.Equal(found.Plan.FileCount, found.Samples.Count);
        Assert.Equal("1 video and your consent clip", VoiceRebuild.Summary(found.Plan)[(VoiceRebuild.Summary(found.Plan).IndexOf("from ", StringComparison.Ordinal) + 5)..]);
        Assert.True(cuts > 0);
    }

    [Fact]
    public async Task TooLittleOwnerSpeechOrNoSpeakerCheckFindsNothing()
    {
        using var fixture = new Fixture();
        var old = await CreateOld(fixture);
        var (a, take) = Video("video-a");
        var nobody = new VoiceRebuildFinder(fixture.Store, Probe(), (_, _, _) => Task.FromResult(take), (_, _, spans, _) => Task.FromResult(Cut(spans, _ => false)), _ => false);
        var notEnough = await Assert.ThrowsAsync<VoiceRebuildFailedException>(() => nobody.FindAsync(old.RecordId, [new(a, "/a.mp4")], ct: Token));
        Assert.Equal(VoiceRebuildFailureKind.NotEnough, notEnough.Kind);
        Assert.Equal(15_000, notEnough.Milliseconds);
        // The closed parity gate: no probe, nothing is read.
        var reads = 0;
        var gated = new VoiceRebuildFinder(fixture.Store, null, (_, _, _) => { reads++; return Task.FromResult(take); }, (_, _, spans, _) => Task.FromResult(Cut(spans, _ => true)), _ => false);
        Assert.Equal(VoiceRebuildFailureKind.Unavailable, (await Assert.ThrowsAsync<VoiceRebuildFailedException>(() => gated.FindAsync(old.RecordId, [new(a, "/a.mp4")], ct: Token))).Kind);
        Assert.Equal(0, reads);
    }

    /// <summary>A matching voice for each video (§6.13, ADR-R45; Mac <c>VoicePerVideoMeasureTests</c>): a video recorded in a noisy room
    /// has no 20 dB speech, so the rebuild finds nothing; the per-video rules take its owner pieces from 8 dB, still one hop, need 30 s of
    /// the video's own speech beside the consent clip, and the creation then asks ElevenLabs to remove the background noise.</summary>
    [Fact]
    public async Task ANoisyVideosOwnSpeechMakesItsVoiceAtTheLowerFloorWithNoiseRemoval()
    {
        using var fixture = new Fixture();
        var old = await CreateOld(fixture);
        // Words at -20 dBFS over a -35 dBFS room: about 15 dB, under §6.5.1's floor and over the per-video one.
        var (car, take) = Video("video-car", room: -35);
        var finder = new VoiceRebuildFinder(fixture.Store, Probe(), (_, _, _) => Task.FromResult(take),
            (_, _, spans, _) => Task.FromResult(Cut(spans, span => span.StartMs is < 21_000 or > 46_000)), _ => false);
        var rebuild = await Assert.ThrowsAsync<VoiceRebuildFailedException>(() => finder.FindAsync(old.RecordId, [new(car, "/car.mp4")], ct: Token));
        Assert.Equal(VoiceRebuildFailureKind.NotEnough, rebuild.Kind);
        Assert.True(rebuild.Noisy > 0);
        var found = await finder.FindAsync(old.RecordId, [new(car, "/car.mp4")], VoiceRebuildFinder.Rules.PerVideo, ct: Token);
        Assert.Equal(15_000, found.Plan.KeptMs);
        Assert.All(found.Plan.Pieces, piece => Assert.InRange(piece.SnrDb, VoicePerVideo.MinimumSnrDb, VoiceRebuild.MinimumSnrDb - 1e-9));
        // Identity is still one hop: the 23–45 s run is someone else's and never makes it in.
        Assert.All(found.Plan.Pieces, piece => Assert.True(piece.StartMs is < 21_000 or > 46_000, $"{piece.StartMs}"));
        Assert.True(found.Plan.Rejected.GetValueOrDefault(VoiceRebuild.Rejection.NotTheOwner) > 0);
        Assert.True(VoicePerVideo.VideoMs(found.Plan) >= VoicePerVideo.MinimumVideoMs);
        Assert.True(VoicePerVideo.RemovesBackgroundNoise(found.Plan));
        // Too little of the video's own speech: the kept clip doesn't count toward the 30 s.
        var shortFinder = new VoiceRebuildFinder(fixture.Store, Probe(), (_, _, _) => Task.FromResult(take),
            (_, _, spans, _) => Task.FromResult(Cut(spans, span => span.StartMs < 21_000)), _ => false);
        var little = await Assert.ThrowsAsync<VoiceRebuildFailedException>(() =>
            shortFinder.FindAsync(old.RecordId, [new(car, "/car.mp4")], VoiceRebuildFinder.Rules.PerVideo, ct: Token));
        Assert.Equal(VoiceRebuildFailureKind.NotEnough, little.Kind);
        Assert.InRange(little.Milliseconds, 1, VoicePerVideo.MinimumVideoMs - 1);
        fixture.Remote.Events.Clear();
        var plan = await fixture.Service.PrepareProjectPlanAsync(Guid.NewGuid().ToString("D"), "en", new(true, true, true, fixture.Clock.Now),
            VoicePerVideo.DisplayName("Example", VoicePerVideo.Title("/car.mp4")), found.Samples, true,
            removeBackgroundNoise: VoicePerVideo.RemovesBackgroundNoise(found.Plan), ct: Token);
        Assert.Empty(fixture.Remote.Events);
        var made = await fixture.Service.ExecuteAsync(plan, true, true, "test", Token);
        Assert.Equal(old.Speaker.Embedding, made.Speaker.Embedding);
        Assert.StartsWith("Example · car", made.VoiceName, StringComparison.Ordinal);
        Assert.Matches("name=\"?remove_background_noise\"?\\s+true", fixture.Remote.CreationBody!);
    }

    [Fact]
    public async Task ARebuildGoesThroughTheAttestedCreationAndKeepsTheVoicesEmbeddingAndReferences()
    {
        using var fixture = new Fixture();
        var old = await CreateOld(fixture);
        fixture.Store.LearnReference(old.RecordId, [1, 0], "video-a", "fixture-calibrated");
        var (a, take) = Video("video-a");
        var finder = new VoiceRebuildFinder(fixture.Store, Probe(), (_, _, _) => Task.FromResult(take), (_, _, spans, _) => Task.FromResult(Cut(spans, _ => true)), _ => false);
        var found = await finder.FindAsync(old.RecordId, [new(a, "/a.mp4")], ct: Token);
        fixture.Remote.Events.Clear();
        var id = Guid.NewGuid().ToString("D");
        var plan = await fixture.Service.PrepareProjectPlanAsync(id, "en", new(true, true, true, fixture.Clock.Now), "Example", found.Samples, true, ct: Token);
        Assert.Empty(fixture.Remote.Events);
        Assert.Equal(found.Plan.TotalMs, plan.TrainingMilliseconds);
        var rebuilt = await fixture.Service.ExecuteAsync(plan, true, true, "test", Token);
        Assert.Equal(["create"], fixture.Remote.Events.Where(value => value == "create"));
        Assert.Equal(old.Speaker.Embedding, rebuilt.Speaker.Embedding);
        Assert.Equal(old.ReferenceAudioSha256, rebuilt.ReferenceAudioSha256);
        Assert.Equal(fixture.Store.ReferenceAudio(old.RecordId), fixture.Store.ReferenceAudio(rebuilt.RecordId));
        Assert.Contains("Reference sha256:" + old.ReferenceAudioSha256, fixture.Remote.CreationBody!);
        Assert.Matches("name=\"?remove_background_noise\"?\\s+false", fixture.Remote.CreationBody!);
        Assert.Equal(VoiceConsentMethod.ProjectAttestation, rebuilt.ConsentMethod);
        Assert.Equal(old.CreatorIdentity, rebuilt.CreatorIdentity);
        Assert.Equal(1, fixture.Store.CarryReferences(old.RecordId, rebuilt.RecordId));
        Assert.Equal("video-a", Assert.Single(fixture.Store.Load(rebuilt.RecordId).Speaker.References!).ContentKey);
        // The old voice is untouched until the user removes it.
        Assert.Equal(VoiceConsentStatus.Active, fixture.Store.Load(old.RecordId).Status);
    }
}
