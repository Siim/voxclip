using System.Numerics;
using System.Runtime.InteropServices;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Audio;

/// <summary>Reads up to <paramref name="frames"/> interleaved stereo frames; 0 at the end.</summary>
internal delegate int StereoRead(Span<float> target, int frames, CancellationToken ct);

/// <summary>Pitch-preserving time stretch by waveform-similarity overlap-add (WSOLA), the Windows twin of Mac's
/// AVAudioTimePitchAlgorithm.spectral read of a scaled composition (ClipVoiceRenderer). Each 40 ms Hann frame of the input is
/// placed every 20 ms of output; its input position is the nominal one (output time × speed) moved by up to ±5 ms to the
/// offset whose waveform best continues the previous frame, so periods line up and the pitch stays where it was. The output
/// is unbounded: past the input's end it reads silence.</summary>
internal sealed class WsolaStretcher
{
    private readonly StereoRead source;
    private readonly int length;
    private readonly int hop;
    private readonly int tolerance;
    private readonly double analysisHop;
    private readonly float[] window;
    private readonly float[] accumulator;
    private readonly float[] reference;
    private readonly float[] candidates;
    private float[] input = new float[1 << 16];
    private long inputStart;
    private int inputFrames;
    private bool sourceEnded;
    private long frameIndex;
    private long previousStart;
    private int readyOffset;
    private int readyFrames;

    internal WsolaStretcher(StereoRead source, double speed, int rate)
    {
        if (!double.IsFinite(speed) || speed <= 0) throw new ArgumentOutOfRangeException(nameof(speed));
        this.source = source;
        hop = Math.Max(16, (int)Math.Round(rate * 0.02));
        length = hop * 2;
        tolerance = Math.Max(4, (int)Math.Round(rate * 0.005));
        analysisHop = hop * speed;
        window = new float[length];
        for (var index = 0; index < length; index++) window[index] = (float)(0.5 - 0.5 * Math.Cos(2 * Math.PI * index / length));
        accumulator = new float[length * 2];
        reference = new float[hop];
        candidates = new float[hop + tolerance * 2];
    }

    internal int Read(Span<float> target, int frames, CancellationToken ct)
    {
        var written = 0;
        while (written < frames)
        {
            if (readyFrames == 0) Produce(ct);
            var count = Math.Min(frames - written, readyFrames);
            accumulator.AsSpan(readyOffset * 2, count * 2).CopyTo(target[(written * 2)..]);
            readyOffset += count; readyFrames -= count; written += count;
            if (readyFrames == 0)
            {
                // Shift the second half of the accumulator forward for the next frame to add into.
                accumulator.AsSpan(hop * 2, hop * 2).CopyTo(accumulator);
                accumulator.AsSpan(hop * 2).Clear();
                readyOffset = 0;
            }
        }
        return written;
    }

    private void Produce(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var nominal = (long)Math.Round(frameIndex * analysisHop, MidpointRounding.AwayFromZero);
        long start;
        if (frameIndex == 0) start = 0;
        else
        {
            var continuation = previousStart + hop;
            var lowest = Math.Max(0, nominal - tolerance);
            Ensure(Math.Max(continuation + hop, nominal + tolerance + length), ct);
            for (var index = 0; index < hop; index++) reference[index] = Mono(continuation + index);
            var span = (int)(nominal + tolerance - lowest) + hop;
            for (var index = 0; index < span; index++) candidates[index] = Mono(lowest + index);
            // Ties keep the nominal position, so silence never drifts.
            start = nominal;
            var best = Correlate(candidates.AsSpan((int)(nominal - lowest), hop));
            for (var offset = 0; offset + hop <= span; offset++)
            {
                var score = Correlate(candidates.AsSpan(offset, hop));
                if (score > best + 1e-9f) { best = score; start = lowest + offset; }
            }
        }
        Ensure(start + length, ct);
        var first = (int)(start - inputStart);
        for (var index = 0; index < length; index++)
        {
            // The first frame has no predecessor to overlap, so its rising half is flat.
            var weight = frameIndex == 0 && index < hop ? 1f : window[index];
            accumulator[index * 2] += weight * input[(first + index) * 2];
            accumulator[index * 2 + 1] += weight * input[(first + index) * 2 + 1];
        }
        previousStart = start;
        frameIndex++;
        readyOffset = 0; readyFrames = hop;
        var next = (long)Math.Round(frameIndex * analysisHop, MidpointRounding.AwayFromZero);
        Discard(Math.Min(start + hop, Math.Max(0, next - tolerance)));
    }

