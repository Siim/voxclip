using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace VoxClip.Media.Audio;

/// <summary>An active endpoint's UI-only identity. Names must not enter logs.</summary>
public sealed record MicrophoneDevice(string Id, string Name, bool IsDefault);

/// <summary>Enumerates endpoints without starting a capture stream.</summary>
[SupportedOSPlatform("windows")]
public static class MicrophoneDevices
{
    /// <summary>Active capture endpoints and the current Console-role default.</summary>
    public static IReadOnlyList<MicrophoneDevice> Active()
    {
        using var enumerator = new MMDeviceEnumerator();
        string? defaultId = null;
        if (enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console))
        { using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console); defaultId = device.ID; }
        using var endpoints = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
        var result = new List<MicrophoneDevice>();
        foreach (var device in endpoints)
        {
            using (device) result.Add(new(device.ID, device.FriendlyName, device.ID == defaultId));
        }
        return result;
    }

    internal static IMicrophoneEndpoint OpenDefault(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var enumerator = new MMDeviceEnumerator();
        MMDevice? device = null;
        try
        {
            using var active = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
            if (active.Count == 0) throw new MicrophoneException(MicrophoneError.NoDevice, unchecked((int)0x80070490));
            if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console))
                throw new MicrophoneException(MicrophoneError.NoDevice, unchecked((int)0x80070490));
            device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
            ct.ThrowIfCancellationRequested();
            return new WasapiMicrophoneEndpoint(enumerator, device);
        }
        catch { device?.Dispose(); enumerator.Dispose(); throw; }
    }
}

[SupportedOSPlatform("windows")]
internal sealed class WasapiMicrophoneEndpoint : IMicrophoneEndpoint
{
    private readonly MMDeviceEnumerator enumerator;
    private readonly MMDevice device;
    private readonly WasapiRecorder recorder;
    private readonly MMDeviceNotificationClient notifications;
    private readonly string boundId;
    private Action<Exception?>? stopped;
    private MicrophonePacket? packet;
    private bool disposed;

    internal WasapiMicrophoneEndpoint(MMDeviceEnumerator enumerator, MMDevice device
#if DEBUG
        , bool loopback = false
#endif
        )
    {
        this.enumerator = enumerator; this.device = device;
        boundId = device.ID; Name = device.FriendlyName;
        var builder = new WasapiRecorderBuilder().WithDevice(device).WithSharedMode().WithEventSync();
#if DEBUG
        if (loopback) builder.WithLoopbackCapture();
#endif
        recorder = builder.Build();
        try
        {
            var format = recorder.WaveFormat;
            Rate = format.SampleRate; Channels = format.Channels;
            var floatFormat = format.Encoding == WaveFormatEncoding.IeeeFloat ||
                format is WaveFormatExtensible extensible && extensible.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
            var pcmFormat = format.Encoding == WaveFormatEncoding.Pcm ||
                format is WaveFormatExtensible pcm && pcm.SubFormat == new Guid("00000001-0000-0010-8000-00aa00389b71");
            Kind = (floatFormat, pcmFormat, format.BitsPerSample) switch
            {
                (true, _, 32) => MicrophoneSampleKind.Float32,
                (_, true, 16) => MicrophoneSampleKind.Pcm16,
                (_, true, 24) => MicrophoneSampleKind.Pcm24,
                (_, true, 32) => MicrophoneSampleKind.Pcm32,
                _ => throw new MicrophoneException(MicrophoneError.Unavailable)
            };
            recorder.DataAvailable += OnData;
            recorder.RecordingStopped += OnStopped;
            notifications = enumerator.CreateNotificationClient(useSynchronizationContext: false);
            notifications.DeviceStateChanged += DeviceChanged;
            notifications.DeviceRemoved += DeviceChanged;
        }
        catch { recorder.Dispose(); throw; }
    }

    public int Rate { get; }
    public int Channels { get; }
    public MicrophoneSampleKind Kind { get; }
    public string Name { get; }
    public void Start(MicrophonePacket packet, Action<Exception?> stopped)
    { this.packet = packet; this.stopped = stopped; recorder.StartRecording(); }
    public void Stop() => recorder.StopRecording();
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        try
        {
            notifications.DeviceStateChanged -= DeviceChanged;
            notifications.DeviceRemoved -= DeviceChanged;
            notifications.Dispose();
        }
        finally
        {
            recorder.DataAvailable -= OnData; recorder.RecordingStopped -= OnStopped;
            try { recorder.Dispose(); }
            finally { device.Dispose(); enumerator.Dispose(); }
        }
    }
    private void OnData(ReadOnlySpan<byte> data, AudioClientBufferFlags flags, long devicePosition, long qpcPosition)
        => packet?.Invoke(data, (flags & AudioClientBufferFlags.Silent) != 0);
    private void OnStopped(object? sender, StoppedEventArgs args) => stopped?.Invoke(args.Exception);
    private void DeviceChanged(object? sender, DeviceNotificationEventArgs args)
    {
        if (args.DeviceId == boundId)
            ThreadPool.QueueUserWorkItem(_ => stopped?.Invoke(new COMException(null, unchecked((int)0x88890004))));
    }
}
