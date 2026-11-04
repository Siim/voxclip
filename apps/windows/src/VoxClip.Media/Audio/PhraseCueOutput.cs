using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace VoxClip.Media.Audio;

/// <summary>The cue before a Say it myself recording (design.md §6.3.8; Mac <c>PhraseCueSpeaker</c>): mono samples through the
/// default output in shared mode, completing when they have played. And whether that output is headphones, so the clip's own audio
/// can lead in without bleeding into the take.</summary>
[SupportedOSPlatform("windows")]
public static class PhraseCueOutput
{
    /// <summary>Plays <paramref name="samples"/> once and returns when playback ends or <paramref name="ct"/> stops it.</summary>
    public static async Task PlayAsync(float[] samples, int sampleRate, CancellationToken ct)
    {
        if (sampleRate <= 0 || samples.Length == 0) return;
        var bytes = MemoryMarshal.AsBytes(samples.AsSpan()).ToArray();
        using var stream = new RawSourceWaveStream(bytes, 0, bytes.Length, WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 1));
        using var output = new WasapiPlayerBuilder().WithSharedMode().WithEventSync().WithLatency(100).Build();
        var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        output.PlaybackStopped += (_, _) => ended.TrySetResult();
        output.Init(stream);
        output.Play();
        using var registration = ct.Register(() => { try { output.Stop(); } catch (COMException) { } ended.TrySetCanceled(ct); });
        await ended.Task.ConfigureAwait(false);
    }

    /// <summary>Whether the default render endpoint is headphones or a headset (its form factor). False when it can't be read.</summary>
    public static bool DefaultOutputIsHeadphones()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Console)) return false;
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            var properties = device.Properties;
            if (!properties.Contains(PropertyKeys.PKEY_AudioEndpoint_FormFactor)) return false;
            // EndpointFormFactor: Headphones = 3, Headset = 5.
            return Convert.ToInt32(properties[PropertyKeys.PKEY_AudioEndpoint_FormFactor].Value, System.Globalization.CultureInfo.InvariantCulture) is 3 or 5;
        }
        catch (COMException) { return false; }
    }

    /// <summary>Whether any capture endpoint is active.</summary>
    public static bool HasMicrophone()
    {
        try { return MicrophoneDevices.Active().Count > 0; }
        catch (COMException) { return false; }
    }
}
