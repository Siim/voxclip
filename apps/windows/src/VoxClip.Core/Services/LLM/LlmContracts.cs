using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Process;
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
    Test,
    /// <summary>One explicitly approved, review-only Voice Lab rewrite.</summary>
    VoiceRewrite
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
public sealed record LlmUsage(long? Input, long? Output, long? CacheRead, long? CacheWrite);
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
public sealed partial class LlmCatalog
{
    /// <summary>Read curated models from SharedResources, never from a second app copy.</summary>
    public Task<IReadOnlyList<LlmModel>> GetModelsAsync(ConnectorId connector, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult<IReadOnlyList<LlmModel>>(Models(connector));
    }
}
/// <summary>Preflight, one fallback, validation and corrective retry; AI §3.2 and §4.</summary>
public sealed partial class LlmRunner
{
    private readonly IKeyProvider keys;
    private readonly LlmCatalog catalog;
    private readonly IRedactor log;
    private readonly Action<LlmErrorKind, string>? onError;
    /// <summary>Injected keys/catalog/redactor. The skeleton never reads or retains key values.</summary>
    public LlmRunner(IKeyProvider keys, LlmCatalog catalog, IRedactor log, Action<LlmErrorKind, string>? onError = null)
    {
        ArgumentNullException.ThrowIfNull(keys);
        ArgumentNullException.ThrowIfNull(catalog);
        ArgumentNullException.ThrowIfNull(log);
        this.keys = keys;
        this.catalog = catalog;
        this.log = log;
        this.onError = onError;
    }
    /// <summary>Run a canonical request without mutating the project.</summary>
    public Task<LlmResult> RunAsync(LlmRequest request, ILlmConnector connector, string model, CancellationToken ct) => RunCoreAsync(request, connector, model, ct);
    /// <summary>Run the catalog test through preflight, fallback and validation; AI §10.2.</summary>
    public async Task<LlmConnectionTestResult> TestAsync(ILlmConnector connector, string model, CancellationToken ct)
    {
        var started = System.Diagnostics.Stopwatch.StartNew();
        var result = await RunAsync(catalog.TestRequest(connector.Id), connector, model, ct).ConfigureAwait(false);
        var passed = result.Object["ok"]?.GetValue<bool>() == true &&
            Domain.Clips.ClipText.Trim(result.Object["echo"]?.GetValue<string>() ?? "").Equals("voxclip", StringComparison.OrdinalIgnoreCase);
        return new(passed, result.Model, result.UsedFallback, started.Elapsed.TotalSeconds);
    }
}
/// <summary>Connection-test outcome without storing a project result; AI §10.2.</summary>
public sealed record LlmConnectionTestResult(bool Passed, string Model, bool UsedFallback, double Seconds);
/// <summary>Safe installed CLI metadata for status and consent; never contains credentials.</summary>
public sealed record CliDetectionInfo(string Path, string Version, string? AuthMethod, bool UsesApiKey);
/// <summary>Who pays for an installed CLI's sends, as its sign-in check reports it: Claude Code's <c>authMethod</c> (AI §6.8) or
/// whether <c>codex login status</c> says "API key" (AI §6.9). A method the app does not recognise has no value; it never
/// counts as a plan.</summary>
public enum CliSignIn
{
    /// <summary>A Claude or ChatGPT plan: a send counts toward the plan and costs nothing extra.</summary>
    Plan,
    /// <summary>An API key: a send is billed to the key the CLI is signed in with.</summary>
    ApiKey
}
/// <summary>HTTP or standalone CLI provider adapter; AI §6.</summary>
public sealed partial class LlmConnector : ILlmConnector
{
    /// <summary>Unavailable compatibility placeholder; use W7 to configure an adapter.</summary>
    public LlmConnector(ConnectorId id) : this(id, new EmptyKeys(), new LlmCatalog(), new Redactor())
    { unavailableReason = "Choose and configure an AI connector in Settings."; }
    /// <summary>Build a connector with injected process and keyless local HTTP transports; W7. Core owns cloud key-bearing HTTP, disables redirects and cookies, and honours the system proxy regardless of the supplied client.</summary>
    public LlmConnector(ConnectorId id, IKeyProvider keys, IProcessRunner processes, LlmCatalog catalog, HttpClient http)
        : this(id, keys, processes, catalog, http, new Redactor()) { }
    /// <summary>W7 with explicit local/CLI settings, redaction and safe diagnostics; AI §4.9 and §8.2. The supplied HTTP client is used only for Ollama and LM Studio; Core's cookie-free cloud transport never redirects and honours the system proxy.</summary>
    public LlmConnector(ConnectorId id, IKeyProvider keys, IProcessRunner processes, LlmCatalog catalog, HttpClient http,
        IRedactor redactor, string? baseUrl = null, string? cliPath = null, Action<string>? onDiagnostic = null)
        : this(id, catalog, id is ConnectorId.Ollama or ConnectorId.LmStudio ? http : LlmRuntime.KeyedHttp, keys, redactor, baseUrl: baseUrl, processes: processes, binaryOverride: cliPath,
            onDiagnostic: onDiagnostic, cacheFile: System.IO.Path.Combine(Services.Project.DataLocations.Resolve().Cache, "llm-models.json")) { }
    /// <summary>App and CLI construction path. Keys come only from the supplied provider; optional server URL and CLI path are explicit user settings.</summary>
    public LlmConnector(ConnectorId id, IKeyProvider keys, LlmCatalog catalog, IRedactor redactor, string? baseUrl = null, string? cliPath = null)
        : this(id, keys, new ProcessRunner(), catalog, LlmRuntime.Http, redactor, baseUrl, cliPath) { }
    /// <inheritdoc />
    public ConnectorId Id { get; }
    /// <summary>The last CLI detection and authentication method, or null before detection.</summary>
    public CliDetectionInfo? CliDetection => cli?.DetectionInfo;
    /// <inheritdoc />
    public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => StatusAsync(ct);
    /// <inheritdoc />
    public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => ModelsAsync(refresh, ct);
    /// <inheritdoc />
    public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => ContextAsync(model, ct);
    /// <inheritdoc />
    public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct) => SendCoreAsync(request, model, ct);
}
