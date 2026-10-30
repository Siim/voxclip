using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;
using NAudio.CoreAudioApi;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class VoiceLabAuditionTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    [Theory]
    [InlineData("take")]
    [InlineData("selection")]
    [InlineData("reject")]
    [InlineData("scratch")]
    [InlineData("snapshot")]
    [InlineData("close")]
    [InlineData("invalidate")]
    [InlineData("dispose")]
    public async Task EveryHookStopsBeforeScratchDeletionAndTearsDownExactlyOnce(string hook)
    {
        await using var fixture = new AuditionFixture();
        Assert.True(await fixture.Player.PlayAsync(fixture.Scratch, fixture.Id, "selection", Token));
        Assert.Equal(new[] { "probe", "pause-preview", "open", "play" }, fixture.Events);
        Assert.True(fixture.Player.Snapshot.IsPlaying); Assert.Equal(fixture.Id, fixture.Player.Snapshot.TakeId);
        await fixture.Player.TakeChangedAsync(fixture.Id); await fixture.Player.SelectionChangedAsync("selection");
        await fixture.Player.RejectAsync(Guid.NewGuid()); Assert.True(fixture.Player.Snapshot.IsPlaying);
        fixture.Endpoint.Position = TimeSpan.FromMilliseconds(650);
        fixture.Clock.Advance(TimeSpan.FromMilliseconds(50));
        Assert.Equal(TimeSpan.FromMilliseconds(650), fixture.Player.Snapshot.Position);
        switch (hook)
        {
            case "take": await fixture.Player.TakeChangedAsync(Guid.NewGuid()); break;
            case "selection": await fixture.Player.SelectionChangedAsync("different"); break;
            case "reject": await fixture.Player.RejectAsync(fixture.Id); break;
            case "scratch": await fixture.Scratch.InvalidateAsync(); break;
            case "snapshot": await fixture.Scratch.Fitted.Snapshot.InvalidateAsync(); break;
            case "close": await fixture.Player.EndSessionAsync(); break;
            case "invalidate": await fixture.Player.InvalidateAsync(); break;
            case "dispose": await fixture.Player.DisposeAsync(); break;
        }
        Assert.False(fixture.Player.Snapshot.IsPlaying);
        Assert.Equal(1, fixture.Endpoint.Disposals); Assert.True(fixture.Endpoint.ReaderClosed);
        await fixture.Player.StopAsync(); await fixture.Player.DisposeAsync();
        Assert.Equal(1, fixture.Endpoint.Disposals);
        if (hook is "reject" or "scratch" or "snapshot" or "close" or "invalidate" or "dispose") Assert.False(fixture.Scratch.IsValid);
    }

    [Fact]
    public async Task NoOutputMakesPlayUnavailableWithATooltipAndNoPreviewOrSound()
    {
        await using var fixture = new AuditionFixture(); fixture.Endpoint.Reason = VoiceLabAudition.NoOutputDevice;
        Assert.False(await fixture.Player.PlayAsync(fixture.Scratch, fixture.Id, "selection", Token));
        Assert.False(fixture.Player.Snapshot.CanPlay); Assert.Equal(VoiceLabAudition.NoOutputDevice, fixture.Player.Snapshot.UnavailableReason);
        Assert.Equal(new[] { "probe", "dispose" }, fixture.Events); Assert.Equal(1, fixture.Endpoint.Disposals);
        Assert.True(fixture.Scratch.IsValid);
    }

    [Fact]
    public async Task AvailabilityProbeNeverOpensOrPlaysTheScratchFile()
    {
        await using var fixture = new AuditionFixture();
        fixture.Endpoint.Reason = VoiceLabAudition.NoOutputDevice;
        Assert.False(await fixture.Player.RefreshAvailabilityAsync(Token));
        Assert.False(fixture.Player.Snapshot.CanPlay); Assert.Equal(new[] { "probe", "dispose" }, fixture.Events);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CompletionAndDeviceLossDisposeAndIgnoreLateCallbacks(bool lost)
    {
        await using var fixture = new AuditionFixture();
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Player.Changed += (_, _) => { if (fixture.Player.Snapshot.Completed || fixture.Player.Snapshot.UnavailableReason is not null) completed.TrySetResult(); };
        Assert.True(await fixture.Player.PlayAsync(fixture.Scratch, fixture.Id, "selection", Token));
        fixture.Endpoint.Position = TimeSpan.FromSeconds(1.2);
        if (lost) fixture.Endpoint.Done.TrySetException(new IOException("synthetic device loss")); else fixture.Endpoint.Done.TrySetResult();
        await completed.Task.WaitAsync(TestContext.Current.CancellationToken);
        Assert.False(fixture.Player.Snapshot.IsPlaying); Assert.Equal(!lost, fixture.Player.Snapshot.Completed);
        Assert.Equal(lost ? VoiceLabAudition.OutputUnavailable : null, fixture.Player.Snapshot.UnavailableReason);
        Assert.Equal(TimeSpan.FromSeconds(1.2), fixture.Player.Snapshot.Position);
        Assert.Equal(1, fixture.Endpoint.Disposals);
        fixture.Clock.Advance(TimeSpan.FromSeconds(10)); Assert.Equal(TimeSpan.FromSeconds(1.2), fixture.Player.Snapshot.Position);
    }

    [Theory]
    [InlineData("open")]
    [InlineData("play")]
    [InlineData("preview")]
    public async Task FailureDoesNotLeakAnEndpointOrLeavePlayingState(string failure)
    {
        await using var fixture = new AuditionFixture(failure);
        Assert.False(await fixture.Player.PlayAsync(fixture.Scratch, fixture.Id, "selection", Token));
        Assert.False(fixture.Player.Snapshot.IsPlaying); Assert.NotNull(fixture.Player.Snapshot.UnavailableReason);
        Assert.Equal(1, fixture.Endpoint.Disposals); Assert.True(fixture.Endpoint.ReaderClosed);
    }

    [Fact]
    public async Task InvalidationCancelsAnInFlightOpenBeforeDeletingItsScratch()
    {
        await using var fixture = new AuditionFixture(); fixture.Endpoint.HoldOpen = true;
        var play = fixture.Player.PlayAsync(fixture.Scratch, fixture.Id, "selection", Token);
        await fixture.Endpoint.Opened.Task.WaitAsync(TestContext.Current.CancellationToken);
        await fixture.Scratch.InvalidateAsync();
        Assert.False(await play); Assert.Equal(1, fixture.Endpoint.Disposals);
        Assert.False(fixture.Player.Snapshot.IsPlaying); Assert.False(Directory.Exists(fixture.ScratchDirectory));
    }

    [Fact]
    public async Task InvalidScratchCannotPausePreviewOrOpenAnEndpoint()
    {
        await using var fixture = new AuditionFixture(); await fixture.Scratch.InvalidateAsync();
        await Assert.ThrowsAsync<VoiceLabException>(() => fixture.Player.PlayAsync(fixture.Scratch, fixture.Id, "selection", Token));
        Assert.Empty(fixture.Events);
    }

    [Fact]
    public async Task CancellingActivePlaybackStopsAndReleasesTheReaderOnce()
    {
        await using var fixture = new AuditionFixture();
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(Token);
        Assert.True(await fixture.Player.PlayAsync(fixture.Scratch, fixture.Id, "selection", cancel.Token));
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Player.Changed += (_, _) => { if (!fixture.Player.Snapshot.IsPlaying) stopped.TrySetResult(); };
        cancel.Cancel(); await stopped.Task.WaitAsync(Token);
        Assert.Equal(1, fixture.Endpoint.Disposals); Assert.True(fixture.Endpoint.ReaderClosed);
    }

    [Fact]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeRenderRequiresVerifiedMuteAndPausesPreviewBeforePlayback()
    {
        if (!OperatingSystem.IsWindows()) { Assert.Skip("Muted native audition is owed on Windows ARM64 and x64."); return; }
        Assert.SkipUnless(Environment.GetEnvironmentVariable("VOXCLIP_AUDITION_NATIVE") == "1", "Opt in only after verifying every active render endpoint is muted. Never produce audible output on the VM.");
        using var devices = new MMDeviceEnumerator();
        using var outputs = devices.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
        Assert.True(outputs.Count > 0, "Native audition needs a render endpoint; do not substitute the fake.");
        foreach (var output in outputs) { using (output) Assert.True(output.AudioEndpointVolume.Mute, "Refuse playback: an active render endpoint is not muted."); }
        await using var fixture = new AuditionFixture(native: true);
        var complete = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Player.Changed += (_, _) => { if (fixture.Player.Snapshot.Completed || fixture.Player.Snapshot.UnavailableReason is not null) complete.TrySetResult(); };
        Assert.True(await fixture.Player.RefreshAvailabilityAsync(Token));
        Assert.True(await fixture.Player.PlayAsync(fixture.Scratch, fixture.Id, "native", Token));
        Assert.Equal("pause-preview", Assert.Single(fixture.Events));
        await complete.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.True(fixture.Player.Snapshot.Completed); Assert.Null(fixture.Player.Snapshot.UnavailableReason);
        foreach (var output in devices.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        { using (output) Assert.True(output.AudioEndpointVolume.Mute, "Mute changed; native acceptance is void."); }
    }

    private sealed class AuditionFixture : IAsyncDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-audition-" + Guid.NewGuid().ToString("N"));
        internal string ScratchDirectory => Path.Combine(root, "take");
        internal readonly List<string> Events = [];
        internal readonly Guid Id = Guid.NewGuid();
        internal readonly MicrophoneClock Clock = new();
        internal readonly FakeRender Endpoint;
        internal readonly VoiceLabTakeScratch Scratch;
        internal readonly VoiceLabAudition Player;
        internal AuditionFixture(string? failure = null, bool native = false)
        {
            Directory.CreateDirectory(ScratchDirectory); Directory.CreateDirectory(Path.Combine(root, "snapshot"));
            File.WriteAllBytes(Path.Combine(ScratchDirectory, "mixed.wav"), VoiceTrainingAudio.Wav(Enumerable.Range(0, 48000).Select(index => (float)(.1 * Math.Sin(index * .03))).ToArray()));
            var snapshot = new PreparedVoiceLabAsset("segment", "asset", "unused", Path.Combine(root, "snapshot"), 48000, 1, 48000, 0, 48000, 1, 0, new string('a', 64));
            var plan = new VoiceLabFitPlan([], new(0, 0), new(0, 0), 0, 48000, 0, 1, 0, 48000, 48000, []);
            var fit = new VoiceLabFitResult.Exact(plan);
            var fitted = new VoiceLabFittedAudio(null!, snapshot, fit, 0, 0, 0, 48000, false, null!);
            Scratch = new(ScratchDirectory, fitted, new(48000, [], [], 0, 0, [], 0, null, fit));
            Endpoint = new(Events, failure);
            Task Pause(CancellationToken ct) { Events.Add("pause-preview"); return failure == "preview" ? Task.FromException(new IOException("synthetic preview failure")) : Task.CompletedTask; }
            Player = native ? new(Pause) : new(() => Endpoint, Pause, Clock);
        }
        public async ValueTask DisposeAsync()
        {
            await Player.DisposeAsync(); await Scratch.DisposeAsync();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }
    private sealed class FakeRender(List<string> events, string? failure) : IVoiceLabRenderEndpoint
    {
        private FileStream? reader;
        internal string? Reason;
        internal int Disposals;
        internal bool HoldOpen;
        internal bool ReaderClosed => reader is null;
        internal readonly TaskCompletionSource Opened = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource Done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TimeSpan Position { get; set; }
        public Task Completion => Done.Task;
        public Task<string?> CheckAvailabilityAsync(CancellationToken ct) { events.Add("probe"); return Task.FromResult(Reason); }
        public async Task OpenAsync(string path, CancellationToken ct)
        {
            events.Add("open"); reader = File.OpenRead(path); Opened.TrySetResult();
            if (HoldOpen) await new TaskCompletionSource().Task.WaitAsync(ct);
            if (failure == "open") throw new IOException("synthetic open failure");
        }
        public Task PlayAsync(CancellationToken ct) { events.Add("play"); return failure == "play" ? Task.FromException(new IOException("synthetic play failure")) : Task.CompletedTask; }
        public ValueTask DisposeAsync()
        {
            Disposals++; events.Add("dispose"); reader?.Dispose(); reader = null; Done.TrySetResult(); return ValueTask.CompletedTask;
        }
    }
}
