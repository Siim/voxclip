#pragma warning disable CS1591
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using FFmpeg.AutoGen;
using Microsoft.Win32.SafeHandles;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;

namespace VoxClip.Media.VoiceLab;

public enum VoiceLabSourceAudioErrorCode
{
    UnsupportedRate, RateMismatch, RangeOutsideMedia, TooShort, TooLong, TooLarge,
    NoAudioTrack, Unreadable, UnsupportedFormat, InvalidAudio, Altered
}

public sealed class VoiceLabSourceAudioException(VoiceLabSourceAudioErrorCode code) : Exception(Explain(code))
{
    public VoiceLabSourceAudioErrorCode Code { get; } = code;
    private static string Explain(VoiceLabSourceAudioErrorCode code) => code switch
    {
        VoiceLabSourceAudioErrorCode.UnsupportedRate => "This audio's sample rate is outside the range Voice Lab supports.",
        VoiceLabSourceAudioErrorCode.RateMismatch => "The source audio's sample rate differs from the project. Reopen the original source.",
        VoiceLabSourceAudioErrorCode.RangeOutsideMedia => "The selected range is not inside the source audio.",
        VoiceLabSourceAudioErrorCode.TooShort => "Select at least 20 ms of audio to convert.",
        VoiceLabSourceAudioErrorCode.TooLong => "A voice changer request holds at most 290 seconds of audio.",
        VoiceLabSourceAudioErrorCode.TooLarge => "This audio exceeds the size Voice Lab can upload or decode.",
        VoiceLabSourceAudioErrorCode.NoAudioTrack => "The source has no audio track.",
        VoiceLabSourceAudioErrorCode.UnsupportedFormat => "This build cannot decode this audio format.",
        VoiceLabSourceAudioErrorCode.InvalidAudio => "The audio contains samples Voice Lab cannot use.",
        VoiceLabSourceAudioErrorCode.Altered => "The generated Voice Lab audio has changed. Restore the original paid file.",
        _ => "The audio cannot be read. Check that the file is still available."
    };
}

/// <summary>Source-grid voice-changer input (§7.2–7.3) and paid-asset samples for Core's conform and QA (§4.4).</summary>
public static class VoiceLabSourceAudio
{
    internal const int UploadLimit = 50_000_000;
    private const long MaxBytes = 8L * 1024 * 1024 * 1024;
    private const long MaxDecodedFrames = 192_000L * 86_400;

