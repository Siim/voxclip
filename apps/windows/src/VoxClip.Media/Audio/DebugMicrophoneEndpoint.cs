#if DEBUG
using System.Globalization;
using System.Runtime.Versioning;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace VoxClip.Media.Audio;

internal sealed class DebugMicrophoneEndpoint : IMicrophoneEndpoint
{
    private readonly string scenario;
    private readonly double boundary;
    private readonly TimeProvider clock;
    private readonly byte[] buffer;
    private readonly byte[]? file;
    private ITimer? timer;
    private MicrophonePacket? packet;
    private Action<Exception?>? stopped;
    private long frames;
    private int fileOffset;
    internal int StopCount { get; private set; }
    internal int DisposeCount { get; private set; }

    internal DebugMicrophoneEndpoint(string options, TimeProvider? clock = null)
    {
        this.clock = clock ?? TimeProvider.System;
        var parts = options.Split([';', ','], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        scenario = parts.FirstOrDefault(part => !part.StartsWith("rate=", StringComparison.Ordinal) && !part.StartsWith("channels=", StringComparison.Ordinal)) ?? "tone";
        Rate = Number(parts, "rate=", 48000); Channels = Number(parts, "channels=", 1);
        if (Rate is < 8000 or > 384000 || Channels is < 1 or > 32) throw new MicrophoneException(MicrophoneError.Unavailable);
        if (scenario is "denied" or "nodevice" or "inuse") throw new MicrophoneException(scenario switch
        { "denied" => MicrophoneError.Permission, "nodevice" => MicrophoneError.NoDevice, _ => MicrophoneError.Unavailable });
        if (scenario.StartsWith("file:", StringComparison.Ordinal))
        {
            using var reader = new WaveFileReader(scenario[5..]);
            if (reader.Length > 64 * 1024 * 1024)
                throw new MicrophoneException(MicrophoneError.Unavailable);
            Rate = reader.WaveFormat.SampleRate; Channels = reader.WaveFormat.Channels;
            if (Rate is < 8000 or > 384000 || Channels is < 1 or > 32) throw new MicrophoneException(MicrophoneError.Unavailable);
            var samples = new float[checked((int)(reader.Length / reader.WaveFormat.BlockAlign * Channels))];
            var source = reader.ToSampleProvider();
            var offset = 0;
            while (offset < samples.Length)
            {
                var count = source.Read(samples.AsSpan(offset));
                if (count == 0) throw new MicrophoneException(MicrophoneError.Unavailable);
                offset += count;
            }
            file = new byte[checked(samples.Length * 4)];
            for (var index = 0; index < samples.Length; index++)
                System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(file.AsSpan(index * 4, 4), samples[index]);
            Array.Clear(samples);
        }
        else if (scenario.StartsWith("lost@", StringComparison.Ordinal) || scenario.StartsWith("stall@", StringComparison.Ordinal))
        {
            if (!double.TryParse(scenario[(scenario.IndexOf('@') + 1)..], NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out boundary) || boundary < 0)
                throw new MicrophoneException(MicrophoneError.Unavailable);
        }
        else if (scenario is not ("tone" or "silence" or "silentflags")) throw new MicrophoneException(MicrophoneError.Unavailable);
        buffer = new byte[checked(Math.Max(1, Rate / 100) * Channels * 4)];
    }

    internal static IMicrophoneEndpoint? FromEnvironment(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Environment.GetEnvironmentVariable("VOXCLIP_DEBUG_MIC") is { Length: > 0 } options ? new DebugMicrophoneEndpoint(options) : null;
    }

    [SupportedOSPlatform("windows")]
    internal static IMicrophoneEndpoint OpenLoopback()
    {
        var enumerator = new MMDeviceEnumerator();
        MMDevice? device = null;
        try
        {
            device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            return new WasapiMicrophoneEndpoint(enumerator, device, loopback: true);
        }
        catch { device?.Dispose(); enumerator.Dispose(); throw; }
    }

    public int Rate { get; }
    public int Channels { get; }
    public MicrophoneSampleKind Kind => MicrophoneSampleKind.Float32;
    public string Name => "Synthetic microphone";
    public void Start(MicrophonePacket packet, Action<Exception?> stopped)
    {
        this.packet = packet; this.stopped = stopped;
        timer = clock.CreateTimer(_ => Emit(), null, TimeSpan.FromMilliseconds(10), TimeSpan.FromMilliseconds(10));
    }
    private void Emit()
    {
        if ((double)frames / Rate >= boundary && scenario.Contains('@', StringComparison.Ordinal))
        {
            if (scenario.StartsWith("lost@", StringComparison.Ordinal))
            { timer?.Dispose(); stopped?.Invoke(new MicrophoneException(MicrophoneError.DeviceLost)); }
            return;
        }
        if (file is not null)
        {
            var count = Math.Min(buffer.Length, file.Length - fileOffset);
            if (count == 0) return;
            packet?.Invoke(file.AsSpan(fileOffset, count), false); fileOffset += count;
            frames += count / (Channels * 4); return;
        }
        for (var frame = 0; frame < buffer.Length / (Channels * 4); frame++)
        {
            var sample = scenario == "silence" ? 0 : (float)(Math.Sin(2 * Math.PI * 440 * (frames + frame) / Rate) * 0.1);
            for (var channel = 0; channel < Channels; channel++)
                System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(buffer.AsSpan((frame * Channels + channel) * 4, 4), sample);
        }
        frames += buffer.Length / (Channels * 4);
        packet?.Invoke(buffer, scenario == "silentflags");
    }
    public void Stop() { StopCount++; timer?.Dispose(); }
    public void Dispose() { DisposeCount++; timer?.Dispose(); Array.Clear(buffer); if (file is not null) Array.Clear(file); }
    private static int Number(string[] parts, string prefix, int fallback)
    {
        var part = parts.FirstOrDefault(part => part.StartsWith(prefix, StringComparison.Ordinal));
        return part is null ? fallback : int.TryParse(part[prefix.Length..], NumberStyles.None, CultureInfo.InvariantCulture, out var number)
            ? number : throw new MicrophoneException(MicrophoneError.Unavailable);
    }
}
#endif
