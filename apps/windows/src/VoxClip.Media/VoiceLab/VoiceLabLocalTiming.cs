using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;

namespace VoxClip.Media.VoiceLab;

/// <summary>Word timing for a take's own PCM from an on-device transcriber: the free fallback of voice-lab §8.5 "Timing
/// recovery" when neither the provider's timing nor the take's Scribe word check gives usable word times (Mac
/// <c>VoiceLabLocalTiming</c>). Arguments: mono samples, their rate, the take's language. Throws when no on-device engine is
/// ready.</summary>
public delegate Task<IReadOnlyList<VoiceLabWord>> VoiceLabLocalTiming(float[] samples, int rate, string language, CancellationToken ct);

/// <summary>The on-device timing sources the take run may fall back to.</summary>
public static class VoiceLabLocalTimingSource
{
    /// <summary>The first installed local Whisper model that is ready for the language (Mac also tries Apple Speech first;
    /// Windows.Media.SpeechRecognition gives no word timings without a download, so it is not a source). Never downloads a model
    /// and never prompts (<see cref="OnDeviceTakeTranscriber"/>).</summary>
    public static VoiceLabLocalTiming OnDevice(ITranscriber transcriber, Func<CancellationToken, Task<IReadOnlyList<string>>> installedModels, string scratch)
    {
        // One on-device recognizer for timing recovery and for the user's own microphone takes.
        var heard = new OnDeviceTakeTranscriber(transcriber, installedModels, scratch);
        return async (samples, rate, language, ct) =>
        {
            if (rate <= 0 || samples.Length == 0) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            try
            {
                var (_, words) = await heard.WordsAsync(Resample(samples, rate, 16000), language, ct).ConfigureAwait(false);
                return words.Select(word => new VoiceLabWord(word.Text, word.Start, word.End, true)).ToArray().AsReadOnly();
            }
            catch (MicrophoneTakeException) { throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment); }
        };
    }

    /// <summary>The transcript's spoken words with their times; events are not words, and a token that joins the previous
    /// one extends it.</summary>
    public static IReadOnlyList<VoiceLabWord> Words(RawTranscript raw)
    {
        var result = new List<VoiceLabWord>();
        foreach (var token in raw.Tokens)
        {
            if (token.Kind == WordKind.Event || token.Start is not { } start || token.End is not { } end ||
                !double.IsFinite(start) || !double.IsFinite(end) || end < start) continue;
            var text = token.Text.Trim();
            if (text.Length == 0) continue;
            if (token.JoinsPrevious && result.Count > 0)
                result[^1] = new(result[^1].Text + text, result[^1].Start, Math.Max(result[^1].End, end), true);
            else result.Add(new(text, start, end, true));
        }
        return result.AsReadOnly();
    }

    /// <summary>Linear interpolation, enough for word timing.</summary>
    public static float[] Resample(float[] samples, int rate, int target)
    {
        if (rate == target) return samples;
        var count = (int)Math.Floor((double)samples.Length * target / rate);
        var ratio = (double)rate / target;
        var result = new float[count];
        for (var index = 0; index < count; index++)
        {
            var position = index * ratio;
            var lower = Math.Min(samples.Length - 1, (int)position);
            var upper = Math.Min(samples.Length - 1, lower + 1);
            result[index] = samples[lower] + (samples[upper] - samples[lower]) * (float)(position - lower);
        }
        return result;
    }
}
