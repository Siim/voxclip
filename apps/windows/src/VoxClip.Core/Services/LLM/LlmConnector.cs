using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Process;

namespace VoxClip.Core.Services.LLM;

public sealed partial class LlmConnector
{
    private const string InvalidKeyDestination = "VoxClip is missing its AI configuration. Reinstall VoxClip.";
    private sealed record KeyDestination(string Account, string Host, string Header, string ValueTemplate);
    private readonly KeyDestination? keyDestination;
    private readonly LlmCatalog catalog;
    private readonly HttpClient http;
    private IKeyProvider keys;
    private IRedactor redactor;
    private readonly Action<string>? onDiagnostic;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly Uri? baseUri;
    private readonly string? unavailableReason;
    private readonly string? cacheFile;
    private readonly Dictionary<string, JsonObject> discovered = new(StringComparer.Ordinal);
    private readonly Dictionary<string, JsonObject> localDetails = new(StringComparer.Ordinal);
    private IReadOnlyList<LlmModel>? modelCache;
    private bool betaUnsupported;
    private readonly CliLlmAdapter? cli;

    internal LlmConnector(ConnectorId id, LlmCatalog catalog, HttpClient http, IKeyProvider keys, IRedactor redactor,
        Func<TimeSpan, CancellationToken, Task>? delay = null, string? baseUrl = null, Action<string>? onDiagnostic = null,
        IProcessRunner? processes = null, string? binaryOverride = null, string? cacheFile = null)
    {
        Id = id;
        keyDestination = id switch
        {
            ConnectorId.Anthropic => new("llm-api-key-anthropic", "api.anthropic.com", "x-api-key", "{key}"),
            ConnectorId.OpenAI => new("llm-api-key-openai", "api.openai.com", "Authorization", "Bearer {key}"),
            ConnectorId.Xai => new("llm-api-key-xai", "api.x.ai", "Authorization", "Bearer {key}"),
            ConnectorId.Gemini => new("llm-api-key-gemini", "generativelanguage.googleapis.com", "x-goog-api-key", "{key}"),
            _ => null
        };
        this.catalog = catalog;
        this.http = http;
        this.keys = keys;
        this.redactor = redactor;
        this.delay = delay ?? Task.Delay;
        this.onDiagnostic = onDiagnostic;
        this.cacheFile = cacheFile;
        var provider = catalog.Provider(id);
        var address = (id is ConnectorId.Ollama or ConnectorId.LmStudio ? baseUrl : null) ?? provider["baseUrl"]?.GetValue<string>();
        if (address is not null)
        {
            if (Uri.TryCreate(address.TrimEnd('/') + "/", UriKind.Absolute, out var parsed) &&
                parsed.Scheme is "http" or "https" && parsed.Host.Length > 0 && parsed.Query.Length == 0 && parsed.Fragment.Length == 0 && parsed.UserInfo.Length == 0 &&
                (keyDestination is null || parsed.Scheme == "https") &&
                (id is not (ConnectorId.Ollama or ConnectorId.LmStudio) || parsed.IsLoopback)) baseUri = parsed;
            else unavailableReason = $"{Label}'s server address in Settings isn't valid.";
        }
        if (!MatchesKeyConfiguration() || keyDestination is not null && !AllowsStoredKey(baseUri)) unavailableReason = InvalidKeyDestination;
        if (id is ConnectorId.ClaudeCode or ConnectorId.Codex) cli = new(id, catalog, processes ?? new ProcessRunner(), redactor, onDiagnostic, binaryOverride);
    }

    internal void Configure(IKeyProvider provider, IRedactor log) { keys = provider; redactor = log; cli?.SetRedactor(log); }
    private JsonObject Provider => catalog.Provider(Id);
    private string Label => Provider["label"]!.GetValue<string>();
    internal static string UserContent(LlmRequest request) => request.CachedBlock is null ? request.Instruction : request.CachedBlock + "\n\n" + request.Instruction;

