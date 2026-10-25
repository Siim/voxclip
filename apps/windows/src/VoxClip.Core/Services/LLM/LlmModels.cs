using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace VoxClip.Core.Services.LLM;

public sealed partial class LlmConnector
{
    private static readonly SemaphoreSlim CacheGate = new(1, 1);
    /// <summary>The model retained by refresh even when it is no longer listed for this key.</summary>
    public string? SelectedModel { get; private set; }
    /// <summary>Redacted model refresh warning for Settings, or null after success.</summary>
    public string? RefreshWarning { get; private set; }
    internal string? LastRefreshError => RefreshWarning;
    /// <summary>The most recent successful model-list fetch, including cached HTTP lists.</summary>
    public DateTimeOffset? ModelsFetchedAt { get; private set; }
    /// <summary>Remember the model selected by the app or CLI.</summary>
    public void SelectModel(string? id) => SelectedModel = id;

    private async Task<IReadOnlyList<LlmModel>> ModelsAsync(bool refresh, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        EnsureAvailable();
        if (cli is not null)
        {
            var models = await cli.ModelsAsync(refresh, ct).ConfigureAwait(false);
            RefreshWarning = cli.LastRefreshError;
            ModelsFetchedAt = cli.ModelsFetchedAt;
            return models;
        }
        if (!refresh)
        {
            if (modelCache is null) await ReadCacheAsync(ct).ConfigureAwait(false);
            return modelCache ?? catalog.Models(Id);
        }
        try
        {
            var found = await DiscoverAsync(ct).ConfigureAwait(false);
            var curated = catalog.Models(Id);
            IReadOnlyList<LlmModel> merged;
            if (Id is ConnectorId.Ollama or ConnectorId.LmStudio) merged = found;
            else
            {
                var visible = curated.Where(model => found.Any(item => item.Id == model.Id)).Select(model =>
                {
                    var fresh = found.First(item => item.Id == model.Id);
                    return model with { ContextTokens = fresh.ContextTokens ?? model.ContextTokens };
                }).ToList();
                visible.AddRange(found.Where(model => !curated.Any(item => item.Id == model.Id)));
                if (SelectedModel is not null && !visible.Any(model => model.Id == SelectedModel))
                {
                    var selected = curated.FirstOrDefault(model => model.Id == SelectedModel) ?? new(SelectedModel, SelectedModel, null, null, ModelSource.Custom);
                    visible.Add(selected with { Name = selected.Name + " (not listed for this key)" });
                }
                merged = visible;
            }
            modelCache = merged;
            ModelsFetchedAt = DateTimeOffset.UtcNow;
            RefreshWarning = null;
            await SaveCacheAsync(ct).ConfigureAwait(false);
            return merged;
        }
        catch (LlmException exception) when (exception.Error.Kind != LlmErrorKind.Cancelled)
        {
            RefreshWarning = "Couldn't refresh: " + exception.Error.UserMessage;
            if (modelCache is null) await ReadCacheAsync(ct).ConfigureAwait(false);
            if (Id is ConnectorId.Ollama or ConnectorId.LmStudio && modelCache is null) throw;
            return modelCache ?? catalog.Models(Id);
        }
    }

    private async Task<IReadOnlyList<LlmModel>> DiscoverAsync(CancellationToken ct)
    {
        if (Id == ConnectorId.AppleFoundation) return catalog.Models(Id);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(catalog.Timeout("modelList"));
        try { return await DiscoverCoreAsync(deadline.Token).ConfigureAwait(false); }
        catch (LlmException exception) when (exception.Error.Kind == LlmErrorKind.Cancelled && !ct.IsCancellationRequested && deadline.IsCancellationRequested)
        { throw Error(LlmErrorKind.Timeout, ""); }
        catch (OperationCanceledException) { throw Error(ct.IsCancellationRequested ? LlmErrorKind.Cancelled : LlmErrorKind.Timeout, ""); }
    }

