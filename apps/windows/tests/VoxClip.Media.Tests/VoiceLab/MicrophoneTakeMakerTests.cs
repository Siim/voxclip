using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>Say it myself's take (design.md §6.3.8, voice-lab.md §8.13; Mac <c>MicrophoneTakeMaker</c>): the user's recording is heard on
/// this PC, trimmed, loudness matched, fitted and joined as a generated take is, and checked for words, clipping and joins. It has no
/// receipt, quote or speaker score, so Core accepts it as a <c>recorded</c> candidate. Nothing is sent anywhere.</summary>
public sealed class MicrophoneTakeMakerTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-mic-take-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task ARecordingIsHeardFittedAndCheckedAsAFreeRecordedTakeWithNoSpeakerScore()
    {
        var heard = new Heard([new("brand", 0.2, 1.6), new("new", 1.7, 2.4), new("words", 2.5, 3.6)]);
        var storage = Storage();
        var id = Guid.NewGuid();
        var take = await MicrophoneTakeMaker.MakeAsync(Recording(3.8), 48000, Input(), heard, storage, id, Date, TestContext.Current.CancellationToken);
        Assert.Equal("en", heard.Language);
        Assert.Equal(16000 * 3.8, heard.Samples, 0);
        Assert.Equal("brand new words", take.Text);
        Assert.Equal("whisper-test", take.Model);
        Assert.Equal(3.8, take.RecordedSeconds, 6);
        Assert.Equal(id, take.Row.Id);
        Assert.Null(take.Row.Receipt); Assert.Null(take.Row.Quote); Assert.Null(take.Row.Generated); Assert.Null(take.Row.Failure);
        Assert.NotNull(take.Row.Audio);
        var qa = take.Row.Qa!;
        Assert.Null(qa.SpeakerScore);
        Assert.True(qa.SpeakerUnmeasured);
        Assert.Equal(1, qa.TranscriptMatch);
        Assert.True(take.Scratch.IsValid);
        Assert.Equal(3, take.Words.Count);
        Assert.Equal("", take.Input.AudioTags.Count == 0 ? "" : "tags");
        Assert.Null(take.Input.Pace);
        // The take is written to the project's own asset folder only.
        Assert.Single(Directory.GetFiles(storage.PaidRoot, "*", SearchOption.AllDirectories));
        Assert.True(take.Row.Selectable && !take.Row.RequiresJoinAdvisoryAcceptance);
        {
            var published = MicrophoneTakeMaker.Publish(take, Date, TestContext.Current.CancellationToken);
            // A take that doesn't fit exactly is used with a video duration that carries it, as the phrase card chooses one.
            var options = new VoiceLabVideoDurationOptions(take.Row, take.Input.SourceSampleRate);
            VoiceLabVideoMode? choice = take.Row.Fits ? null : options.Allows(VoiceLabVideoMode.Cut) ? VoiceLabVideoMode.Cut : VoiceLabVideoMode.Retimed;
            var candidate = VoiceLabRecordedTake.Candidate(take.Row, take.Input, published, take.Model, Date, choice);
            Assert.True(VoiceLabRecordedTake.IsRecorded(candidate.Recipe!.Provenance));
            var segment = VoiceLabRecordedTake.Segment("own", candidate, take.Input, take.Row.Audio!.Fit.Plan);
            Assert.Equal(VoiceLabSegmentKind.Recorded, segment.Kind);
            Assert.False(segment.HasAISpeech());
        }
        await take.Scratch.InvalidateAsync();
    }

    [Fact]
    public async Task ARecordingWithNoWordsHeardIsRefusedAsNoSpeechAndWritesNothing()
    {
        var storage = Storage();
        var error = await Assert.ThrowsAsync<MicrophoneTakeException>(() =>
            MicrophoneTakeMaker.MakeAsync(Recording(2), 48000, Input(), new Heard([new(" ", 0.1, 0.5), new("late", 1, 1)]), storage, Guid.NewGuid(), Date, TestContext.Current.CancellationToken));
        Assert.Equal(MicrophoneTakeError.NoSpeech, error.Error);
        Assert.False(Directory.Exists(storage.PaidRoot));
        await Assert.ThrowsAsync<VoiceLabException>(() =>
            MicrophoneTakeMaker.MakeAsync([float.NaN], 48000, Input(), new Heard([]), storage, Guid.NewGuid(), Date, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task OnDeviceRecognitionUsesOnlyAReadyInstalledModelAndNeverDownloads()
    {
        var engine = new Recognizer(ready: false);
        var transcriber = new OnDeviceTakeTranscriber(engine, _ => Task.FromResult<IReadOnlyList<string>>(["small.en"]), Path.Combine(root, "heard"));
        var error = await Assert.ThrowsAsync<MicrophoneTakeException>(() => transcriber.WordsAsync(new float[16000], "en", TestContext.Current.CancellationToken));
        Assert.Equal(MicrophoneTakeError.TranscriptionUnavailable, error.Error);
        Assert.Equal(0, engine.Transcribed);
        var none = new OnDeviceTakeTranscriber(new Recognizer(ready: true), _ => Task.FromResult<IReadOnlyList<string>>([]), Path.Combine(root, "heard"));
        Assert.Equal(MicrophoneTakeError.TranscriptionUnavailable,
            (await Assert.ThrowsAsync<MicrophoneTakeException>(() => none.WordsAsync(new float[16000], "en", TestContext.Current.CancellationToken))).Error);
        var ready = new Recognizer(ready: true);
        var words = await new OnDeviceTakeTranscriber(ready, _ => Task.FromResult<IReadOnlyList<string>>(["small.en"]), Path.Combine(root, "heard"))
            .WordsAsync(new float[16000], "en", TestContext.Current.CancellationToken);
        Assert.Equal("whisper small.en", words.Model);
        Assert.Equal(["Hello,", "there"], words.Words.Select(word => word.Text));
        Assert.Equal("en", ready.Language);
        // The 16 kHz WAV lives in the scratch folder only while it is transcribed.
        Assert.Empty(Directory.GetFiles(Path.Combine(root, "heard")));
    }

    private static readonly DateTimeOffset Date = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);
    private VoiceLabTakeStorage Storage() => new(Guid.NewGuid().ToString("D"), Path.Combine(root, "Paid"), Path.Combine(root, "scratch"));

    /// <summary>The take-run tests' phrase: 8 s of a 100 Hz voice at 24 kHz with pauses at 1.9–2.1 s and 5.9–6.1 s around the 2–6 s window.</summary>
    private static VoiceLabTakeInput Input()
    {
        var source = Enumerable.Range(0, 24000 * 8).Select(index =>
        {
            var seconds = index / 24000.0;
            return seconds is >= 1.9 and < 2.1 or >= 5.9 and < 6.1 or >= 6.5 and < 7.1 ? 0.001f : (float)(0.1 * Math.Sin(2 * Math.PI * 100 * seconds));
        }).ToArray();
        TimedWord Word(string id, double start, double end) => new(id, id, WordKind.Word, start, end, null, null, 1, "one", TimingSource.Native);
        var window = new VoiceLabWindow("old", "old", [], [], 2, 6, 48000, 144000, new(VoiceLabSeamKind.Hard, 2, 48000, 288), new(VoiceLabSeamKind.Hard, 6, 144000, 288));
        return new("Hello", "eleven_v4", "own", "en", 0, "synthetic-source", source, 24000,
            [Word("before", 0, 1.9), Word("old", 2.1, 5.9), Word("after", 6.1, 6.5), Word("last", 7.1, 7.9)], new HashSet<string>(), window, null, null, false, true, HardJoinSmoothing: false);
    }

    /// <summary>A recording of <paramref name="seconds"/>: a voice-like 120 Hz tone with short quiet edges, at 48 kHz.</summary>
    private static float[] Recording(double seconds) => Enumerable.Range(0, (int)(48000 * seconds)).Select(index =>
    {
        var time = index / 48000.0;
        return time < 0.1 || time > seconds - 0.1 ? 0.0005f : (float)(0.1 * Math.Sin(2 * Math.PI * 120 * time));
    }).ToArray();

    private sealed class Heard(IReadOnlyList<VoiceLabSpokenWord> words) : IMicrophoneTakeTranscriber
    {
        internal string? Language;
        internal int Samples;
        public Task<(string Model, IReadOnlyList<VoiceLabSpokenWord> Words)> WordsAsync(float[] samples, string language, CancellationToken ct)
        {
            Language = language; Samples = samples.Length;
            return Task.FromResult(("whisper-test", words));
        }
    }

    private sealed class Recognizer(bool ready) : ITranscriber
    {
        internal int Transcribed;
        internal string? Language;
        public TranscriptEngine Engine => TranscriptEngine.Whispercpp;
        public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Native, true, true, null, null, true);
        public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => Task.FromResult(true);
        public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) =>
            Task.FromResult<Readiness>(ready ? new Readiness.Ready() : new Readiness.NeedsModels([plan.Model ?? ""], 1));
        public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => throw new InvalidOperationException("Never prepares or downloads.");
        public Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
        {
            Transcribed++;
            Language = (request.Plan.Language as LanguageChoice.Forced)?.Code;
            Assert.True(File.Exists(request.Audio.Wav16kPath));
            return Task.FromResult(new RawTranscript(new(Engine, "small.en", null, "test", null), 1, new(GroupingEnd.LastToken, GroupingConfidence.Single, false),
                [new("Hello", false, 0.1, 0.4, 0.9, null, WordKind.Word, 0), new(",", true, 0.4, 0.45, 0.9, null, WordKind.Word, 0),
                 new("there", false, 0.5, 0.9, 0.9, null, WordKind.Word, 1)], "en", null, true, TimingSource.Native, null));
        }
    }

    public void Dispose()
    {
        try { Directory.Delete(root, true); } catch (DirectoryNotFoundException) { }
    }
}
