using System.Buffers.Binary;
using VoxClip.Core.Domain.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed record VoiceLabTakeStorage(string ProjectId, string PaidRoot, string ScratchRoot);
public sealed class VoiceLabTakeScratch : IAsyncDisposable
{
    private readonly VoiceLabLifetime lifetime;
    public string MixedAudioPath { get; }
    public string FittedAudioPath { get; }
    public VoiceLabFittedAudio Fitted { get; }
    public VoiceLabTakeAudio Audio { get; }
    public bool IsValid => lifetime.IsValid && Fitted.Snapshot.IsValid;
    internal VoiceLabTakeScratch(string directory, VoiceLabFittedAudio fitted, VoiceLabTakeAudio audio)
    {
        Fitted = fitted; Audio = audio;
        MixedAudioPath = Path.Combine(directory, "mixed.wav");
        FittedAudioPath = Path.Combine(directory, "fitted.wav");
        lifetime = new(() => { if (Directory.Exists(directory)) Directory.Delete(directory, true); });
    }
    public IDisposable AttachConsumer(Func<Task> stop)
    {
        if (!IsValid) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var stopped = 0;
        Task Stop() => Interlocked.Exchange(ref stopped, 1) == 0 ? stop() : Task.CompletedTask;
        var own = lifetime.Attach(Stop);
        try { return new Consumer(own, Fitted.Snapshot.AttachConsumer(Stop)); }
        catch { own.Dispose(); throw; }
    }
    public async Task InvalidateAsync()
    {
        try { await lifetime.InvalidateAsync().ConfigureAwait(false); }
        finally { await Fitted.Snapshot.InvalidateAsync().ConfigureAwait(false); }
    }
    public ValueTask DisposeAsync() => new(InvalidateAsync());
    private sealed class Consumer(IDisposable own, IDisposable snapshot) : IDisposable
    {
        public void Dispose() { own.Dispose(); snapshot.Dispose(); }
    }
}
public static class VoiceLabTakeRenderer
{
    public static VoiceLabTakeScratch Stage(VoiceLabFittedAudio fitted, VoiceLabTakeAnalysis analysis, VoiceLabTakeInput input,
        float[] sourceAtAssetRate, string scratchRoot, CancellationToken ct = default)
    {
        var plan = fitted.Fit.Plan;
        var rate = fitted.Snapshot.SampleRate;
        int Frames(double seconds) => checked((int)Math.Floor(seconds * rate + 0.5));
        var start = Frames(plan.WindowStart);
        var end = Frames(plan.WindowEnd);
        var length = checked((int)plan.OutputFrames);
        var source = sourceAtAssetRate;
        if (!fitted.Snapshot.IsValid || start < 0 || end <= start || end > source.Length || source.Any(sample => !float.IsFinite(sample))) throw Invalid();
        var lead = Math.Min(rate / 2, start);
        var tail = Math.Min(rate / 2, source.Length - end);
        if ((long)lead + length + tail > (long)VoiceLabTakeProcessing.MaximumQaSeconds * rate) throw Invalid();
        float[] tone = [];
        if (analysis.RoomTone is { } room)
        {
            var lower = Frames(room.SourceStartSample / (double)input.SourceSampleRate);
            var upper = Frames(room.SourceEndSample / (double)input.SourceSampleRate);
            if (lower < 0 || upper <= lower || upper > source.Length || upper - lower <= Frames(0.05)) throw Invalid();
            tone = source[lower..upper].SelectMany(sample => new[] { sample, sample }).ToArray();
        }
        var gain = (float)Math.Pow(10, analysis.GainDb / 20);
        var toneGain = (float)Math.Pow(10, (analysis.RoomTone?.GainDb ?? 0) / 20);
        float Signal(int relative)
        {
            var frame = fitted.TrimStartFrame + relative;
            if (frame < 0 || frame >= fitted.Wave.Frames) throw Invalid();
            float sample = 0;
            for (var channel = 0; channel < fitted.Wave.Channels; channel++) sample += (float)fitted.Wave.Sample(frame, channel) / fitted.Wave.Channels;
            var background = tone.Length == 0 ? 0 : VoiceLabAudioMixer.RoomToneSample(tone, relative, 0, Frames(0.05)) * toneGain;
            return sample * gain + background;
        }
        var mixed = new float[lead + length + tail];
        source.AsSpan(start - lead, lead).CopyTo(mixed);
        for (var relative = 0; relative < length; relative++)
        {
            if ((relative & 4095) == 0) ct.ThrowIfCancellationRequested();
            mixed[lead + relative] = Signal(relative);
        }
        source.AsSpan(end, tail).CopyTo(mixed.AsSpan(lead + length));
        var seams = new List<int>();
        foreach (var incoming in new[] { true, false })
        {
            var placement = incoming ? input.Window.LeftSeam : input.Window.RightSeam;
            if (placement.Kind == VoiceLabSeamKind.None) continue;
            var count = Frames(placement.FadeSamples / (double)input.SourceSampleRate);
            var before = count / 2;
            var seam = lead + (incoming ? 0 : length);
            var sourceSeam = incoming ? start : end;
            if (count < 2 || seam < before || seam + count - before > mixed.Length || sourceSeam < before || sourceSeam + count - before > source.Length) throw Invalid();
            for (var offset = 0; offset < count; offset++)
            {
                var local = offset - before;
                var original = source[sourceSeam + local];
                var synthetic = Signal((incoming ? 0 : length) + local);
                var phase = offset / (double)(count - 1);
                var left = incoming ? original : synthetic;
                var right = incoming ? synthetic : original;
                mixed[seam + local] = (float)(left * Math.Cos(Math.PI * phase / 2) + right * Math.Sin(Math.PI * phase / 2));
            }
            seams.Add(seam);
        }
        if (mixed.Any(sample => !float.IsFinite(sample))) throw Invalid();
        Directory.CreateDirectory(scratchRoot);
        VoiceLabCapacity.Require([new(scratchRoot, (long)mixed.Length * 4 + fitted.Wave.Pcm.Length + 88)]);
        var directory = Path.Combine(scratchRoot, "voxclip-take-" + Guid.NewGuid().ToString("N"));
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(directory);
        else Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try
        {
            WritePrivate(Path.Combine(directory, "fitted.wav"), fitted.Wave.Bytes());
            var pcm = new byte[mixed.Length * 4];
            for (var index = 0; index < mixed.Length; index++) BinaryPrimitives.WriteSingleLittleEndian(pcm.AsSpan(index * 4), mixed[index]);
            var path = Path.Combine(directory, "mixed.wav");
            WritePrivate(path, new VoiceLabWavePcm(rate, 1, 32, true, pcm).Bytes());
            var readback = VoiceLabWavePcm.Parse(File.ReadAllBytes(path));
            var measured = Enumerable.Range(0, readback.Frames).Select(frame => (float)readback.Sample(frame, 0)).ToArray();
            if (!mixed.AsSpan().SequenceEqual(measured)) throw Invalid();
            ct.ThrowIfCancellationRequested();
            return new(directory, fitted, new(rate, analysis.Trimmed, measured, lead, lead + length, seams.AsReadOnly(), analysis.GainDb, analysis.RoomTone, fitted.Fit));
        }
        catch { Directory.Delete(directory, true); throw; }
    }
    private static void WritePrivate(string path, byte[] bytes)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.WriteThrough };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using var stream = new FileStream(path, options);
        stream.Write(bytes);
        stream.Flush(true);
    }
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidAudio);
}
