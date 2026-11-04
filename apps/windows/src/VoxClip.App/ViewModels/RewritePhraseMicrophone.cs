using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>The microphone a phrase's own take records from: the WASAPI <see cref="VoiceMicrophoneRecorder"/>, or a stand-in in tests
/// and the smoke (Mac <c>PhraseMicrophone</c>).</summary>
internal interface IPhraseMicrophone
{
    Task StartAsync(int maximumSeconds, CancellationToken ct);
    MicrophoneSnapshot Snapshot();
    MicrophoneTake Stop();
    void Discard();
}

/// <summary>Plays the cue before recording through the default output and completes when it ends.</summary>
internal interface IPhraseCuePlayer
{
    Task PlayAsync(float[] samples, int sampleRate, CancellationToken ct);
}

/// <summary>Whether this PC can record: a microphone exists, and Windows lets VoxClip use it.</summary>
internal enum PhraseMicrophoneAccess { Allowed, Denied, NoMicrophone }

internal sealed class RecorderMicrophone(VoiceMicrophoneRecorder recorder) : IPhraseMicrophone, IAsyncDisposable
{
    public ValueTask DisposeAsync() => recorder.DisposeAsync();
    public Task StartAsync(int maximumSeconds, CancellationToken ct) => recorder.StartAsync(maximumSeconds, ct);
    public MicrophoneSnapshot Snapshot() => recorder.Snapshot();
    public MicrophoneTake Stop() => recorder.Stop();
    public void Discard() => recorder.Discard();
}

internal static class PhraseMicrophoneCopy
{
    internal const string NoMicrophone = "No microphone is connected. Connect one to say it yourself.";
    internal const string Denied = "Microphone access is off for VoxClip. Turn on Microphone access and Let desktop apps access your microphone in Settings → Privacy & security → Microphone, then record.";
    internal const string NoTranscriber = "On-device transcription isn't ready. Install a transcription model in Settings → Transcription.";
    internal const string OpenSettings = "Open Microphone Settings";
    internal static string Copy(Exception error) => error switch
    {
        MicrophoneTakeException { Error: MicrophoneTakeError.NoSpeech } => "No words were heard in this take. Record again, closer to the microphone.",
        MicrophoneTakeException { Error: MicrophoneTakeError.TranscriptionUnavailable } =>
            "On-device transcription isn't ready for this language. Install a transcription model for it in Settings → Transcription.",
        MicrophoneException { Error: MicrophoneError.Permission } => Denied,
        MicrophoneException { Error: MicrophoneError.NoDevice } => NoMicrophone,
        MicrophoneException microphone => VoiceLabCopy.MicrophoneFailure(microphone.Error),
        _ => "This take couldn't be checked: " + RewriteSession.Refusal(error) + " Record again."
    };
    internal static string Seconds(double value) => value.ToString("F1", CultureInfo.InvariantCulture) + " s";
}

/// <summary>"● Say it myself" for one phrase at a time (design.md §6.3.8, voice-lab.md §8.13; Mac <c>PhraseMicrophoneTake</c>): a cue,
/// then record; it stops at the gap plus 1.5 s or on [Stop]; the take is checked on this PC and listed beside the phrase's other takes.
/// Nothing is uploaded and nothing is paid.</summary>
internal sealed class RewritePhraseMicrophone
{
    internal enum MicrophoneState { Idle, Cueing, Recording, Checking }
    internal const double ExtraSeconds = 1.5;
    private readonly IPhraseMicrophone microphone;
    private readonly IPhraseCuePlayer? cue;
    private readonly Func<PhraseMicrophoneAccess> access;
    private readonly Func<bool> headphones;
    private readonly TimeProvider clock;
    private readonly Func<Action, Task> onUi;
    private readonly List<double> levels = [];
    private readonly Dictionary<int, Guid> lastTake = [];
    private CancellationTokenSource? turn;
    private ITimer? meter;
    private double limit;
    private bool denied;

    internal RewritePhraseMicrophone(IPhraseMicrophone microphone, IPhraseCuePlayer? cue, IMicrophoneTakeTranscriber? transcriber,
        Func<PhraseMicrophoneAccess> access, Func<bool> headphones, Func<Action, Task>? onUi = null, TimeProvider? clock = null, bool meters = true)
    {
        this.microphone = microphone; this.cue = cue; Transcriber = transcriber;
        this.access = access; this.headphones = headphones; this.clock = clock ?? TimeProvider.System; Meters = meters;
        this.onUi = onUi ?? (action => { action(); return Task.CompletedTask; });
    }

