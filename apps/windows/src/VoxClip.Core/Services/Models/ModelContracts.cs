using VoxClip.Core.Domain.Transcript;
namespace VoxClip.Core.Services.Models;

/// <summary>One commit-pinned model file; transcription §12.1.</summary>
public sealed record ModelFile(string Role, string Name, Uri Url, long Bytes, string Sha256);
/// <summary>Downloadable model catalog entry; transcription §12.1. RawMetadata preserves engine-specific catalog extensions.</summary>
public sealed record TranscriptionModel(string Id, TranscriptEngine Engine, string Kind, IReadOnlyList<string> Languages,
    string? ForcedLanguage, bool Verbatim, TimingSource Timing, IReadOnlyList<ModelFile> Files, long TotalBytes,
    IReadOnlyList<string> Requires, string License, Uri LicenseUrl, string Attribution, bool Listed,
    System.Text.Json.JsonElement RawMetadata);
/// <summary>Installed model and verification status; transcription §12.2.</summary>
public sealed record InstalledModel(string Id, string Directory, bool Verified, DateTimeOffset? VerifiedAt);
/// <summary>Model transfer/verification progress; transcription §12.3.</summary>
public sealed record ModelDownloadProgress(string ModelId, string File, string Stage, long BytesReceived, long? TotalBytes);
/// <summary>Bundled catalog reader; transcription §12.1. Catalog is never downloaded in v1.</summary>
public interface IModelCatalog
{
    /// <summary>Read all entries from the single shared catalog.</summary>
    Task<IReadOnlyList<TranscriptionModel>> GetModelsAsync(CancellationToken ct);
    /// <summary>Resolve a stable catalog id.</summary>
    Task<TranscriptionModel?> GetModelAsync(string id, CancellationToken ct);
}
/// <summary>Explicit cancelable downloads with SHA256 validation; transcription §12.3.</summary>
public interface IModelDownloader
{
    /// <summary>Install the model and required entries only after user confirmation.</summary>
    Task<InstalledModel> InstallAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct);
    /// <summary>Verify every file before native loading.</summary>
    Task<bool> VerifyAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct);
    /// <summary>Remove only the explicitly selected installed model.</summary>
    Task RemoveAsync(string id, CancellationToken ct);
    /// <summary>List installed models, never treating them as disposable cache.</summary>
    Task<IReadOnlyList<InstalledModel>> ListInstalledAsync(CancellationToken ct);
}
/// <summary>Catalog reader placeholder owned by win-speech.</summary>
public sealed class ModelCatalog : IModelCatalog
{
    /// <inheritdoc />
    public Task<IReadOnlyList<TranscriptionModel>> GetModelsAsync(CancellationToken ct) => ServiceStub.Missing<IReadOnlyList<TranscriptionModel>>("win-speech", ct);
    /// <inheritdoc />
    public Task<TranscriptionModel?> GetModelAsync(string id, CancellationToken ct) => ServiceStub.Missing<TranscriptionModel?>("win-speech", ct);
}
/// <summary>Model manager placeholder owned by win-speech.</summary>
public sealed class ModelStore : IModelDownloader
{
    // TODO(win-speech): enumerate verified installed models instead of the startup-safe empty list.
    /// <inheritdoc />
    public Task<InstalledModel> InstallAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct) => ServiceStub.Missing<InstalledModel>("win-speech", ct);
    /// <inheritdoc />
    public Task<bool> VerifyAsync(string id, IProgress<ModelDownloadProgress>? progress, CancellationToken ct) => ServiceStub.Missing<bool>("win-speech", ct);
    /// <inheritdoc />
    public Task RemoveAsync(string id, CancellationToken ct) => ServiceStub.Missing("win-speech", ct);
    /// <inheritdoc />
    public Task<IReadOnlyList<InstalledModel>> ListInstalledAsync(CancellationToken ct) => Task.FromResult<IReadOnlyList<InstalledModel>>([]);
}
