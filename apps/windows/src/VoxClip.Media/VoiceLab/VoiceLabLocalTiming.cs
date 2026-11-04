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
    /// Windows speech recognition is an App-level WinRT engine and joins with the App's own-take package). Never downloads
    /// a model and never prompts. The 16 kHz WAV lives in <paramref name="scratch"/> only while it is transcribed.</summary>
    public static VoiceLabLocalTiming OnDevice(ITranscriber transcriber, Func<CancellationToken, Task<IReadOnlyList<string>>> installedModels, string scratch) =>
        async (samples, rate, language, ct) =>
        {
            if (rate <= 0 || samples.Length == 0) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            var resampled = Resample(samples, rate, 16000);
            var choice = new LanguageChoice.Forced(language);
            foreach (var model in await installedModels(ct).ConfigureAwait(false))
            {
                var plan = new TranscriptionPlan(transcriber.Engine, model, choice, new());
                if (await transcriber.ReadinessAsync(plan, ct).ConfigureAwait(false) is not Readiness.Ready) continue;
                Directory.CreateDirectory(scratch);
                var path = Path.Combine(scratch, "timing-" + Guid.NewGuid().ToString("N") + ".wav");
                try
                {
                    await File.WriteAllBytesAsync(path, VoiceLabTakeProcessing.EncodeQaWav(resampled, 16000), ct).ConfigureAwait(false);
                    var audio = new ExtractedAudio(path, resampled.Length, resampled.Length / 16000.0, 0, 0);
                    var raw = await transcriber.TranscribeAsync(new(plan, audio, "voice-lab-timing"), new Progress<TranscriptionProgress>(), ct).ConfigureAwait(false);
                    return Words(raw);
                }
                finally { try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
            }
            throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
        };

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
