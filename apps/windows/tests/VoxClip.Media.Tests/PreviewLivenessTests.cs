using System.Runtime.InteropServices;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class PreviewLivenessTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);
    private static ComposeSnapshot Snapshot => new(
        new("test.mp4", 10, new(2, 2, 30, 0), null, new(2, 2), "h264", null, false, 0, -1, 0),
        TestPlan.FromKept(48_000, 480_000, [new(0, 480_000)]), null, new(new(2, 2), 30, 1_000_000));

    [Fact]
    public async Task DecoderConstructionFailureRejectsPendingAndFutureReads()
    {
        await using var worker = new VideoWorker("missing", "vc-test-failed-decoder", () => throw new IOException("decoder construction"));
        var pending = worker.ReadAsync(0, true, TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<IOException>(() => worker.Ready.WaitAsync(Timeout, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<IOException>(() => pending.WaitAsync(Timeout, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<IOException>(() => worker.ReadAsync(1, true, TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken));
        await worker.DisposeAsync().AsTask().WaitAsync(Timeout, TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task FailedLoadClearsSnapshotAndAllowsCommandsRetryAndDisposal()
    {
        var fail = true;
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { },
            createWorker: (_, _) => new Worker(fail ? new IOException("decoder construction") : null));
        await Assert.ThrowsAsync<IOException>(() => preview.LoadAsync(Snapshot, null, TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken));
        Assert.False(preview.Position.IsPlaying);
        await Assert.ThrowsAsync<InvalidOperationException>(() => preview.UpdateSnapshotAsync(Snapshot, TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<InvalidOperationException>(() => preview.SeekAsync(1, true, TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<InvalidOperationException>(() => preview.PlayAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken));
        await preview.PauseAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        fail = false;
        await preview.LoadAsync(Snapshot, null, TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await preview.SeekAsync(1, true, TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await preview.PlayAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await preview.PauseAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await preview.DisposeAsync().AsTask().WaitAsync(Timeout, TestContext.Current.CancellationToken);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PlaybackDeviceOrDecodeFailureIsReportedAndOwnerRemainsLive(bool decoderFailure)
    {
        var fault = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
        var enabled = 0;
        Exception error = decoderFailure ? new IOException("decode failed") : new COMException("device invalidated", unchecked((int)0x88890004));
        var worker = new Worker();
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { }, createWorker: (_, _) => worker,
            clockOverride: () =>
            {
                if (Volatile.Read(ref enabled) == 0) return 0;
                if (!decoderFailure) throw error;
                worker.DecodeFailure = error;
                return 1;
            });
        preview.PlaybackFaulted += (_, _) => throw new InvalidOperationException("consumer failed");
        IPreviewEngine contract = preview;
        contract.PlaybackFaulted += (_, exception) => fault.TrySetResult(exception);
        await preview.LoadAsync(Snapshot, null, TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await using var reader = preview.ReadFramesAsync(TestContext.Current.CancellationToken).GetAsyncEnumerator(TestContext.Current.CancellationToken);
        Assert.True(await reader.MoveNextAsync().AsTask().WaitAsync(Timeout, TestContext.Current.CancellationToken));
        Volatile.Write(ref enabled, 1);
        await preview.PlayAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        Assert.Same(error, await fault.Task.WaitAsync(Timeout, TestContext.Current.CancellationToken));
        Assert.False(preview.Position.IsPlaying);
        Volatile.Write(ref enabled, 0); worker.DecodeFailure = null;
        var reported = await Assert.ThrowsAnyAsync<Exception>(() => preview.PlayAsync(TestContext.Current.CancellationToken));
        Assert.Same(error, reported);
        await preview.SeekAsync(2, true, TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        Assert.True(await reader.MoveNextAsync().AsTask().WaitAsync(Timeout, TestContext.Current.CancellationToken));
        Assert.Equal(2, reader.Current.EditedPts);
        await preview.PlayAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await preview.PauseAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await preview.DisposeAsync().AsTask().WaitAsync(Timeout, TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task CancellingQueuedCommandCompletesWithoutWaitingForBusyOwner()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim();
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { entered.TrySetResult(); release.Wait(Timeout, TestContext.Current.CancellationToken); },
            createWorker: (_, _) => new Worker());
        var load = preview.LoadAsync(Snapshot, null, TestContext.Current.CancellationToken);
        try
        {
            await entered.Task.WaitAsync(Timeout, TestContext.Current.CancellationToken);
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
            var queued = preview.PauseAsync(cancellation.Token);
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => queued.WaitAsync(Timeout, TestContext.Current.CancellationToken));
        }
        finally { release.Set(); }
        await load.WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await preview.PauseAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await preview.DisposeAsync().AsTask().WaitAsync(Timeout, TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => preview.PlayAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken));
    }

    private sealed class Worker(Exception? startupFailure = null) : IPreviewVideoWorker
    {
        public Exception? DecodeFailure { get; set; }
        public Task Ready { get; } = startupFailure is null ? Task.CompletedTask : Task.FromException(startupFailure);
        public double Position { get; private set; }
        public Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct)
        {
            Position = source;
            return DecodeFailure is { } exception ? Task.FromException<PixelBuffer>(exception) : Task.FromResult(new PixelBuffer(new byte[16], 2, 2, 8));
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedPrefetchFallsBackAcrossJoinWithoutSeek(bool cancelled)
    {
        var active = new Worker();
        var prefetch = new PrefetchWorker(cancelled);
        var workers = 0;
        double clock = 0;
        var snapshot = Snapshot with { Plan = TestPlan.FromKept(48_000, 480_000, [new(0, 48_000), new(96_000, 144_000)]) };
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { },
            createWorker: (_, _) => ++workers == 1 ? active : prefetch, clockOverride: () => Volatile.Read(ref clock));
        using var commandCancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        await preview.LoadAsync(snapshot, null, commandCancellation.Token).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        commandCancellation.Cancel();
        Assert.False(prefetch.Token.IsCancellationRequested);
        await using var reader = preview.ReadFramesAsync(TestContext.Current.CancellationToken).GetAsyncEnumerator(TestContext.Current.CancellationToken);
        Assert.True(await reader.MoveNextAsync().AsTask().WaitAsync(Timeout, TestContext.Current.CancellationToken));
        await preview.PlayAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
        Volatile.Write(ref clock, 1.1);
        do { Assert.True(await reader.MoveNextAsync().AsTask().WaitAsync(Timeout, TestContext.Current.CancellationToken)); }
        while (reader.Current.EditedPts < 1);
        Assert.True(preview.Position.IsPlaying);
        Assert.InRange(reader.Current.SourcePts, 2, 3);
        await preview.PauseAsync(TestContext.Current.CancellationToken).WaitAsync(Timeout, TestContext.Current.CancellationToken);
    }

    private sealed class PrefetchWorker(bool cancelled) : IPreviewVideoWorker
    {
        public Task Ready => Task.CompletedTask;
        public double Position => 2;
        public CancellationToken Token { get; private set; }
        public Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct)
        {
            Token = ct;
            return cancelled ? Task.FromCanceled<PixelBuffer>(new CancellationToken(true))
                : Task.FromException<PixelBuffer>(new IOException("prefetch failed"));
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class Composer : IFrameComposer
    {
        public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
            => output.Pixels.Span.Clear();
    }
}
