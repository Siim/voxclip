namespace VoxClip.Core.Services.LLM;

/// <summary>Future paid-action estimate, no provider calls in M1; Voice Lab §3.1.</summary>
public sealed record CostEstimate(string Provider, string Operation, double Units, string Unit, decimal? Usd, int? Credits, string Basis);
/// <summary>Future lip-sync quality tier; Voice Lab §9.1.</summary>
public enum LipsyncTier
{
    /// <summary>Fast.</summary>
    Fast,
    /// <summary>Quality.</summary>
    Quality,
    /// <summary>Best.</summary>
    Best
}
/// <summary>Future model capability; Voice Lab §9.1.</summary>
public sealed record LipsyncModel(string Provider, string Id, LipsyncTier Tier, bool SupportsRemap);
/// <summary>Future duration behavior; Voice Lab §9.1.</summary>
public enum SyncMode
{
    /// <summary>Cut to matching duration.</summary>
    CutOff,
    /// <summary>Remap output.</summary>
    Remap
}
/// <summary>Future provider options; Voice Lab §9.1.</summary>
public sealed record LipsyncOptions(SyncMode SyncMode, uint? Seed);
/// <summary>Future remote job identity, not part of schema-v1 projects; Voice Lab §9.1.</summary>
public sealed record LipsyncJob(LipsyncModel Model, string RemoteId, Uri? StatusUrl, Uri? ResponseUrl, Uri? CancelUrl,
    IReadOnlyList<string> UploadedAssetIds, DateTimeOffset SubmittedAt);
/// <summary>Future remote state; Voice Lab §9.1.</summary>
public abstract record LipsyncState
{
    /// <summary>Waiting.</summary>
    public sealed record Queued(int? Position) : LipsyncState;
    /// <summary>Processing.</summary>
    public sealed record Running(double? Progress) : LipsyncState;
    /// <summary>Downloadable result.</summary>
    public sealed record Done(Uri Result) : LipsyncState;
    /// <summary>Safe provider error metadata.</summary>
    public sealed record Failed(string Code, string Message) : LipsyncState;
}
/// <summary>Future explicit paid-action boundary; Voice Lab §9.1. No implementation or credentials in the M1 skeleton.</summary>
public interface ILipsyncProvider
{
    /// <summary>Provider id.</summary>
    string Id { get; }
    /// <summary>Supported model list.</summary>
    IReadOnlyList<LipsyncModel> Models { get; }
    /// <summary>Estimate before billing.</summary>
    Task<CostEstimate> EstimateAsync(LipsyncModel model, double seconds, double fps, CancellationToken ct);
    /// <summary>Submit only after consent and cost confirmation.</summary>
    Task<LipsyncJob> SubmitAsync(LipsyncModel model, string videoPath, string audioPath, LipsyncOptions options, CancellationToken ct);
    /// <summary>Read status.</summary>
    Task<LipsyncState> PollAsync(LipsyncJob job, CancellationToken ct);
    /// <summary>Cancel remote work; cancellation token is explicit on Windows.</summary>
    Task CancelAsync(LipsyncJob job, CancellationToken ct);
    /// <summary>Download validated output with progress.</summary>
    Task DownloadAsync(Uri result, string path, IProgress<double>? progress, CancellationToken ct);
    /// <summary>Delete provider uploads when supported.</summary>
    Task CleanupAsync(LipsyncJob job, CancellationToken ct);
}
