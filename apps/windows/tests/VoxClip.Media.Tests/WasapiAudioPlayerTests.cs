using System.Runtime.InteropServices;
using NAudio.Wave;
using VoxClip.Media.Audio;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The device-loss path of the production WASAPI owner, driven through its NAudio output seam.</summary>
public sealed class WasapiAudioPlayerTests
{
    /// <summary>Stands in for NAudio's WasapiPlayer: the test moves the render position and ends the render thread.</summary>
    private sealed class Output : IWasapiOutput
    {
        private long position;
        private int polls;
        internal volatile bool Played, Stopped, Disposed;
        public event EventHandler<StoppedEventArgs> PlaybackStopped = delegate { };
        public WaveFormat OutputWaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(48_000, 2);
        internal int Polls => Volatile.Read(ref polls);
        internal void Render(long frames) => Interlocked.Exchange(ref position, frames * OutputWaveFormat.BlockAlign);
        /// <summary>Report the end of the render thread as NAudio does, with the error that ended it or null after a normal stop.</summary>
        internal void End(Exception? error) => PlaybackStopped(this, new StoppedEventArgs(error));
        public void Init(IWaveProvider source) { }
        public void Play() => Played = true;
        public void Pause() { }
        public void Stop() => Stopped = true;
        public long GetPosition() { Interlocked.Increment(ref polls); return Interlocked.Read(ref position); }
        public void Dispose() => Disposed = true;
    }

#pragma warning disable CA1416 // Only SharedWasapiOutput touches Windows; the owner thread, ring and frame clock run anywhere.
    private static IPreviewAudioOutput Player(Output output) => new WasapiAudioPlayer(() => output);
#pragma warning restore CA1416

    private static async Task Until(Func<bool> condition, CancellationToken ct)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "The WASAPI owner thread did not get there within 5 s.");
            await Task.Delay(5, ct);
        }
    }

    /// <summary>Wait until the owner thread has read the device position a few more times.</summary>
    private static Task Polled(Output output, CancellationToken ct)
    {
        var polls = output.Polls;
        return Until(() => output.Polls > polls + 2, ct);
    }

    [Fact]
    public async Task LostDeviceFaultsCompletionAndKeepsTheLastPlayedFrame()
    {
        var ct = TestContext.Current.CancellationToken;
        var device = new Output();
        var player = Player(device);
        await player.ConfigureAsync(48_000, 2, false, ct);
        await player.PlayAsync(ct);
        Assert.True(device.Played);
        device.Render(48_000);
        await Until(() => player.FramesPlayed == 48_000, ct);
        // NAudio stops the render thread before it reports the error, and a stopped player reads position 0.
        device.Render(0);
        await Polled(device, ct);
        Assert.Equal(48_000, player.FramesPlayed);
        Assert.False(player.Completion.IsCompleted);
        var removed = new COMException("device invalidated", unchecked((int)0x88890004));
        device.End(removed);
        Assert.Same(removed, await Assert.ThrowsAsync<COMException>(() => player.Completion.WaitAsync(TimeSpan.FromSeconds(5), ct)));
        Assert.Equal(48_000, player.FramesPlayed);
        Assert.True(device.Stopped);
        Assert.True(device.Disposed);
        // The owner has stopped, so later calls report the loss instead of touching the device.
        Assert.Same(removed, await Assert.ThrowsAsync<COMException>(() => player.PauseAsync(ct)));
        Assert.Same(removed, await Assert.ThrowsAsync<COMException>(async () => await player.DisposeAsync()));
    }

    [Fact]
    public async Task NormalStopIsNotDeviceLoss()
    {
        var ct = TestContext.Current.CancellationToken;
        var device = new Output();
        var player = Player(device);
        await player.ConfigureAsync(48_000, 2, true, ct);
        Assert.True(device.Played);
        device.Render(4_800);
        await Until(() => player.FramesPlayed == 4_800, ct);
        device.End(null);
        await Polled(device, ct);
        Assert.False(player.Completion.IsCompleted);
        await player.PauseAsync(ct); // the owner still serves commands
        await player.DisposeAsync();
        Assert.True(player.Completion.IsCompletedSuccessfully);
        Assert.True(device.Stopped);
        Assert.True(device.Disposed);
    }
}
