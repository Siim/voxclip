#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Say it myself (design.md §6.3.8, voice-lab.md §8.13; Mac MicrophoneTake): a count-in, or the clip's lead-in with
/// headphones; recording that stops at the gap + 1.5 s or on [Stop], with a level meter and the time; on-device recognition, then
/// the real trim, loudness match, fit and join checks; "Your take · “words” · fits X s ✓ · free" with [Use your take] and [Record
/// again]; a recorded row with no speaker score; denied access and no microphone shown inline. A stub microphone and recognizer stand
/// in for WASAPI and Whisper; the source is a decoded stand-in. Nothing is sent and nothing is paid.</summary>
public sealed class RewriteOwnTakeTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-own-take-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task ARecordingAfterACountInStopsAtTheGapPlusOneAndAHalfAndIsListedAsAFreeOwnTake()
    {
        var (session, runner, microphone, cue, heard) = await PricedWithMicrophoneAsync();
        using var _ = session;
        var window = session.Generation!;
        var before = window.Rows.Count;
        var selected = window.SelectedTakeId;
        await session.RecordPhraseAsync(0);
        Assert.Equal(PhraseWording.Microphone, session.Wording(0));
        Assert.Equal(RewritePhraseMicrophone.MicrophoneState.Recording, session.PhraseMicrophone!.State);
        // Speakers: a count-in of three beeps, so the clip doesn't bleed into the take.
        Assert.Equal(48_000, cue.Rate);
        Assert.Equal(RewritePhraseMicrophone.CountIn(48_000), cue.Samples);
        var gap = window.Slot(window.Rows[0])!.Value;
        Assert.Equal(gap + 1.5, session.PhraseMicrophone.Limit, 9);
        Assert.Equal(30, microphone.Maximum);
        microphone.Seconds = 0.5;
        Assert.False(await session.PhraseMicrophone.TickAsync(session));
        Assert.Single(session.PhraseMicrophone.Levels);
        microphone.Seconds = gap + 1.5;
        Assert.True(await session.PhraseMicrophone.TickAsync(session));
        Assert.True(microphone.Stopped);
        Assert.True(microphone.Discarded);
        Assert.Equal(RewritePhraseMicrophone.MicrophoneState.Idle, session.PhraseMicrophone.State);
        Assert.Equal("", session.PhraseMicrophone.Problem);
        Assert.Equal("en", heard.Language);
        Assert.Equal(before + 1, window.Rows.Count);
        var own = window.Rows[^1];
        Assert.True(window.IsRecorded(own.Id));
        Assert.Null(own.Receipt); Assert.Null(own.Quote);
        Assert.Null(own.Qa!.SpeakerScore);
        Assert.True(own.Qa.SpeakerUnmeasured);
        Assert.Equal("much clearer words", window.RecordedTake(own.Id)!.Text);
        // Free and never chosen automatically: [Use your take] is the user's choice.
        Assert.Equal(1, runner.Sends);
        Assert.Equal(selected, window.SelectedTakeId);
        var line = RewritePhraseMicrophone.TakeLine(own, "much clearer words", window.Slot(own)!.Value, window.LengthFits(own), window.DurationAvailable(own));
        Assert.StartsWith("Your take · “much clearer words” · ", line);
        Assert.EndsWith("· free", line);
        Assert.Equal(RewriteSession.AiDisclosureLine, session.DisclosureLine);
        Assert.True(own.Selectable);
        Assert.True(await UseAsync(window, own));
        Assert.Equal(own.Id, window.SelectedTakeId);
        Assert.True(window.UsesOwnTake);
        Assert.Equal(RewriteSession.OwnTakeDisclosureLine, session.DisclosureLine);
        // The resolver never rewrites the user's own take.
        session.AdvanceAutoFix();
        Assert.Equal(1, runner.Sends);
    }

    [Fact]
    public async Task RecordAgainReplacesTheLastOwnTakeWhenItIsNotInUseAndKeepsEveryOtherTake()
    {
        var (session, runner, microphone, _, _) = await PricedWithMicrophoneAsync();
        using var __ = session;
        var window = session.Generation!;
        await RecordAsync(session, microphone);
        var first = window.Rows[^1];
        Assert.Equal(first.Id, session.PhraseMicrophone!.LastTake(0));
        await RecordAsync(session, microphone);
        Assert.Equal(2, window.Rows.Count);
        var second = window.Rows[^1];
        Assert.NotEqual(first.Id, second.Id);
        Assert.Equal(first.Index, second.Index);
        // In use, the own take stays: Record again adds a new one beside it.
        Assert.True(await UseAsync(window, second));
        await RecordAsync(session, microphone);
        Assert.Equal(3, window.Rows.Count);
        Assert.Contains(window.Rows, row => row.Id == second.Id);
        Assert.Equal(1, runner.Sends);
    }

    [Fact]
    public async Task HeadphonesLeadInWithTheClipBeforeThePhraseAndStopEndsTheRecordingEarly()
    {
        var (session, _, microphone, cue, _) = await PricedWithMicrophoneAsync(headphones: true);
        using var _session = session;
        await session.RecordPhraseAsync(0);
        Assert.Equal(48_000, cue.Rate);
        Assert.Equal(96_000, cue.Samples!.Length);
        Assert.NotEqual(RewritePhraseMicrophone.CountIn(48_000).Length, cue.Samples.Length);
        microphone.Seconds = 1.3;
        await session.StopPhraseRecordingAsync();
        Assert.Equal("", session.PhraseMicrophone!.Problem);
        Assert.True(microphone.Stopped);
        Assert.Equal(RewritePhraseMicrophone.MicrophoneState.Idle, session.PhraseMicrophone!.State);
        Assert.True(session.Generation!.IsRecorded(session.Generation.Rows[^1].Id));
    }

    [Fact]
    public async Task DeniedAccessShowsInlineGuidanceAndNoMicrophoneHidesRecord()
    {
        var (session, _, microphone, _, _) = await PricedWithMicrophoneAsync();
        using var _session = session;
        microphone.Failure = new MicrophoneException(MicrophoneError.Permission);
        await session.RecordPhraseAsync(0);
        Assert.Equal(RewritePhraseMicrophone.MicrophoneState.Idle, session.PhraseMicrophone!.State);
        Assert.Equal(PhraseMicrophoneCopy.Denied, session.PhraseMicrophone.Problem);
        Assert.Equal(PhraseMicrophoneAccess.Denied, session.PhraseMicrophone.Access);
        Assert.Contains("Settings → Privacy & security → Microphone", PhraseMicrophoneCopy.Denied);
        Assert.Equal("ms-settings:privacy-microphone", VoiceLabCopy.MicrophoneSettingsUri);
        var (none, _, _, _, _) = await PricedWithMicrophoneAsync(access: PhraseMicrophoneAccess.NoMicrophone);
        using var _none = none;
        await none.RecordPhraseAsync(0);
        Assert.Equal(PhraseMicrophoneAccess.NoMicrophone, none.PhraseMicrophone!.Access);
        Assert.Equal(PhraseMicrophoneCopy.NoMicrophone, none.PhraseMicrophone.Problem);
        Assert.Equal(RewritePhraseMicrophone.MicrophoneState.Idle, none.PhraseMicrophone.State);
    }

    [Fact]
    public async Task NoWordsHeardAndLeavingSayItMyselfDropTheRecordingAndKeepTheTakes()
    {
        var (session, _, microphone, _, heard) = await PricedWithMicrophoneAsync();
        using var _session = session;
        heard.Words = [];
        await RecordAsync(session, microphone);
        Assert.Equal("No words were heard in this take. Record again, closer to the microphone.", session.PhraseMicrophone!.Problem);
        Assert.Single(session.Generation!.Rows);
        heard.Words = Words;
        await session.RecordPhraseAsync(0);
        Assert.Equal(RewritePhraseMicrophone.MicrophoneState.Recording, session.PhraseMicrophone.State);
        await session.ChooseWordingAsync(PhraseWording.Suggested, 0);
        Assert.Equal(RewritePhraseMicrophone.MicrophoneState.Idle, session.PhraseMicrophone.State);
        Assert.True(microphone.Discarded);
        Assert.Single(session.Generation.Rows);
    }

    [Fact]
    public void AMisfitTakeSaysItsMeasuredLengthAndRecordAgain()
    {
        var failed = new VoiceLabTakeRow(Guid.NewGuid(), 1, 0, Qa: new(.2, 0, -3, null, [VoiceLabTakeQaFailure.Transcript]) { SpeakerUnmeasured = true });
        Assert.EndsWith("Record again.", RewritePhraseMicrophone.TakeLine(failed, "hi", 1.2, false, false));
        Assert.Equal(2.7, RewritePhraseMicrophone.LimitFor(1.2), 9);
        Assert.Equal(72_000, RewritePhraseMicrophone.CountIn(48_000).Length);
    }

    internal static readonly IReadOnlyList<VoiceLabSpokenWord> Words = [new("much", 0.15, 0.4), new("clearer", 0.45, 0.8), new("words", 0.85, 1.2)];

    /// <summary>[Use your take], or Use anyway when the join needs listening first: the control the own take's row shows.</summary>
    private static Task<bool> UseAsync(RewriteGeneration window, VoiceLabTakeRow row) =>
        row.RequiresJoinAdvisoryAcceptance ? window.UseTakeAnywayAsync(row.Id) : window.SelectTakeAsync(row.Id);

    private static async Task RecordAsync(RewriteSession session, FakeMicrophone microphone)
    {
        await session.RecordPhraseAsync(0);
        microphone.Seconds = 1.3;
        await session.StopPhraseRecordingAsync();
    }

    private async Task<(RewriteSession Session, Runner Runner, FakeMicrophone Microphone, FakeCue Cue, FakeHeard Heard)> PricedWithMicrophoneAsync(
        bool headphones = false, PhraseMicrophoneAccess access = PhraseMicrophoneAccess.Allowed)
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed));
        var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        session.ConfigureGenerationFactory(index => new(runner,
            _ => Task.FromResult(new RewriteGenerationChoices([new("record", "My voice")], [new("eleven_v4", "Eleven v4", ["en"], true, false, 5000, 1)])),
            (voice, model, seed, ct) => session.GenerationInputAsync(voice, model, seed, true,
                (request, _) => Task.FromResult((Source, session.Envelope!)), ct, index),
            _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent));
        await session.DiscoverWindowsAsync();
        var batch = session.PreparedBatch!;
        session.MarkBatchEstimateShown(batch);
        await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        await SettleAsync(session);
        var microphone = new FakeMicrophone();
        var cue = new FakeCue();
        var heard = new FakeHeard { Words = Words };
        session.ConfigureMicrophone(new RewritePhraseMicrophone(microphone, cue, heard, () => access, () => headphones, meters: false),
            new(session.Project.Id, Path.Combine(root, "VoiceLab"), Path.Combine(root, "VoiceLabScratch")));
        return (session, runner, microphone, cue, heard);
    }

    /// <summary>The fix-loop editor's audio, decoded: a voice-like tone under each word (word k at k+1 to k+1.4 s), quiet room tone
    /// between them, 100 s at 48 kHz.</summary>
    private static readonly VoiceLabSourceExcerpt Source = VoiceLabSourceExcerpt.Whole(Enumerable.Range(0, 48_000 * 100).Select(index =>
    {
        var seconds = index / 48_000.0;
        var within = seconds - Math.Floor(seconds);
        return seconds >= 1 && within < 0.4 ? (float)(0.1 * Math.Sin(2 * Math.PI * 110 * seconds)) : 0.001f;
    }).ToArray());

    internal sealed class FakeMicrophone : IPhraseMicrophone
    {
        internal double Seconds;
        internal int Maximum;
        internal bool Started, Stopped, Discarded;
        internal Exception? Failure;
        public Task StartAsync(int maximumSeconds, CancellationToken ct)
        {
            if (Failure is { } failure) return Task.FromException(failure);
            Maximum = maximumSeconds; Started = true; Stopped = false; Discarded = false; Seconds = 0;
            return Task.CompletedTask;
        }
        public MicrophoneSnapshot Snapshot() => new(Started && !Stopped, false, Seconds, 0.4, null, null);
        public MicrophoneTake Stop()
        {
            Stopped = true;
            // The user's words: a voice-like tone with quiet edges, for as long as they spoke.
            var count = (int)(48_000 * Math.Max(0.2, Seconds));
            return new(Enumerable.Range(0, count).Select(index =>
            {
                var time = index / 48_000.0;
                return time < 0.1 || time > count / 48_000.0 - 0.1 ? 0.0005f : (float)(0.1 * Math.Sin(2 * Math.PI * 120 * time));
            }).ToArray(), 48_000);
        }
        public void Discard() { Discarded = true; Started = false; }
    }

    internal sealed class FakeCue : IPhraseCuePlayer
    {
        internal float[]? Samples;
        internal int Rate;
        public Task PlayAsync(float[] samples, int sampleRate, CancellationToken ct) { Samples = samples; Rate = sampleRate; return Task.CompletedTask; }
    }

    internal sealed class FakeHeard : IMicrophoneTakeTranscriber
    {
        internal IReadOnlyList<VoiceLabSpokenWord> Words = [];
        internal string? Language;
        public Task<(string Model, IReadOnlyList<VoiceLabSpokenWord> Words)> WordsAsync(float[] samples, string language, CancellationToken ct)
        {
            Language = language;
            return Task.FromResult(("whisper test", Words));
        }
    }

    public void Dispose()
    {
        try { Directory.Delete(root, true); } catch (DirectoryNotFoundException) { }
    }
}
#endif
