using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Text;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.VoiceLab;

namespace VoxClip.Media.Pipeline;

internal unsafe delegate void ExportFrameObserver(long index, PixelBuffer decoded, PixelBuffer composed, AVFrame* nv12);

/// <summary>Sequential CFR H.264/AAC MP4 exporter; architecture §6.4.</summary>
public sealed class Exporter : IExporter
{
    private readonly IFrameComposer composer;
    private readonly IEncoderProbe encoders;
    private readonly Func<ExportJob, string, IProgress<ExportProgress>?, CancellationToken, ExportResult>? runExport;
    private readonly Action<EncoderCacheKey, string> recordFailure;
    private readonly ExportFrameObserver? frameObserver;
    /// <summary>Use the same compositor as preview and the Windows hardware ladder.</summary>
    public Exporter() : this(new FrameComposer(), new EncoderProbe()) { }
    internal Exporter(IFrameComposer composer, IEncoderProbe encoders,
        Func<ExportJob, string, IProgress<ExportProgress>?, CancellationToken, ExportResult>? runExport = null,
        Action<EncoderCacheKey, string>? recordFailure = null, ExportFrameObserver? frameObserver = null)
    { this.composer = composer; this.encoders = encoders; this.runExport = runExport; this.recordFailure = recordFailure ?? ((key, name) => EncoderProbe.RecordFailure(key, name)); this.frameObserver = frameObserver; }

    /// <inheritdoc />
    public Task<ExportResult> ExportAsync(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct)
        => ExportAsync(job, progress, ct, true);

    internal Task<ExportResult> PrepareAsync(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct)
        => ExportAsync(job, progress, ct, false);

