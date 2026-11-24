using System.Security.Cryptography;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Frames;
using VoxClip.Media.Pipeline;
using VoxClip.Media.Thumbnails;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed class LipsyncUpload : IDisposable
{
    internal LipsyncUpload(string folder) { Folder = folder; }
    private string Folder { get; }
    public string Video => Path.Combine(Folder, "window.mp4");
    public string Audio => Path.Combine(Folder, "mixed.wav");
    public void Dispose()
    {
        try { Directory.Delete(Folder, true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}

public static class LipsyncMedia
{
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    public static async Task PlayVoiceAsync(ComposeSnapshot snapshot, CancellationToken ct)
    {
        await FfmpegLoader.InitializeAsync(ct).ConfigureAwait(false);
        using var voice = await VoiceLabRenderSession.PrepareAsync(snapshot, ct).ConfigureAwait(false);
        const int rate = 24000;
        var mono = await MediaThread.Run("vc-whole-clip-audition", () =>
        {
            using var reader = RenderedAudioReader.OpenEditedVoice(snapshot, rate, voice, ct);
            if (reader.TotalFrames is < 1 or > 300 * rate) throw InvalidMedia();
            var samples = new float[(int)reader.TotalFrames];
            var buffer = new float[8192];
            for (int offset = 0, read; (read = reader.Read(buffer, buffer.Length / 2, ct)) > 0; offset += read)
                for (var index = 0; index < read; index++) samples[offset + index] = (buffer[2 * index] + buffer[2 * index + 1]) / 2;
            return samples;
        }, ct).ConfigureAwait(false);
        await PhraseCueOutput.PlayAsync(mono, rate, ct).ConfigureAwait(false);
    }

    public static bool Supports(MediaInfo media) => media.Audio is not null && media.Video?.FrameRate is >= 1 and <= 60 &&
        media.OrientedSize.Width >= 16 && media.OrientedSize.Height >= 16;

    public static async Task<bool> HasFaceAsync(MediaInfo media, double from, double to, IFrameFaces faces, CancellationToken ct)
    {
        await FfmpegLoader.InitializeAsync(ct).ConfigureAwait(false);
        for (int sample = 0; sample < 5; sample++)
        {
            var time = from + (Math.Max(0, to - from) * (sample + 0.5) / 5);
            var decoded = await MediaThread.Run("vc-lipsync-face", () =>
            {
                using var reader = new FfmpegFrameDecoder().Open(media.Path, 1280, 0.1, ct);
                return reader.Read(time, ct).Pixels;
            }, ct).ConfigureAwait(false);
            var finding = await faces.FacesAsync(decoded, [], ct).ConfigureAwait(false);
            if (finding.Largest is not null) return true;
        }
        return false;
    }

    public static async Task<LipsyncUpload> PrepareAsync(ComposeSnapshot snapshot, LipsyncRenderWindow window, string scratchRoot, CancellationToken ct)
    {
        if (snapshot.VoiceLab is not { } input || !Supports(snapshot.Media)) throw InvalidMedia();
        snapshot = input.CaptureSnapshot(snapshot) with { Clip = null, ContextDemo = null, Captions = null, Footage = [] };
        var rate = input.Prepared.OutputPlan.SampleRate;
        var needed = window.Seconds(rate);
        var frameRate = snapshot.Media.Video!.FrameRate;
        var upload = FalLipsyncProvider.UploadSeconds(needed, frameRate);
        if (needed < 3 || upload > 300 || window.OutputStartSample < 0 || window.OutputEndSample > input.Prepared.OutputPlan.OutputSamples)
            throw InvalidMedia();
        await FfmpegLoader.InitializeAsync(ct).ConfigureAwait(false);
        Directory.CreateDirectory(scratchRoot);
        var folder = Path.Combine(scratchRoot, "lipsync-" + Guid.NewGuid().ToString("N"));
        VoiceConsentPrivacy.CreateDirectory(folder);
        var files = new LipsyncUpload(folder);
        try
        {
            using var voice = await VoiceLabRenderSession.PrepareAsync(snapshot, ct).ConfigureAwait(false);
            var frames = checked((long)Math.Round(upload * frameRate));
            var size = Size(snapshot.Media.OrientedSize);
            var bitrate = (long)Math.Min(Math.Round(size.Width * size.Height * frameRate * 0.33),
                Math.Floor(FalLipsyncProvider.UploadVideoBudgetBytes * 8 / upload));
            snapshot = snapshot with { Output = new(size, frameRate, bitrate) { PreserveSource = true } };
            var composer = new FrameComposer();
            var first = window.OutputStartSample / rate;
            await Exporter.WriteLipsyncVideoAsync(snapshot.Media.Path, files.Video, snapshot.Output, frames, (decoder, frame, picture, token) =>
            {
                var edited = Math.Min(first + frame / frameRate, window.OutputEndSample / rate - 1 / rate);
                composer.Compose(decoder.ReadAt(snapshot.Timeline.SourceTime(edited), false, token), picture, snapshot, edited, false,
                    null, token, pictureOnly: true);
            }, ct, composer.ReleaseThreadResources).ConfigureAwait(false);
            await MediaThread.Run("vc-lipsync-audio", () =>
            {
                const int audioRate = 48000;
                using var reader = RenderedAudioReader.OpenEditedVoice(snapshot, audioRate, voice, ct, first);
                using var writer = new WaveWriter(files.Audio, audioRate, 2, false);
                var samples = new float[8192];
                long speech = (long)Math.Round(needed * audioRate, MidpointRounding.AwayFromZero);
                long remaining = (long)Math.Ceiling(frames / frameRate * audioRate);
                while (remaining > 0)
                {
                    ct.ThrowIfCancellationRequested();
                    int count = (int)Math.Min(samples.Length / 2, remaining);
                    int read = speech > 0 ? reader.Read(samples, (int)Math.Min(count, speech), ct) : 0;
                    if (read < Math.Min(count, speech) && speech - read > audioRate / 100) throw InvalidMedia();
                    samples.AsSpan(read * 2, (count - read) * 2).Clear();
                    writer.Write(samples.AsSpan(0, count * 2));
                    speech -= count; remaining -= count;
                }
                return true;
            }, ct).ConfigureAwait(false);
            if (new FileInfo(files.Video).Length is < 1 or > FalLipsyncProvider.UploadVideoBudgetBytes) throw InvalidMedia();
            return files;
        }
        catch { files.Dispose(); throw; }
    }

    public static async Task<VoiceLabVideoAsset> ImportAsync(SavedLipsyncPicture saved, string projectId, string paidRoot, MediaInfo reference,
        double needed, CancellationToken ct)
    {
        var input = await new FfmpegMediaProbe().ProbeAsync(saved.Path, ct).ConfigureAwait(false);
        var expected = Size(reference.OrientedSize);
        if (input.Video is not { FrameRate: >= 1 and <= 120 } video || input.OrientedSize != expected ||
            !double.IsFinite(input.DurationSeconds) || input.DurationSeconds + 3 / video.FrameRate + 1e-6 < needed)
            throw InvalidMedia();
        var assetId = Guid.NewGuid().ToString("D");
        var name = VoiceLabAssetNaming.VideoFile(projectId, assetId);
        var folder = Path.Combine(Path.GetFullPath(paidRoot), projectId);
        VoiceLabAssetStore.RequireDirectory(folder, "lipsync", create: false);
        var destination = Path.Combine(paidRoot, name);
        var partial = destination + ".part";
        var fps = reference.Video!.FrameRate;
        long frames = checked((long)Math.Ceiling(needed * fps));
        try
        {
            await Exporter.WriteLipsyncVideoAsync(saved.Path, partial, new(expected, fps, 8_000_000), frames, (decoder, index, picture, token) =>
            {
                var raw = decoder.ReadAt(Math.Min(index / fps, Math.Max(0, input.DurationSeconds - 1 / video.FrameRate)), false, token);
                var upright = CurrentFrames.Transform(raw, video.RotationDegrees, expected, expected, preserveSource: true);
                upright.Pixels.CopyTo(picture.Pixels);
            }, ct).ConfigureAwait(false);
            await using var stream = new FileStream(partial, FileMode.Open, FileAccess.ReadWrite, FileShare.Read | FileShare.Delete);
            var hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false));
            stream.Flush(true);
            File.Move(partial, destination, false);
            return new(assetId, name, hash, needed, fps, expected.Width, expected.Height);
        }
        finally { File.Delete(partial); }
    }

    private static PixelSize Size(PixelSize source)
    {
        var scale = Math.Min(1, 1920d / Math.Max(source.Width, source.Height));
        return new(Math.Max(16, (int)Math.Round(source.Width * scale / 2) * 2), Math.Max(16, (int)Math.Round(source.Height * scale / 2) * 2));
    }

    private static VoxClipException InvalidMedia() => new(VoxClipErrorCode.DecodeFailed, "The lip-sync picture or its timing couldn't be verified. Your edits and paid work are saved.");
}