    /// <summary>Complete mono PCM16 WAV for exactly [startSample, endSample), without resampling.</summary>
    public static async Task<byte[]> ConversionInputAsync(string source, long startSample, long endSample,
        double sourceSampleRate, CancellationToken cancellationToken = default)
    {
        var (rate, frames) = ConversionChunk(startSample, endSample, sourceSampleRate);
        return await MediaThread.Run("vc-voice-input", () =>
        {
            try
            {
                FfmpegLoader.InitializeAsync(cancellationToken).GetAwaiter().GetResult();
                var wav = new byte[44 + frames * 2];
                VoiceLabAssetStore.WavHeader(frames, rate).CopyTo(wav, 0);
                Decode(source, rate, startSample, endSample, (samples, first) =>
                {
                    for (var index = 0; index < samples.Length; index++)
                        BinaryPrimitives.WriteInt16LittleEndian(wav.AsSpan(44 + checked((int)(first - startSample) + index) * 2), VoiceLabAssetStore.Pcm16(samples[index]));
                }, cancellationToken);
                return wav;
            }
            catch (VoxClipException failure) when (failure.Code == VoxClipErrorCode.NoAudioTrack)
            { throw Failure(VoiceLabSourceAudioErrorCode.NoAudioTrack); }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or VoxClipException)
            { throw Failure(VoiceLabSourceAudioErrorCode.Unreadable); }
        }, cancellationToken).ConfigureAwait(false);
    }

    internal static (int Rate, int Frames) ConversionChunk(long startSample, long endSample, double sourceSampleRate)
    {
        if (!double.IsFinite(sourceSampleRate) || Math.Round(sourceSampleRate) != sourceSampleRate || sourceSampleRate is < 8_000 or > 96_000)
            throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedRate);
        var rate = (int)sourceSampleRate;
        if (startSample < 0 || endSample <= startSample) throw Failure(VoiceLabSourceAudioErrorCode.RangeOutsideMedia);
        var frames = endSample - startSample;
        if (frames < (rate + 49) / 50) throw Failure(VoiceLabSourceAudioErrorCode.TooShort);
        if (frames > 290L * rate) throw Failure(VoiceLabSourceAudioErrorCode.TooLong);
        if (44 + 2 * frames >= UploadLimit) throw Failure(VoiceLabSourceAudioErrorCode.TooLarge);
        return (rate, (int)frames);
    }

    /// <summary>Decodes only a private snapshot of a regular paid WAV; optional SHA-256 binds it to its project record.</summary>
    public static float[] DecodeAsset(string path, int targetSampleRate, string? expectedSha256 = null,
        CancellationToken cancellationToken = default)
        => DecodeAsset(path, targetSampleRate, expectedSha256, cancellationToken, null);

    internal static float[] DecodeAsset(string path, int targetSampleRate, string? expectedSha256,
        CancellationToken cancellationToken, Action<string>? afterCheck)
    {
        if (targetSampleRate is < 8_000 or > 192_000) throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedRate);
        if (Path.GetExtension(path) != ".wav") throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedFormat);
        string? scratch = null;
        try
        {
            using var source = OpenSource(path);
            if (!source.CanSeek || source.Length <= 0) throw Failure(VoiceLabSourceAudioErrorCode.Unreadable);
            var length = source.Length;
            if (length > MaxBytes) throw Failure(VoiceLabSourceAudioErrorCode.TooLarge);
            scratch = Directory.CreateTempSubdirectory("voxclip-voice-decode-").FullName;
            if (!OperatingSystem.IsWindows()) System.IO.File.SetUnixFileMode(scratch, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var snapshot = Path.Combine(scratch, "asset.wav");
            var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var copy = new FileStream(snapshot, options))
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                afterCheck?.Invoke(snapshot);
                var buffer = new byte[1024 * 1024];
                long copied = 0;
                while (true)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var count = source.Read(buffer);
                    if (count == 0) break;
                    copied += count;
                    if (copied > length) throw Failure(VoiceLabSourceAudioErrorCode.Altered);
                    hash.AppendData(buffer, 0, count); copy.Write(buffer, 0, count);
                }
                if (copied != length || expectedSha256 is not null && Convert.ToHexStringLower(hash.GetHashAndReset()) != expectedSha256)
                    throw Failure(VoiceLabSourceAudioErrorCode.Altered);
            }
            FfmpegLoader.InitializeAsync(cancellationToken).GetAwaiter().GetResult();
            var mono = new List<float>();
            var sourceRate = Decode(snapshot, null, 0, null, (samples, _) => mono.AddRange(samples), cancellationToken);
            return sourceRate == targetSampleRate ? mono.ToArray() : Resample(mono.ToArray(), sourceRate, targetSampleRate, cancellationToken);
        }
        catch (VoxClipException failure) when (failure.Code == VoxClipErrorCode.NoAudioTrack)
        { throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedFormat); }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or NotSupportedException or VoxClipException)
        { throw Failure(VoiceLabSourceAudioErrorCode.Unreadable); }
        finally { if (scratch is not null) Directory.Delete(scratch, true); }
    }

    /// <summary>The exact Core 10 ms mono RMS envelope, omitting the final partial frame.</summary>
    public static AudioEnvelope Envelope(ReadOnlySpan<float> samples, int sampleRate)
    {
        var builder = new AudioEnvelopeBuilder(sampleRate, 1);
        builder.Append(samples);
        return builder.Finish();
    }

    internal delegate void SampleBlock(ReadOnlySpan<float> samples, long first);

    /// <summary>The first audio track's mono mix (the mean of its channels) at the source rate, from sample 0 in decode order, for
    /// own-voice training (§6.5.1): one streamed pass that stops once <paramref name="more"/> refuses the next sample index. The
    /// decoded rate must equal <paramref name="rate"/> (8–96 kHz), and it is returned; missing media and decode failures are refused.</summary>
    internal static Task<int> TrainingMixAsync(string source, int rate, SampleBlock consume, Func<long, bool>? more, CancellationToken ct)
        => MediaThread.Run("voice-training-audio", () =>
        {
            if (rate is < 8_000 or > 96_000) throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedRate);
            try
            {
                FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult();
                return Decode(source, rate, 0, null, consume, ct, more);
            }
            catch (VoxClipException failure) when (failure.Code == VoxClipErrorCode.NoAudioTrack)
            { throw Failure(VoiceLabSourceAudioErrorCode.NoAudioTrack); }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or VoxClipException)
            { throw Failure(VoiceLabSourceAudioErrorCode.Unreadable); }
        }, ct);

    private static unsafe int Decode(string path, int? expectedRate, long start, long? end, SampleBlock consume, CancellationToken ct,
        Func<long, bool>? more = null)
    {
        using var decoder = OpenDecoder(path, end.HasValue);
        var rate = decoder.Codec->sample_rate;
        var channels = decoder.Codec->ch_layout.nb_channels;
        if (expectedRate is { } expected && rate != expected) throw Failure(VoiceLabSourceAudioErrorCode.RateMismatch);
        if (rate is < 8_000 or > 192_000) throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedRate);
        if (channels < 1 || !end.HasValue && channels > 8) throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedFormat);
        if (end.HasValue && decoder.Format->duration >= 0)
        {
            var sourceFrames = decoder.Format->duration * (double)rate / ffmpeg.AV_TIME_BASE;
            if (end.Value > Math.Floor(sourceFrames + 0.5)) throw Failure(VoiceLabSourceAudioErrorCode.RangeOutsideMedia);
            if (start > 0) decoder.Seek(Math.Max(0, start / (double)rate - 0.5));
        }
        long next = start;
        long? previousEnd = null;
        NativeHandle? converter = null;
        var format = AVSampleFormat.AV_SAMPLE_FMT_NONE;
        var layout = new AVChannelLayout();
        try
        {
            while ((!end.HasValue || next < end.Value) && (more is null || more(next)) && decoder.Next(ct))
            {
                ct.ThrowIfCancellationRequested();
                var frame = decoder.Frame;
                if (frame->sample_rate != rate) throw Failure(VoiceLabSourceAudioErrorCode.RateMismatch);
                if (frame->ch_layout.nb_channels != channels || frame->extended_data == null || frame->nb_samples is < 0 or > 1_048_576)
                    throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedFormat);
                if (frame->nb_samples == 0) continue;
                if (frame->nb_samples > Array.MaxLength / channels) throw Failure(VoiceLabSourceAudioErrorCode.TooLarge);
                var first = end.HasValue
                    ? SourceFrame(frame->best_effort_timestamp, decoder.Origin, previousEnd, rate, decoder.Stream->time_base.num, decoder.Stream->time_base.den)
                    : next;
                if (converter is null)
                {
                    SwrContext* context = null;
                    Native.Check(ffmpeg.swr_alloc_set_opts2(&context, &frame->ch_layout, AVSampleFormat.AV_SAMPLE_FMT_FLT, rate,
                        &frame->ch_layout, (AVSampleFormat)frame->format, rate, 0, null), "Configure Voice Lab sample decoding");
                    converter = NativeHandle.Own(context, NativeKind.Resample);
                    Native.Check(ffmpeg.swr_init(context), "Initialize Voice Lab sample decoding");
                    Native.Check(ffmpeg.av_channel_layout_copy(&layout, &frame->ch_layout), "Keep Voice Lab audio layout");
                    format = (AVSampleFormat)frame->format;
                }
                if (format != (AVSampleFormat)frame->format || ffmpeg.av_channel_layout_compare(&layout, &frame->ch_layout) != 0)
                    throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedFormat);
                var interleaved = new float[frame->nb_samples * channels];
                fixed (float* values = interleaved)
                {
                    var destination = (byte*)values;
                    var count = ffmpeg.swr_convert((SwrContext*)converter.Pointer, &destination, frame->nb_samples, frame->extended_data, frame->nb_samples);
                    Native.Check(count, "Decode Voice Lab samples");
                    if (count != frame->nb_samples) throw Failure(VoiceLabSourceAudioErrorCode.Unreadable);
                }
                if (end.HasValue)
                {
                    previousEnd = first + frame->nb_samples;
                    if (first > next) throw Failure(VoiceLabSourceAudioErrorCode.RangeOutsideMedia);
                    if (first + frame->nb_samples <= next) continue;
                }
                var skip = checked((int)(next - first));
                var take = (int)Math.Min(frame->nb_samples - skip, end.HasValue ? end.Value - next : frame->nb_samples);
                if (!end.HasValue && (next + take > MaxDecodedFrames || next + take > Array.MaxLength))
                    throw Failure(VoiceLabSourceAudioErrorCode.TooLarge);
                var mono = new float[take];
                for (var index = 0; index < take; index++)
                {
                    double sum = 0;
                    for (var channel = 0; channel < channels; channel++) sum += interleaved[(skip + index) * channels + channel];
                    mono[index] = (float)(sum / channels);
                    if (!float.IsFinite(mono[index])) throw Failure(VoiceLabSourceAudioErrorCode.InvalidAudio);
                }
                consume(mono, next); next += take;
            }
            if (end.HasValue && next != end.Value) throw Failure(VoiceLabSourceAudioErrorCode.RangeOutsideMedia);
            if (!end.HasValue && next == 0) throw Failure(VoiceLabSourceAudioErrorCode.InvalidAudio);
            return rate;
        }
        finally { converter?.Dispose(); ffmpeg.av_channel_layout_uninit(&layout); }
    }

    internal static long SourceFrame(long timestamp, double origin, long? previousEnd, int rate, int timeBaseNumerator, int timeBaseDenominator)
    {
        if (timestamp == ffmpeg.AV_NOPTS_VALUE)
            return previousEnd ?? throw Failure(VoiceLabSourceAudioErrorCode.Unreadable);
        var exact = (timestamp * ((double)timeBaseNumerator / timeBaseDenominator) - origin) * rate;
        return SourceFrame(exact, previousEnd, rate, timeBaseNumerator, timeBaseDenominator);
    }

    internal static long SourceFrame(double exact, long? previousEnd, int rate, int timeBaseNumerator, int timeBaseDenominator)
    {
        if (!double.IsFinite(exact) || exact < -Math.Pow(2, 62) || exact >= Math.Pow(2, 62))
            throw Failure(VoiceLabSourceAudioErrorCode.Unreadable);
        var tolerance = Math.Max(1, (double)rate * timeBaseNumerator / timeBaseDenominator);
        return previousEnd is { } continuous && Math.Abs(exact - continuous) < tolerance ? continuous : Native.Round(exact);
    }

    private static unsafe float[] Resample(float[] samples, int rate, int target, CancellationToken ct)
    {
        var expected = (long)Math.Floor(samples.LongLength * (double)target / rate + 0.5);
        if (expected > Array.MaxLength) throw Failure(VoiceLabSourceAudioErrorCode.TooLarge);
        var shortInput = samples.Length < 64;
        if (shortInput)
        {
            var padded = new float[64]; samples.CopyTo(padded, 0); samples = padded;
        }
        var layout = new AVChannelLayout();
        ffmpeg.av_channel_layout_default(&layout, 1);
        SwrContext* context = null;
        try
        {
            Native.Check(ffmpeg.swr_alloc_set_opts2(&context, &layout, AVSampleFormat.AV_SAMPLE_FMT_FLT, target,
                &layout, AVSampleFormat.AV_SAMPLE_FMT_FLT, rate, 0, null), "Configure Voice Lab source-rate resampling");
        }
        finally { ffmpeg.av_channel_layout_uninit(&layout); }
        using var converter = NativeHandle.Own(context, NativeKind.Resample);
        Native.Check(ffmpeg.swr_init(context), "Initialize Voice Lab source-rate resampling");
        var result = new List<float>((int)expected);
        var buffer = new float[(int)Math.Ceiling(65_536d * target / rate) + 256];
        fixed (float* input = samples)
        fixed (float* output = buffer)
        {
            for (var start = 0; start < samples.Length; start += Math.Min(65_536, samples.Length - start))
            {
                ct.ThrowIfCancellationRequested();
                var count = Math.Min(65_536, samples.Length - start);
                var source = (byte*)(input + start); var destination = (byte*)output;
                var converted = ffmpeg.swr_convert(context, &destination, buffer.Length, &source, count);
                Native.Check(converted, "Resample Voice Lab asset");
                result.AddRange(buffer.AsSpan(0, converted));
            }
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var destination = (byte*)output;
                var converted = ffmpeg.swr_convert(context, &destination, buffer.Length, null, 0);
                Native.Check(converted, "Drain Voice Lab resampler");
                if (converted == 0) break;
                result.AddRange(buffer.AsSpan(0, converted));
            }
        }
        if (shortInput)
        {
            if (result.Count < expected) throw Failure(VoiceLabSourceAudioErrorCode.Unreadable);
            return result.GetRange(0, (int)expected).ToArray();
        }
        return result.ToArray();
    }

    private static DecodeSession OpenDecoder(string path, bool conversion)
    {
        try { return new DecodeSession(path, AVMediaType.AVMEDIA_TYPE_AUDIO); }
        catch (VoxClipException failure) when (!conversion && failure.Code != VoxClipErrorCode.NoAudioTrack)
        { throw Failure(VoiceLabSourceAudioErrorCode.UnsupportedFormat); }
    }

    private static FileStream OpenSource(string path)
    {
        var attributes = System.IO.File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0)
            throw Failure(VoiceLabSourceAudioErrorCode.Unreadable);
        SafeFileHandle handle;
        if (OperatingSystem.IsWindows())
            handle = CreateFileW(path, 0x80000000, FileShare.Read | FileShare.Delete, IntPtr.Zero, FileMode.Open, 0x00200000, IntPtr.Zero);
        else
        {
            var descriptor = Open(path, OperatingSystem.IsMacOS() ? 0x104 : 0x20800);
            if (descriptor < 0) throw Failure(VoiceLabSourceAudioErrorCode.Unreadable);
            handle = new SafeFileHandle((IntPtr)descriptor, ownsHandle: true);
        }
        if (handle.IsInvalid) { handle.Dispose(); throw Failure(VoiceLabSourceAudioErrorCode.Unreadable); }
        try { return new FileStream(handle, FileAccess.Read); }
        catch { handle.Dispose(); throw; }
    }

    [DllImport("libc", EntryPoint = "open", SetLastError = true)]
    private static extern int Open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, int flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, FileShare share, IntPtr security,
        FileMode disposition, uint flags, IntPtr template);

    private static VoiceLabSourceAudioException Failure(VoiceLabSourceAudioErrorCode code) => new(code);
}