    private async Task<ExportResult> ExportAsync(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct, bool publish)
    {
        ct.ThrowIfCancellationRequested();
        job = job with { Snapshot = job.Snapshot.VoiceLab?.CaptureSnapshot(job.Snapshot) ?? job.Snapshot };
        Validate(job);
        var allocations = VoiceLabOutputAllocations(job, publish);
        using var voiceSession = await VoiceLabRenderSession.PrepareAsync(job.Snapshot, ct, allocations).ConfigureAwait(false);
        var cacheKey = WindowsAdapterIdentity.Read();
        var after = -1;
        var failed = new HashSet<string>(StringComparer.Ordinal);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var choices = await (encoders is EncoderProbe probe
                ? probe.ProbeRemainingAsync(cacheKey, failed, ct)
                : encoders.ProbeAsync(cacheKey, null, ct)).ConfigureAwait(false);
            var selected = EncoderProbe.Ladder.Skip(after + 1).FirstOrDefault(name => choices.Any(encoder => encoder.Available && encoder.Name == name));
            if (selected is null) throw new VoxClipException(VoxClipErrorCode.EncoderUnavailable, ExportErrors.EncoderUnavailable);
            try
            {
                var result = await MediaThread.Run("vc-export", () => runExport is null ? Export(job, selected, progress, ct, publish, voiceSession) : runExport(job, selected, progress, ct), ct).ConfigureAwait(false);
                return result with { SoftwareEncoding = selected == EncoderProbe.SoftwareMediaFoundation };
            }
            catch (Exception exception) when (ExportErrors.IsEncoderFailure(exception))
            {
                failed.Add(selected);
                recordFailure(cacheKey, selected);
                if (attempt != 0) throw ExportErrors.Map(exception, job.OutputPath);
                after = EncoderProbe.Ladder.ToList().IndexOf(selected);
            }
            catch (MediaException exception) when (exception.Code == VoxClipErrorCode.ExportFailed) { throw ExportErrors.Map(exception, job.OutputPath); }
            catch (IOException exception) { throw ExportErrors.Map(exception, job.OutputPath); }
            catch (UnauthorizedAccessException exception) { throw ExportErrors.Map(exception, job.OutputPath); }
        }
        throw new VoxClipException(VoxClipErrorCode.ExportFailed, "Export stopped: the encoder failed. Your edits are saved.");
    }

    internal static void Validate(ExportJob job)
    {
        var snapshot = job.Snapshot;
        if (snapshot.Timeline.OutputSamples <= 0)
            throw new VoxClipException(VoxClipErrorCode.EverythingCut, "Keep at least one word before exporting.");
        if (!double.IsFinite(snapshot.Timeline.SampleRate) || snapshot.Timeline.SampleRate <= 0 || snapshot.Media.Video is null)
            throw new VoxClipException(VoxClipErrorCode.ExportFailed, "Export stopped: this export requires a video and a valid edit plan. Your edits are saved.");
        if (snapshot.VoiceLab is { Prepared.OutputPlan.RequiresSyntheticRendering: true } input)
        {
            var requestedClip = job.Target is ExportTarget.Clip clip ? clip.Id : null;
            var expectedSize = ExportPresets.OutputSize(snapshot.Media.OrientedSize, job.Aspect);
            if (input.Prepared.OutputPlan.Scope.ClipId != requestedClip || snapshot.Output.Size != expectedSize ||
                snapshot.Captions is { } captions && captions.Frame != expectedSize)
                throw new VoxClip.Core.Domain.VoiceLab.VoiceLabProjectException(
                    VoxClip.Core.Domain.VoiceLab.VoiceLabProjectErrorCode.StaleRenderContract);
        }
        var protectedPaths = new List<string> { snapshot.Media.Path };
        if (snapshot.VoiceLab is { } voiceInput)
        {
            var project = voiceInput.IsolatedProject();
            protectedPaths.AddRange(project.VoiceLab.Assets?.Select(asset =>
                Path.Combine(voiceInput.PaidRoot, project.Id, Path.GetFileName(asset.File))) ?? []);
        }
        var destinations = new List<string> { job.OutputPath };
        if (job.SrtPath is { } srt) destinations.Add(srt);
        if (snapshot.VoiceLab is { Prepared.OutputPlan.RequiresSyntheticRendering: true })
            destinations.Add(job.OutputPath + ".provenance.json");
        OutputSafety.Validate(protectedPaths, destinations);
    }

    internal static VoiceLabCapacity.Allocation[] VoiceLabOutputAllocations(ExportJob job, bool publish)
    {
        var snapshot = job.Snapshot;
        if (snapshot.VoiceLab is not { Prepared.OutputPlan.RequiresSyntheticRendering: true } input) return [];
        var size = ExportPresets.OutputSize(snapshot.Media.OrientedSize, job.Aspect);
        var fps = ExportPresets.OutputFrameRate(snapshot.Output.FrameRate);
        var bitrate = ExportPresets.VideoBitrate(size, job.Aspect, job.Quality, fps) + 160_000d;
        var estimate = Math.Ceiling(snapshot.Timeline.Duration * bitrate / 8d * 1.25) + 32d * 1024 * 1024;
        if (!double.IsFinite(estimate) || estimate > long.MaxValue / 2d)
            throw new VoxClipException(VoxClipErrorCode.DiskFull, "The marked MP4 is too large for this volume. Your edits are saved.");
        var mp4Bytes = (long)estimate;
        var destination = OutputSafety.Resolve(job.OutputPath);
        var sidecar = destination + ".provenance.json";
        var sidecarBytes = VoiceLabCapacity.Bytes(System.Text.Encoding.UTF8.GetByteCount(input.Fingerprint), 2, 1_048_576);
        var srt = job.SrtPath is null ? null : OutputSafety.Resolve(job.SrtPath);
        var allocations = new List<VoiceLabCapacity.Allocation>
        {
            new(destination, mp4Bytes), new(destination, VoiceLabCapacity.Bytes(mp4Bytes, 1, 65_536)),
            new(sidecar, sidecarBytes)
        };
        if (srt is not null)
            allocations.Add(new(srt, System.Text.Encoding.UTF8.GetByteCount(Subtitles(snapshot.Captions))));
        if (publish)
        {
            allocations.Add(VoiceLabCapacity.Rollback(destination));
            allocations.Add(VoiceLabCapacity.Rollback(sidecar));
            if (srt is not null) allocations.Add(VoiceLabCapacity.Rollback(srt));
        }
        return allocations.ToArray();
    }

    private unsafe ExportResult Export(ExportJob job, string encoderName, IProgress<ExportProgress>? progress, CancellationToken ct, bool publish,
        VoiceLabRenderSession? voiceSession)
    {
        FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult();
        var timer = Stopwatch.StartNew();
        var snapshot = job.Snapshot;
        var output = ExportPresets.Output(snapshot.Media.OrientedSize, snapshot.Output.FrameRate, job.Aspect, job.Quality, snapshot.Output.VideoCodec);
        var size = output.Size;
        var fps = output.FrameRate;
        snapshot = snapshot with { Output = output };
        var frames = Native.Round(snapshot.Timeline.Duration * fps);
        var samples = snapshot.Media.Audio is null ? 0 : Native.Round(snapshot.Timeline.Duration * 48_000);
        var destination = OutputSafety.Resolve(job.OutputPath);
        var partial = destination + ".partial";
        var srtDestination = job.SrtPath is null ? null : OutputSafety.Resolve(job.SrtPath);
        var srtPartial = srtDestination is null ? null : srtDestination + ".partial";
        var sidecarDestination = snapshot.VoiceLab is { Prepared.OutputPlan.RequiresSyntheticRendering: true }
            ? destination + ".provenance.json" : null;
        var sidecarPartial = sidecarDestination is null ? null : sidecarDestination + ".partial";
        var xmpStage = sidecarDestination is null ? null : partial + ".xmp-" + Guid.NewGuid().ToString("N");
        var lastProgress = -1.0;
        string? lastPhase = null;
        var hasPartial = false;
        var hasSrtPartial = false;
        var hasSidecarPartial = false;
        var ownsXmpStage = false;
        try
        {
            if (composer is FrameComposer frameComposer) frameComposer.PrepareDisclosure(snapshot);
            using (OutputSafety.CreatePartial(partial)) { hasPartial = true; }
            var reporter = new Action<string, long>((phase, count) =>
            {
                if (progress is null) return;
                var remaining = 0.1 - (timer.Elapsed.TotalSeconds - lastProgress);
                if (remaining > 0)
                {
                    if (phase == lastPhase) return;
                    if (ct.WaitHandle.WaitOne(TimeSpan.FromSeconds(remaining))) ct.ThrowIfCancellationRequested();
                }
                progress.Report(new(phase, frames == 0 ? 0 : (double)count / frames, count, frames));
                lastPhase = phase;
                lastProgress = timer.Elapsed.TotalSeconds;
            });
            reporter("preparing", 0);
            using (var video = new EncoderSession(encoderName, output))
            using (var audio = snapshot.Media.Audio is null ? null : new EncoderSession("aac", output, true))
            using (var mux = CreateMux(partial, video, audio, out var videoStream, out var audioStream))
            using (var decoder = new VideoDecoder(snapshot.Media.Path))
            using (var nv12Handle = NativeHandle.Own(Native.Frame(AVPixelFormat.AV_PIX_FMT_NV12, size.Width, size.Height), NativeKind.Frame))
            using (var scaling = NativeHandle.Own(ffmpeg.sws_getContext(size.Width, size.Height, AVPixelFormat.AV_PIX_FMT_BGRA,
                size.Width, size.Height, AVPixelFormat.AV_PIX_FMT_NV12, (int)SwsFlags.SWS_BILINEAR, null, null, null), NativeKind.Scale))
            using (var editedAudio = audio is null ? null : new EditedAudioReader(snapshot, 48_000, session: voiceSession, ct: ct))
            using (var audioFrameHandle = audio is null ? null : CreateAudioFrame(audio))
            {
                var format = (AVFormatContext*)mux.Pointer;
                var nv12 = (AVFrame*)nv12Handle.Pointer;
                var bgra = new PixelBuffer(new byte[checked(size.Width * size.Height * 4)], size.Width, size.Height, size.Width * 4);
                var cursor = new TimelineCursor(snapshot.Timeline);
                Native.Colors((SwsContext*)scaling.Pointer, true);
                long audioOffset = 0;
                var audioBuffer = new float[2048];
                for (long index = 0; index < frames; index++)
                {
                    ct.ThrowIfCancellationRequested();
                    var editedTime = index / fps;
                    var sourceTime = cursor.Source(editedTime);
                    var decoded = decoder.ReadAt(sourceTime, false, ct);
                    composer.Compose(decoded, bgra, snapshot, editedTime, false, ct);
                    Native.Check(ffmpeg.av_frame_make_writable(nv12), "Reuse export video frame", VoxClipErrorCode.ExportFailed);
                    using (var memory = bgra.Pixels.Pin())
                    {
                        var pixels = new byte_ptrArray4(); pixels[0] = (byte*)memory.Pointer;
                        var strides = new int_array4(); strides[0] = bgra.Stride;
                        Native.Check(ffmpeg.sws_scale((SwsContext*)scaling.Pointer, pixels, strides, 0, size.Height, nv12->data, nv12->linesize), "Convert BGRA to NV12", VoxClipErrorCode.ExportFailed);
                    }
                    nv12->pts = index;
                    nv12->duration = 1;
                    nv12->color_primaries = AVColorPrimaries.AVCOL_PRI_BT709;
                    nv12->color_trc = AVColorTransferCharacteristic.AVCOL_TRC_BT709;
                    nv12->colorspace = AVColorSpace.AVCOL_SPC_BT709;
                    nv12->color_range = AVColorRange.AVCOL_RANGE_MPEG;
                    frameObserver?.Invoke(index, decoded, bgra, nv12);
                    video.Send(nv12, packet => Mux(format, video, videoStream, packet), ct);
                    if (audio is not null)
                    {
                        var until = Math.Min(samples, Native.Round((index + 1) / fps * 48_000));
                        while (audioOffset < until)
                            EncodeAudio(audio, editedAudio!, (AVFrame*)audioFrameHandle!.Pointer, audioBuffer, samples, ref audioOffset,
                                packet => Mux(format, audio, audioStream, packet), ct);
                    }
                    reporter("encoding", index + 1);
                }
                if (audio is not null)
                {
                    while (audioOffset < samples)
                        EncodeAudio(audio, editedAudio!, (AVFrame*)audioFrameHandle!.Pointer, audioBuffer, samples, ref audioOffset,
                            packet => Mux(format, audio, audioStream, packet), ct);
                    audio.Send(null, packet => Mux(format, audio, audioStream, packet), ct);
                }
                video.Send(null, packet => Mux(format, video, videoStream, packet), ct);
                reporter("finalizing", frames);
                ct.ThrowIfCancellationRequested();
                Native.Check(ffmpeg.av_write_trailer(format), "Finalize MP4", VoxClipErrorCode.ExportFailed);
            }
            ct.ThrowIfCancellationRequested();
            if (sidecarPartial is not null)
            {
                var remaining = new List<VoiceLabCapacity.Allocation>
                {
                    new(destination, VoiceLabCapacity.Bytes(new FileInfo(partial).Length, 1, 65_536)),
                    new(sidecarDestination!, 1_048_576)
                };
                if (srtDestination is not null)
                    remaining.Add(new(srtDestination, System.Text.Encoding.UTF8.GetByteCount(Subtitles(snapshot.Captions))));
                if (publish)
                {
                    remaining.Add(VoiceLabCapacity.Rollback(destination));
                    remaining.Add(VoiceLabCapacity.Rollback(sidecarDestination!));
                    if (srtDestination is not null) remaining.Add(VoiceLabCapacity.Rollback(srtDestination));
                }
                VoiceLabCapacity.Require(remaining);
                var input = snapshot.VoiceLab!;
                var project = input.IsolatedProject();
                var version = typeof(Exporter).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
                    .InformationalVersion.Split('+')[0] ?? typeof(Exporter).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
                var staged = VoiceLabDisclosureWriter.StageAsync(partial, xmpStage!, Path.GetFileName(destination),
                    project, input.Prepared, version, DateTimeOffset.UtcNow, ct).GetAwaiter().GetResult();
                ownsXmpStage = true;
                if (staged.Mp4Path != xmpStage || staged.SidecarFilename != Path.GetFileName(sidecarDestination))
                    throw new InvalidDataException("The disclosure stage names do not match the export.");
                remaining.Clear();
                remaining.Add(new(sidecarDestination!, staged.SidecarData.Length));
                if (srtDestination is not null)
                    remaining.Add(new(srtDestination, System.Text.Encoding.UTF8.GetByteCount(Subtitles(snapshot.Captions))));
                if (publish)
                {
                    remaining.Add(VoiceLabCapacity.Rollback(destination));
                    remaining.Add(VoiceLabCapacity.Rollback(sidecarDestination!));
                    if (srtDestination is not null) remaining.Add(VoiceLabCapacity.Rollback(srtDestination));
                }
                VoiceLabCapacity.Require(remaining);
                using (var sidecar = OutputSafety.CreatePartial(sidecarPartial))
                {
                    hasSidecarPartial = true;
                    sidecar.Write(staged.SidecarData);
                    sidecar.Flush(true);
                }
                ct.ThrowIfCancellationRequested();
                File.Move(xmpStage!, partial, true);
                ownsXmpStage = false;
            }
            if (srtPartial is not null)
            {
                using (OutputSafety.CreatePartial(srtPartial)) { hasSrtPartial = true; }
                File.WriteAllText(srtPartial, Subtitles(snapshot.Captions), new UTF8Encoding(false));
                ct.ThrowIfCancellationRequested();
            }
            var destinations = new List<string> { destination };
            if (srtDestination is not null) destinations.Add(srtDestination);
            if (sidecarDestination is not null) destinations.Add(sidecarDestination);
            if (publish) OutputSafety.Publish(destinations, ct: ct);
            hasPartial = false; hasSrtPartial = false; hasSidecarPartial = false;
            return new(destination, srtDestination, snapshot.Timeline.Duration,
                size.Width, size.Height, fps, frames, 48_000, samples, "h264", encoderName, timer.Elapsed.TotalSeconds);
        }
        finally
        {
            if (hasPartial) DeletePartial(partial);
            if (hasSrtPartial && srtPartial is not null) DeletePartial(srtPartial);
            if (hasSidecarPartial && sidecarPartial is not null) DeletePartial(sidecarPartial);
            if (ownsXmpStage && xmpStage is not null) DeletePartial(xmpStage);
            if (composer is FrameComposer concrete)
            {
                concrete.ReleaseDisclosure(snapshot);
                concrete.ReleaseThreadResources();
            }
        }
    }

    private static void DeletePartial(string path)
    {
        try { File.Delete(path); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private static unsafe NativeHandle CreateMux(string path, EncoderSession video, EncoderSession? audio, out int videoIndex, out int audioIndex)
    {
        AVFormatContext* format = null;
        Native.Check(ffmpeg.avformat_alloc_output_context2(&format, null, "mp4", path), "Create MP4 muxer", VoxClipErrorCode.ExportFailed);
        var handle = NativeHandle.Own(format, NativeKind.Output);
        try
        {
            var videoStream = ffmpeg.avformat_new_stream(format, null);
            if (videoStream == null) throw new OutOfMemoryException();
            videoIndex = videoStream->index; videoStream->time_base = video.Context->time_base;
            Native.Check(ffmpeg.avcodec_parameters_from_context(videoStream->codecpar, video.Context), "Copy video encoding parameters", VoxClipErrorCode.ExportFailed);
            videoStream->codecpar->codec_tag = 0x31637661;
            audioIndex = -1;
            if (audio is not null)
            {
                var audioStream = ffmpeg.avformat_new_stream(format, null);
                if (audioStream == null) throw new OutOfMemoryException();
                audioIndex = audioStream->index; audioStream->time_base = new() { num = 1, den = 48_000 };
                Native.Check(ffmpeg.avcodec_parameters_from_context(audioStream->codecpar, audio.Context), "Copy audio encoding parameters", VoxClipErrorCode.ExportFailed);
                audioStream->codecpar->codec_tag = 0x6134706d;
            }
            Native.Check(ffmpeg.avio_open(&format->pb, path, ffmpeg.AVIO_FLAG_WRITE), "Open export output", VoxClipErrorCode.ExportFailed);
            AVDictionary* options = null;
            try
            {
                Native.Check(ffmpeg.av_dict_set(&options, "movflags", "+faststart", 0), "Set MP4 faststart", VoxClipErrorCode.ExportFailed);
                Native.Check(ffmpeg.avformat_write_header(format, &options), "Write MP4 header", VoxClipErrorCode.ExportFailed);
            }
            finally { ffmpeg.av_dict_free(&options); }
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }

    private static unsafe NativeHandle CreateAudioFrame(EncoderSession encoder)
    {
        var frame = ffmpeg.av_frame_alloc();
        var handle = NativeHandle.Own(frame, NativeKind.Frame);
        try
        {
            frame->format = (int)AVSampleFormat.AV_SAMPLE_FMT_FLTP;
            frame->sample_rate = 48_000; frame->nb_samples = encoder.Context->frame_size;
            Native.Check(ffmpeg.av_channel_layout_copy(&frame->ch_layout, &encoder.Context->ch_layout), "Set AAC channel layout", VoxClipErrorCode.ExportFailed);
            Native.Check(ffmpeg.av_frame_get_buffer(frame, 0), "Allocate AAC frame", VoxClipErrorCode.ExportFailed);
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }

    private static unsafe void EncodeAudio(EncoderSession encoder, EditedAudioReader reader, AVFrame* frame, float[] buffer,
        long total, ref long offset, PacketSink consume, CancellationToken ct)
    {
        Native.Check(ffmpeg.av_frame_make_writable(frame), "Reuse AAC frame");
        var count = reader.Read(buffer, (int)Math.Min(encoder.Context->frame_size, total - offset), ct);
        if (count == 0) throw new VoxClipException(VoxClipErrorCode.ExportFailed, "Export stopped: the edited audio ended unexpectedly. Your edits are saved.");
        for (var channel = 0; channel < 2; channel++)
        {
            var samples = (float*)frame->extended_data[channel];
            for (var index = 0; index < count; index++) samples[index] = buffer[index * 2 + channel];
        }
        frame->nb_samples = count; frame->pts = offset;
        encoder.Send(frame, consume, ct); offset += count;
    }

    private static unsafe void Mux(AVFormatContext* format, EncoderSession encoder, int index, AVPacket* packet)
    {
        if (encoder.Context->codec_type == AVMediaType.AVMEDIA_TYPE_VIDEO && packet->duration <= 0) packet->duration = 1;
        ffmpeg.av_packet_rescale_ts(packet, encoder.Context->time_base, format->streams[index]->time_base);
        packet->stream_index = index;
        Native.Check(ffmpeg.av_interleaved_write_frame(format, packet), "Mux MP4 packet", VoxClipErrorCode.ExportFailed);
    }

    internal static string Subtitles(CaptionTrack? captions, Func<string, CaptionText, string>? transform = null)
    {
        if (captions is null) return string.Empty;
        var output = new StringBuilder();
        var index = 0;
        transform ??= CaptionEngine.TransformText;
        var textOptions = captions.Style.Text with { Transform = CaptionTextTransformValue.None, Punctuation = CaptionTextPunctuationValue.Keep };
        foreach (var page in captions.Pages)
        {
            if (page.End <= page.Start) continue;
            output.Append(++index).Append('\n').Append(SrtTime(page.Start)).Append(" --> ").Append(SrtTime(page.End)).Append('\n');
            foreach (var line in page.Lines)
                output.AppendJoin(' ', line.Words.Select(word => transform(captions.Words[word].Raw, textOptions))).Append('\n');
            output.Append('\n');
        }
        return output.ToString();
    }

    private static string SrtTime(double seconds)
    {
        var milliseconds = Math.Max(0, Native.Round(seconds * 1000));
        return string.Create(CultureInfo.InvariantCulture, $"{milliseconds / 3_600_000:00}:{milliseconds / 60_000 % 60:00}:{milliseconds / 1000 % 60:00},{milliseconds % 1000:000}");
    }
}