    private float Correlate(ReadOnlySpan<float> candidate)
    {
        var sum = Vector<float>.Zero;
        var left = MemoryMarshal.Cast<float, Vector<float>>(reference.AsSpan(0, hop));
        var right = MemoryMarshal.Cast<float, Vector<float>>(candidate);
        for (var index = 0; index < left.Length; index++) sum += left[index] * right[index];
        var total = Vector.Dot(sum, Vector<float>.One);
        for (var tail = left.Length * Vector<float>.Count; tail < hop; tail++) total += reference[tail] * candidate[tail];
        return total;
    }

    private float Mono(long frame)
    {
        var index = (int)(frame - inputStart);
        return (input[index * 2] + input[index * 2 + 1]) * 0.5f;
    }

    private void Ensure(long until, CancellationToken ct)
    {
        var needed = (int)(until - inputStart);
        if (needed <= inputFrames) return;
        if (needed * 2 > input.Length) Array.Resize(ref input, Math.Max(input.Length * 2, needed * 2));
        while (inputFrames < needed)
        {
            var count = sourceEnded ? 0 : source(input.AsSpan(inputFrames * 2, (needed - inputFrames) * 2), needed - inputFrames, ct);
            if (count <= 0)
            {
                sourceEnded = true;
                input.AsSpan(inputFrames * 2, (needed - inputFrames) * 2).Clear();
                inputFrames = needed;
            }
            else inputFrames += count;
        }
    }

    private void Discard(long keepFrom)
    {
        var drop = (int)(keepFrom - inputStart);
        if (drop <= 0 || drop < input.Length / 8) return;
        drop = Math.Min(drop, inputFrames);
        input.AsSpan(drop * 2, (inputFrames - drop) * 2).CopyTo(input);
        inputFrames -= drop; inputStart += drop;
    }
}

/// <summary>The audio half of a render's effects (Mac EffectAudio, ai.md §18.5). Bleeps and mutes silence the edited voice over
/// their words' output bounds, ramping over <see cref="ClipEffect.BleepRampSeconds"/> outside them; a bleep's 1 kHz tone is the
/// complement of that ramp on the rendered timeline. Sound effects play at their rendered start with their own gain.</summary>
internal static class EffectAudio
{
    /// <summary>The edited-time ranges (seconds) a bleep or mute silences, in order.</summary>
    internal static (double Start, double End)[] SilencedRanges(ComposeSnapshot snapshot)
    {
        if (snapshot.Clip?.Effects is not { } input) return [];
        var timeline = snapshot.Timeline;
        return input.Audio.Where(effect => effect.UsesWords)
            .Select(effect => (Start: timeline.MapTime(effect.Start), End: timeline.MapTime(effect.End)))
            .Where(range => range.End > range.Start).OrderBy(range => range.Start).ToArray();
    }

    /// <summary>The voice's gain at <paramref name="time"/> under <paramref name="ranges"/>: 0 inside, a linear ramp outside.</summary>
    internal static double VoiceGain(double time, ReadOnlySpan<(double Start, double End)> ranges)
    {
        const double ramp = ClipEffect.BleepRampSeconds;
        var gain = 1.0;
        foreach (var range in ranges)
        {
            if (time >= range.Start && time <= range.End) return 0;
            if (time < range.Start && range.Start - time < ramp) gain = Math.Min(gain, (range.Start - time) / ramp);
            if (time > range.End && time - range.End < ramp) gain = Math.Min(gain, (time - range.End) / ramp);
        }
        return gain;
    }

