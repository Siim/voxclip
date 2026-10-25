using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Core.Services.LLM;

/// <summary>Connector ids, including decode-only AppleFoundation on Windows; AI §3.2.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ConnectorId>))]
public enum ConnectorId
{
    /// <summary>Anthropic API.</summary>
    [JsonStringEnumMemberName("anthropic")] Anthropic,
    /// <summary>OpenAI API.</summary>
    [JsonStringEnumMemberName("openai")] OpenAI,
    /// <summary>xAI API.</summary>
    [JsonStringEnumMemberName("xai")] Xai,
    /// <summary>Gemini API.</summary>
    [JsonStringEnumMemberName("gemini")] Gemini,
    /// <summary>Local Ollama.</summary>
    [JsonStringEnumMemberName("ollama")] Ollama,
    /// <summary>Local LM Studio.</summary>
    [JsonStringEnumMemberName("lmstudio")] LmStudio,
    /// <summary>macOS-only on-device connector.</summary>
    [JsonStringEnumMemberName("apple-foundation")] AppleFoundation,
    /// <summary>Installed Claude Code CLI.</summary>
    [JsonStringEnumMemberName("claude-code")] ClaudeCode,
    /// <summary>Installed Codex CLI.</summary>
    [JsonStringEnumMemberName("codex")] Codex
}
/// <summary>Requested operation; AI §3.2.</summary>
public enum LlmFeature
{
    /// <summary>Suggest clips.</summary>
    ClipFinder,
    /// <summary>M2 cut suggestions.</summary>
    AiTighten,
    /// <summary>Connection test.</summary>
    Test
}
/// <summary>Portable effort selection; AI §3.2.</summary>
public enum Effort
{
    /// <summary>Low reasoning effort.</summary>
    Low,
    /// <summary>Medium reasoning effort.</summary>
    Medium,
    /// <summary>High reasoning effort.</summary>
    High
}
/// <summary>Model-list provenance; AI §3.2.</summary>
public enum ModelSource
{
    /// <summary>Bundled catalog.</summary>
    Curated,
    /// <summary>Provider discovery.</summary>
    Discovered,
    /// <summary>User-entered id.</summary>
    Custom
}
/// <summary>Canonical request. Never log its text; AI §2.1, §4.9.</summary>
public sealed record LlmRequest(LlmFeature Feature, string System, string? CachedBlock, string Instruction,
    string SchemaName, JsonObject Schema, int MaxOutputTokens, Effort? Effort, TimeSpan Timeout, string? Language, string Tag);
