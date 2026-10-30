using System.Buffers.Binary;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using VoxClip.Core.Services.Logging;
using VoxClip.Media.Audio;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class MicrophoneCaptureTests
{
#if DEBUG
    [Theory]
    [InlineData("silence", MicrophoneError.Silent)]
    [InlineData("silentflags", MicrophoneError.Silent)]
    [InlineData("lost@1", MicrophoneError.DeviceLost)]
    [InlineData("stall@1", MicrophoneError.DeviceLost)]
    public async Task DebugScenarioFailuresNeverOpenHardware(string scenario, MicrophoneError expected)
    {
        var clock = new MicrophoneClock(); var endpoint = new DebugMicrophoneEndpoint(scenario, clock);
        await using var recorder = new VoiceMicrophoneRecorder(_ => endpoint, clock);
        await recorder.StartAsync(30, TestContext.Current.CancellationToken);
        clock.Advance(TimeSpan.FromSeconds(3)); await recorder.Completion;
        Assert.Equal(expected, recorder.Snapshot().Failure); Assert.Empty(recorder.Stop().Mono);
        Assert.Equal(1, endpoint.StopCount); Assert.Equal(1, endpoint.DisposeCount);
    }

    [Theory]
    [InlineData("denied", MicrophoneError.Permission)]
    [InlineData("nodevice", MicrophoneError.NoDevice)]
    [InlineData("inuse", MicrophoneError.Unavailable)]
    public void DebugScenarioActivationErrors(string scenario, MicrophoneError expected)
        => Assert.Equal(expected, Assert.Throws<MicrophoneException>(() => new DebugMicrophoneEndpoint(scenario)).Error);

    [Theory]
    [InlineData(44100, 1)] [InlineData(48000, 2)] [InlineData(16000, 4)]
    public async Task DebugTonePreservesDeviceRateAndChannelAverage(int rate, int channels)
    {
        var clock = new MicrophoneClock(); var endpoint = new DebugMicrophoneEndpoint($"tone;rate={rate};channels={channels}", clock);
        await using var recorder = new VoiceMicrophoneRecorder(_ => endpoint, clock);
        await recorder.StartAsync(30, TestContext.Current.CancellationToken);
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.True(recorder.Snapshot().Level > 0);
        var take = recorder.Stop(); await recorder.Completion;
        Assert.Equal(rate, take.Rate); Assert.Equal(rate, take.Mono.Length);
        for (var frame = 0; frame < rate; frame++)
            Assert.InRange(Math.Abs(Math.Sin(2 * Math.PI * 440 * frame / rate) * 0.1 - take.Mono[frame]), 0, 0.000001);
    }

    [Fact]
    public async Task DebugFileReadsPcmWavInMemoryAtItsOwnRate()
    {
        var path = Path.Combine(Path.GetTempPath(), "voxclip-mic-" + Guid.NewGuid().ToString("N") + ".wav");
        try
        {
            using (var writer = new NAudio.Wave.WaveFileWriter(path, new NAudio.Wave.WaveFormat(44100, 16, 2)))
                for (var frame = 0; frame < 4410; frame++) { writer.WriteSample(0.125f); writer.WriteSample(0.375f); }
            var clock = new MicrophoneClock(); var endpoint = new DebugMicrophoneEndpoint("file:" + path, clock);
            await using var recorder = new VoiceMicrophoneRecorder(_ => endpoint, clock);
            await recorder.StartAsync(30, TestContext.Current.CancellationToken); clock.Advance(TimeSpan.FromMilliseconds(100));
            var take = recorder.Stop(); await recorder.Completion;
            Assert.Equal(44100, take.Rate); Assert.Equal(4410, take.Mono.Length);
            Assert.All(take.Mono, sample => Assert.Equal(0.25f, sample, 4));
        }
        finally { File.Delete(path); }
    }
#endif

    [Fact]
    public void AudioInputFlagIsIndependentAndUnsetByDefault()
    {
        Assert.Equal(NativeGateOutcome.Skip, NativeTest.Decide(NativeGate.AudioInput, false, "1", "1", "1"));
        Assert.Equal(NativeGateOutcome.Fail, NativeTest.Decide(NativeGate.AudioInput, false, null, null, null, "1"));
        Assert.Equal(NativeGateOutcome.Run, NativeTest.Decide(NativeGate.AudioInput, true, null, null, null));
        Assert.Equal(NativeGateOutcome.Skip, NativeTest.Decide(NativeGate.AudioOutput, false, null, null, null, "1"));
    }

    [Fact]
    public async Task ActivationFailureIsTypedAndSanitized()
    {
        await using var recorder = new VoiceMicrophoneRecorder(_ => throw new COMException("private exception", unchecked((int)0x80070005)), new MicrophoneClock());
        var failure = await Assert.ThrowsAsync<MicrophoneException>(() => recorder.StartAsync(30, TestContext.Current.CancellationToken));
        await recorder.Completion;
        Assert.Equal(MicrophoneError.Permission, failure.Error);
        Assert.DoesNotContain("private", failure.Message);
    }

    [Fact]
    public async Task StopDiscardAndDisposeDuringActivationReleaseTheLateEndpoint()
    {
        var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
        var endpoint = new FakeMicrophoneEndpoint();
        var recorder = new VoiceMicrophoneRecorder(_ => { entered.SetResult(); release.Task.GetAwaiter().GetResult(); return endpoint; }, new MicrophoneClock());
        var start = recorder.StartAsync(30, TestContext.Current.CancellationToken); await entered.Task;
        Assert.Empty(recorder.Stop().Mono); recorder.Discard();
        var disposal = recorder.DisposeAsync().AsTask(); Assert.False(disposal.IsCompleted);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => start);
        release.SetResult(); await disposal;
        Assert.Equal(1, endpoint.StopCount); Assert.Equal(1, endpoint.DisposeCount);
    }

    [Theory]
    [InlineData(0)] [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public async Task SignedSamplesDownmixWithoutBias(int kind)
    {
        var endpoint = new FakeMicrophoneEndpoint { Kind = (MicrophoneSampleKind)kind, Channels = 2 };
        await using var recorder = New(endpoint, new());
        await recorder.StartAsync(30, TestContext.Current.CancellationToken);
        endpoint.Emit([-0.5f, 0.25f]);
        Assert.Equal(-0.125f, Assert.Single(recorder.Stop().Mono));
        await recorder.Completion;
    }

    [Theory]
    [InlineData(0)] [InlineData(29)] [InlineData(31)] [InlineData(89)] [InlineData(91)]
    public async Task OnlyThirtyOrNinetySecondsAreAccepted(int seconds)
    {
        await using var recorder = New(new(), new());
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => recorder.StartAsync(seconds, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(30)] [InlineData(90)]
    public async Task FrameCapStopsAndKeepsDeviceRate(int seconds)
    {
        var endpoint = new FakeMicrophoneEndpoint();
        await using var recorder = New(endpoint, new());
        await recorder.StartAsync(seconds, TestContext.Current.CancellationToken);
        endpoint.Emit(Enumerable.Repeat(0.125f, (seconds + 1) * endpoint.Rate).ToArray());
        await recorder.Completion;
        var take = recorder.Stop();
        Assert.Equal(endpoint.Rate * seconds, take.Mono.Length);
        Assert.Equal(endpoint.Rate, take.Rate);
        Assert.All(take.Mono, sample => Assert.Equal(0.125f, sample));
        Assert.Equal(1, endpoint.StopCount); Assert.Equal(1, endpoint.DisposeCount);
        Assert.Equal("vc-mic", endpoint.OwnerName);
    }

    [Fact]
    public async Task MonotonicDeadlineStopsEvenWithFewerFrames()
    {
        var clock = new MicrophoneClock(); var endpoint = new FakeMicrophoneEndpoint();
        await using var recorder = New(endpoint, clock);
        await recorder.StartAsync(30, TestContext.Current.CancellationToken);
        for (var second = 0; second < 30; second++) { endpoint.Emit([0.25f]); clock.Advance(TimeSpan.FromSeconds(1)); }
        await recorder.Completion;
        Assert.False(recorder.Snapshot().Recording); Assert.Null(recorder.Snapshot().Failure);
        Assert.Equal(30, recorder.Stop().Mono.Length);
    }

    [Fact]
    public async Task StallZerosStorageAndTearsDownOnce()
    {
        var clock = new MicrophoneClock(); var endpoint = new FakeMicrophoneEndpoint();
        await using var recorder = New(endpoint, clock);
        await recorder.StartAsync(30, TestContext.Current.CancellationToken); endpoint.Emit([0.5f]);
        var buffer = Buffer(recorder);
        clock.Advance(TimeSpan.FromMilliseconds(1499)); Assert.True(recorder.Snapshot().Recording);
        clock.Advance(TimeSpan.FromMilliseconds(101)); await recorder.Completion;
        Assert.Equal(MicrophoneError.DeviceLost, recorder.Snapshot().Failure);
        Assert.All(buffer, sample => Assert.Equal(0, sample));
        Assert.Empty(recorder.Stop().Mono);
        recorder.Discard(); await recorder.DisposeAsync();
        Assert.Equal(1, endpoint.StopCount); Assert.Equal(1, endpoint.DisposeCount);
    }

    [Theory]
    [InlineData(0x80070005u, false, MicrophoneError.Permission)]
    [InlineData(0x80070490u, false, MicrophoneError.NoDevice)]
    [InlineData(0x8889000Au, false, MicrophoneError.Unavailable)]
    [InlineData(0x8889000Fu, false, MicrophoneError.Unavailable)]
    [InlineData(0x88890010u, false, MicrophoneError.Unavailable)]
    [InlineData(0x88890004u, false, MicrophoneError.Unavailable)]
    [InlineData(0x88890026u, false, MicrophoneError.Unavailable)]
    [InlineData(0x88890004u, true, MicrophoneError.DeviceLost)]
    [InlineData(0x88890026u, true, MicrophoneError.DeviceLost)]
    [InlineData(0x80004005u, true, MicrophoneError.Unavailable)]
    public void HresultMap(uint hresult, bool recording, MicrophoneError expected)
        => Assert.Equal(expected, VoiceMicrophoneRecorder.MapError(unchecked((int)hresult), recording));

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task TwoSecondsOfZerosOrSilentFlagsFailFast(bool silentFlags)
    {
        var endpoint = new FakeMicrophoneEndpoint(); await using var recorder = New(endpoint, new());
        await recorder.StartAsync(30, TestContext.Current.CancellationToken);
        endpoint.Emit(Enumerable.Repeat(silentFlags ? 0.5f : 0, endpoint.Rate * 2 - 1).ToArray(), silentFlags);
        Assert.True(recorder.Snapshot().Recording);
        endpoint.Emit([silentFlags ? 0.5f : 0], silentFlags); await recorder.Completion;
        Assert.Equal(MicrophoneError.Silent, recorder.Snapshot().Failure); Assert.Empty(recorder.Stop().Mono);
    }

    [Fact]
    public async Task SilentRunResetsOnNonzeroSamplesAndShortSilentTakesAreRejected()
    {
        var endpoint = new FakeMicrophoneEndpoint(); await using var recorder = New(endpoint, new());
        await recorder.StartAsync(30, TestContext.Current.CancellationToken);
        endpoint.Emit(new float[endpoint.Rate]); endpoint.Emit([0.1f]); endpoint.Emit(new float[endpoint.Rate]);
        Assert.True(recorder.Snapshot().Recording); recorder.Stop(); await recorder.Completion;
        await recorder.StartAsync(30, TestContext.Current.CancellationToken); endpoint.Emit([0]); recorder.Stop(); await recorder.Completion;
        Assert.Equal(MicrophoneError.Silent, recorder.Snapshot().Failure);
    }

    [Fact]
    public async Task ActivationWaitsWithoutTimeoutAndCancellationIsPrompt()
    {
        var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
        var clock = new MicrophoneClock(); var endpoint = new FakeMicrophoneEndpoint();
        await using var recorder = new VoiceMicrophoneRecorder(_ => { entered.SetResult(); release.Task.GetAwaiter().GetResult(); return endpoint; }, clock);
        using var cancellation = new CancellationTokenSource();
        var start = recorder.StartAsync(30, cancellation.Token); await entered.Task;
        clock.Advance(TimeSpan.FromMilliseconds(999)); Assert.False(recorder.Snapshot().Activating);
        clock.Advance(TimeSpan.FromHours(1)); Assert.True(recorder.Snapshot().Activating); Assert.False(start.IsCompleted);
        cancellation.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => start);
        release.SetResult(); await recorder.Completion;
        Assert.Equal(1, endpoint.StopCount); Assert.Equal(1, endpoint.DisposeCount);
        Assert.Empty(recorder.Stop().Mono);
    }

    [Fact]
    public async Task StopDiscardDisposeAndCallbacksCanRace()
    {
        for (var iteration = 0; iteration < 20; iteration++)
        {
            var endpoint = new FakeMicrophoneEndpoint(); var recorder = New(endpoint, new());
            await recorder.StartAsync(30, TestContext.Current.CancellationToken); endpoint.Emit([0.125f]);
            await Task.WhenAll(Task.Run(() => recorder.Stop(), TestContext.Current.CancellationToken), Task.Run(recorder.Discard, TestContext.Current.CancellationToken),
                Task.Run(async () => await recorder.DisposeAsync(), TestContext.Current.CancellationToken), Task.Run(() => endpoint.Fail(0x88890004u), TestContext.Current.CancellationToken));
            await recorder.Completion;
            Assert.Equal(1, endpoint.StopCount); Assert.Equal(1, endpoint.DisposeCount);
            Assert.DoesNotContain(recorder.Stop().Mono, sample => sample != 0);
        }
    }

    [Theory]
    [InlineData(0, 1)] [InlineData(0, 2)] [InlineData(0, 4)]
    [InlineData(1, 1)] [InlineData(1, 2)] [InlineData(1, 4)]
    [InlineData(2, 1)] [InlineData(2, 2)] [InlineData(2, 4)]
    [InlineData(3, 1)] [InlineData(3, 2)] [InlineData(3, 4)]
    public async Task SupportedFormatsAverageAllChannels(int kind, int channels)
    {
        var endpoint = new FakeMicrophoneEndpoint { Kind = (MicrophoneSampleKind)kind, Channels = channels };
        await using var recorder = New(endpoint, new()); await recorder.StartAsync(30, TestContext.Current.CancellationToken);
        var vector = Enumerable.Range(1, channels).Select(channel => channel * 0.125f).ToArray();
        endpoint.Emit(vector);
        Assert.Equal(Math.Min(1, vector.Average() * 5), recorder.Snapshot().Level, 6);
        var take = recorder.Stop(); await recorder.Completion;
        Assert.Equal(vector.Average(), Assert.Single(take.Mono), 6);
    }

    [Fact]
    public async Task MeterUsesLast1024FramesAcrossPacketBoundaries()
    {
        var endpoint = new FakeMicrophoneEndpoint(); await using var recorder = New(endpoint, new());
        await recorder.StartAsync(30, TestContext.Current.CancellationToken);
        endpoint.Emit(Enumerable.Repeat(0.1f, 1024).ToArray()); Assert.Equal(0.5, recorder.Snapshot().Level, 6);
        endpoint.Emit(new float[512]); Assert.Equal(Math.Sqrt(0.005) * 5, recorder.Snapshot().Level, 6);
        endpoint.Emit(new float[512]); Assert.Equal(0, recorder.Snapshot().Level);
        endpoint.Emit([1]); Assert.True(recorder.Snapshot().Level > 0);
    }

    [Fact]
    public async Task FailureLogsOnlyApprovedMetadataAndNeverDeviceOrExceptionNames()
    {
        var log = new MicrophoneLog(); var endpoint = new FakeMicrophoneEndpoint();
        await using var recorder = new VoiceMicrophoneRecorder(_ => endpoint, new MicrophoneClock(), log);
        await recorder.StartAsync(30, TestContext.Current.CancellationToken); endpoint.Emit([0.25f]); endpoint.Fail(0x88890004u); await recorder.Completion;
        var line = Assert.Single(log.Messages);
        Assert.DoesNotContain(endpoint.Name, line); Assert.DoesNotContain("private exception", line);
        Assert.Contains("hresult=0x88890004", line); Assert.Contains("kind=DeviceLost", line);
        Assert.Contains("rate=8000 channels=1", line); Assert.Contains("elapsedMs=", line);
    }

    [Fact]
    public void ReleaseAssemblyContainsNoDebugEndpointOrEnvironmentRead()
    {
#if !DEBUG
        var assembly = typeof(VoiceMicrophoneRecorder).Assembly;
        Assert.DoesNotContain(assembly.GetTypes(), type => type.Name.Contains("DebugMicrophone", StringComparison.Ordinal));
        var bytes = File.ReadAllBytes(assembly.Location);
        Assert.DoesNotContain("VOXCLIP_DEBUG_MIC", Encoding.Unicode.GetString(bytes));
        Assert.DoesNotContain("OpenLoopback", Encoding.UTF8.GetString(bytes));
        Assert.DoesNotContain("WithLoopbackCapture", Encoding.UTF8.GetString(bytes));
#endif
    }

    internal static VoiceMicrophoneRecorder New(FakeMicrophoneEndpoint endpoint, MicrophoneClock clock) => new(_ => endpoint, clock);
    private static float[] Buffer(VoiceMicrophoneRecorder recorder)
    {
        var session = typeof(VoiceMicrophoneRecorder).GetField("session", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(recorder)!;
        return (float[])session.GetType().GetField("Buffer", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(session)!;
    }
}

internal sealed class FakeMicrophoneEndpoint : IMicrophoneEndpoint
{
    public int Rate { get; init; } = 8000;
    public int Channels { get; init; } = 1;
    public MicrophoneSampleKind Kind { get; init; }
    public string Name => "Private Person's microphone";
    internal int StopCount, DisposeCount;
    internal string? OwnerName;
    private MicrophonePacket? packet;
    private Action<Exception?>? stopped;
    public void Start(MicrophonePacket packet, Action<Exception?> stopped)
    { OwnerName = Thread.CurrentThread.Name; this.packet = packet; this.stopped = stopped; }
    public void Stop() => Interlocked.Increment(ref StopCount);
    public void Dispose() => Interlocked.Increment(ref DisposeCount);
    internal void Fail(uint hresult) => stopped?.Invoke(new COMException("private exception", unchecked((int)hresult)));
    internal void Emit(float[] samples, bool silent = false)
    {
        var width = Kind == MicrophoneSampleKind.Pcm16 ? 2 : Kind == MicrophoneSampleKind.Pcm24 ? 3 : 4;
        var bytes = new byte[samples.Length * width];
        for (var index = 0; index < samples.Length; index++)
        {
            var target = bytes.AsSpan(index * width, width); var sample = samples[index];
            switch (Kind)
            {
                case MicrophoneSampleKind.Float32: BinaryPrimitives.WriteSingleLittleEndian(target, sample); break;
                case MicrophoneSampleKind.Pcm16: BinaryPrimitives.WriteInt16LittleEndian(target, (short)(sample * 32768)); break;
                case MicrophoneSampleKind.Pcm24:
                    var value = (int)(sample * 8388608); target[0] = (byte)value; target[1] = (byte)(value >> 8); target[2] = (byte)(value >> 16); break;
                default: BinaryPrimitives.WriteInt32LittleEndian(target, (int)(sample * 2147483648.0)); break;
            }
        }
        packet?.Invoke(bytes, silent);
    }
}

internal sealed class MicrophoneClock : TimeProvider
{
    private long ticks;
    private readonly List<ClockTimer> timers = [];
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public override long GetTimestamp() => ticks;
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ClockTimer(this, callback, state, ticks + dueTime.Ticks, period.Ticks); timers.Add(timer); return timer;
    }
    internal void Advance(TimeSpan duration)
    {
        var target = ticks + duration.Ticks;
        while (timers.Where(timer => !timer.Disposed && timer.Next <= target).OrderBy(timer => timer.Next).FirstOrDefault() is { } timer)
        {
            ticks = timer.Next; timer.Next += timer.Period; timer.Callback(timer.State);
        }
        ticks = target;
    }
    private sealed class ClockTimer(MicrophoneClock owner, TimerCallback callback, object? state, long next, long period) : ITimer
    {
        internal readonly TimerCallback Callback = callback;
        internal readonly object? State = state;
        internal long Next = next, Period = period;
        internal volatile bool Disposed;
        public bool Change(TimeSpan dueTime, TimeSpan period) { Next = owner.ticks + dueTime.Ticks; Period = period.Ticks; return !Disposed; }
        public void Dispose() => Disposed = true;
        public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
}

internal sealed class MicrophoneLog : ILog
{
    internal readonly List<string> Messages = [];
    public void RegisterSecret(string secret) { }
    public void Write(LogLevel level, string category, string message) => Messages.Add(message);
    public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>(Messages);
    public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
