using VoxClip.Core.Domain.Shared;
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
/// <summary>Safe no-sink skeleton logger; architecture §11.1. win-ui adds channel-backed rolling-file/stderr sinks in place.</summary>
public sealed class Log : ILog
{
    // TODO(win-ui): replace the safe no-sink read/flush/dispose placeholders with channel-backed rolling logs.
    private readonly object gate = new();
    private readonly List<string> secrets = [];
    /// <inheritdoc />
    public void RegisterSecret(string secret)
    {
        if (secret.Length < 8) return;
        lock (gate) if (!secrets.Contains(secret, StringComparer.Ordinal)) secrets.Add(secret);
    }
    /// <inheritdoc />
    public void Write(LogLevel level, string category, string message)
    {
        lock (gate) _ = new Redactor(secrets, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).Redact(message);
    }
    /// <inheritdoc />
    public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
    /// <inheritdoc />
    public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
    /// <inheritdoc />
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