    /// <summary>A sound placed on the rendered timeline: its first frame, interleaved stereo samples and linear gain.</summary>
    internal sealed record PlacedSound(long StartFrame, float[] Samples, float Gain);

    /// <summary>The bleep tones (rendered seconds) and sounds of a render.</summary>
    internal sealed record Track((double Start, double End)[] Tones, PlacedSound[] Sounds)
    {
        internal bool IsEmpty => Tones.Length == 0 && Sounds.Length == 0;
    }

    /// <summary>The effects track of <paramref name="snapshot"/> at <paramref name="rate"/>; sounds decoded once.</summary>
    internal static Track Stage(ComposeSnapshot snapshot, int rate)
    {
        if (snapshot.Clip?.Effects is not { } input) return new([], []);
        var timeline = snapshot.Timeline;
        var speed = snapshot.Speed;
        double Map(double source) => speed.Rendered(timeline.MapTime(source));
        var outputFrames = (long)Math.Round(snapshot.RenderedDuration * rate, MidpointRounding.AwayFromZero);
        var tones = input.Audio.Where(effect => effect.Kind == "bleep").Select(effect => (Start: Map(effect.Start), End: Map(effect.End)))
            .Where(range => range.End > range.Start).ToArray();
        var sounds = new List<PlacedSound>();
        foreach (var effect in input.Audio.Where(effect => effect.Kind == "sound"))
        {
            if (!input.SoundPaths.TryGetValue(effect.Id, out var path))
                throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip's bundled sound effects are missing. Reinstall VoxClip. Your edits are saved.");
            var start = (long)Math.Round(Map(effect.Start) * rate, MidpointRounding.AwayFromZero);
            if (start >= outputFrames) continue;
            var samples = Decode(path, effect.Sound?.DurationSeconds ?? ClipEffect.MaximumSoundSeconds, rate);
            sounds.Add(new(start, samples, (float)Math.Pow(10, (effect.GainDb ?? 0) / 20)));
        }
        return new(tones, sounds.ToArray());
    }

    /// <summary>Adds the effects track at rendered frames <paramref name="firstFrame"/>… into <paramref name="target"/>.</summary>
    internal static void Mix(Track track, Span<float> target, long firstFrame, int frames, int rate)
    {
        const double ramp = ClipEffect.BleepRampSeconds;
        var blockStart = firstFrame / (double)rate;
        var blockEnd = (firstFrame + frames) / (double)rate;
        foreach (var tone in track.Tones)
        {
            if (tone.Start - ramp >= blockEnd || tone.End + ramp <= blockStart) continue;
            var first = Math.Max(firstFrame, (long)Math.Floor((tone.Start - ramp) * rate));
            var last = Math.Min(firstFrame + frames, (long)Math.Ceiling((tone.End + ramp) * rate) + 1);
            ReadOnlySpan<(double, double)> only = [tone];
            for (var frame = first; frame < last; frame++)
            {
                var seconds = frame / (double)rate;
                var level = 1 - VoiceGain(seconds, only);
                var value = (float)(ClipEffect.BleepToneAmplitude * level * Math.Sin(2 * Math.PI * ClipEffect.BleepToneHz * seconds));
                var index = (int)(frame - firstFrame) * 2;
                target[index] += value; target[index + 1] += value;
            }
        }
        foreach (var sound in track.Sounds)
        {
            var soundFrames = sound.Samples.Length / 2;
            var from = Math.Max(firstFrame, sound.StartFrame);
            var to = Math.Min(firstFrame + frames, sound.StartFrame + soundFrames);
            for (var frame = from; frame < to; frame++)
            {
                var source = (int)(frame - sound.StartFrame) * 2;
                var index = (int)(frame - firstFrame) * 2;
                target[index] += sound.Samples[source] * sound.Gain;
                target[index + 1] += sound.Samples[source + 1] * sound.Gain;
            }
        }
    }

