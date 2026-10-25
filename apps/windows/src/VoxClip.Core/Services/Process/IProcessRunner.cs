namespace VoxClip.Core.Services.Process;

/// <summary>Argument-array process invocation; AI §6.10. No shell string and no credential/config overrides.</summary>
public sealed record ProcessRequest(string Executable, IReadOnlyList<string> Arguments, string WorkingDirectory,
    string? StandardInput, TimeSpan Timeout, IReadOnlyDictionary<string, string?>? Environment = null, int OutputLimitBytes = 16 * 1024 * 1024);
/// <summary>Bounded stdout/stderr result. Never log these bodies; AI §6.10.</summary>
public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError, TimeSpan Elapsed, bool OutputTruncated);
/// <summary>Process progress safe for UI; AI §6.10.</summary>
public sealed record ProcessProgress(string Stage, long StandardOutputBytes, long StandardErrorBytes);
/// <summary>Isolated subprocess boundary; AI §6.10. Windows implementation must use a kill-on-close Job Object.</summary>
public interface IProcessRunner
{
    /// <summary>Read both pipes concurrently, honor timeout/cancel and kill the process tree.</summary>
    Task<ProcessResult> RunAsync(ProcessRequest request, IProgress<ProcessProgress>? progress, CancellationToken ct);
}
/// <summary>Bounded UTF-8 subprocess runner with process-group or Job Object cleanup; AI §6.10.</summary>
public sealed partial class ProcessRunner : IProcessRunner
{
    /// <inheritdoc />
    public Task<ProcessResult> RunAsync(ProcessRequest request, IProgress<ProcessProgress>? progress, CancellationToken ct) => RunCoreAsync(request, progress, ct);
}