/// <summary>Provider stop state; AI §3.2.</summary>
public abstract record StopKind
{
    /// <summary>Complete reply.</summary>
    public sealed record Complete : StopKind;
    /// <summary>Incomplete reply, not valid output.</summary>
    public sealed record Truncated : StopKind;
    /// <summary>Safety refusal.</summary>
    public sealed record Refused(string? Category) : StopKind;
}
/// <summary>Optional usage counts; AI §3.2.</summary>
public sealed record LlmUsage(int? Input, int? Output, int? CacheRead, int? CacheWrite);
/// <summary>One model response, before canonical validation; AI §3.2.</summary>
public sealed record RawCompletion(string? Text, JsonNode? Object, string Model, StopKind Stop, LlmUsage? Usage, string? RequestId);
/// <summary>Validated canonical result; AI §3.2.</summary>
public sealed record LlmResult(JsonObject Object, int DroppedItems, string Model, bool UsedFallback, LlmUsage? Usage, string? RequestId);
/// <summary>Provider model metadata; AI §9.</summary>
public sealed record LlmModel(string Id, string Name, string? Tier, int? ContextTokens, ModelSource Source);
/// <summary>Connector preflight state; AI §3.1.</summary>
public abstract record ConnectorStatus
{
    /// <summary>Ready.</summary>
    public sealed record Ready : ConnectorStatus;
    /// <summary>Key missing.</summary>
    public sealed record NeedsKey : ConnectorStatus;
    /// <summary>Local server not running.</summary>
    public sealed record NotRunning(string Url) : ConnectorStatus;
    /// <summary>No chat models installed.</summary>
    public sealed record NoModels : ConnectorStatus;
    /// <summary>Unavailable runtime.</summary>
    public sealed record Unavailable(string Reason) : ConnectorStatus;
    /// <summary>CLI not installed.</summary>
    public sealed record CliMissing : ConnectorStatus;
    /// <summary>CLI lacks required arguments.</summary>
    public sealed record CliTooOld(string Version, IReadOnlyList<string> Missing) : ConnectorStatus;
    /// <summary>User must sign in outside VoxClip.</summary>
    public sealed record CliSignedOut : ConnectorStatus;
}
/// <summary>One provider adapter; AI §3.2. HTTP retries stay inside SendAsync; model fallback is owned by LlmRunner.</summary>
public interface ILlmConnector
{
    /// <summary>Catalog id.</summary>
    ConnectorId Id { get; }
    /// <summary>Preflight without starting a generation.</summary>
    Task<ConnectorStatus> GetStatusAsync(CancellationToken ct);
    /// <summary>Curated plus discovered model list.</summary>
    Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct);
    /// <summary>Context limit, if known.</summary>
    Task<int?> GetContextTokensAsync(string model, CancellationToken ct);
    /// <summary>Single-model completion honoring timeout and cancellation.</summary>
    Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct);
}
/// <summary>Keys are values, never stored by Core; architecture §2.1 and AI §8.1.</summary>
public interface IKeyProvider
{
    /// <summary>Read the requested account or return null. CLI implementations read only environment variables.</summary>
    Task<string?> GetKeyAsync(string account, CancellationToken ct);
}
/// <summary>Detailed provider failure cases, separate from app-level codes; AI §5.</summary>
public enum LlmErrorKind
{
    /// <summary>No connector selected.</summary>
    NoConnector,
    /// <summary>API key missing.</summary>
    MissingKey,
    /// <summary>API key rejected.</summary>
    Unauthorized,
    /// <summary>Account credit exhausted.</summary>
    QuotaExceeded,
    /// <summary>Retry budget exhausted.</summary>
    RateLimited,
    /// <summary>Installed CLI subscription limit.</summary>
    PlanLimit,
    /// <summary>Provider overloaded.</summary>
    Overloaded,
    /// <summary>Other server error.</summary>
    Server,
    /// <summary>Network/TLS/offline error.</summary>
    Network,
    /// <summary>Request timed out, not user cancellation.</summary>
    Timeout,
    /// <summary>Model unavailable to this account.</summary>
    ModelNotFound,
    /// <summary>Context limit exceeded.</summary>
    ContextTooLong,
    /// <summary>Other client error.</summary>
    BadRequest,
    /// <summary>Provider safety refusal.</summary>
    Refused,
    /// <summary>Output token limit reached.</summary>
    Truncated,
    /// <summary>Output invalid after corrective retry.</summary>
    InvalidOutput,
    /// <summary>On-device locale gate.</summary>
    UnsupportedLanguage,
    /// <summary>Local server stopped.</summary>
    NotRunning,
    /// <summary>No local chat model.</summary>
    NoModels,
    /// <summary>Runtime unavailable.</summary>
    Unavailable,
    /// <summary>Executable missing.</summary>
    CliMissing,
    /// <summary>Required CLI flags missing.</summary>
    CliTooOld,
    /// <summary>CLI account signed out.</summary>
    CliSignedOut,
    /// <summary>Other process or parse failure.</summary>
    CliFailed,
    /// <summary>User cancelled.</summary>
    Cancelled
}
/// <summary>Detailed AI failure mapped to an architecture §10.2 code; AI §5. Metadata must already be redacted.</summary>
public sealed record LlmError(LlmErrorKind Kind, VoxClipErrorCode Code, string UserMessage, int? Status = null,
    TimeSpan? RetryAfter = null, string? Model = null, string? Reason = null);
/// <summary>AI-specific exception retained from AI §3.2. Surface its Error.Code as a VoxClipException at the application boundary.</summary>
public sealed class LlmException(LlmError error) : Exception(error.UserMessage)
{
    /// <summary>Structured failure. Message is already redacted and safe.</summary>
    public LlmError Error { get; } = error;
}
/// <summary>Catalog access and provider metadata; AI §9.</summary>
public sealed class LlmCatalog
{
    /// <summary>Read curated models from SharedResources, never from a second app copy.</summary>
    public Task<IReadOnlyList<LlmModel>> GetModelsAsync(ConnectorId connector, CancellationToken ct) => ServiceStub.Missing<IReadOnlyList<LlmModel>>("win-ai", ct);
}
/// <summary>Preflight, one fallback, validation and corrective retry; AI §3.2 and §4.</summary>
public sealed class LlmRunner
{
    /// <summary>Injected keys/catalog/redactor. The skeleton never reads or retains key values.</summary>
    public LlmRunner(IKeyProvider keys, LlmCatalog catalog, IRedactor log)
    {
        ArgumentNullException.ThrowIfNull(keys);
        ArgumentNullException.ThrowIfNull(catalog);
        ArgumentNullException.ThrowIfNull(log);
    }
    /// <summary>Run a canonical request without mutating the project.</summary>
    public Task<LlmResult> RunAsync(LlmRequest request, ILlmConnector connector, string model, CancellationToken ct) => ServiceStub.Missing<LlmResult>("win-ai", ct);
}
/// <summary>Provider adapter placeholder. Replace internals in win-ai without changing ILlmConnector.</summary>
public sealed class LlmConnector(ConnectorId id) : ILlmConnector
{
    // TODO(win-ai): replace the unavailable status with provider-specific preflight without starting generation.
    /// <inheritdoc />
    public ConnectorId Id { get; } = id;
    /// <inheritdoc />
    public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Unavailable("win-ai"));
    /// <inheritdoc />
    public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => ServiceStub.Missing<IReadOnlyList<LlmModel>>("win-ai", ct);
    /// <inheritdoc />
    public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => ServiceStub.Missing<int?>("win-ai", ct);
    /// <inheritdoc />
    public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct) => ServiceStub.Missing<RawCompletion>("win-ai", ct);
}