    /// <summary>A sound file as interleaved stereo floats at <paramref name="rate"/>, at most <paramref name="seconds"/> long. WAV is
    /// read directly (the bundled sounds); other formats go through FFmpeg.</summary>
    internal static float[] Decode(string path, double seconds, int rate)
    {
        if (!File.Exists(path))
            throw new VoxClipException(VoxClipErrorCode.ExportFailed, $"Export stopped: the sound effect {Path.GetFileName(path)} is missing. Your edits are saved.");
        int sourceRate;
        float[] stereo;
        if (Path.GetExtension(path).Equals(".wav", StringComparison.OrdinalIgnoreCase))
        {
            var wave = VoiceLabWavePcm.Parse(File.ReadAllBytes(path));
            sourceRate = wave.Rate;
            var frames = (int)Math.Min(wave.Frames, Math.Ceiling(seconds * sourceRate));
            stereo = new float[frames * 2];
            for (var frame = 0; frame < frames; frame++)
            {
                stereo[frame * 2] = (float)wave.Sample(frame, 0);
                stereo[frame * 2 + 1] = (float)wave.Sample(frame, Math.Min(1, wave.Channels - 1));
            }
        }
        else
        {
            FfmpegLoader.InitializeAsync(CancellationToken.None).GetAwaiter().GetResult();
            using var decoder = new AudioDecoder(path, 2);
            sourceRate = decoder.SampleRate;
            var frames = (int)Math.Ceiling(seconds * sourceRate);
            stereo = new float[frames * 2];
            decoder.Read(stereo, frames, CancellationToken.None);
        }
        return sourceRate == rate ? stereo : Resample(stereo, sourceRate, rate);
    }

    /// <summary>Linear-interpolation resample of a short interleaved stereo sound.</summary>
    internal static float[] Resample(float[] stereo, int from, int to)
    {
        var frames = stereo.Length / 2;
        var output = (int)Math.Round(frames * (double)to / from);
        var result = new float[output * 2];
        for (var frame = 0; frame < output; frame++)
        {
            var position = frame * (double)from / to;
            var index = (int)position;
            if (index >= frames) break;
            var fraction = (float)(position - index);
            var next = Math.Min(frames - 1, index + 1);
            for (var channel = 0; channel < 2; channel++)
                result[frame * 2 + channel] = stereo[index * 2 + channel] * (1 - fraction) + stereo[next * 2 + channel] * fraction;
        }
        return result;
    }
}

/// <summary>The audio a preview or export plays for a snapshot: the edited voice with bleeps and mutes silenced, stretched to the
/// clip's speed with its pitch kept, its volume, fades and mute applied on the rendered clock, and the effects track (bleep tones
/// and sound effects) added on that clock (design §6.9, ai.md §18.5; Mac ClipVoiceRenderer and EffectAudio). Without clip
/// controls or audio effects it reads the edited voice unchanged, sample for sample.</summary>
internal sealed class RenderedAudioReader : IDisposable
{
    private readonly StereoRead edited;
    private readonly IDisposable? owner;
    private readonly int rate;
    private readonly (double Start, double End)[] silenced;
    private readonly WsolaStretcher? stretcher;
    private readonly ProjectClipControls? gain;
    private readonly EffectAudio.Track effects;
    private readonly double renderedStart;
    private readonly double renderedDuration;
    private readonly double editedStart;
    private readonly long renderedFirstFrame;
    private readonly bool passthrough;
    private long editedRead;
    private long produced;

    /// <summary>Rendered frames from the start position to the end.</summary>
    internal long TotalFrames { get; }

    /// <summary>The rendered audio of <paramref name="snapshot"/> from edited time <paramref name="startEdited"/>.</summary>
    internal static RenderedAudioReader Open(ComposeSnapshot snapshot, int rate, double startEdited = 0, VoiceLabRenderSession? session = null,
        CancellationToken ct = default) => Open(snapshot, rate, startEdited, session, true, ct);

