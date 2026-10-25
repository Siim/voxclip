using System.Text.Json;
using System.Text.Json.Nodes;
using System.Reflection;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.LLM;

public sealed partial class LlmCatalog
{
    private readonly string? root;
    private JsonObject? data;
    /// <summary>Resolve the one shared catalog lazily through SharedResources.</summary>
    public LlmCatalog() { }
    /// <summary>Eagerly load the shared provider catalog; plan §4.2.2 W7.</summary>
    public static LlmCatalog Load(string sharedRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sharedRoot);
        var catalog = new LlmCatalog(sharedRoot);
        _ = catalog.Data;
        return catalog;
    }
    internal LlmCatalog(string sharedRoot) => root = sharedRoot;
    internal string SharedRoot => root ?? SharedResources.ResolveRoot();
    internal JsonObject Data => data ??= ReadAsset("catalog/llm-providers.json");
    internal JsonObject ReadAsset(string relative)
    {
        try
        {
            var asset = JsonNode.Parse(File.ReadAllText(Path.Combine(SharedRoot, relative)))!.AsObject();
            if (asset["schemaVersion"]?.GetValue<int>() != 1) throw new JsonException();
            return asset;
        }
        catch (Exception exception) when (exception is IOException or JsonException or InvalidOperationException)
        {
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        }
    }
    internal JsonObject Provider(ConnectorId id) => Data["connectors"]!.AsArray().OfType<JsonObject>().Single(provider => provider["id"]!.GetValue<string>() == WireId(id));
    internal JsonObject? Model(ConnectorId id, string model) => Provider(id)["models"]?.AsArray().OfType<JsonObject>().FirstOrDefault(item => item["id"]!.GetValue<string>() == model);
    internal IReadOnlyList<LlmModel> Models(ConnectorId id) => Provider(id)["models"]!.AsArray().OfType<JsonObject>()
        .Select(model => new LlmModel(model["id"]!.GetValue<string>(), model["name"]!.GetValue<string>(), model["tier"]?.GetValue<string>(), model["contextTokens"]?.GetValue<int>(), ModelSource.Curated)).ToArray();
    internal string? Fallback(ConnectorId id, string model) => Provider(id)["fallbackOrder"]!.AsArray().Select(item => item!.GetValue<string>()).FirstOrDefault(item => item != model);
    internal TimeSpan Timeout(string kind) => TimeSpan.FromSeconds(Data["policy"]!["timeoutsSeconds"]![kind]!.GetValue<double>());
    internal int Cap(ConnectorId id, int requested) => Math.Min(requested, Provider(id)["maxOutputTokensCap"]?.GetValue<int>() ?? requested);
    internal double BytesPerToken => Data["policy"]!["tokenEstimate"]!["utf8BytesPerToken"]!.GetValue<double>();
    internal int Estimate(string? text) => Domain.Clips.ClipWindowing.Estimate(text, BytesPerToken);
    internal TimeSpan RetryBackoff(int attempt) => TimeSpan.FromSeconds(Data["policy"]!["retry"]!["backoffSeconds"]![attempt]!.GetValue<double>());
    internal TimeSpan MaxRetryAfter => TimeSpan.FromSeconds(Data["policy"]!["retry"]!["maxRetryAfterSeconds"]!.GetValue<double>());
    internal static string WireId(ConnectorId id) => id switch { ConnectorId.OpenAI => "openai", ConnectorId.LmStudio => "lmstudio", ConnectorId.AppleFoundation => "apple-foundation", ConnectorId.ClaudeCode => "claude-code", _ => id.ToString().ToLowerInvariant() };
    internal static string FeatureId(LlmFeature feature) => feature switch { LlmFeature.ClipFinder => "clipFinder", LlmFeature.AiTighten => "aiTighten", LlmFeature.VoiceRewrite => "voiceRewrite", _ => "test" };
    /// <summary>Build the shared catalog's connection test with the connector's timeout; AI §10.2.</summary>
    public LlmRequest TestRequest(ConnectorId id)
    {
        var test = Data["testRequest"]!;
        return new(LlmFeature.Test, test["system"]!.GetValue<string>(), null, test["instruction"]!.GetValue<string>(),
            test["schemaName"]!.GetValue<string>(), test["schema"]!.DeepClone().AsObject(), test["maxOutputTokens"]!.GetValue<int>(),
            Effort.Low, Timeout(id is ConnectorId.ClaudeCode or ConnectorId.Codex ? "cliTest" : "test"), "en", "test");
    }
}

internal static class LlmRuntime
{
    internal static readonly JsonSerializerOptions CompactJson = VoxClip.Core.Domain.Shared.JsonFormatting.CreateOptions(new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    internal static readonly HttpClient Http = new(CreateHttpHandler()) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
    internal static readonly AsyncLocal<HttpClient?> ScopedKeyedHttp = new();
    internal static HttpClient KeyedHttp => ScopedKeyedHttp.Value ?? Http;
    internal static SocketsHttpHandler CreateHttpHandler() => new() { UseCookies = false, AllowAutoRedirect = false };
    internal static readonly string Version = typeof(LlmRuntime).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.0.0";
}

internal sealed class EmptyKeys : IKeyProvider
{
    public Task<string?> GetKeyAsync(string account, CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.FromResult<string?>(null); }
}
