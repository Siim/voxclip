using System.Buffers.Binary;
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
        if (!input.ProviderConsent || string.IsNullOrEmpty(input.ContentKey) || string.IsNullOrEmpty(input.Text) || input.Text.EnumerateRunes().Count() > 5000 ||
            rate is < 8000 or > 96000 || input.Source.Length == 0 || input.Source.Any(sample => !float.IsFinite(sample)) ||
            window.StartSample < 0 || window.EndSample > input.Source.Length || window.EndSample <= window.StartSample ||
            !double.IsFinite(window.Start) || !double.IsFinite(window.End) || window.Start < 0 || window.End <= window.Start ||
            window.End > input.Source.Length / (double)rate || Frames(window.Start, rate) != window.StartSample || Frames(window.End, rate) != window.EndSample)
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var tokens = VoiceLabTakeQuality.Tokens(input.Text);
        string[] Bridge(IReadOnlyList<string> ids) => ids.SelectMany(id =>
        {
            var word = input.Items.FirstOrDefault(item => item.Id == id && item.Kind == Shared.WordKind.Word && !input.CutWordIds.Contains(id))
                ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            return VoiceLabTakeQuality.Tokens(word.Text);
        }).ToArray();
        var leading = Bridge(window.LeftBridgeWordIds);
        var trailing = Bridge(window.RightBridgeWordIds);
        if (tokens.Length == 0 || !tokens.Take(leading.Length).SequenceEqual(leading) || !tokens.TakeLast(trailing.Length).SequenceEqual(trailing))
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var level = VoiceLabLoudness.NeighbourhoodVoicedRmsDb(input.Source, rate, (int)window.StartSample, (int)window.EndSample);
        var tone = input.CleanAudioOn ? null : VoiceLabRoomToneSelection.Select(input.Items, Envelope(input.Source, rate), rate, input.Source.Length);
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
        var trim = VoiceLabAlignment.Trim(words, samples.Length / (double)rate);
        var lower = Frames(trim.Start, rate);
        var upper = Frames(trim.End, rate);
        if (lower < 0 || upper > samples.Length || upper <= lower) throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
        var trimmed = samples[lower..upper];
        var gain = VoiceLabLoudness.LevelGainDb(preflight.SourceLevel, VoiceLabLoudness.VoicedRmsDb(trimmed, rate), VoiceLabLoudness.TruePeakDbtp(trimmed, rate));
        var take = new VoiceLabFitTake(samples.Length, rate, trim.Start, trim.End, words, Envelope(samples, rate));
        var fit = VoiceLabFitPlanner.Plan(input.Window, input.IncomingSilence, input.OutgoingSilence, take, words.Select(word => word.Text).ToArray(), input.SourceSampleRate);
        return new(rate, trimmed, gain, preflight.RoomTone, fit);
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
}
