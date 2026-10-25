using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

/// <summary>Streaming native-rate analysis and mono16k extraction; architecture §4 and §8.</summary>
public sealed class FfmpegAudioExtractor : IAudioExtractor
{
    /// <inheritdoc />
    public Task<AudioExtractionResult> ExtractAsync(AudioExtractionRequest request, IProgress<MediaProgress>? progress, CancellationToken ct)
        => MediaThread.Run("vc-audio-extract", () => Extract(request, progress, ct), ct);

    private static unsafe AudioExtractionResult Extract(AudioExtractionRequest request, IProgress<MediaProgress>? progress, CancellationToken ct)
    {
        FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult();
        if (request.Media.Audio is null) throw new VoxClipException(VoxClipErrorCode.NoAudioTrack, "This video has no audio track, so there is nothing to transcribe.");
        Directory.CreateDirectory(request.CacheDirectory);
        var wav = Path.Combine(request.CacheDirectory, "audio-16k.wav");
        var envelope = Path.Combine(request.CacheDirectory, "envelope-10ms.f32");
        var suffix = "." + Guid.NewGuid().ToString("N") + ".partial";
        var pcmTemporary = wav + suffix;
        var envelopeTemporary = envelope + suffix;
        try
        {
            using var audio = new AudioDecoder(request.Media.Path);
            var rate = audio.SampleRate;
            var channels = audio.Channels;
            var frameSize = Math.Max(1, (int)Native.Round(rate * 0.01));
            var total = Native.Round(request.Media.DurationSeconds * rate);
            var expected = Native.Round(request.Media.DurationSeconds * 16_000);
            var analysis = new AudioEnvelopeBuilder(rate, channels);
            var input = new float[frameSize * channels];
            var output = new float[(int)Math.Ceiling(frameSize * 16000.0 / rate) + 256];
            var inputLayout = new AVChannelLayout();
            var outputLayout = new AVChannelLayout();
            ffmpeg.av_channel_layout_default(&inputLayout, channels);
            ffmpeg.av_channel_layout_default(&outputLayout, 1);
            SwrContext* context = null;
            try
            {
                Native.Check(ffmpeg.swr_alloc_set_opts2(&context, &outputLayout, AVSampleFormat.AV_SAMPLE_FMT_FLT, 16000,
                    &inputLayout, AVSampleFormat.AV_SAMPLE_FMT_FLT, rate, 0, null), "Configure mono audio extraction");
            }
            finally { ffmpeg.av_channel_layout_uninit(&inputLayout); ffmpeg.av_channel_layout_uninit(&outputLayout); }
            using var resample = NativeHandle.Own(context, NativeKind.Resample);
            var matrix = Enumerable.Repeat(1.0 / channels, channels).ToArray();
            fixed (double* coefficients = matrix)
                Native.Check(ffmpeg.swr_set_matrix(context, coefficients, channels), "Set equal-weight mono downmix");
            Native.Check(ffmpeg.swr_init(context), "Initialize mono audio extraction");
            var stopwatch = Stopwatch.StartNew();
            var lastProgress = -1.0;
            using (var writer = new WaveWriter(pcmTemporary, 16000, 1, false))
            {
                for (long offset = 0; offset < total; offset += frameSize)
                {
                    ct.ThrowIfCancellationRequested();
                    var count = (int)Math.Min(frameSize, total - offset);
                    audio.Read(input, count, ct);
                    analysis.Append(input.AsSpan(0, count * channels));
                    fixed (float* inputPointer = input)
                    fixed (float* outputPointer = output)
                    {
                        var source = (byte*)inputPointer; var destination = (byte*)outputPointer;
                        var converted = ffmpeg.swr_convert(context, &destination, output.Length, &source, count);
                        Native.Check(converted, "Resample transcription audio");
                        writer.Write(output.AsSpan(0, (int)Math.Min(converted, expected - writer.Samples)));
                    }
                    if (stopwatch.Elapsed.TotalSeconds - lastProgress >= 0.1)
                    { progress?.Report(new("extracting", (double)offset / total)); lastProgress = stopwatch.Elapsed.TotalSeconds; }
                }
                fixed (float* outputPointer = output)
                {
                    var destination = (byte*)outputPointer;
                    while (writer.Samples < expected)
                    {
                        ct.ThrowIfCancellationRequested();
                        var count = ffmpeg.swr_convert(context, &destination, output.Length, null, 0);
                        Native.Check(count, "Drain transcription resampler");
                        if (count == 0) output.AsSpan().Clear();
                        writer.Write(output.AsSpan(0, (int)Math.Min(count == 0 ? output.Length : count, expected - writer.Samples)));
                    }
                }
            }
                    ct.ThrowIfCancellationRequested();
            var resultEnvelope = analysis.Finish();
            using (var levels = new BinaryWriter(File.Create(envelopeTemporary)))
                foreach (var level in resultEnvelope.Rms) levels.Write(level);
            File.Move(pcmTemporary, wav, true); File.Move(envelopeTemporary, envelope, true);
            var now = DateTimeOffset.UtcNow;
            var metadata = new AudioCacheMetadata("voxclip-cache/1", request.ContentKey, now, now,
                new FileInfo(wav).Length + new FileInfo(envelope).Length, new(rate, 0.01, resultEnvelope.Rms.Count));
            var meta = Path.Combine(request.CacheDirectory, "meta.json");
            File.WriteAllText(meta + suffix, JsonSerializer.Serialize(metadata, AudioCacheJson.Default.AudioCacheMetadata));
            File.Move(meta + suffix, meta, true);
            return new(new(wav, expected, expected / 16000.0, 0, request.Media.AudioTrackIndex), resultEnvelope);
        }
        finally { File.Delete(pcmTemporary); File.Delete(envelopeTemporary); File.Delete(Path.Combine(request.CacheDirectory, "meta.json") + suffix); }
    }
}

internal sealed record AudioCacheMetadata(string Schema, string ContentKey, DateTimeOffset CreatedAt, DateTimeOffset LastAccessAt, long Bytes, EnvelopeMetadata Envelope);
internal sealed record EnvelopeMetadata(int SampleRate, double FrameSeconds, int Count);
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(AudioCacheMetadata))]
internal partial class AudioCacheJson : JsonSerializerContext;
