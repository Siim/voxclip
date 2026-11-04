using System.Buffers.Binary;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;

namespace VoxClip.Media.VoiceLab;

/// <summary>Hears the words of a microphone take on this PC, with their timing from the start of the recording (Mac
/// <c>MicrophoneTakeTranscribing</c>).</summary>
public interface IMicrophoneTakeTranscriber
{
    /// <summary><paramref name="samples"/> are mono 16 kHz. Returns the recognizer's model name with the words; no words means no
    /// speech. Throws <see cref="MicrophoneTakeException"/> with <see cref="MicrophoneTakeError.TranscriptionUnavailable"/> when no
    /// on-device recognizer is ready.</summary>
    Task<(string Model, IReadOnlyList<VoiceLabSpokenWord> Words)> WordsAsync(float[] samples, string language, CancellationToken ct);
}

/// <summary>Why a microphone take could not be made.</summary>
public enum MicrophoneTakeError
{
    /// <summary>The recognizer heard no words.</summary>
    NoSpeech,
    /// <summary>No on-device recognizer is ready for the project's language.</summary>
    TranscriptionUnavailable
}

/// <summary>A microphone take failure with no recording content in its message.</summary>
public sealed class MicrophoneTakeException(MicrophoneTakeError error) : Exception(error.ToString())
{
    /// <summary>The failure.</summary>
    public MicrophoneTakeError Error { get; } = error;
}

/// <summary>A phrase's microphone take, checked on this PC (design.md §6.3.8 "Say it myself", voice-lab.md §8.13; Mac
/// <c>MicrophoneTake</c>). <see cref="Input"/> is the phrase's input with the recognized words as its text: what the take says.</summary>
public sealed record VoiceLabRecordedPhraseTake(VoiceLabTakeRow Row, VoiceLabTakeScratch Scratch, VoiceLabTakeInput Input,
    IReadOnlyList<VoiceLabSpokenWord> Words, string Model, double RecordedSeconds, VoiceLabTakeStorage Storage)
{
    /// <summary>The recognized words.</summary>
    public string Text => Input.Text;
}

/// <summary>Makes a microphone take from the user's recording (Mac <c>MicrophoneTakeMaker</c>): the on-device recognizer gives its
/// words and timings, the take is trimmed to the speech, its loudness is matched to the source beside the window, and it is fitted
/// and joined as a generated take is, with the word, clipping and join checks. Nothing leaves the PC: the recording is written to the
/// project's Voice Lab asset folder only. The row has no receipt, quote or speaker score (<see cref="VoiceLabTakeQaResult.SpeakerUnmeasured"/>),
/// so Core stores it as a <c>recorded</c> segment.</summary>
public static class MicrophoneTakeMaker
{
    /// <summary>The take's asset rate.</summary>
    public const int AssetRate = 24_000;

