using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

public sealed class VoiceConsentMediaTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private sealed class Keys : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => throw new InvalidOperationException("No network in consent tests.");
    }
    private sealed class Clock : TimeProvider
    {
        internal long Ticks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Ticks;
        public override DateTimeOffset GetUtcNow() => DateTimeOffset.UnixEpoch;
    }
    private sealed class Storage : IDisposable
    {
        internal readonly string Root = Path.Combine(Path.GetTempPath(), "voxclip-voice-media-" + Guid.NewGuid().ToString("N"));
        internal DataLocations Locations => new(Root, Path.Combine(Root, "settings.json"), Path.Combine(Root, "Models"), Path.Combine(Root, "Cache"),
            Path.Combine(Root, "Autosave"), Path.Combine(Root, "Secrets"), Path.Combine(Root, "Logs"));
        internal Storage() => Directory.CreateDirectory(Root);
        public void Dispose() => Directory.Delete(Root, true);
    }
    private static float[] Tone(int rate, int seconds) => Enumerable.Range(0, rate * seconds)
        .Select(index => (float)(0.1 * Math.Sin(2 * Math.PI * 440 * index / rate))).ToArray();
    [Fact]
    public async Task ReviewProbe_KnownUndispatchedFailureKeepsVerifiedStatementForRetry()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var wav = VoiceTrainingAudio.Wav(Tone(48000, 6));
        var record = System.Text.Json.JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"), VoiceConsentJson.Default.VoiceConsentRecord)!;
        record = record with { RecordId = Guid.NewGuid().ToString("D"), VoiceId = "pending",
            Statement = record.Statement with { AudioSha256 = VoiceConsentStore.Hash(wav) } };
        store.SaveStatement(wav, record.RecordId);
        using var claim = store.ClaimCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, DateTimeOffset.UtcNow);
        var reconciler = new VoiceOperationReconciler(store, _ => throw new InvalidOperationException("No transport allowed"));
        Assert.True(await VoiceEnrollment.ResolveCreationFailureAsync(claim, reconciler, DateTimeOffset.UtcNow));
        Assert.Equal(wav, store.Statement(record.RecordId));
        Assert.Empty(store.Operations());
        using var retry = store.ClaimCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, DateTimeOffset.UtcNow);
        Assert.Equal(VoiceOperationState.Intent, retry.Operation.State);
    }
    [Fact]
    public void NativeWindowsParityGateMustRemainClosedUntilBothRidsHaveEvidence()
    {
        Assert.False(VoiceSpeakerCheck.WindowsNativeParityVerified);
        Assert.False(VoiceSpeakerCheck.Unavailable.Available);
        Assert.Contains("win-arm64 and win-x64", VoiceSpeakerCheck.UnavailableReason);
        Assert.Null(VoiceSpeakerCheck.Unavailable.Threshold);
        Assert.False(VoiceSpeakerCheck.Unavailable.Supports("en"));
        Assert.Throws<VoiceConsentException>(() => VoiceSpeakerCheck.Unavailable.ValidateAvailability());
    }
    [Fact]
    public void MissingAssetsAndEstonianNeverAuthorizeFromEnglishCalibration()
    {
        using var storage = new Storage();
        Assert.Throws<VoiceConsentException>(() => new ONNXSpeakerEmbedder(storage.Root));
        var model = new SpeakerModelCatalog().Entry;
        Assert.Equal(0.45, model.CalibratedThreshold("en"));
        Assert.Null(model.CalibratedThreshold("et"));
    }
    [Fact]
    public void TrainingWavIsMonoPcm16WithBoundedPeakAndVoicedRms()
    {
        var wav = VoiceTrainingAudio.Wav(Tone(48000, 5));
        var format = VoiceConsentAudio.ValidateWav(wav);
        Assert.Equal(48000, format.Rate);
        Assert.Equal(240000, format.Frames);
        var pcm = VoiceConsentAudio.Pcm16k(wav);
        Assert.InRange(VoiceLabLoudness.VoicedRmsDb(pcm, 16000)!.Value, -20.05, -19.95);
        Assert.True(VoiceLabLoudness.TruePeakDbtp(pcm, 16000) <= -3);
        Assert.Throws<VoiceLabException>(() => VoiceTrainingAudio.Wav(new float[48000]));
        Assert.Throws<VoiceLabException>(() => VoiceTrainingAudio.Wav([float.NaN]));
    }
    [Fact]
    public void ReadAloudSplitsCompleteSixtySecondsIntoTrainingSpans()
    {
        var samples = VoiceTrainingAudio.ReadAloud(Tone(48000, 60));
        Assert.InRange(samples.Count, 2, 12);
        Assert.Equal(60, samples.Sum(sample => sample.Seconds), 6);
        Assert.All(samples, sample =>
        {
            Assert.InRange(sample.Seconds, 5, 30);
            Assert.Equal("readAloud", sample.Source);
            Assert.Equal(sample.Seconds * 48000, VoiceConsentAudio.ValidateWav(sample.Wav).Frames);
        });
        Assert.Throws<VoiceLabException>(() => VoiceTrainingAudio.ReadAloud(new float[48000 * 59]));
    }
    [Fact]
    public async Task EnrollmentReservesBeforeScribeAwaitAndHonorsCancellation()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        using var client = new ElevenLabsVoiceLab(new Keys());
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource<RawTranscript>(TaskCreationOptions.RunContinuationsAsynchronously);
        var enrollment = new VoiceEnrollment(store, client, (_, _, _) => { entered.SetResult(); return resume.Task; });
        var id = Guid.NewGuid().ToString("D");
        var statement = new VoiceConsentStatement("en", "statement", ["one", "two", "three", "four"]);
        var wav = VoiceTrainingAudio.Wav(Tone(16000, 6), 16000);
        var attestations = new VoiceConsentAttestations(true, true, true, DateTimeOffset.UnixEpoch);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(Token);
        var verify = enrollment.VerifyAsync(id, statement, wav, attestations, true, true, cancellation.Token);
        await entered.Task;
        Assert.Equal(VoiceLabErrorKind.InvalidInput, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            enrollment.VerifyAsync(id, statement, wav, attestations, true, true, Token))).Kind);
        cancellation.Cancel();
        resume.SetResult(null!);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => verify);
        Assert.Equal(VoiceConsentError.SpeakerUnavailable, (await Assert.ThrowsAsync<VoiceConsentException>(() =>
            enrollment.PrepareAsync(id, "Name", [], true, Token))).Kind);
        enrollment.Cancel(id);
        Assert.False(File.Exists(Path.Combine(store.Root, id, "statement.wav")));
    }
    [Fact]
    public async Task ThreeFailedStatementChecksUseMonotonicTenMinuteThrottle()
    {
        using var storage = new Storage();
        var clock = new Clock();
        var store = new VoiceConsentStore(storage.Locations, clock);
        using var client = new ElevenLabsVoiceLab(new Keys());
        var calls = 0;
        var enrollment = new VoiceEnrollment(store, client, (_, _, _) =>
        {
            calls++;
            throw new VoiceConsentException(VoiceConsentError.StatementMismatch);
        }, clock: clock);
        var id = Guid.NewGuid().ToString("D");
        var statement = new VoiceConsentStatement("en", "statement", ["one", "two", "three", "four"]);
        var wav = VoiceTrainingAudio.Wav(Tone(16000, 6), 16000);
        Task Verify() => enrollment.VerifyAsync(id, statement, wav, new(true, true, true, DateTimeOffset.UnixEpoch), true, true, Token);
        for (var attempt = 0; attempt < 3; attempt++)
            Assert.Equal(VoiceConsentError.StatementMismatch, (await Assert.ThrowsAsync<VoiceConsentException>(Verify)).Kind);
        Assert.Equal(VoiceConsentError.TooManyAttempts, (await Assert.ThrowsAsync<VoiceConsentException>(Verify)).Kind);
        Assert.Equal(3, calls);
        clock.Ticks = TimeSpan.FromMinutes(10).Ticks;
        Assert.Equal(VoiceConsentError.StatementMismatch, (await Assert.ThrowsAsync<VoiceConsentException>(Verify)).Kind);
        Assert.Equal(4, calls);
    }
    [Fact]
    public async Task SharedRealModelSpeakerVectorsReplayWhenVerifiedLocalAssetsExist()
    {
        var directory = Environment.GetEnvironmentVariable("VOXCLIP_SPEAKER_MODEL_DIR");
        Assert.SkipUnless(directory is not null, "Set VOXCLIP_SPEAKER_MODEL_DIR to hash-verified existing model/VAD files; tests never download them.");
        using var embedder = new ONNXSpeakerEmbedder(directory!);
        using var fixture = FixtureLoader.ReadJson("fixtures/voice-lab/speaker/vectors.json");
        var root = fixture.RootElement;
        var vectors = new Dictionary<string, float[]>();
        foreach (var clip in root.GetProperty("clips").EnumerateArray())
        {
            var id = clip.GetProperty("id").GetString()!;
            var wav = File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, "fixtures/voice-lab/speaker/" + id + ".wav"));
            Assert.Equal(clip.GetProperty("sha256").GetString(), Convert.ToHexStringLower(SHA256.HashData(wav)));
            var pcm = VoiceConsentAudio.Pcm16k(wav);
            var ranges = await embedder.VoicedRangesAsync(pcm, Token);
            Assert.Equal(clip.GetProperty("ranges").EnumerateArray().Select(range => (range[0].GetInt32(), range[1].GetInt32())), ranges);
            var actual = await embedder.EmbeddingAsync(pcm, Token);
            var expected = clip.GetProperty("embedding").EnumerateArray().Select(value => value.GetSingle()).ToArray();
            Assert.Equal(expected.Length, actual.Length);
            for (var index = 0; index < expected.Length; index++)
                Assert.InRange(Math.Abs(actual[index] - expected[index]), 0, root.GetProperty("embeddingAbsoluteTolerance").GetDouble());
            vectors.Add(id, actual);
        }
        Assert.Equal(8, vectors.Count);
        foreach (var score in root.GetProperty("scores").EnumerateArray())
            Assert.InRange(Math.Abs(SpeakerAudio.Cosine(vectors[score[0].GetString()!], vectors[score[1].GetString()!]) - score[2].GetDouble()),
                0, root.GetProperty("scoreAbsoluteTolerance").GetDouble());
    }
}
