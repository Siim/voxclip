using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Audio;

/// <summary>The music bed under the final voice (doc/spec/music.md §4), the Windows twin of Mac MusicBedRenderer. Every gain comes
/// from Core <see cref="MusicMix"/>: speech activity measured in the scope's rendered voice (after the clip's speed, volume, fades
/// and mute, bleeps silenced, without tones or sound effects) drives the −12 dB ducking (150 ms attack, 400 ms release), the bed
/// sits <c>gainDb</c> under the measured speech loudness, fades in and out on the rendered clock, and is trimmed from its start
/// offset or looped with equal-power crossfades. A clip's speed never speeds the bed up: it spans the rendered length. Only the
/// decoded track and the 10 ms ducking curve are kept; samples are computed as they are mixed, so preview and export share it.</summary>
internal sealed class MusicBed
{
    private readonly float[] track;
    private readonly IReadOnlyList<MusicMix.LoopPiece> pieces;
    private readonly double[] ducking;
    private readonly ProjectMusic entry;
    private readonly int rate;

    /// <summary>The bed's length in frames: the scope's rendered length.</summary>
    internal long OutputFrames { get; }
    /// <summary>The static bed gain in dB (speech + gainDb − music, bounded).</summary>
    internal double BedGainDb { get; }
    /// <summary>The measured speech loudness in dBFS, or null without speech.</summary>
    internal double? SpeechDb { get; }
    private readonly double bedGain;

    private MusicBed(float[] track, IReadOnlyList<MusicMix.LoopPiece> pieces, double[] ducking, ProjectMusic entry, int rate, long outputFrames,
        double bedGainDb, double? speechDb)
    {
        this.track = track; this.pieces = pieces; this.ducking = ducking; this.entry = entry; this.rate = rate;
        OutputFrames = outputFrames; BedGainDb = bedGainDb; SpeechDb = speechDb; bedGain = Math.Pow(10, bedGainDb / 20);
    }

    /// <summary>The bed of <paramref name="snapshot"/>'s music at <paramref name="rate"/>, or null without music. Reads the scope's
    /// rendered voice once for its speech levels, and decodes the track from its start up to the offset plus the rendered length.</summary>
    internal static MusicBed? Stage(ComposeSnapshot snapshot, int rate, VoiceLabRenderSession? session, CancellationToken ct) =>
        Stage(snapshot, rate, () => RenderedAudioReader.OpenVoiceForMusic(snapshot, rate, session, ct), ct);

    /// <summary><see cref="Stage(ComposeSnapshot, int, VoiceLabRenderSession?, CancellationToken)"/> with the voice it measures
    /// opened by <paramref name="openVoice"/>.</summary>
    internal static MusicBed? Stage(ComposeSnapshot snapshot, int rate, Func<RenderedAudioReader> openVoice, CancellationToken ct)
    {
        if (snapshot.Clip?.Music is not { } input) return null;
        if (snapshot.Media.Audio is null) throw new VoxClipException(VoxClipErrorCode.ExportFailed, NoAudioMessage);
        var outputFrames = (long)Math.Round(snapshot.RenderedDuration * rate, MidpointRounding.AwayFromZero);
        if (outputFrames <= 0) throw new VoxClipException(VoxClipErrorCode.ExportFailed, "The clip is too short for music. Your edits are saved.");
        double[] speech;
        using (var voice = openVoice()) speech = SpeechLevels(voice, rate, ct);
        var seconds = Math.Min(input.Entry.Asset.DurationSeconds, input.Entry.StartOffsetSeconds + outputFrames / (double)rate + 0.05);
        return Create(input.Entry, Decode(input, seconds, rate), speech, outputFrames, rate);
    }

    /// <summary>A Windows export of a video without an audio track has no audio stream to carry music.</summary>
    internal const string NoAudioMessage =
        "Export stopped: this video has no sound, so Windows can't add its music yet. Remove the music, or export it on a Mac. Your edits are saved.";