    /// <summary>Makes the take. <paramref name="input"/> is the phrase as planned; its room tone and source level are the take's.</summary>
    public static async Task<VoiceLabRecordedPhraseTake> MakeAsync(float[] samples, int sampleRate, VoiceLabTakeInput input,
        IMicrophoneTakeTranscriber transcriber, VoiceLabTakeStorage storage, Guid id, DateTimeOffset date, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(samples); ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(transcriber); ArgumentNullException.ThrowIfNull(storage);
        if (sampleRate <= 0 || samples.Length == 0 || samples.Any(sample => !float.IsFinite(sample))) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var clamped = samples.Select(sample => Math.Clamp(sample, -1f, 1f)).ToArray();
        var heard = await transcriber.WordsAsync(VoiceConsentAudio.Resample(clamped, sampleRate), input.Language, ct).ConfigureAwait(false);
        var words = heard.Words.Where(word => word.Text.Trim().Length > 0 && word.End > word.Start).ToArray();
        if (words.Length == 0) throw new MicrophoneTakeException(MicrophoneTakeError.NoSpeech);
        var text = string.Join(" ", words.Select(word => word.Text.Trim()));
        var spoken = input with { Text = text, Seed = 0, Pace = null, AudioTags = [] };
        var audio = VoiceLabLocalTimingSource.Resample(clamped, sampleRate, AssetRate).Select(sample => Math.Clamp(sample, -1f, 1f)).ToArray();
        var duration = audio.Length / (double)AssetRate;
        var timed = words.Select(word => new VoiceLabSpokenWord(word.Text.Trim(), Math.Min(word.Start, duration), Math.Min(word.End, duration))).ToArray();
        var pcm = new byte[audio.Length * 2];
        for (var index = 0; index < audio.Length; index++)
            BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(index * 2), (short)Math.Clamp(Math.Round(audio[index] * 32767.0), -32768, 32767));
        var receipt = new VoiceLabReceipt(VoiceLabRecordedTake.Provider, ElevenLabsRegion.Default, VoiceLabRecordedTake.Endpoint, null, null, id, null, null);
        var result = new VoiceLabAudioResult(pcm, AssetRate, VoiceLabRecordedTake.Alignment(timed), receipt);
        // The room tone and source level come from the phrase as planned; the take itself says the recognized words.
        var preflight = VoiceLabTakeProcessing.Preflight(input);
        var analysis = VoiceLabTakeProcessing.Process(result, spoken, preflight);
        Directory.CreateDirectory(storage.ScratchRoot);
        var asset = VoiceLabAssetStore.Write(pcm, AssetRate, storage.ProjectId, Guid.NewGuid().ToString("D"), storage.PaidRoot, date);
        var snapshot = await VoiceLabAssets.PreparePaidAsync(asset, storage.ProjectId, storage.PaidRoot, storage.ScratchRoot, ct).ConfigureAwait(false);
        VoiceLabTakeScratch? scratch = null;
        try
        {
            var fitted = VoiceLabSilenceFit.Prepare(snapshot, asset, analysis.Fit, spoken.Window, spoken.SourceSampleRate, ct);
            var source = VoiceLabSourceAudio.Resample(spoken.Source, spoken.SourceSampleRate, VoiceLabSourceAudio.TakeAssetRate);
            scratch = VoiceLabTakeRenderer.Stage(fitted, analysis, spoken, source, storage.ScratchRoot, ct);
            var staged = scratch.Audio;
            // The words are what was said, so the word check passes by construction; clipping and the joins are measured. A recorded
            // take is the user's own voice: it has no speaker score.
            var qa = VoiceLabTakeQuality.Evaluate(text, timed.Select(word => word.Text).ToArray(), staged.Mixed, staged.SampleRate, staged.Seams, null, 0,
                staged.Seams.Select(seam => seam == staged.PatchStart).ToArray(), staged.SeamExcesses, false,
                VoiceLabTakeQuality.ReplacementWords(text, spoken.Items, spoken.Window)) with { SpeakerUnmeasured = true };
            var rank = VoiceLabTakeQuality.Rank(staged.Fit, spoken.Window.End - spoken.Window.Start, qa.TranscriptMatch ?? 0,
                VoiceLabLoudness.Flatness(staged.Trimmed, staged.SampleRate));
            var row = new VoiceLabTakeRow(id, 0, 0, Audio: staged, Qa: qa, Score: rank);
            return new(row, scratch, spoken, timed, heard.Model, samples.Length / (double)sampleRate, storage);
        }
        catch
        {
            if (scratch is not null) await scratch.InvalidateAsync().ConfigureAwait(false);
            else await snapshot.InvalidateAsync().ConfigureAwait(false);
            throw;
        }
    }

    /// <summary>The take's audio as a project asset, at Use.</summary>
    public static VoiceLabPublishedTake Publish(VoiceLabRecordedPhraseTake take, DateTimeOffset date, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(take);
        if (!take.Scratch.IsValid) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var publication = take.Scratch.Fitted.Publish(take.Storage.ProjectId, Guid.NewGuid().ToString("D"), take.Storage.PaidRoot, date,
            take.Row.Id.ToString("D"), 0, take.Scratch.Audio.GainDb, ct);
        return new(publication.Assets, publication.Audio, publication.OutDuration, publication.Words, publication.Chunks);
    }
}

/// <summary>Words heard on this PC by an installed, verified Whisper model (Mac <c>OnDeviceTakeTranscriber</c>, which tries Apple
/// Speech first). Windows.Media.SpeechRecognition gives no word timings without a download, so it is not a source. Never downloads
/// a model and never prompts; the 16 kHz WAV lives in the scratch folder only while it is transcribed.</summary>
public sealed class OnDeviceTakeTranscriber(ITranscriber transcriber, Func<CancellationToken, Task<IReadOnlyList<string>>> installedModels, string scratch)
    : IMicrophoneTakeTranscriber
{
    /// <inheritdoc/>
    public async Task<(string Model, IReadOnlyList<VoiceLabSpokenWord> Words)> WordsAsync(float[] samples, string language, CancellationToken ct)
    {
        if (samples.Length == 0) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var choice = new LanguageChoice.Forced(language);
        foreach (var model in await installedModels(ct).ConfigureAwait(false))
        {
            var plan = new TranscriptionPlan(transcriber.Engine, model, choice, new());
            if (await transcriber.ReadinessAsync(plan, ct).ConfigureAwait(false) is not Readiness.Ready) continue;
            Directory.CreateDirectory(scratch);
            var path = Path.Combine(scratch, "heard-" + Guid.NewGuid().ToString("N") + ".wav");
            try
            {
                await File.WriteAllBytesAsync(path, VoiceLabTakeProcessing.EncodeQaWav(samples, 16000), ct).ConfigureAwait(false);
                var audio = new ExtractedAudio(path, samples.Length, samples.Length / 16000.0, 0, 0);
                var raw = await transcriber.TranscribeAsync(new(plan, audio, "voice-lab-heard"), new Progress<TranscriptionProgress>(), ct).ConfigureAwait(false);
                return ("whisper " + model, VoiceLabLocalTimingSource.Words(raw).Select(word => new VoiceLabSpokenWord(word.Text, word.Start, word.End)).ToArray());
            }
            finally { try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
        }
        throw new MicrophoneTakeException(MicrophoneTakeError.TranscriptionUnavailable);
    }
}