    internal IMicrophoneTakeTranscriber? Transcriber { get; }
    /// <summary>The meter's pace while recording; tests drive <see cref="TickAsync"/> themselves.</summary>
    internal bool Meters { get; }
    internal MicrophoneState State { get; private set; }
    internal int? Phrase { get; private set; }
    internal string Problem { get; private set; } = "";
    /// <summary>The level history the meter draws while recording, newest last.</summary>
    internal IReadOnlyList<double> Levels => levels;
    internal double Seconds => microphone.Snapshot().Seconds;
    internal double Limit => limit;
    internal bool Busy => State != MicrophoneState.Idle;
    /// <summary>Microphone access: once Windows refused it, the denied guidance stays until a recording starts.</summary>
    internal PhraseMicrophoneAccess Access => access() is var now && now == PhraseMicrophoneAccess.Allowed && denied ? PhraseMicrophoneAccess.Denied : now;
    /// <summary>The take the last recording of phrase <paramref name="index"/> made, for Record again.</summary>
    internal Guid? LastTake(int index) => lastTake.TryGetValue(index, out var id) ? id : null;
    internal event EventHandler? Changed;

    /// <summary>The seconds a take may run before it stops by itself: the phrase's gap plus 1.5 s.</summary>
    internal static double LimitFor(double gap) => gap + ExtraSeconds;

    /// <summary>[● Record] or [Record again]: the cue (the clip's audio before the phrase through headphones, else a count-in), then
    /// recording until the limit or [Stop].</summary>
    internal async Task RecordAsync(RewriteSession session, int index)
    {
        if (State != MicrophoneState.Idle || session.GenerationWindows.ElementAtOrDefault(index) is not { } window || !session.GenerationIsCurrent) return;
        Phrase = index; Problem = "";
        switch (access())
        {
            case PhraseMicrophoneAccess.NoMicrophone: Problem = PhraseMicrophoneCopy.NoMicrophone; Notify(); return;
            case PhraseMicrophoneAccess.Denied: denied = true; Problem = PhraseMicrophoneCopy.Denied; Notify(); return;
        }
        if (Transcriber is null) { Problem = PhraseMicrophoneCopy.NoTranscriber; Notify(); return; }
        var current = new CancellationTokenSource();
        turn = current;
        levels.Clear();
        var input = await window.RecordingInputAsync(current.Token);
        if (!ReferenceEquals(turn, current)) return;
        if (input is null) { Problem = "This phrase can't be recorded right now."; Notify(); return; }
        limit = LimitFor(input.Window.End - input.Window.Start);
        await window.StopForSourceAsync();
        State = MicrophoneState.Cueing; Notify();
        try
        {
            var (samples, rate) = headphones() && LeadIn(input) is { } lead ? lead : (CountIn(48_000), 48_000);
            if (cue is not null) await cue.PlayAsync(samples, rate, current.Token);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error) when (error is not OutOfMemoryException) { }
        if (!ReferenceEquals(turn, current) || State != MicrophoneState.Cueing) return;
        State = MicrophoneState.Recording; Notify();
        try
        {
            await microphone.StartAsync(limit <= 30 ? 30 : 90, current.Token);
            denied = false;
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            if (!ReferenceEquals(turn, current)) return;
            State = MicrophoneState.Idle;
            if (error is MicrophoneException { Error: MicrophoneError.Permission }) denied = true;
            Problem = PhraseMicrophoneCopy.Copy(error);
            Notify();
            return;
        }
        if (!ReferenceEquals(turn, current) || State != MicrophoneState.Recording) { microphone.Discard(); return; }
        if (Meters) meter = clock.CreateTimer(_ => _ = onUi(() => _ = TickAsync(session)), null, TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(100));
        Notify();
    }

    /// <summary>One meter reading: draws the level, and stops at the limit or when the microphone stopped. True once it stopped.</summary>
    internal async Task<bool> TickAsync(RewriteSession session)
    {
        if (State != MicrophoneState.Recording) return true;
        var snapshot = microphone.Snapshot();
        levels.Add(snapshot.Level);
        if (levels.Count > 120) levels.RemoveRange(0, levels.Count - 120);
        Notify();
        if (!snapshot.Recording || snapshot.Failure is not null || snapshot.Seconds >= limit)
        {
            await StopAsync(session);
            return true;
        }
        return false;
    }