    /// <summary>The edited voice alone for the edited WAV (Mac withoutClipControls + withoutAudio): 1×, no clip levels, bleeps and
    /// mutes silent, no tones or sounds.</summary>
    internal static RenderedAudioReader OpenEditedVoice(ComposeSnapshot snapshot, int rate, VoiceLabRenderSession? session, CancellationToken ct)
        => Open(EditedVoiceSnapshot(snapshot), rate, 0, session, false, ct);

    /// <summary>The snapshot the edited WAV reads: no controls, no sounds, bleeps and mutes kept.</summary>
    internal static ComposeSnapshot EditedVoiceSnapshot(ComposeSnapshot snapshot) => snapshot with { Clip = snapshot.Clip?.ForEditedAudio };

    private static RenderedAudioReader Open(ComposeSnapshot snapshot, int rate, double startEdited, VoiceLabRenderSession? session, bool effectsTrack,
        CancellationToken ct)
    {
        var reader = new EditedAudioReader(snapshot, rate, startEdited, session, ct);
        try { return new(snapshot, rate, startEdited, reader.Read, reader, reader.TotalFrames, effectsTrack); }
        catch { reader.Dispose(); throw; }
    }

    internal RenderedAudioReader(ComposeSnapshot snapshot, int rate, double startEdited, StereoRead edited, IDisposable? owner, long editedFrames,
        bool effectsTrack = true)
    {
        this.edited = edited; this.owner = owner; this.rate = rate;
        editedStart = startEdited;
        silenced = EffectAudio.SilencedRanges(snapshot);
        effects = effectsTrack ? EffectAudio.Stage(snapshot, rate) : new([], []);
        var controls = snapshot.Clip?.Controls;
        var speed = snapshot.Speed;
        if (controls is not null && (controls.GainDb != 0 || controls.FadeInSeconds > 0 || controls.FadeOutSeconds > 0 || controls.MuteSource)) gain = controls;
        renderedStart = speed.Rendered(startEdited);
        renderedDuration = snapshot.RenderedDuration;
        renderedFirstFrame = (long)Math.Round(renderedStart * rate, MidpointRounding.AwayFromZero);
        if (speed.Speed != 1)
        {
            stretcher = new(Silenced, speed.Speed, rate);
            TotalFrames = Math.Max(0, (long)Math.Round(renderedDuration * rate, MidpointRounding.AwayFromZero) - renderedFirstFrame);
        }
        else TotalFrames = editedFrames;
        passthrough = stretcher is null && gain is null && silenced.Length == 0 && effects.IsEmpty;
    }

    internal int Read(Span<float> target, int frames, CancellationToken ct)
    {
        frames = (int)Math.Min(frames, TotalFrames - produced);
        if (frames <= 0) return 0;
        if (passthrough)
        {
            var count = edited(target, frames, ct);
            produced += count;
            return count;
        }
        var voice = target[..(frames * 2)];
        if (stretcher is not null) stretcher.Read(voice, frames, ct);
        else
        {
            var count = Silenced(voice, frames, ct);
            if (count < frames) voice[(count * 2)..].Clear();
        }
        if (gain is not null)
            for (var frame = 0; frame < frames; frame++)
            {
                var seconds = renderedStart + (produced + frame) / (double)rate;
                var level = (float)ClipAudioMix.Gain(seconds, renderedDuration, gain);
                voice[frame * 2] *= level; voice[frame * 2 + 1] *= level;
            }
        if (!effects.IsEmpty) EffectAudio.Mix(effects, voice, renderedFirstFrame + produced, frames, rate);
        produced += frames;
        return frames;
    }

    /// <summary>The edited voice with bleeps and mutes silenced on the edited clock.</summary>
    private int Silenced(Span<float> target, int frames, CancellationToken ct)
    {
        var count = edited(target, frames, ct);
        if (silenced.Length > 0)
            for (var frame = 0; frame < count; frame++)
            {
                var level = (float)EffectAudio.VoiceGain(editedStart + (editedRead + frame) / (double)rate, silenced);
                if (level == 1) continue;
                target[frame * 2] *= level; target[frame * 2 + 1] *= level;
            }
        editedRead += count;
        return count;
    }

    public void Dispose() => owner?.Dispose();
}