    private async Task<IReadOnlyList<LlmModel>> DiscoverCoreAsync(CancellationToken ct)
    {
        var path = Provider["modelList"]!["path"]!.GetValue<string>();
        if (Id == ConnectorId.Anthropic) path += "?limit=100";
        if (Id == ConnectorId.Gemini) path += "?pageSize=1000";
        var all = new List<JsonObject>();
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        for (var page = 0; page < 100; page++)
        {
            var root = await GetAsync(path, catalog.Timeout("modelList"), ct).ConfigureAwait(false);
            var items = root?[Id is ConnectorId.Gemini or ConnectorId.Ollama ? "models" : "data"] as JsonArray ?? [];
            all.AddRange(items.OfType<JsonObject>());
            var cursor = Id == ConnectorId.Gemini ? root?["nextPageToken"]?.GetValue<string>() :
                Id == ConnectorId.Anthropic && root?["has_more"]?.GetValue<bool>() == true ? root["last_id"]?.GetValue<string>() : null;
            if (string.IsNullOrEmpty(cursor) || !cursors.Add(cursor)) break;
            path = Id == ConnectorId.Gemini ? "/v1beta/models?pageSize=1000&pageToken=" + Uri.EscapeDataString(cursor) : "/v1/models?limit=100&after_id=" + Uri.EscapeDataString(cursor);
        }
        if (Id == ConnectorId.OpenAI) all = all.OrderByDescending(item => item["created"]?.GetValue<long>() ?? 0).ToList();
        var found = new List<LlmModel>();
        foreach (var item in all)
        {
            var id = item[Id is ConnectorId.Gemini or ConnectorId.Ollama ? "name" : "id"]?.GetValue<string>();
            if (id is null) continue;
            if (Id == ConnectorId.Gemini && id.StartsWith("models/", StringComparison.Ordinal)) id = id[7..];
            var lower = id.ToLowerInvariant();
            bool HasAny(params string[] fragments) => fragments.Any(fragment => lower.Contains(fragment, StringComparison.Ordinal));
            var keep = Id switch
            {
                ConnectorId.Anthropic => item["capabilities"]?["structured_outputs"]?["supported"]?.GetValue<bool>() != false,
                ConnectorId.OpenAI => (id.StartsWith("gpt-", StringComparison.Ordinal) || Regex.IsMatch(id, "^o[0-9]", RegexOptions.CultureInvariant)) && !HasAny("audio", "realtime", "transcribe", "tts", "image", "search", "embedding", "moderation", "instruct"),
                ConnectorId.Xai => id.StartsWith("grok-", StringComparison.Ordinal) && !HasAny("image", "imagine", "video", "vision", "tts", "stt"),
                ConnectorId.Gemini => id.StartsWith("gemini-", StringComparison.Ordinal) && !HasAny("embedding", "image", "tts", "audio", "live", "aqa") && (item["supportedGenerationMethods"] as JsonArray ?? []).Any(method => method?.GetValue<string>() == "generateContent"),
                _ => !HasAny("embed")
            };
            discovered[id] = item.DeepClone().AsObject();
            if (!keep) continue;
            if (Id == ConnectorId.Ollama)
            {
                localDetails.Remove(id);
                try { await OllamaDetailsAsync(id, ct).ConfigureAwait(false); }
                catch (LlmException exception) when (exception.Error.Kind == LlmErrorKind.NoModels) { continue; }
            }
            var name = item[Id == ConnectorId.Anthropic ? "display_name" : "displayName"]?.GetValue<string>() ?? id;
            var context = Id == ConnectorId.Ollama ? await ContextAsync(id, ct).ConfigureAwait(false) : item[Id == ConnectorId.Anthropic ? "max_input_tokens" : "inputTokenLimit"]?.GetValue<int>();
            if (!found.Any(model => model.Id == id)) found.Add(new(id, name, null, context, ModelSource.Discovered));
        }
        return found;
    }

    private async Task ReadCacheAsync(CancellationToken ct)
    {
        if (cacheFile is null || !File.Exists(cacheFile)) return;
        try
        {
            var saved = (await File.ReadAllTextAsync(cacheFile, ct).ConfigureAwait(false));
            var entry = LlmOutput.Parse(saved)?[LlmCatalog.WireId(Id)];
            if (entry?["models"] is not JsonArray models) return;
            modelCache = models.OfType<JsonObject>().Select(item => new LlmModel(item["id"]!.GetValue<string>(), item["name"]!.GetValue<string>(), item["tier"]?.GetValue<string>(), item["contextTokens"]?.GetValue<int>(),
                Enum.TryParse<ModelSource>(item["source"]?.GetValue<string>(), true, out var source) ? source : ModelSource.Discovered)).ToArray();
            if (DateTimeOffset.TryParse(entry["fetchedAt"]?.GetValue<string>(), out var time)) ModelsFetchedAt = time;
        }
        catch (Exception exception) when (exception is IOException or JsonException or InvalidOperationException or ArgumentException) { }
    }

    private async Task SaveCacheAsync(CancellationToken ct)
    {
        if (cacheFile is null) return;
        await CacheGate.WaitAsync(ct).ConfigureAwait(false);
        var temporary = cacheFile + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var root = File.Exists(cacheFile) ? LlmOutput.Parse(await File.ReadAllTextAsync(cacheFile, ct).ConfigureAwait(false)) as JsonObject ?? new() : new JsonObject();
            var models = new JsonArray();
            foreach (var model in modelCache ?? []) models.Add((JsonNode)new JsonObject { ["id"] = model.Id, ["name"] = model.Name, ["tier"] = model.Tier, ["contextTokens"] = model.ContextTokens, ["source"] = model.Source.ToString().ToLowerInvariant() });
            root[LlmCatalog.WireId(Id)] = new JsonObject { ["fetchedAt"] = ModelsFetchedAt?.ToString("O"), ["models"] = models };
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(cacheFile))!);
            await File.WriteAllTextAsync(temporary, root.ToJsonString(VoxClip.Core.Domain.Shared.JsonFormatting.CreateOptions()) + "\n", ct).ConfigureAwait(false);
            File.Move(temporary, cacheFile, true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        finally { if (File.Exists(temporary)) File.Delete(temporary); CacheGate.Release(); }
    }
}
