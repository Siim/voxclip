using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Core.Services.LLM;

/// <summary>Explicit clip finder request; AI §11.1. Consent must be obtained by the caller before cloud use.</summary>
public sealed record ClipFinderRequest(IReadOnlyList<TimedWord> Words, IReadOnlyDictionary<string, string> Corrections,
    IReadOnlySet<string> CutWordIds, ClipPreset Preset, string? Instructions, string? Language,
    ConnectorId Connector, string Model, bool Snap = true, bool DryRun = false);
/// <summary>Progress without prompt or transcript text; AI §4.9.</summary>
public sealed record ClipFinderProgress(string Stage, double? Fraction, int Window, int WindowCount);
/// <summary>Cancelable clip pipeline; architecture §7.2 and AI §11.</summary>
public interface IClipFinder
{
    /// <summary>Return validated suggestions; the caller stores the result and adds its clip ranges in one editor operation (AI §11.8).</summary>
    Task<AiResult> FindClipsAsync(ClipFinderRequest request, IProgress<ClipFinderProgress>? progress, CancellationToken ct);
}
/// <summary>Clip finder placeholder owned by win-ai.</summary>
public sealed class ClipFinder : IClipFinder
{
    /// <inheritdoc />
    public Task<AiResult> FindClipsAsync(ClipFinderRequest request, IProgress<ClipFinderProgress>? progress, CancellationToken ct) => ServiceStub.Missing<AiResult>("win-ai", ct);
}
