using VoxClip.Core.Domain.Shared;
using System.Diagnostics;
using System.Globalization;
using System.Threading.Channels;
namespace VoxClip.Core.Services.Logging;

/// <summary>Logging levels; architecture §11.1.</summary>
public enum LogLevel
{
    /// <summary>Unexpected failure.</summary>
    Error,
    /// <summary>Recoverable problem.</summary>
    Warn,
    /// <summary>Safe lifecycle metadata.</summary>
    Info,
    /// <summary>Diagnostic metadata, never bodies or transcript text.</summary>
    Debug
}
/// <summary>Redacted structured metadata; architecture §11.1. Do not put prompts/transcripts/bodies into Message.</summary>
public sealed record LogEntry(DateTimeOffset Timestamp, LogLevel Level, string Category, string Message);
/// <summary>Nonblocking logging facade; architecture §11.1. A sink failure must never crash startup.</summary>
public interface ILog : IAsyncDisposable
{
    /// <summary>Register a secret before it can reach any sink; values shorter than eight characters are ignored.</summary>
    void RegisterSecret(string secret);
    /// <summary>Enqueue metadata through the redactor; callers never write to sinks directly.</summary>
    void Write(LogLevel level, string category, string message);
    /// <summary>Read only redacted lines for diagnostics.</summary>
    Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct);
    /// <summary>Flush background writes on orderly shutdown.</summary>
    Task FlushAsync(CancellationToken ct);
}
/// <summary>Bounded, nonblocking rolling-file logger; architecture §11.1. All sinks receive redacted metadata only.</summary>
public sealed class Log : ILog
{
    private readonly object gate = new();
    private readonly List<string> secrets = [];
    private readonly Queue<string> recent = new();
    private readonly Channel<PendingWrite> pending = Channel.CreateBounded<PendingWrite>(new BoundedChannelOptions(1024)
    {
        SingleReader = true, FullMode = BoundedChannelFullMode.Wait, AllowSynchronousContinuations = false
    });
    private readonly string directory;
    private readonly TextWriter? standardError;
    private readonly Task worker;
    private readonly LogLevel minimum;
    private int sinkFailureReported;
    private int disposed;
    private sealed record PendingWrite(string? Line, TaskCompletionSource? Completion);

    /// <summary>Use the per-user Logs directory by default. stderr is opt-in for CLI hosts only.</summary>
    public Log(string? directory = null, TextWriter? standardError = null)
    {
        this.directory = directory ?? Services.Project.DataLocations.Resolve().Logs;
        this.standardError = standardError;
        minimum = Enum.TryParse<LogLevel>(Environment.GetEnvironmentVariable("VOXCLIP_LOG_LEVEL"), true, out var level) ? level : LogLevel.Info;
        worker = Task.Run(ConsumeAsync);
    }
    /// <inheritdoc />
    public void RegisterSecret(string secret)
    {
        if (secret.Length < 8) return;
        lock (gate) if (!secrets.Contains(secret, StringComparer.Ordinal)) secrets.Add(secret);
    }
    /// <inheritdoc />
    public void Write(LogLevel level, string category, string message)
    {
        if (level > minimum || Volatile.Read(ref disposed) != 0) return;
        string line;
        lock (gate)
        {
            var redactor = new Redactor(secrets, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
            var safeCategory = string.Concat(category.Where(character => char.IsAsciiLetterOrDigit(character) || character == '-')).ToLowerInvariant();
            var safeMessage = redactor.Redact(message).Replace('\r', ' ').Replace('\n', ' ');
            if (safeCategory.Length > 64) safeCategory = safeCategory[..64];
            if (safeMessage.Length > 4096) safeMessage = safeMessage[..4096];
            line = string.Create(CultureInfo.InvariantCulture, $"{DateTimeOffset.UtcNow:O} {level.ToString().ToLowerInvariant()} [{safeCategory}] {safeMessage}");
            recent.Enqueue(line);
            while (recent.Count > 200) recent.Dequeue();
        }
        pending.Writer.TryWrite(new(line, null));
    }
    /// <inheritdoc />
    public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        lock (gate)
        {
            var redactor = new Redactor(secrets, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
            return Task.FromResult<IReadOnlyList<string>>(recent.TakeLast(Math.Clamp(count, 0, 200)).Select(redactor.Redact).ToArray());
        }
    }
    /// <inheritdoc />
    public async Task FlushAsync(CancellationToken ct)
    {
        if (Volatile.Read(ref disposed) != 0) { await worker.WaitAsync(ct).ConfigureAwait(false); return; }
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try { await pending.Writer.WriteAsync(new(null, completion), ct).ConfigureAwait(false); }
        catch (ChannelClosedException) { await worker.WaitAsync(ct).ConfigureAwait(false); return; }
        await completion.Task.WaitAsync(ct).ConfigureAwait(false);
    }
    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0) pending.Writer.TryComplete();
        await worker.ConfigureAwait(false);
    }

    private async Task ConsumeAsync()
    {
        await foreach (var write in pending.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            if (write.Line is { } line)
            {
                try
                {
                    Directory.CreateDirectory(directory);
                    var path = Path.Combine(directory, "voxclip.log");
                    if (File.Exists(path) && new FileInfo(path).Length + System.Text.Encoding.UTF8.GetByteCount(line) + 1 > 5 * 1024 * 1024)
                    {
                        File.Delete(path + ".4");
                        for (var index = 3; index >= 1; index--)
                            if (File.Exists(path + "." + index)) File.Move(path + "." + index, path + "." + (index + 1), true);
                        File.Move(path, path + ".1", true);
                    }
                    await File.AppendAllTextAsync(path, line + "\n").ConfigureAwait(false);
                }
                catch (Exception exception) when (exception is not OutOfMemoryException)
                {
                    if (Interlocked.Exchange(ref sinkFailureReported, 1) == 0) Debug.WriteLine("VoxClip: file logging unavailable.");
                }
                if (standardError is not null)
                {
                    try { await standardError.WriteLineAsync(line).ConfigureAwait(false); }
                    catch (Exception exception) when (exception is not OutOfMemoryException) { }
                }
            }
            write.Completion?.TrySetResult();
        }
    }
}