    private async Task<ConnectorStatus> StatusAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (unavailableReason is not null) return new ConnectorStatus.Unavailable(unavailableReason);
        if (cli is not null) return await cli.StatusAsync(ct).ConfigureAwait(false);
        if (Id == ConnectorId.AppleFoundation) return new ConnectorStatus.Unavailable("Apple Intelligence is available only on macOS.");
        if (keyDestination is { } destination)
        {
            string? key;
            try { key = await keys.GetKeyAsync(destination.Account, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { return new ConnectorStatus.NeedsKey(); }
            if (!string.IsNullOrWhiteSpace(key)) return new ConnectorStatus.Ready();
            return new ConnectorStatus.NeedsKey();
        }
        try
        {
            await GetAsync(Id == ConnectorId.Ollama ? "/api/version" : "/v1/models", catalog.Timeout("status"), ct).ConfigureAwait(false);
            return (await ModelsAsync(true, ct).ConfigureAwait(false)).Count == 0 ? new ConnectorStatus.NoModels() : new ConnectorStatus.Ready();
        }
        catch (LlmException exception) when (exception.Error.Kind is LlmErrorKind.NotRunning or LlmErrorKind.Timeout or LlmErrorKind.Network)
        { return new ConnectorStatus.NotRunning(baseUri!.GetLeftPart(UriPartial.Path).TrimEnd('/')); }
        catch (LlmException exception) when (exception.Error.Kind == LlmErrorKind.BadRequest && Id is ConnectorId.Ollama or ConnectorId.LmStudio)
        { return new ConnectorStatus.Unavailable($"{Label} rejected the request ({exception.Error.Status})."); }
        catch (LlmException exception) when (exception.Error.Kind != LlmErrorKind.Cancelled)
        { return new ConnectorStatus.Unavailable(exception.Error.UserMessage.Replace(" Your edits are saved.", "", StringComparison.Ordinal)); }
    }

    private async Task<int?> ContextAsync(string model, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        EnsureAvailable(model);
        if (cli is not null) return catalog.Model(Id, model)?["contextTokens"]?.GetValue<int>();
        if (Id == ConnectorId.Ollama)
        {
            var details = await OllamaDetailsAsync(model, ct).ConfigureAwait(false);
            return details["model_info"]?.AsObject().FirstOrDefault(field => field.Key.EndsWith(".context_length", StringComparison.Ordinal)).Value?.GetValue<int>() ?? 4096;
        }
        if (Id == ConnectorId.LmStudio)
        {
            try
            {
                var details = await GetAsync("/api/v0/models/" + Uri.EscapeDataString(model), catalog.Timeout("modelList"), ct).ConfigureAwait(false);
                if (details?["state"]?.GetValue<string>() == "loaded")
                {
                    if (details["loaded_context_length"] is JsonValue loaded && loaded.TryGetValue<int>(out var context) && context > 0) return context;
                    if (details["max_context_length"] is JsonValue maximum && maximum.TryGetValue<int>(out context) && context > 0) return context;
                }
            }
            catch (LlmException exception) when (exception.Error.Kind != LlmErrorKind.Cancelled) { }
            return 4096;
        }
        return discovered.GetValueOrDefault(model)?["max_input_tokens"]?.GetValue<int>() ??
            discovered.GetValueOrDefault(model)?["inputTokenLimit"]?.GetValue<int>() ?? catalog.Model(Id, model)?["contextTokens"]?.GetValue<int>();
    }

    private async Task<JsonObject> OllamaDetailsAsync(string model, CancellationToken ct)
    {
        if (localDetails.TryGetValue(model, out var cached)) return cached;
        var details = (await ExchangeAsync(HttpMethod.Post, "/api/show", new JsonObject { ["model"] = model }, catalog.Timeout("modelList"), null, model, ct).ConfigureAwait(false)).Object;
        if (details["capabilities"] is JsonArray capabilities && !capabilities.Any(item => item?.GetValue<string>() == "completion"))
            throw Error(LlmErrorKind.NoModels, model);
        localDetails[model] = details;
        return details;
    }

    private async Task<RawCompletion> SendCoreAsync(LlmRequest request, string model, CancellationToken ct)
    {
        if (ct.IsCancellationRequested) throw Error(LlmErrorKind.Cancelled, model, request.Feature);
        EnsureAvailable(model, request.Feature);
        if (cli is not null) return await cli.SendAsync(request, model, ct).ConfigureAwait(false);
        if (Id == ConnectorId.AppleFoundation) throw Error(LlmErrorKind.Unavailable, model, request.Feature, detail: "Apple Intelligence is available only on macOS.");
        try
        {
            var body = await BodyAsync(request, model, ct).ConfigureAwait(false);
            var path = Provider["generate"]!["path"]!.GetValue<string>();
            path = path.Replace("{model}", Uri.EscapeDataString(model.StartsWith("models/", StringComparison.Ordinal) ? model[7..] : model), StringComparison.Ordinal);
            var response = await ExchangeAsync(HttpMethod.Post, path, body, request.Timeout, request, model, ct).ConfigureAwait(false);
            return ParseCompletion(response.Object, response.RequestId, request, model);
        }
        catch (OperationCanceledException) { throw Error(ct.IsCancellationRequested ? LlmErrorKind.Cancelled : LlmErrorKind.Timeout, model, request.Feature); }
    }

    internal async Task<JsonObject> BodyAsync(LlmRequest request, string model, CancellationToken ct)
    {
        var maxOut = catalog.Cap(Id, request.MaxOutputTokens);
        var schema = request.Schema.DeepClone();
        var effort = request.Effort?.ToString().ToLowerInvariant();
        var supportsEffort = catalog.Model(Id, model)?["effort"]?.GetValue<bool>() == true;
        if (Id == ConnectorId.Anthropic)
        {
            var capabilities = discovered.GetValueOrDefault(model)?["capabilities"];
            supportsEffort |= capabilities?["effort"]?["supported"]?.GetValue<bool>() == true || Regex.IsMatch(model, "^claude-(opus|sonnet|haiku|fable)-5", RegexOptions.CultureInvariant);
            var structured = catalog.Model(Id, model) is not null || capabilities?["structured_outputs"]?["supported"]?.GetValue<bool>() != false;
            var instruction = request.Instruction + (structured ? "" : "\n\nReply with only a JSON object that matches this JSON Schema: " + request.Schema.ToJsonString(LlmRuntime.CompactJson));
            var content = new JsonArray();
            if (request.CachedBlock is not null) content.Add((JsonNode)new JsonObject { ["type"] = "text", ["text"] = request.CachedBlock, ["cache_control"] = new JsonObject { ["type"] = "ephemeral" } });
            content.Add((JsonNode)new JsonObject { ["type"] = "text", ["text"] = instruction });
            var output = new JsonObject();
            if (supportsEffort && effort is not null) output["effort"] = effort;
            if (structured) output["format"] = new JsonObject { ["type"] = "json_schema", ["schema"] = schema };
            var body = new JsonObject { ["model"] = model, ["max_tokens"] = maxOut, ["system"] = request.System,
                ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = content }), ["output_config"] = output };
            if (request.Feature != LlmFeature.VoiceRewrite && UsesBeta(model)) body["fallbacks"] = "default";
            return body;
        }
        if (Id == ConnectorId.OpenAI)
        {
            var content = new JsonArray();
            if (request.CachedBlock is not null) content.Add((JsonNode)new JsonObject { ["type"] = "input_text", ["text"] = request.CachedBlock });
            content.Add((JsonNode)new JsonObject { ["type"] = "input_text", ["text"] = request.Instruction });
            var body = new JsonObject { ["model"] = model, ["instructions"] = request.System,
                ["input"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = content }),
                ["text"] = new JsonObject { ["format"] = SchemaFormat(request, schema) }, ["max_output_tokens"] = maxOut, ["store"] = false };
            if ((supportsEffort || Regex.IsMatch(model, "^(gpt-5|gpt-6|o[0-9])", RegexOptions.CultureInvariant)) && effort is not null)
                body["reasoning"] = new JsonObject { ["effort"] = effort };
            if (request.CachedBlock is not null) body["prompt_cache_key"] = "voxclip-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(request.CachedBlock)))[..16];
            return body;
        }
        if (Id == ConnectorId.Gemini)
        {
            var parts = new JsonArray();
            if (request.CachedBlock is not null) parts.Add((JsonNode)new JsonObject { ["text"] = request.CachedBlock });
            parts.Add((JsonNode)new JsonObject { ["text"] = request.Instruction });
            var generation = new JsonObject { ["maxOutputTokens"] = maxOut, ["responseMimeType"] = "application/json", ["responseJsonSchema"] = schema };
            var stripped = model.StartsWith("models/", StringComparison.Ordinal) ? model[7..] : model;
            if (effort is not null && Regex.IsMatch(stripped, "^gemini-([3-9]|[1-9][0-9]+)([.-]|$)", RegexOptions.CultureInvariant))
                generation["thinkingConfig"] = new JsonObject { ["thinkingLevel"] = effort.ToUpperInvariant() };
            return new JsonObject { ["systemInstruction"] = new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = request.System }) },
                ["contents"] = new JsonArray(new JsonObject { ["role"] = "user", ["parts"] = parts }),
                ["generationConfig"] = generation };
        }
        var messages = new JsonArray(new JsonObject { ["role"] = "system", ["content"] = request.System }, new JsonObject { ["role"] = "user", ["content"] = UserContent(request) });
        if (Id == ConnectorId.Ollama)
        {
            var details = await OllamaDetailsAsync(model, ct).ConfigureAwait(false);
            var context = await ContextAsync(model, ct).ConfigureAwait(false) ?? 4096;
            var needed = catalog.Estimate(request.System) + catalog.Estimate(request.CachedBlock) + catalog.Estimate(request.Instruction) + catalog.Estimate(request.Schema.ToJsonString()) + maxOut + 256;
            if (needed > context) throw Error(LlmErrorKind.ContextTooLong, model, request.Feature);
            var numContext = Math.Min(context, Math.Max(8192, (int)(Math.Ceiling(needed / 1024.0) * 1024)));
            var body = new JsonObject { ["model"] = model, ["stream"] = false, ["messages"] = messages, ["format"] = schema,
                ["options"] = new JsonObject { ["num_ctx"] = numContext, ["num_predict"] = maxOut, ["temperature"] = 0 }, ["keep_alive"] = "10m" };
            if (details["capabilities"] is JsonArray capabilities && capabilities.Any(capability => capability?.GetValue<string>() == "thinking")) body["think"] = false;
            return body;
        }
        var compatible = new JsonObject { ["model"] = model, ["messages"] = messages,
            ["response_format"] = new JsonObject { ["type"] = "json_schema", ["json_schema"] = StrictSchema(request, schema) } };
        compatible[Id == ConnectorId.Xai ? "max_completion_tokens" : "max_tokens"] = maxOut;
        if (Id == ConnectorId.LmStudio) compatible["temperature"] = 0;
        return compatible;
    }

    private static JsonObject StrictSchema(LlmRequest request, JsonNode schema) => new() { ["name"] = request.SchemaName, ["strict"] = true, ["schema"] = schema };
    private static JsonObject SchemaFormat(LlmRequest request, JsonNode schema) { var format = StrictSchema(request, schema); format["type"] = "json_schema"; return format; }
    private bool UsesBeta(string model) => !betaUnsupported && catalog.Model(Id, model)?["serverSideFallback"]?.GetValue<bool>() == true;

    private async Task<JsonObject?> GetAsync(string path, TimeSpan timeout, CancellationToken ct) =>
        (await ExchangeAsync(HttpMethod.Get, path, null, timeout, null, "", ct).ConfigureAwait(false)).Object;

    private async Task<(JsonObject Object, string? RequestId)> ExchangeAsync(HttpMethod method, string path, JsonObject? body, TimeSpan timeout,
        LlmRequest? canonical, string model, CancellationToken ct)
    {
        var feature = canonical?.Feature ?? LlmFeature.Test;
        EnsureAvailable(model, feature);
        var attempts = catalog.Data["policy"]!["retry"]!["attempts"]!.GetValue<int>();
        for (var attempt = 0; ; attempt++)
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(timeout);
            var stopwatch = Stopwatch.StartNew();
            var status = 0;
            var recorded = false;
            string? key = null;
            try
            {
                using var request = new HttpRequestMessage(method, new Uri(baseUri!, path.TrimStart('/')));
                request.Headers.TryAddWithoutValidation("User-Agent", $"VoxClip/{LlmRuntime.Version} ({(OperatingSystem.IsWindows() ? "Windows" : "macOS")})");
                if (keyDestination is { } destination)
                {
                    if (!AllowsStoredKey(request.RequestUri)) throw Error(LlmErrorKind.Unavailable, model, feature, detail: InvalidKeyDestination);
                    try { key = (await keys.GetKeyAsync(destination.Account, deadline.Token).ConfigureAwait(false))?.Trim(); }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception) { throw Error(LlmErrorKind.MissingKey, model, feature); }
                    if (string.IsNullOrEmpty(key)) throw Error(LlmErrorKind.MissingKey, model, feature);
                    request.Headers.TryAddWithoutValidation(destination.Header, destination.ValueTemplate.Replace("{key}", key, StringComparison.Ordinal));
                }
                if (Id == ConnectorId.Anthropic)
                {
                    request.Headers.TryAddWithoutValidation("anthropic-version", Provider["headers"]!["anthropic-version"]!.GetValue<string>());
                    if (body?.ContainsKey("fallbacks") == true) request.Headers.TryAddWithoutValidation("anthropic-beta", Provider["serverSideFallback"]!["betaHeader"]!.GetValue<string>());
                }
                if (body is not null)
                {
                    request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
                    request.Content.Headers.ContentType!.CharSet = null;
                }
                using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
                if (keyDestination is not null && response.RequestMessage?.RequestUri is { } finalUri &&
                    (!AllowsStoredKey(finalUri) || finalUri.Port != request.RequestUri!.Port))
                    throw Error(LlmErrorKind.Unavailable, model, feature, detail: InvalidKeyDestination);
                status = (int)response.StatusCode;
                var responseText = feature == LlmFeature.VoiceRewrite
                    ? await ReadRewriteResponseAsync(response.Content, deadline.Token).ConfigureAwait(false)
                    : await response.Content.ReadAsStringAsync(deadline.Token).ConfigureAwait(false);
                var parsed = LlmOutput.Envelope(responseText) as JsonObject ?? new JsonObject();
                var requestIdHeader = Provider["requestIdHeader"]?.GetValue<string>();
                var requestId = requestIdHeader is not null && response.Headers.TryGetValues(requestIdHeader, out var values) ? values.FirstOrDefault() : null;
                WriteAttempt(model, canonical, attempt, status, stopwatch.Elapsed, parsed, requestId, key);
                recorded = true;
                if (response.IsSuccessStatusCode) return (parsed, requestId);
                var message = parsed["error"] is JsonValue value ? value.GetValue<string>() : parsed["error"]?["message"]?.GetValue<string>() ?? "The provider rejected the request.";
                if (feature != LlmFeature.VoiceRewrite && Id == ConnectorId.Anthropic && status == 400 && body?.ContainsKey("fallbacks") == true && message.Contains("anthropic-beta", StringComparison.OrdinalIgnoreCase) && message.Contains("unexpected", StringComparison.OrdinalIgnoreCase))
                { betaUnsupported = true; body.Remove("fallbacks"); attempt--; continue; }
                var retryAfter = RetryAfter(response, parsed);
                var kind = Classify(status, parsed, message);
                var safe = key is null ? redactor.Redact(message) : new Redactor([key]).Redact(redactor.Redact(message));
                if (status == 404 && model.Length == 0 && Id is ConnectorId.Ollama or ConnectorId.LmStudio)
                {
                    kind = LlmErrorKind.Unavailable;
                    safe = $"{Label}'s server address in Settings isn't valid.";
                }
                if (status is 401 or 403 && keyDestination is null) safe = $"{Label} rejected the request ({status}).";
                var failure = Error(kind, model, feature, status, safe, retryAfter);
                var retryStatus = catalog.Data["policy"]!["retry"]!["retryStatuses"]!.AsArray().Any(item => item!.GetValue<int>() == status);
                if (feature == LlmFeature.VoiceRewrite || !retryStatus || kind is LlmErrorKind.QuotaExceeded or LlmErrorKind.Timeout or LlmErrorKind.Unauthorized or LlmErrorKind.ContextTooLong or LlmErrorKind.ModelNotFound) throw failure;
                if (retryAfter > catalog.MaxRetryAfter) throw Error(LlmErrorKind.RateLimited, model, feature, status, retryAfter: retryAfter);
                if (attempt + 1 >= attempts) throw failure;
                await delay(retryAfter ?? catalog.RetryBackoff(attempt), ct).ConfigureAwait(false);
            }
            catch (HttpRequestException exception)
            {
                WriteAttempt(model, canonical, attempt, status, stopwatch.Elapsed, null, null, key);
                recorded = true;
                if (feature != LlmFeature.VoiceRewrite && ConnectionReset(exception) && attempt + 1 < attempts)
                { await delay(catalog.RetryBackoff(attempt), ct).ConfigureAwait(false); continue; }
                throw Error(Id is ConnectorId.Ollama or ConnectorId.LmStudio ? LlmErrorKind.NotRunning : LlmErrorKind.Network, model, feature, detail: baseUri?.GetLeftPart(UriPartial.Path));
            }
            catch (OperationCanceledException)
            {
                throw Error(ct.IsCancellationRequested ? LlmErrorKind.Cancelled : LlmErrorKind.Timeout, model, feature);
            }
            finally { if (!recorded) WriteAttempt(model, canonical, attempt, status, stopwatch.Elapsed, null, null, key); }
        }
    }

    private static bool ConnectionReset(Exception? exception)
    {
        for (; exception is not null; exception = exception.InnerException)
            if (exception is SocketException { SocketErrorCode: SocketError.ConnectionReset }) return true;
        return false;
    }

    private static async Task<string> ReadRewriteResponseAsync(HttpContent content, CancellationToken ct)
    {
        const int limit = 1024 * 1024;
        if (content.Headers.ContentLength > limit) throw LlmErrors.Create(LlmErrorKind.InvalidOutput, "", feature: LlmFeature.VoiceRewrite);
        await using var stream = await content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, ct).ConfigureAwait(false);
            if (count == 0) break;
            if (output.Length + count > limit) throw LlmErrors.Create(LlmErrorKind.InvalidOutput, "", feature: LlmFeature.VoiceRewrite);
            output.Write(buffer, 0, count);
        }
        return Encoding.UTF8.GetString(output.GetBuffer().AsSpan(0, (int)output.Length));
    }

    private LlmErrorKind Classify(int status, JsonObject body, string message)
    {
        var error = body["error"] as JsonObject;
        var code = error?["code"]?.ToString() ?? "";
        var type = error?["type"]?.GetValue<string>() ?? "";
        var lower = message.ToLowerInvariant();
        if (status is 401 or 403) return keyDestination is null ? LlmErrorKind.Unavailable : LlmErrorKind.Unauthorized;
        if (Id == ConnectorId.Gemini && body.ToJsonString().Contains("API_KEY_INVALID", StringComparison.Ordinal) || Id == ConnectorId.Xai && status == 400 && lower.Contains("api key", StringComparison.Ordinal)) return LlmErrorKind.Unauthorized;
        if (status == 402 || code == "insufficient_quota" || type is "insufficient_quota" or "billing_error") return LlmErrorKind.QuotaExceeded;
        if (status == 413 || code == "context_length_exceeded" || lower.Contains("prompt is too long", StringComparison.Ordinal) || lower.Contains("too many tokens", StringComparison.Ordinal) || lower.Contains("maximum context length", StringComparison.Ordinal) || lower.Contains("too long", StringComparison.Ordinal) || lower.Contains("maximum number of tokens", StringComparison.Ordinal)) return LlmErrorKind.ContextTooLong;
        if (Id == ConnectorId.LmStudio && lower.Contains("no models loaded", StringComparison.Ordinal)) return LlmErrorKind.NoModels;
        if (status == 404 || code == "model_not_found" || Id == ConnectorId.Ollama && lower.Contains("not found", StringComparison.Ordinal)) return LlmErrorKind.ModelNotFound;
        if (Id == ConnectorId.Gemini && status == 504) return LlmErrorKind.Timeout;
        if (status == 429) return LlmErrorKind.RateLimited;
        if (status >= 500 && Id == ConnectorId.Ollama) return LlmErrorKind.Server;
        if (status is 503 or 529 || type == "overloaded_error") return LlmErrorKind.Overloaded;
        if (status >= 500) return LlmErrorKind.Server;
        return LlmErrorKind.BadRequest;
    }

    private static TimeSpan? RetryAfter(HttpResponseMessage response, JsonObject body)
    {
        if (response.Headers.TryGetValues("retry-after-ms", out var milliseconds) && double.TryParse(milliseconds.FirstOrDefault(), CultureInfo.InvariantCulture, out var ms) && double.IsFinite(ms) && ms >= 0) return TimeSpan.FromMilliseconds(Math.Min(ms, TimeSpan.MaxValue.TotalMilliseconds / 2));
        if (response.Headers.RetryAfter?.Delta is { } delta) return delta < TimeSpan.Zero ? TimeSpan.Zero : delta;
        if (response.Headers.RetryAfter?.Date is { } date) return date > DateTimeOffset.UtcNow ? date - DateTimeOffset.UtcNow : TimeSpan.Zero;
        if (body["error"] is JsonObject error && error["details"] is JsonArray details)
            foreach (var detail in details)
                if (detail?["retryDelay"]?.GetValue<string>() is { } hint && hint.EndsWith('s') && double.TryParse(hint[..^1], CultureInfo.InvariantCulture, out var seconds) && double.IsFinite(seconds) && seconds >= 0)
                    return TimeSpan.FromSeconds(Math.Min(seconds, TimeSpan.MaxValue.TotalSeconds / 2));
        return null;
    }

    private void WriteAttempt(string model, LlmRequest? request, int attempt, int status, TimeSpan elapsed, JsonObject? response, string? requestId, string? key)
    {
        if (onDiagnostic is null) return;
        var usage = Usage(response);
        var message = redactor.Redact($"llm connector={LlmCatalog.WireId(Id)} model={model} feature={LlmCatalog.FeatureId(request?.Feature ?? LlmFeature.Test)} tag=\"{request?.Tag}\" attempt={attempt + 1} status={status} ms={(long)elapsed.TotalMilliseconds} in={usage?.Input} out={usage?.Output} cacheRead={usage?.CacheRead} cacheWrite={usage?.CacheWrite} requestId={requestId}");
        var safe = new Redactor(key is null ? [] : [key]).Redact(message);
        try { onDiagnostic(safe); }
        catch (Exception) { }
    }

    private void EnsureAvailable(string model = "", LlmFeature feature = LlmFeature.Test)
    {
        if (unavailableReason is not null) throw Error(LlmErrorKind.Unavailable, model, feature, detail: unavailableReason);
    }

    private bool AllowsStoredKey(Uri? uri)
    {
        return keyDestination is not null && uri is not null && uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
            uri.Host.Equals(keyDestination.Host, StringComparison.OrdinalIgnoreCase) && uri.UserInfo.Length == 0;
    }

    private bool MatchesKeyConfiguration()
    {
        var auth = Provider["auth"];
        if (keyDestination is not { } destination)
            return auth is null || auth is JsonObject local && MatchesAuthField(local, "type", "none") &&
                !local.ContainsKey("keyAccount") && !local.ContainsKey("header") && !local.ContainsKey("valueTemplate");
        return auth is JsonObject fields && MatchesAuthField(fields, "type", "apiKey") &&
            MatchesAuthField(fields, "keyAccount", destination.Account) && MatchesAuthField(fields, "header", destination.Header) &&
            MatchesAuthField(fields, "valueTemplate", destination.ValueTemplate);
    }

    private static bool MatchesAuthField(JsonObject auth, string field, string expected) =>
        auth[field] is JsonValue value && value.TryGetValue<string>(out var actual) && actual == expected;

    private LlmException Error(LlmErrorKind kind, string model = "", LlmFeature feature = LlmFeature.Test, int? status = null, string? detail = null, TimeSpan? retryAfter = null) => LlmErrors.Create(kind, Label, model, feature, status, detail, retryAfter, redactor);

    private RawCompletion ParseCompletion(JsonObject body, string? requestId, LlmRequest request, string model)
    {
        StopKind stop = new StopKind.Complete();
        var text = "";
        if (Id == ConnectorId.Anthropic)
        {
            text = string.Concat((body["content"] as JsonArray ?? []).Where(block => block?["type"]?.GetValue<string>() == "text").Select(block => block!["text"]?.GetValue<string>()));
            stop = body["stop_reason"]?.GetValue<string>() switch { "max_tokens" or "model_context_window_exceeded" => new StopKind.Truncated(), "refusal" => new StopKind.Refused(body["stop_details"]?["category"]?.GetValue<string>()), _ => stop };
        }
        else if (Id == ConnectorId.OpenAI)
        {
            if (body["status"]?.GetValue<string>() == "failed")
            {
                var code = body["error"]?["code"]?.GetValue<string>();
                throw code switch
                {
                    "rate_limit_exceeded" => Error(LlmErrorKind.RateLimited, model, request.Feature),
                    "invalid_prompt" or "bio_policy" or "misalignment_policy_violation" or "image_content_policy_violation" => Error(LlmErrorKind.Refused, model, request.Feature, detail: code),
                    "data_residency_mismatch" => Error(LlmErrorKind.Unavailable, model, request.Feature, detail: "OpenAI can't serve this request in the configured data region."),
                    "invalid_image" or "invalid_image_format" or "invalid_base64_image" or "invalid_image_url" or "image_too_large" or "image_too_small" or "image_parse_error" or "invalid_image_mode" or "image_file_too_large" or "unsupported_image_media_type" or "empty_image_file" or "failed_to_download_image" or "image_file_not_found" => Error(LlmErrorKind.BadRequest, model, request.Feature, status: 400, detail: "OpenAI couldn't process an image in the request."),
                    _ => Error(LlmErrorKind.Server, model, request.Feature, status: 500)
                };
            }
            if (body["status"]?.GetValue<string>() == "incomplete") stop = body["incomplete_details"]?["reason"]?.GetValue<string>() == "content_filter" ? new StopKind.Refused("content_filter") : new StopKind.Truncated();
            foreach (var item in body["output"] as JsonArray ?? [])
            {
                if (item?["type"]?.GetValue<string>() != "message") continue;
                foreach (var part in item["content"] as JsonArray ?? [])
                    if (part?["type"]?.GetValue<string>() == "refusal") stop = new StopKind.Refused(null);
                    else if (part?["type"]?.GetValue<string>() == "output_text") text += part["text"]?.GetValue<string>();
            }
        }
        else if (Id == ConnectorId.Gemini)
        {
            var candidate = (body["candidates"] as JsonArray)?.FirstOrDefault();
            foreach (var part in candidate?["content"]?["parts"] as JsonArray ?? []) if (part?["thought"]?.GetValue<bool>() != true) text += part?["text"]?.GetValue<string>();
            var finish = candidate?["finishReason"]?.GetValue<string>();
            var blocked = body["promptFeedback"]?["blockReason"]?.GetValue<string>();
            if (!string.IsNullOrEmpty(blocked)) stop = new StopKind.Refused(blocked);
            else stop = finish switch
            {
                "STOP" => new StopKind.Complete(),
                "MAX_TOKENS" or "CONTINUATION" => new StopKind.Truncated(),
                "SAFETY" or "RECITATION" or "LANGUAGE" or "BLOCKLIST" or "PROHIBITED_CONTENT" or "SPII" or "OTHER" or "IMAGE_SAFETY" or "IMAGE_PROHIBITED_CONTENT" or "IMAGE_OTHER" or "IMAGE_RECITATION" or "ESCALATION" => new StopKind.Refused(finish),
                "PUP_LIMITED_DISABLED" => throw Error(LlmErrorKind.Unavailable, model, request.Feature, detail: "Google Gemini has limited or disabled this account for prohibited use."),
                _ => throw Error(LlmErrorKind.Server, model, request.Feature, status: 500)
            };
        }
        else if (Id == ConnectorId.Ollama)
        {
            text = body["message"]?["content"]?.GetValue<string>() ?? "";
            if (body["done_reason"]?.GetValue<string>() == "length") stop = new StopKind.Truncated();
        }
        else
        {
            var choice = (body["choices"] as JsonArray)?.FirstOrDefault();
            text = choice?["message"]?["content"]?.GetValue<string>() ?? "";
            if (choice?["message"]?["refusal"] is not null) stop = new StopKind.Refused(null);
            else if (choice?["finish_reason"]?.GetValue<string>() == "length") stop = new StopKind.Truncated();
        }
        return new(text, null, body["model"]?.GetValue<string>() ?? model, stop, Usage(body), requestId);
    }

    private LlmUsage? Usage(JsonObject? body)
    {
        if (body is null) return null;
        var usage = body["usage"];
        static int? Count(JsonNode? node) => node is JsonValue value && value.TryGetValue<int>(out var count) ? count : null;
        return Id switch
        {
            ConnectorId.Anthropic => new(Count(usage?["input_tokens"]), Count(usage?["output_tokens"]), Count(usage?["cache_read_input_tokens"]), Count(usage?["cache_creation_input_tokens"])),
            ConnectorId.OpenAI => new(Count(usage?["input_tokens"]), Count(usage?["output_tokens"]), Count(usage?["input_tokens_details"]?["cached_tokens"]), null),
            ConnectorId.Gemini => new(Count(body["usageMetadata"]?["promptTokenCount"]), GeminiOutput(body["usageMetadata"]), Count(body["usageMetadata"]?["cachedContentTokenCount"]), null),
            ConnectorId.Ollama => new(Count(body["prompt_eval_count"]), Count(body["eval_count"]), null, null),
            _ => new(Count(usage?["prompt_tokens"]), Count(usage?["completion_tokens"]), Count(usage?["prompt_tokens_details"]?["cached_tokens"]), null)
        };
    }

    private static long? GeminiOutput(JsonNode? usage)
    {
        static long? Count(JsonNode? node) => node is JsonValue value && value.TryGetValue<long>(out var count) ? count : null;
        var visible = Count(usage?["candidatesTokenCount"]);
        var thoughts = Count(usage?["thoughtsTokenCount"]);
        if (visible is null && thoughts is null) return null;
        try { return checked((visible ?? 0) + (thoughts ?? 0)); }
        catch (OverflowException) { return null; }
    }
}
