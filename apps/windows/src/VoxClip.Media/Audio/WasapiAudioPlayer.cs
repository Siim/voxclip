using System.Runtime.Versioning;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Media.Audio;

/// <summary>WASAPI shared-mode playback placeholder; architecture §6.3. Caller must guard with OperatingSystem.IsWindows().</summary>
[SupportedOSPlatform("windows")]
public sealed class WasapiAudioPlayer : IAsyncDisposable
{
    // TODO(win-media): connect the device clock; the uninitialized player reports zero and disposes safely.
    /// <summary>Device frame clock, not wall-clock or video PTS; architecture §6.3.</summary>
    public long FramesPlayed => 0;
    /// <summary>Start ring-buffer playback on its owner thread; no native calls are made by this skeleton.</summary>
    public Task StartAsync(int sampleRate, int channels, CancellationToken ct) => Task.FromException(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-media"));
    /// <summary>Release on the owner thread; safe before initialization.</summary>
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