    /// <summary>[Stop]: the recording ends and its checks run on this PC; the take is listed once they finish.</summary>
    internal async Task StopAsync(RewriteSession session)
    {
        if (State != MicrophoneState.Recording || Phrase is not { } index || turn is not { } current) return;
        meter?.Dispose(); meter = null;
        var failure = microphone.Snapshot().Failure;
        var take = microphone.Stop();
        // Discard also zeroes a returned take, so the samples are copied first.
        var samples = take.Mono.ToArray();
        var rate = take.Rate;
        microphone.Discard();
        if (failure is not null || samples.Length == 0 || rate <= 0)
        {
            State = MicrophoneState.Idle;
            Problem = PhraseMicrophoneCopy.Copy(new MicrophoneException(failure ?? MicrophoneError.DeviceLost));
            Notify();
            return;
        }
        if (Transcriber is null || session.GenerationWindows.ElementAtOrDefault(index) is not { } window || session.RecordedStorage is not { } storage)
        {
            State = MicrophoneState.Idle; Problem = PhraseMicrophoneCopy.NoTranscriber; Notify();
            return;
        }
        State = MicrophoneState.Checking; Notify();
        try
        {
            var input = await window.RecordingInputAsync(current.Token) ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            var made = await MicrophoneTakeMaker.MakeAsync(samples, rate, input, Transcriber, storage, Guid.NewGuid(), clock.GetUtcNow(), current.Token);
            if (!ReferenceEquals(turn, current)) { await made.Scratch.InvalidateAsync(); return; }
            if (await window.AddRecordedTakeAsync(made, input, LastTake(index))) lastTake[index] = made.Row.Id;
            State = MicrophoneState.Idle;
        }
        catch (OperationCanceledException) { if (ReferenceEquals(turn, current)) State = MicrophoneState.Idle; }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            if (!ReferenceEquals(turn, current)) return;
            State = MicrophoneState.Idle; Problem = PhraseMicrophoneCopy.Copy(error);
        }
        finally { Array.Clear(samples); Notify(); }
    }

    /// <summary>Leaving Say it myself, or the takes changing: a recording in progress is dropped, its takes are kept.</summary>
    internal void Cancel()
    {
        try { turn?.Cancel(); } catch (ObjectDisposedException) { }
        turn = null; meter?.Dispose(); meter = null;
        if (State is MicrophoneState.Recording or MicrophoneState.Cueing) microphone.Discard();
        State = MicrophoneState.Idle; levels.Clear();
        Notify();
    }

    /// <summary>Up to 2 s of the clip before the phrase, as the input holds it; null when none is there.</summary>
    internal static (float[] Samples, int Rate)? LeadIn(VoiceLabTakeInput input)
    {
        var rate = input.SourceSampleRate;
        var start = input.Window.StartSample;
        foreach (var seconds in new[] { 2.0, 1.0, 0.5 })
        {
            var count = (long)(seconds * rate);
            if (start - count >= 0 && input.Source.Samples(start - count, start) is { } run) return (run.ToArray(), rate);
        }
        return null;
    }

    /// <summary>Three short beeps half a second apart, the last a little higher: recording starts after it.</summary>
    internal static float[] CountIn(int rate)
    {
        var samples = new float[rate * 3 / 2];
        var beep = rate * 8 / 100;
        foreach (var (offset, frequency) in new[] { (0, 880.0), (rate / 2, 880.0), (rate, 1320.0) })
            for (var index = 0; index < beep; index++)
            {
                var fade = Math.Min(1, Math.Min(index, beep - index) / (rate * 0.005));
                samples[offset + index] = (float)(0.2 * fade * Math.Sin(2 * Math.PI * frequency * index / rate));
            }
        return samples;
    }

    private void Notify() => Changed?.Invoke(this, EventArgs.Empty);

    /// <summary>Closing Rewrite: a recording in progress is dropped and the microphone released.</summary>
    internal async ValueTask DisposeAsync()
    {
        Cancel();
        if (microphone is IAsyncDisposable owned) await owned.DisposeAsync();
    }

    /// <summary>The Say it myself take line (Mac <c>PhraseMicrophoneRow.line</c>): "Your take · “words” · fits 1.4 s ✓ · free", or the
    /// misfit's measured length, or why it failed, each ending in its next step.</summary>
    internal static string TakeLine(VoiceLabTakeRow row, string words, double slot, bool lengthFits, bool carried)
    {
        var length = RewriteGeneration.Length(row) is { } value ? PhraseMicrophoneCopy.Seconds(value) : "no length";
        if (!row.Selectable)
            return $"Your take · “{words}” · {TakeRowPresentation.From(row, null, 1).FailureText ?? "didn't pass the checks."} Record again.";
        var difference = (RewriteGeneration.Length(row) ?? slot) - slot;
        if (!carried)
            return $"Your take · “{words}” · runs {length} for a {PhraseMicrophoneCopy.Seconds(slot)} gap, too {(difference < 0 ? "short" : "long")} to fit. Record again.";
        var join = row.HasJoinAdvisory ? " · the join may sound uneven, listen before using" : "";
        if (row.Fits) return $"Your take · “{words}” · fits {length} ✓{join} · free";
        var verdict = $"{PhraseMicrophoneCopy.Seconds(Math.Abs(difference))} {(difference < 0 ? "shorter" : "longer")}, the video is {(lengthFits ? "cut" : "matched")} to it";
        return $"Your take · “{words}” · {verdict}{join} · free";
    }
}
