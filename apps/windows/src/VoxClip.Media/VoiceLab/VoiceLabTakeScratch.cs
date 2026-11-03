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
        var sharedStop = VoiceLabLifetime.Once(stop);
        var own = lifetime.Attach(sharedStop);
        try { return new Consumer(own, Fitted.Snapshot.AttachConsumer(sharedStop)); }
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
    /// <summary>The scratch mix of a take: the fitted take with its gain and room tone between the source's half-second lead and
    /// tail, crossfaded into the source at each seam (§8.9). <paramref name="sourceAtAssetRate"/> is the source on the take's
    /// sample grid; staging reads the lead, tail, seam handles and room-tone run at absolute frames and refuses an excerpt
    /// that lacks them.</summary>
    public static VoiceLabTakeScratch Stage(VoiceLabFittedAudio fitted, VoiceLabTakeAnalysis analysis, VoiceLabTakeInput input,
        VoiceLabSourceExcerpt sourceAtAssetRate, string scratchRoot, CancellationToken ct = default)
    {
        var plan = fitted.Fit.Plan;
        var rate = fitted.Snapshot.SampleRate;
        long Frames(double seconds) => checked((long)Math.Floor(seconds * rate + 0.5));
        var start = Frames(plan.WindowStart);
        var end = Frames(plan.WindowEnd);
        var length = checked((int)plan.OutputFrames);
        var source = sourceAtAssetRate;
        var total = source.TotalFrames;
        if (!fitted.Snapshot.IsValid || start < 0 || end <= start || end > total || !source.IsFinite) throw Invalid();
        var lead = (int)Math.Min(rate / 2, start);
        var tail = (int)Math.Min(rate / 2, total - end);
        if ((long)lead + length + tail > (long)VoiceLabTakeProcessing.MaximumQaSeconds * rate) throw Invalid();
        var loop = (int)Frames(0.05);
        float[] tone = [];
        if (analysis.RoomTone is { } room)
        {
            var lower = Frames(room.SourceStartSample / (double)input.SourceSampleRate);
            var upper = Frames(room.SourceEndSample / (double)input.SourceSampleRate);
            if (lower < 0 || upper <= lower || upper - lower <= loop || source.Samples(lower, upper) is not { } run) throw Invalid();
            tone = run.ToArray().SelectMany(sample => new[] { sample, sample }).ToArray();
        }
        var gain = (float)Math.Pow(10, analysis.GainDb / 20);
        var toneGain = (float)Math.Pow(10, (analysis.RoomTone?.GainDb ?? 0) / 20);
        var duration = fitted.OutDuration;
        var incomingPause = plan.HardJoinSmoothing && input.Window.LeftSeam.Kind == VoiceLabSeamKind.Hard ? VoiceLabHardJoin.Pause(plan.Words, duration, true) : null;
        var outgoingPause = plan.HardJoinSmoothing && input.Window.RightSeam.Kind == VoiceLabSeamKind.Hard ? VoiceLabHardJoin.Pause(plan.Words, duration, false) : null;
        var smoothing = incomingPause is not null || outgoingPause is not null;
        VoiceLabEdgeGain? edgeGain = null;
        float Background(int relative)
        {
            var bed = analysis.RoomTone is { EndGainDb: not null } ramp ? (float)Math.Pow(10, ramp.GainDbAt(relative, smoothing ? duration * rate : length) / 20) : toneGain;
            return tone.Length == 0 ? 0 : VoiceLabAudioMixer.RoomToneSample(tone, relative, 0, loop) * bed;
        }
        float Signal(int relative)
        {
            var frame = fitted.TrimStartFrame + relative;
            if (frame < 0 || frame >= fitted.Wave.Frames) throw Invalid();
            float sample = 0;
            for (var channel = 0; channel < fitted.Wave.Channels; channel++) sample += (float)fitted.Wave.Sample(frame, channel) / fitted.Wave.Channels;
            if (!smoothing) return sample * gain + Background(relative);
            var seconds = relative / (double)rate;
            var voice = VoiceLabHardJoin.GeneratedWeight(seconds, duration, incomingPause, outgoingPause);
            var boost = Math.Pow(10, VoiceLabHardJoin.EdgeGainDb(seconds, duration, edgeGain) / 20);
            var bedWeight = VoiceLabHardJoin.BedWeight(seconds, duration, plan.Words, incomingPause, outgoingPause);
            return sample * gain * (float)(voice * boost) + Background(relative) * (float)bedWeight;
        }
        if (source.Samples(start - lead, start) is not { } leading || source.Samples(end, end + tail) is not { } trailing) throw Invalid();
        var mixed = new float[lead + length + tail];
        leading.Span.CopyTo(mixed);
        for (var relative = 0; relative < length; relative++)
        {
            if ((relative & 4095) == 0) ct.ThrowIfCancellationRequested();
            mixed[lead + relative] = Signal(relative);
        }
        trailing.Span.CopyTo(mixed.AsSpan(lead + length));
        var seams = new List<int>();
        foreach (var incoming in new[] { true, false })
        {
            var placement = incoming ? input.Window.LeftSeam : input.Window.RightSeam;
            if (placement.Kind == VoiceLabSeamKind.None) continue;
            if ((incoming ? incomingPause : outgoingPause) is not null)
            {
                var fadeCount = (int)Frames(VoiceLabHardJoin.SourceFadeSeconds);
                if (fadeCount < 2 || (incoming ? fadeCount > lead : fadeCount > tail)) throw Invalid();
                var join = lead + (incoming ? 0 : length);
                var sourceJoin = incoming ? start : end;
                for (var offset = 0; offset < fadeCount; offset++)
                {
                    var local = incoming ? offset - fadeCount : offset;
                    if (source.Samples(sourceJoin + local, sourceJoin + local + 1) is not { } original) throw Invalid();
                    var weight = VoiceLabHardJoin.SourceWeight(local / (double)rate, incoming);
                    mixed[join + local] = original.Span[0] * (float)weight + Background((incoming ? 0 : length) + local) * (float)Math.Sqrt(Math.Max(0, 1 - weight * weight));
                }
                seams.Add(join);
                continue;
            }
            var count = checked((int)Frames(placement.FadeSamples / (double)input.SourceSampleRate));
            var before = count / 2;
            var seam = lead + (incoming ? 0 : length);
            var sourceSeam = incoming ? start : end;
            if (count < 2 || seam < before || seam + count - before > mixed.Length || sourceSeam < before ||
                source.Samples(sourceSeam - before, sourceSeam + count - before) is not { } handle) throw Invalid();
            for (var offset = 0; offset < count; offset++)
            {
                var local = offset - before;
                var original = handle.Span[offset];
                var synthetic = Signal((incoming ? 0 : length) + local);
                var phase = offset / (double)(count - 1);
                var left = incoming ? original : synthetic;
                var right = incoming ? synthetic : original;
                mixed[seam + local] = (float)(left * Math.Cos(Math.PI * phase / 2) + right * Math.Sin(Math.PI * phase / 2));
            }
            seams.Add(seam);
        }
        if (mixed.Any(sample => !float.IsFinite(sample))) throw Invalid();
        double[]? excesses = null;
        if (smoothing)
        {
            excesses = seams.Select(seam => VoiceLabLoudness.LufsJumpLu(mixed, rate, [seam])).ToArray();
            if (source.Samples(start - lead, end + tail) is not { } original) throw Invalid();
            for (var index = 0; index < seams.Count; index++)
            {
                var incoming = seams[index] == lead;
                if ((incoming ? incomingPause : outgoingPause) is not { } pause) continue;
                var sourceJoin = checked(lead + (incoming ? 0 : (int)(end - start)));
                var reference = VoiceLabHardJoin.SourceStep(original.ToArray(), rate, sourceJoin);
                var step = VoiceLabHardJoin.SpeechStep(mixed, rate, seams[index], pause, incoming);
                if (VoiceLabHardJoin.Excess(step, reference) > VoiceLabHardJoin.ToleranceLu)
                {
                    var first = checked(seams[index] + (int)Frames(pause.WordStartSeconds));
                    var last = checked(seams[index] + (int)Frames(pause.WordEndSeconds));
                    var sourceLower = incoming ? Math.Max(0, start - Frames(0.4)) : end;
                    var sourceUpper = incoming ? start : Math.Min(total, end + Frames(0.4));
                    if (source.Samples(sourceLower, sourceUpper) is not { } meeting) throw Invalid();
                    var unboosted = Enumerable.Range(first, last - first).Select(position => mixed[position] /
                        (float)Math.Pow(10, VoiceLabHardJoin.EdgeGainDb((position - lead) / (double)rate, duration, edgeGain) / 20)).ToArray();
                    var boost = VoiceLabHardJoin.MatchingGain(unboosted, meeting.ToArray(), rate, incoming);
                    if (boost > 0)
                    {
                        var adjustment = new VoiceLabEdgeGainWord(boost, pause);
                        edgeGain ??= new();
                        edgeGain = incoming ? edgeGain with { In = adjustment } : edgeGain with { Out = adjustment };
                        for (var position = first; position < last; position++) mixed[position] = Signal(position - lead);
                    }
                }
                excesses[index] = VoiceLabHardJoin.Excess(VoiceLabHardJoin.SpeechStep(mixed, rate, seams[index], pause, incoming), reference);
            }
            for (var index = 0; index < seams.Count; index++)
            {
                var incoming = seams[index] == lead;
                if ((incoming ? incomingPause : outgoingPause) is not { } pause) continue;
                var sourceJoin = checked(lead + (incoming ? 0 : (int)(end - start)));
                var reference = VoiceLabHardJoin.SourceStep(original.ToArray(), rate, sourceJoin);
                excesses[index] = VoiceLabHardJoin.Excess(VoiceLabHardJoin.SpeechStep(mixed, rate, seams[index], pause, incoming), reference);
            }
        }
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
            return new(directory, fitted, new(rate, analysis.Trimmed, measured, lead, lead + length, seams.AsReadOnly(), analysis.GainDb, analysis.RoomTone, fitted.Fit)
            { MicroPauseIn = incomingPause, MicroPauseOut = outgoingPause, EdgeGain = edgeGain, SeamExcesses = excesses });
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
