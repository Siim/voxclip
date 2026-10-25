using System.Diagnostics;
using System.Net;
using System.Text.Json;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;

namespace VoxClip.Core.Services.Speech;

internal static class SpeechTransport
{
    internal static HttpClient Client { get; } = new(new SocketsHttpHandler
    {
        ConnectTimeout = TimeSpan.FromSeconds(30), AllowAutoRedirect = true
    }) { Timeout = Timeout.InfiniteTimeSpan };

    internal static SocketsHttpHandler CreateCloudHandler() => new()
    {
        ConnectTimeout = TimeSpan.FromSeconds(30), AllowAutoRedirect = false, UseCookies = false
    };

    internal static bool Retryable(HttpStatusCode status) => status == HttpStatusCode.TooManyRequests || (int)status >= 500;

    internal static TimeSpan Backoff(HttpResponseMessage? response, int attempt)
    {
        var retry = response?.Headers.RetryAfter;
        var delay = retry?.Delta ?? (retry?.Date is { } date ? date - DateTimeOffset.UtcNow : TimeSpan.FromSeconds(1 << attempt));
        return TimeSpan.FromSeconds(Math.Clamp(delay.TotalSeconds, 0, 30));
    }

    internal static async Task AtomicWriteAsync(string path, Action<Utf8JsonWriter> write, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                using var writer = new Utf8JsonWriter(stream, VoxClip.Core.Domain.Shared.JsonFormatting.CreateWriterOptions());
                write(writer);
                await writer.FlushAsync(ct).ConfigureAwait(false);
                await stream.WriteAsync("\n"u8.ToArray(), ct).ConfigureAwait(false);
                await stream.FlushAsync(ct).ConfigureAwait(false);
            }
            ct.ThrowIfCancellationRequested();
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    internal static async Task<bool> TryCacheWriteAsync(Func<Task> write, CancellationToken ct)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try { await write().ConfigureAwait(false); return true; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                if (attempt == 2) return false;
                await Task.Delay(TimeSpan.FromMilliseconds(50 * (attempt + 1)), ct).ConfigureAwait(false);
            }
        }
        return false;
    }
}

/// <summary>Pure UI mapping from stage-local progress to the import-wide ranges in transcription §13.1.</summary>
public static class ImportProgress
{
    internal static (double Start, double End) Range(TranscriptionStage stage, TranscriptEngine engine) => stage switch
    {
        TranscriptionStage.Uploading => (0.10, 0.50),
        TranscriptionStage.Transcribing when engine == TranscriptEngine.Elevenlabs => (0.50, 0.95),
        TranscriptionStage.Transcribing => (0.10, 0.95),
        TranscriptionStage.Aligning => (0.95, 1.00),
        _ => (0, 1)
    };

    /// <summary>Return the import-wide fraction, preserving indeterminate stages; preparation uses its own bar.</summary>
    public static double? Overall(TranscriptionStage stage, TranscriptEngine engine, double? fraction)
    {
        if (fraction is not { } value || !double.IsFinite(value)) return null;
        var (start, end) = Range(stage, engine);
        return start + Math.Clamp(value, 0, 1) * (end - start);
    }
}

/// <summary>Throttle adapter progress to 10 Hz while preserving stage boundaries and completion.</summary>
/// <typeparam name="T">The adapter progress value.</typeparam>
/// <param name="target">The caller's progress observer, if any.</param>
public sealed class SpeechProgress<T>(IProgress<T>? target) : IProgress<T>
{
    private readonly object gate = new();
    private long last;
    private T? previous;
    /// <inheritdoc />
    public void Report(T value) => Report(value, false);

    private void Report(T value, bool force)
    {
        lock (gate)
        {
            var now = Stopwatch.GetTimestamp();
            var boundary = value is TranscriptionProgress speech &&
                (previous is not TranscriptionProgress prior || prior.Stage != speech.Stage || speech.Fraction == 1) ||
                value is ModelDownloadProgress download &&
                (previous is not ModelDownloadProgress priorDownload || priorDownload.Stage != download.Stage || download.BytesReceived == download.TotalBytes);
            if (!force && !boundary && last != 0 && Stopwatch.GetElapsedTime(last, now).TotalSeconds < 0.1) return;
            last = now;
            previous = value;
            target?.Report(value);
        }
    }

    /// <summary>Deliver the final value after the throttle interval, unless cancelled.</summary>
    public async Task CompleteAsync(T value, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        TimeSpan delay;
        lock (gate) delay = last == 0 ? TimeSpan.Zero : TimeSpan.FromSeconds(0.1) - Stopwatch.GetElapsedTime(last);
        if (delay > TimeSpan.Zero) await Task.Delay(delay, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        Report(value, true);
    }
}
