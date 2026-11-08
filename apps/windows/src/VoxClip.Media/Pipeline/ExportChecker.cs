using System.Diagnostics;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

/// <summary>The export self-check on an exported MP4 (ADR-R49; Mac <c>ExportChecker</c>): it reads both tracks' time ranges, decodes
/// the audio once with the Windows decoder for the shared ADR-R47 meter and, with a local engine, for a 16 kHz mono copy, transcribes
/// that copy locally, and runs <see cref="ExportCheck"/> against the render the export ran. Nothing leaves this PC: the engine is
/// the local Whisper, never a provider.</summary>
public sealed class ExportChecker
{
    /// <summary>A local engine and the plan it transcribes with.</summary>
    public sealed record Hearing(ITranscriber Transcriber, TranscriptionPlan Plan);

    /// <summary>The check's report and how long each part took, seconds: <paramref name="MeasureSeconds"/> the track read and the
    /// decode, <paramref name="HearSeconds"/> the local transcription (0 without one). <paramref name="Engine"/> and
    /// <paramref name="Model"/> name the engine that heard the export, null without one.</summary>
    public sealed record Outcome(ExportCheckReport Report, double MeasureSeconds, double HearSeconds, double TotalSeconds,
        TranscriptEngine? Engine, string? Model);

    private readonly Hearing? hearing;
    private readonly string scratch;
    private readonly string? sharedRoot;

    /// <summary>A checker that hears with <paramref name="hearing"/> (null skips the words), writes its 16 kHz copy under
    /// <paramref name="scratch"/> while the engine reads it, and lays titles out with the fonts under <paramref name="sharedRoot"/>.</summary>
    public ExportChecker(Hearing? hearing, string scratch, string? sharedRoot)
    {
        this.hearing = hearing; this.scratch = scratch; this.sharedRoot = sharedRoot;
    }

    /// <summary>The engine that hears an export of <paramref name="transcript"/>'s project, all local: Whisper with the project's own
    /// model when it is installed and verified, otherwise with any installed, verified Whisper model; the transcript's language first,
    /// then auto. Null when none is ready: the words check and phrase sync are then skipped. Never a provider.</summary>
    public static async Task<Hearing?> LocalHearingAsync(Transcript? transcript, IModelCatalog catalog, IReadOnlyList<InstalledModel> installed,
        ITranscriber whisper, CancellationToken ct)
    {
        if (whisper.Engine != TranscriptEngine.Whispercpp) throw new ArgumentException("The export check hears with Whisper only.", nameof(whisper));
        var spoken = transcript?.Language ?? "";
        LanguageChoice language = spoken.Length == 0 || spoken == "und" ? new LanguageChoice.Auto() : new LanguageChoice.Forced(spoken);
        var ready = installed.Where(model => model.Verified).Select(model => model.Id).ToList();
        var candidates = new List<string>();
        if (transcript?.Engine.Id == TranscriptEngine.Whispercpp && transcript.Engine.ModelId is { } own && ready.Contains(own)) candidates.Add(own);
        foreach (var id in ready.Where(id => !candidates.Contains(id)))
        {
            if (await catalog.GetModelAsync(id, ct).ConfigureAwait(false) is not { Engine: TranscriptEngine.Whispercpp } descriptor ||
                !descriptor.Files.Any(file => file.Role == "model")) continue;
            candidates.Add(id);
        }
        foreach (var model in candidates)
        {
            LanguageChoice[] choices = language is LanguageChoice.Auto ? [language] : [language, new LanguageChoice.Auto()];
            foreach (var choice in choices)
            {
                var plan = new TranscriptionPlan(TranscriptEngine.Whispercpp, model, choice, new());
                if (await whisper.SupportsAsync(choice, model, ct).ConfigureAwait(false) &&
                    await whisper.ReadinessAsync(plan, ct).ConfigureAwait(false) is Readiness.Ready)
                    return new(whisper, plan);
            }
        }
        return null;
    }

