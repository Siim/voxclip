using System.Text.Json;
using System.Text.Json.Serialization;
namespace VoxClip.Core.Services.Settings;

/// <summary>Flat dotted-key settings; architecture §2.5 and settings.schema.json. Never contains credentials.</summary>
public sealed record AppSettings
{
    /// <summary>Construct the schema envelope; unknown dotted keys are retained by extension data.</summary>
    [JsonConstructor]
    public AppSettings(string schema) => Schema = schema;
    /// <summary>Required voxclip-settings/1 discriminator.</summary>
    public string Schema { get; init; }
    /// <summary>Flat settings entries, including unknown keys and per-connector models. Treat each loaded instance as a snapshot.</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement> Values { get; set; } = [];
}
/// <summary>Atomic, 500ms-debounced settings persistence; architecture §2.5 and §7.2. Never stores keys.</summary>
public interface ISettingsStore
{
    /// <summary>Read or return documented defaults for a missing settings file.</summary>
    Task<AppSettings> LoadAsync(CancellationToken ct);
    /// <summary>Schedule an atomic write after the debounce.</summary>
    Task SaveAsync(AppSettings settings, CancellationToken ct);
    /// <summary>Flush the pending snapshot on orderly close.</summary>
    Task FlushAsync(CancellationToken ct);
}
/// <summary>Settings store placeholder owned by win-editing.</summary>
public sealed class SettingsStore : ISettingsStore
{
    // TODO(win-editing): load defaults and persisted settings; the empty snapshot has no pending write to flush.
    /// <inheritdoc />
    public Task<AppSettings> LoadAsync(CancellationToken ct)
        => ct.IsCancellationRequested ? Task.FromCanceled<AppSettings>(ct) : Task.FromResult(new AppSettings("voxclip-settings/1"));
    /// <inheritdoc />
    public Task SaveAsync(AppSettings settings, CancellationToken ct) => ServiceStub.Missing("win-editing", ct);
    /// <inheritdoc />
    public Task FlushAsync(CancellationToken ct) => ct.IsCancellationRequested ? Task.FromCanceled(ct) : Task.CompletedTask;
}
