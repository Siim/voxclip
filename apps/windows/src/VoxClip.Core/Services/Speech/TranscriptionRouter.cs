using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;

namespace VoxClip.Core.Services.Speech;

internal sealed record RoutingDecision(TranscriptionPlan? Plan, Readiness Readiness, string? Prompt = null, bool OfferCloud = false)
{
    internal RoutingDecision? Alternative { get; init; }
}

internal sealed class TranscriptionRouter(ModelCatalog catalog, IModelDownloader store)
{
    internal async Task<RoutingDecision> RouteAsync(string mode, LanguageChoice language, long ramBytes, bool keyPresent,
        Func<CancellationToken, Task<(string Language, double Probability)?>>? detect, CancellationToken ct)
    {
        if (mode is not ("local" or "ask" or "apple" or "elevenlabs")) throw new ArgumentException("Unknown transcription mode.", nameof(mode));
        ct.ThrowIfCancellationRequested();
        if (mode == "elevenlabs" && keyPresent) return new(new(TranscriptEngine.Elevenlabs, null, language, new()), new Readiness.Ready());
        if (mode is "elevenlabs" or "ask")
        {
            var local = await RouteAsync("local", language, ramBytes, keyPresent, detect, ct).ConfigureAwait(false);
            return mode == "elevenlabs"
                ? new(null, new Readiness.NeedsKey("elevenlabs"), "addKey") { Alternative = local }
                : new(null, new Readiness.Unavailable("Choose an engine."), "chooseEngine", keyPresent) { Alternative = local };
        }
        var models = await catalog.GetModelsAsync(ct).ConfigureAwait(false);
        var installed = (await store.ListInstalledAsync(ct).ConfigureAwait(false)).Where(model => model.Verified).Select(model => model.Id).ToHashSet(StringComparer.Ordinal);
        if (language is LanguageChoice.Auto)
        {
            if (models.Any(model => installed.Contains(model.Id) && model.Id.StartsWith("whisper-large-v3-turbo-", StringComparison.Ordinal)) && detect is not null)
            {
                var detected = await detect(ct).ConfigureAwait(false);
                if (detected is { Probability: >= 0.5 } result) return await RouteAsync("local", new LanguageChoice.Forced(result.Language), ramBytes, keyPresent, null, ct).ConfigureAwait(false);
            }
            return new(null, new Readiness.Unavailable("Which language is spoken?"), "chooseLanguage");
        }
        var code = await catalog.NormalizeLanguageAsync(((LanguageChoice.Forced)language).Code, ct).ConfigureAwait(false);
        var root = await catalog.RootAsync(ct).ConfigureAwait(false);
        var defaults = root.GetProperty("defaults");
        var byLanguage = defaults.GetProperty("byLanguage");
        var candidates = (byLanguage.TryGetProperty(code, out var chosen) ? chosen : byLanguage.GetProperty("*")).GetProperty("windows");
        var ordered = candidates.GetProperty("local").EnumerateArray().Select(item => models.Single(model => model.Id == item.GetString())).ToArray();
        bool Supports(TranscriptionModel model) => model.Languages.Contains(code, StringComparer.Ordinal) || model.Languages.Contains("*", StringComparer.Ordinal);
        var selected = LanguageRouter.SelectInstalled(ordered, code, installed);
        if (selected is not null) return new(LanguageRouter.Plan(selected, new LanguageChoice.Forced(code)), new Readiness.Ready());
        var downloadId = ramBytes < defaults.GetProperty("lowMemoryThresholdBytes").GetInt64() && candidates.TryGetProperty("lowMemoryDownload", out var low)
            ? low.GetString()! : candidates.GetProperty("recommendedDownload").GetString()!;
        var download = models.Single(model => model.Id == downloadId);
        if (!Supports(download)) return new(null, new Readiness.UnsupportedLanguage(code), "chooseLanguage", keyPresent);
        var needs = new[] { download.Id }.Concat(download.Requires).Where(id => !installed.Contains(id)).ToArray();
        return new(null, new Readiness.NeedsModels(needs, models.Where(model => needs.Contains(model.Id, StringComparer.Ordinal)).Sum(model => model.TotalBytes)), "download", keyPresent);
    }
}