    /// <summary>The bed for <paramref name="trackStereo"/> (interleaved stereo at <paramref name="rate"/>) under a voice with these
    /// 10 ms <paramref name="speechLevels"/>, spanning <paramref name="outputFrames"/>.</summary>
    internal static MusicBed Create(ProjectMusic entry, float[] trackStereo, double[] speechLevels, long outputFrames, int rate)
    {
        var trackFrames = trackStereo.Length / 2;
        var offsetFrames = (long)Math.Round(entry.StartOffsetSeconds * rate, MidpointRounding.AwayFromZero);
        var pieces = MusicMix.LoopPieces(trackFrames, Math.Min(offsetFrames, Math.Max(0, trackFrames - 1)), outputFrames,
            (long)(MusicMix.LoopCrossfadeSeconds * rate));
        if (pieces.Count == 0) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The music track is too short to use. Your edits are saved.");
        // Per-frame power averaged over both channels, so a wide stereo track is not read 3 dB quieter than it plays.
        var first = (int)pieces[0].SourceStart;
        var power = new float[Math.Max(0, trackFrames - first)];
        for (var index = 0; index < power.Length; index++)
        {
            var left = trackStereo[2 * (index + first)]; var right = trackStereo[2 * (index + first) + 1];
            power[index] = MathF.Sqrt((left * left + right * right) / 2);
        }
        var musicDb = MusicMix.MusicLevelDb(MusicMix.FrameLevels(power, rate));
        var activity = MusicMix.SpeechActivity(speechLevels);
        var speechDb = MusicMix.SpeechLevelDb(speechLevels, activity);
        var bedDb = MusicMix.BedGainDb(speechDb, musicDb, entry.GainDb);
        return new(trackStereo, pieces, MusicMix.DuckingGainsDb(activity, entry.Ducking), entry, rate, outputFrames, bedDb, speechDb);
    }

    /// <summary>Adds the bed at rendered frames <paramref name="firstFrame"/>… into interleaved stereo <paramref name="target"/>.</summary>
    internal void Mix(Span<float> target, long firstFrame, int frames)
    {
        var duration = OutputFrames / (double)rate;
        var last = Math.Min(firstFrame + frames, OutputFrames);
        for (var frame = Math.Max(0, firstFrame); frame < last; frame++)
        {
            float left = 0, right = 0;
            foreach (var piece in pieces)
            {
                if (frame < piece.OutputStart || frame >= piece.OutputStart + piece.Count) continue;
                var index = frame - piece.OutputStart;
                var weight = (float)MusicMix.PieceWeight(piece, index);
                var source = (int)(2 * (piece.SourceStart + index));
                left += track[source] * weight; right += track[source + 1] * weight;
            }
            var seconds = frame / (double)rate;
            var gain = (float)(bedGain * MusicMix.FadeFactor(seconds, duration, entry.FadeInSeconds, entry.FadeOutSeconds) * MusicMix.DuckFactor(ducking, seconds));
            var at = (int)(frame - firstFrame) * 2;
            target[at] += left * gain; target[at + 1] += right * gain;
        }
    }

    /// <summary>10 ms speech levels of a stereo voice, read to its end (a mono mix of both channels).</summary>
    internal static double[] SpeechLevels(RenderedAudioReader voice, int rate, CancellationToken ct)
    {
        var levels = new MusicMix.LevelAccumulator(MusicMix.FrameSize(rate));
        var buffer = new float[4096 * 2];
        var mono = new float[4096];
        int count;
        while ((count = voice.Read(buffer, 4096, ct)) > 0)
        {
            for (var frame = 0; frame < count; frame++) mono[frame] = (buffer[2 * frame] + buffer[2 * frame + 1]) * 0.5f;
            levels.Append(mono.AsSpan(0, count));
        }
        return levels.Finish();
    }

    /// <summary>The track as interleaved stereo at <paramref name="rate"/>, at most <paramref name="seconds"/> long. WAV is read
    /// directly; MP3, M4A, AIFF and FLAC go through FFmpeg.</summary>
    internal static float[] Decode(MusicRenderInput input, double seconds, int rate)
    {
        var path = input.AssetPath;
        if (!File.Exists(path))
            throw new VoxClipException(VoxClipErrorCode.ExportFailed, $"Export stopped: the music file {Path.GetFileName(path)} is missing. Your edits are saved.");
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
            // The decoder pads past the end with silence, so the recorded duration bounds the track.
            var frames = (int)Math.Ceiling(seconds * sourceRate);
            stereo = new float[frames * 2];
            decoder.Read(stereo, frames, CancellationToken.None);
        }
        return sourceRate == rate ? stereo : EffectAudio.Resample(stereo, sourceRate, rate);
    }
}

/// <summary>Music files the Music section stores: their length, for the project's asset record.</summary>
public static class MusicFiles
{
    /// <summary>The decoded length in seconds of <paramref name="path"/>: WAV read directly, other types through FFmpeg's probe.</summary>
    public static async Task<double> DurationSecondsAsync(string path, CancellationToken ct)
    {
        double seconds;
        if (Path.GetExtension(path).Equals(".wav", StringComparison.OrdinalIgnoreCase))
        {
            var wave = VoiceLabWavePcm.Parse(await File.ReadAllBytesAsync(path, ct).ConfigureAwait(false));
            seconds = wave.Frames / (double)wave.Rate;
        }
        else seconds = (await new Pipeline.FfmpegMediaProbe().ProbeAsync(path, ct).ConfigureAwait(false)).DurationSeconds;
        if (!double.IsFinite(seconds) || seconds <= 0) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The music file has no length.");
        return seconds;
    }
}
