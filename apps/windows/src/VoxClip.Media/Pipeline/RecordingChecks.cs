using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

internal static class RecordingChecks
{
    internal static bool?[] Pictures(string? path, ComposeSnapshot snapshot, ExportCheckExpectation.Edit edit, double frameSeconds,
        CancellationToken ct)
    {
        var result = new bool?[edit.RecordingSeams.Count];
        if (path is null || result.Length == 0) return result;
        var recordings = snapshot.SpanSources.DistinctBy(source => source.ContentKey).ToArray();
        if (recordings.Length < 2) return result;
        var size = snapshot.Output.Size;
        var frame = new PixelBuffer(new byte[checked(size.Width * size.Height * 4)], size.Width, size.Height, size.Width * 4);
        var composer = new FrameComposer();
        var timeline = snapshot.Timeline;
        var timing = snapshot.Speed;
        var cursor = new TimelineCursor(timeline);
        using var exported = new VideoDecoder(path, hardware: false);
        using var candidates = new RecordingVideo(snapshot.Media.Path, hardware: false);
        composer.PrepareSnapshot(snapshot);
        try
        {
            for (var index = 0; index < result.Length; index++)
            {
                ct.ThrowIfCancellationRequested();
                var seam = edit.RecordingSeams[index];
                var end = index + 1 == result.Length ? edit.Duration : edit.RecordingSeams[index + 1].At;
                var time = Math.Min(seam.At + .2, (seam.At + end) / 2);
                var frameTime = Math.Max(Math.Ceiling(seam.At / frameSeconds - 1e-6), Math.Floor(time / frameSeconds + 1e-6)) * frameSeconds;
                if (frameTime >= end) continue;
                var edited = timing.Edited(frameTime);
                var (expected, local) = cursor.Picture(snapshot, cursor.Source(edited));
                if (expected is null || expected.Label != seam.To) continue;
                var actual = Fingerprint(exported.ReadAt(frameTime, false, ct));
                double[] Reference(RecordingRenderSource source)
                {
                    var timeInRecording = source.LocalTime(local + source.OffsetSamples / timeline.SampleRate, timeline.SampleRate);
                    var decoded = candidates.Read(source, timeInRecording, ct);
                    composer.Compose(decoded, frame, snapshot, edited, false, null, ct, rotationOverride: source.RotationDegrees);
                    return Fingerprint(frame);
                }
                var expectedFingerprint = Reference(expected);
                var expectedDistance = Distance(actual, expectedFingerprint);
                foreach (var other in recordings.Where(source => source.ContentKey != expected.ContentKey))
                {
                    var otherFingerprint = Reference(other);
                    if (Distance(expectedFingerprint, otherFingerprint) < 1) continue;
                    var otherDistance = Distance(actual, otherFingerprint);
                    if (otherDistance < expectedDistance) { result[index] = false; break; }
                    if (otherDistance > expectedDistance) result[index] = true;
                }
            }
        }
        finally { composer.ReleaseSnapshot(snapshot); composer.ReleaseThreadResources(); }
        return result;
    }

    internal static (GatedSpeechMeter Before, GatedSpeechMeter After)[] Levels(ExportCheckExpectation.Edit edit, int rate, int channels,
        double origin)
    {
        var words = edit.Words.Where(word => !word.Optional).Select(word => new TimeRange(word.Start, word.End)).OrderBy(word => word.Start).ToArray();
        return edit.RecordingSeams.Select((seam, index) =>
        {
            var start = Math.Max(seam.At - 2, index == 0 ? 0 : edit.RecordingSeams[index - 1].At);
            var end = Math.Min(seam.At + 2, index + 1 == edit.RecordingSeams.Count ? edit.Duration : edit.RecordingSeams[index + 1].At);
            return (new GatedSpeechMeter(rate, channels, GatedSpeechMeter.Ranges(words, rate, origin, start, seam.At)),
                new GatedSpeechMeter(rate, channels, GatedSpeechMeter.Ranges(words, rate, origin, seam.At, end)));
        }).ToArray();
    }

    private static double[] Fingerprint(PixelBuffer pixels)
    {
        const int grid = 16, taps = 4, samples = grid * taps;
        var bytes = pixels.Pixels.Span;
        var luma = new double[grid * grid];
        for (var row = 0; row < samples; row++)
        for (var column = 0; column < samples; column++)
        {
            var index = ((row * 2 + 1) * pixels.Height / (samples * 2)) * pixels.Stride +
                ((column * 2 + 1) * pixels.Width / (samples * 2)) * 4;
            luma[(row / taps) * grid + column / taps] += (.0722 * bytes[index] + .7152 * bytes[index + 1] + .2126 * bytes[index + 2]) / (taps * taps);
        }
        return luma;
    }

    private static double Distance(double[] first, double[] second) => first.Zip(second).Average(pair =>
        (pair.First - pair.Second) * (pair.First - pair.Second));
}