    /// <summary>Checks <paramref name="export"/> against <paramref name="snapshot"/> (the render the export ran, its captions laid out)
    /// and <paramref name="edit"/> (its words, phrases and cuts, <see cref="ExportCheckExpectation"/>), with the export's
    /// <paramref name="loudness"/> setting.</summary>
    public async Task<Outcome> CheckAsync(string export, ComposeSnapshot snapshot, ExportCheckExpectation.Edit edit, ExportLoudness loudness, CancellationToken ct)
    {
        var clock = Stopwatch.StartNew();
        using var file = await MediaThread.Run("vc-export-check-open", () => FfmpegExportFile.Open(export, ct), ct).ConfigureAwait(false);
        return await CheckAsync(file, snapshot, edit, loudness, clock, ct).ConfigureAwait(false);
    }

    /// <summary><see cref="CheckAsync(string, ComposeSnapshot, ExportCheckExpectation.Edit, ExportLoudness, CancellationToken)"/> on an
    /// opened <paramref name="file"/>; the caller disposes it. <paramref name="clock"/> started when the check did.</summary>
    internal async Task<Outcome> CheckAsync(IExportFile file, ComposeSnapshot snapshot, ExportCheckExpectation.Edit edit, ExportLoudness loudness,
        Stopwatch clock, CancellationToken ct)
    {
        Directory.CreateDirectory(scratch);
        var wav = Path.Combine(scratch, "export-check-" + Guid.NewGuid().ToString("N") + "-16k.wav");
        try
        {
            var measured = await MediaThread.Run("vc-export-check", () => Measure(file, snapshot.Output, hearing is null ? null : wav, ct), ct).ConfigureAwait(false);
            var measureSeconds = clock.Elapsed.TotalSeconds;
            IReadOnlyList<ExportCheckHeard>? heard = null;
            var skipped = ExportCheck.NoLocalEngine;
            if (hearing is not null && measured.HeardSamples is { } samples)
            {
                // An engine that fails (its model gone or unreadable) leaves the words unchecked, not the export.
                try { heard = await HearAsync(wav, samples, hearing, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { throw; }
                catch (VoxClipException error) when (error.Code == VoxClipErrorCode.Cancelled || ct.IsCancellationRequested) { throw; }
                catch (Exception) when (!ct.IsCancellationRequested) { skipped = "The local transcription failed"; }
            }
            else if (hearing is not null) skipped = "No audio track";
            var hearSeconds = heard is null ? 0 : clock.Elapsed.TotalSeconds - measureSeconds;
            var input = new ExportCheckInput(edit.Words, heard, measured.Video, measured.Audio, measured.FrameSeconds, measured.Loudness is { } meter
                ? new ExportCheckLoudness(loudness, meter.IntegratedLufs(), meter.TruePeakDbtp) : null, measured.Frame)
            {
                HearingSkipped = skipped, Cuts = edit.Cuts, Phrases = edit.Phrases,
                Boxes = [.. ExportCheckExpectation.CaptionBoxes(snapshot.Captions, snapshot.Output.Size, snapshot.Speed), .. TitleBoxes(snapshot, sharedRoot)],
            };
            return new(ExportCheck.Run(input), measureSeconds, hearSeconds, clock.Elapsed.TotalSeconds,
                heard is null ? null : hearing!.Plan.Engine, heard is null ? null : hearing!.Plan.Model);
        }
        finally { try { File.Delete(wav); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }

    /// <summary>Each title the render draws (Ask Claude's and the hook's), laid out by the compositor's own
    /// <see cref="EffectTitleLayout"/>, top-left origin, in fractions of the frame, from its first output second. Empty without the
    /// bundled title font.</summary>
    internal static IReadOnlyList<ExportCheckBox> TitleBoxes(ComposeSnapshot snapshot, string? sharedRoot)
    {
        if (snapshot.Clip?.Effects is not { } effects) return [];
        var titles = effects.Effects.Where(effect => effect.Kind == "title" && !string.IsNullOrEmpty(effect.Text)).ToArray();
        int width = snapshot.Output.Size.Width, height = snapshot.Output.Size.Height;
        if (titles.Length == 0 || width <= 0 || height <= 0) return [];
        using var frames = new EffectFrames(effects, sharedRoot);
        var boxes = new List<ExportCheckBox>();
        foreach (var title in titles)
        {
            if (frames.TitleLayout(title.Text!, title.Position ?? "top", width, height) is not { } layout) continue;
            var box = layout.Box;
            var time = snapshot.Speed.Rendered(snapshot.Timeline.MapTime(Math.Max(0, title.Start)));
            boxes.Add(new(ExportCheckBoxKind.Title, time, new((double)box.Left / width, (double)box.Top / height, (double)box.Width / width, (double)box.Height / height)));
        }
        return boxes;
    }

    private sealed record Measured(ExportCheckTrack? Video, ExportCheckTrack? Audio, double FrameSeconds, PixelSize Frame,
        SocialLoudnessMeasurement? Loudness, long? HeardSamples);

    /// <summary>The tracks' ranges and the frame from the file; the audio measured by the shared ADR-R47 meter at its own rate and
    /// channels and, with <paramref name="wav"/>, written there as 16 kHz mono PCM for the engine. The audio is read for its known
    /// length under a bounded token: the decoder pads with silence past the end and never returns 0.</summary>
    private static Measured Measure(IExportFile file, OutputSpec output, string? wav, CancellationToken ct)
    {
        var frameSeconds = file.FrameRate is { } fps && fps > 0 && double.IsFinite(fps) ? 1 / fps : 1 / Math.Max(1, output.FrameRate);
        var frame = file.Frame is { Width: > 0, Height: > 0 } size ? size : output.Size;
        if (file.Audio is not { } audio) return new(file.Video, null, frameSeconds, frame, null, null);
        var channels = file.Channels;
        if (file.SampleRate <= 0 || channels <= 0) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The export's audio has an unsupported format.");
        var total = Math.Max(0, (long)Math.Round((audio.End - audio.Start) * file.SampleRate, MidpointRounding.AwayFromZero));
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(ct);
        bounded.CancelAfter(TimeSpan.FromSeconds(60 + 2 * (audio.End - audio.Start)));
        var meter = new SocialLoudnessMeter(file.SampleRate, channels);
        var resampler = wav is null ? null : new SincResampler(file.SampleRate, 16_000);
        using var writer = wav is null ? null : new WaveWriter(wav, 16_000, 1, false);
        var block = Math.Max(1, file.SampleRate / 10);
        var samples = new float[block * channels];
        var mono = new float[block];
        try
        {
            for (long read = 0; read < total;)
            {
                var frames = (int)Math.Min(block, total - read);
                var got = file.Read(samples, frames, bounded.Token);
                if (got <= 0) throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The export's audio did not decode.");
                meter.Append(samples.AsSpan(0, got * channels));
                if (resampler is not null)
                {
                    for (var index = 0; index < got; index++)
                    {
                        var sum = 0f;
                        for (var channel = 0; channel < channels; channel++) sum += samples[index * channels + channel];
                        mono[index] = sum / channels;
                    }
                    writer!.Write(resampler.Process(mono.AsSpan(0, got)));
                }
                read += got;
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The export's audio took too long to decode.");
        }
        if (resampler is not null) writer!.Write(resampler.Finish());
        return new(file.Video, audio, frameSeconds, frame, meter.Finish(), writer?.Samples);
    }

    /// <summary>The words the local engine hears in the 16 kHz copy, with their times.</summary>
    private static async Task<IReadOnlyList<ExportCheckHeard>> HearAsync(string wav, long samples, Hearing hearing, CancellationToken ct)
    {
        if (samples <= 0) return [];
        var audio = new ExtractedAudio(wav, samples, samples / 16_000.0, 0, 0);
        RawTranscript raw;
        try { raw = await hearing.Transcriber.TranscribeAsync(new(hearing.Plan, audio, "export-check"), new Progress<TranscriptionProgress>(), ct).ConfigureAwait(false); }
        catch (VoxClipException error) when (error.Code == VoxClipErrorCode.NoSpeech) { return []; }
        var words = EditingImport.Pipeline(WordAssembler.Group(raw.Tokens, raw.Grouping, 0), null, raw.Timing, raw.Verbatim, audio.DurationSeconds).Words;
        return words.Where(word => word.Kind == WordKind.Word).Select(word => new ExportCheckHeard(word.Text, word.Start, word.End)).ToArray();
    }
}

/// <summary>What the export check reads from a file: both tracks' ranges, the frame, and the audio as interleaved float at the file's
/// own rate and channels.</summary>
internal interface IExportFile : IDisposable
{
    /// <summary>The video track's range, null without one.</summary>
    ExportCheckTrack? Video { get; }
    /// <summary>The audio track's range, null without one.</summary>
    ExportCheckTrack? Audio { get; }
    /// <summary>The video's frame rate, null without video.</summary>
    double? FrameRate { get; }
    /// <summary>The upright frame, null without video.</summary>
    PixelSize? Frame { get; }
    /// <summary>The audio's sample rate.</summary>
    int SampleRate { get; }
    /// <summary>The audio's channels.</summary>
    int Channels { get; }
    /// <summary>Exactly <paramref name="frames"/> frames into <paramref name="interleaved"/>; silence past the end.</summary>
    int Read(Span<float> interleaved, int frames, CancellationToken ct);
}

/// <summary>An exported file read through FFmpeg: the streams' ranges on the file's presentation timeline (its start time is 0) and
/// the audio through <see cref="AudioDecoder"/>.</summary>
internal sealed unsafe class FfmpegExportFile : IExportFile
{
    private readonly AudioDecoder? decoder;

    private FfmpegExportFile(ExportCheckTrack? video, ExportCheckTrack? audio, double? frameRate, PixelSize? frame, AudioDecoder? decoder)
    {
        Video = video; Audio = audio; FrameRate = frameRate; Frame = frame; this.decoder = decoder;
    }

    public ExportCheckTrack? Video { get; }
    public ExportCheckTrack? Audio { get; }
    public double? FrameRate { get; }
    public PixelSize? Frame { get; }
    public int SampleRate => decoder?.SampleRate ?? 0;
    public int Channels => decoder?.Channels ?? 0;

    internal static IExportFile Open(string path, CancellationToken ct)
    {
        FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult();
        ExportCheckTrack? video = null, audio = null;
        double? rate = null;
        PixelSize? frame = null;
        using (var handle = NativeHandle.Own(Native.Open(path), NativeKind.Input))
        {
            var format = (AVFormatContext*)handle.Pointer;
            var origin = format->start_time == ffmpeg.AV_NOPTS_VALUE ? 0 : format->start_time / (double)ffmpeg.AV_TIME_BASE;
            var fileDuration = format->duration == ffmpeg.AV_NOPTS_VALUE ? (double?)null : format->duration / (double)ffmpeg.AV_TIME_BASE;
            ExportCheckTrack? Range(int index)
            {
                if (index < 0) return null;
                var stream = format->streams[index];
                var start = (stream->start_time == ffmpeg.AV_NOPTS_VALUE ? origin : Native.Seconds(stream->start_time, stream->time_base)) - origin;
                double? length = stream->duration == ffmpeg.AV_NOPTS_VALUE ? fileDuration - start : Native.Seconds(stream->duration, stream->time_base);
                if (length is not { } seconds || !double.IsFinite(start) || !double.IsFinite(seconds))
                    throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "The export's track has no time range.");
                return new(start, start + seconds);
            }
            var videoIndex = Native.Stream(format, AVMediaType.AVMEDIA_TYPE_VIDEO);
            var audioIndex = Native.Stream(format, AVMediaType.AVMEDIA_TYPE_AUDIO);
            video = Range(videoIndex);
            audio = Range(audioIndex);
            if (videoIndex >= 0)
            {
                var stream = format->streams[videoIndex];
                var guessed = ffmpeg.av_guess_frame_rate(format, stream, null);
                if (guessed.den != 0 && guessed.num > 0) rate = ffmpeg.av_q2d(guessed);
                var parameters = stream->codecpar;
                frame = FfmpegMediaProbe.Rotation(parameters) is 90 or 270 ? new PixelSize(parameters->height, parameters->width)
                    : new PixelSize(parameters->width, parameters->height);
            }
        }
        return new FfmpegExportFile(video, audio, rate, frame, audio is null ? null : new AudioDecoder(path));
    }

    public int Read(Span<float> interleaved, int frames, CancellationToken ct) => decoder!.Read(interleaved, frames, ct);

    public void Dispose() => decoder?.Dispose();
}
