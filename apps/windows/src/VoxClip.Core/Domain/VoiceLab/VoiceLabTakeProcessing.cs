using System.Buffers.Binary;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public sealed record VoiceLabTakePreflight(double SourceLevel, VoiceLabRoomTone? RoomTone);
public sealed record VoiceLabTakeAnalysis(int SampleRate, float[] Trimmed, double GainDb, VoiceLabRoomTone? RoomTone, VoiceLabFitResult Fit);
public static class VoiceLabTakeProcessing
{
    public const int MaximumQaSeconds = 290;
    public static VoiceLabTakePreflight Preflight(VoiceLabTakeInput input)
    {
        var rate = input.SourceSampleRate;
        var window = input.Window;
        var total = input.Source.TotalFrames;
        if (!input.ProviderConsent || string.IsNullOrEmpty(input.ContentKey) || string.IsNullOrEmpty(input.Text) || input.Text.EnumerateRunes().Count() > 5000 ||
            rate is < 8000 or > 96000 || total <= 0 || !input.Source.IsFinite ||
            window.StartSample < 0 || window.EndSample > total || window.EndSample <= window.StartSample ||
            !double.IsFinite(window.Start) || !double.IsFinite(window.End) || window.Start < 0 || window.End <= window.Start ||
            window.End > total / (double)rate || SourceFrames(window.Start, rate) != window.StartSample || SourceFrames(window.End, rate) != window.EndSample)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        if (!KeepsBridgeWords(input.Text, BridgeWords(input))) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var level = VoiceLabLoudness.NeighbourhoodVoicedRmsDb(input.Source, rate, window.StartSample, window.EndSample);
        var tone = input.CleanAudioOn ? null : VoiceLabRoomToneSelection.Select(input.Items, input.SourceEnvelope, rate, total,
            VoiceLabRoomToneSelection.ExcludeDigitalSilence(input.Items, input.SourceEnvelope, rate, total, window, input.HardJoinSmoothing));
        if (input.HardJoinSmoothing && (window.LeftSeam.Kind == VoiceLabSeamKind.Hard || window.RightSeam.Kind == VoiceLabSeamKind.Hard) && tone is not null)
            tone = VoiceLabHardJoin.MatchedRoomTone(tone, input, level);
        return new(level, tone);
    }
    public static AudioEnvelope Envelope(float[] samples, int sampleRate)
    {
        var frame = Math.Max(1, Frames(0.01, sampleRate));
        var levels = new float[samples.Length / frame];
        for (var start = 0; start < levels.Length; start++)
        {
            double power = 0;
            for (var offset = 0; offset < frame; offset++) power += (double)samples[start * frame + offset] * samples[start * frame + offset];
            levels[start] = (float)Math.Sqrt(power / frame);
        }
        return new(sampleRate, 0.01, levels);
    }
    public static VoiceLabTakeAnalysis Process(VoiceLabAudioResult result, VoiceLabTakeInput input, VoiceLabTakePreflight preflight)
    {
        var rate = result.SampleRate;
        if (rate != 24000 || result.Pcm.Length == 0 || result.Pcm.Length % 2 != 0 || result.Pcm.Length / 2 > rate * 289 || result.Alignment is not { } alignment)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
        var samples = new float[result.Pcm.Length / 2];
        for (var index = 0; index < samples.Length; index++) samples[index] = BinaryPrimitives.ReadInt16LittleEndian(result.Pcm.AsSpan(index * 2)) / 32768f;
        var words = VoiceLabAlignment.Words(alignment.Select(item => item.Character).ToArray(), alignment.Select(item => item.Start).ToArray(),
            alignment.Select(item => item.End).ToArray(), input.Text);
        if (input.HardJoinSmoothing) words = VoiceLabHardJoin.Refine(words, samples, rate,
            input.Window.LeftSeam.Kind == VoiceLabSeamKind.Hard, input.Window.RightSeam.Kind == VoiceLabSeamKind.Hard);
        words = VoiceLabAudioTags.ExtendEdges(words, samples, rate, input.AudioTags, EditingAlgorithms.SplitWords(input.Text).Count, input.ModelId, result.RawAlignment ?? alignment);
        var trim = VoiceLabAlignment.Trim(words, samples.Length / (double)rate);
        var lower = Frames(trim.Start, rate);
        var upper = Frames(trim.End, rate);
        if (lower < 0 || upper > samples.Length || upper <= lower) throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
        var trimmed = samples[lower..upper];
        var gain = VoiceLabLoudness.LevelGainDb(preflight.SourceLevel, VoiceLabLoudness.VoicedRmsDb(trimmed, rate), VoiceLabLoudness.TruePeakDbtp(trimmed, rate));
        var take = new VoiceLabFitTake(samples.Length, rate, trim.Start, trim.End, words, Envelope(samples, rate));
        var profile = input.PauseProfile ?? VoiceLabPauseProfile.Measure(input.Items, input.SourceEnvelope, 0, double.MaxValue);
        var fit = VoiceLabNaturalPacing.Fit(input.Window, input.IncomingSilence, input.OutgoingSilence, take,
            input.SourceSampleRate, input.HardJoinSmoothing, profile,
            VoiceLabNaturalPacing.PauseTags(input.AudioTags, input.ModelId, words.Count), input.SourceEnvelope, input.Items);
        return new(rate, trimmed, gain, preflight.RoomTone, fit);
    }
    /// <summary>The bridge words a take's text must begin and end with (voice-lab §8.4; Mac <c>bridgeWords</c>): the unchanged
    /// words that join the change to the source around it, as the input's items spell them. Throws when a bridge word is cut
    /// or not a word.</summary>
    public static (IReadOnlyList<string> Leading, IReadOnlyList<string> Trailing) BridgeWords(VoiceLabTakeInput input)
    {
        string[] Texts(IReadOnlyList<string> ids) => ids.Select(id =>
            (input.CutWordIds.Contains(id) ? null : input.Items.FirstOrDefault(item => item.Id == id && item.Kind == Shared.WordKind.Word))?.Text
                ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput)).ToArray();
        return (Texts(input.Window.LeftBridgeWordIds), Texts(input.Window.RightBridgeWordIds));
    }
    /// <summary>Whether <paramref name="text"/> begins with the leading bridge words and ends with the trailing ones, compared
    /// as the word check compares words (case, punctuation and tags aside). A wording that drops them can't be placed or priced.</summary>
    public static bool KeepsBridgeWords(string text, (IReadOnlyList<string> Leading, IReadOnlyList<string> Trailing) bridge)
    {
        var tokens = VoiceLabTakeQuality.Tokens(text);
        var leading = bridge.Leading.SelectMany(VoiceLabTakeQuality.Tokens).ToArray();
        var trailing = bridge.Trailing.SelectMany(VoiceLabTakeQuality.Tokens).ToArray();
        return tokens.Length > 0 && tokens.Take(leading.Length).SequenceEqual(leading) && tokens.TakeLast(trailing.Length).SequenceEqual(trailing);
    }
    public static byte[] EncodeQaWav(ReadOnlySpan<float> samples, int rate)
    {
        if (rate is < 8000 or > 96000 || samples.Length == 0 || samples.Length > (long)rate * MaximumQaSeconds)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var bytes = new byte[44 + samples.Length * 2];
        "RIFF"u8.CopyTo(bytes);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(4), bytes.Length - 8);
        "WAVEfmt "u8.CopyTo(bytes.AsSpan(8));
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(16), 16);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(20), 1);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(22), 1);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(24), rate);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(28), rate * 2);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(32), 2);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(34), 16);
        "data"u8.CopyTo(bytes.AsSpan(36));
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(40), samples.Length * 2);
        for (var index = 0; index < samples.Length; index++)
        {
            var sample = samples[index];
            if (!float.IsFinite(sample) || Math.Abs(sample) > 1) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(44 + index * 2), (short)Math.Round((double)sample * 32767, MidpointRounding.AwayFromZero));
        }
        return bytes;
    }
    private static int Frames(double seconds, int rate) => checked((int)Math.Floor(seconds * rate + 0.5));
    private static long SourceFrames(double seconds, int rate) => checked((long)Math.Floor(seconds * rate + 0.5));
}
