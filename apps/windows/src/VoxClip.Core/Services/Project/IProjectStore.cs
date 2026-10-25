using VoxClip.Core.Domain.Shared;
using ProjectModel = VoxClip.Core.Domain.Shared.Project;
namespace VoxClip.Core.Services.Project;

/// <summary>Project load plus cleaned-reference warnings; editing §10.4.</summary>
public sealed record ProjectOpenResult(ProjectModel Project, string? ResolvedMediaPath, bool IsReadOnly, IReadOnlyList<string> Warnings);
/// <summary>Atomic project persistence and relinking boundary; editing §10.</summary>
public interface IProjectStore
{
    /// <summary>Load and validate; missing media never discards saved edits.</summary>
    Task<ProjectOpenResult> LoadAsync(string path, CancellationToken ct);
    /// <summary>Atomic UTF8 save, recomputing relativePath and writer identity.</summary>
    Task SaveAsync(ProjectModel project, string path, CancellationToken ct);
    /// <summary>Resolve source by absolute path, relative path, then explicit user relink.</summary>
    Task<string?> ResolveMediaAsync(MediaReference source, string projectPath, CancellationToken ct);
    /// <summary>Compute the shared content key, not a whole-file SHA256; architecture §8.1.</summary>
    Task<string> ComputeContentKeyAsync(string mediaPath, IProgress<double>? progress, CancellationToken ct);
}
/// <summary>Project store placeholder owned by win-editing.</summary>
public sealed class ProjectStore : IProjectStore
{
    /// <inheritdoc />
    public Task<ProjectOpenResult> LoadAsync(string path, CancellationToken ct) => ServiceStub.Missing<ProjectOpenResult>("win-editing", ct);
    /// <inheritdoc />
    public Task SaveAsync(ProjectModel project, string path, CancellationToken ct) => ServiceStub.Missing("win-editing", ct);
    /// <inheritdoc />
    public Task<string?> ResolveMediaAsync(MediaReference source, string projectPath, CancellationToken ct) => ServiceStub.Missing<string?>("win-editing", ct);
    /// <inheritdoc />
    public Task<string> ComputeContentKeyAsync(string mediaPath, IProgress<double>? progress, CancellationToken ct) => ServiceStub.Missing<string>("win-editing", ct);
}
