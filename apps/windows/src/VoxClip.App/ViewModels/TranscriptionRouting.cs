using System.Text.Json;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;

namespace VoxClip.App.ViewModels;

/// <summary>What the Transcribe dialog does next with the local engine: run <see cref="Plan"/>, detect the language with
/// <see cref="Detector"/> first, or show <see cref="Message"/>. <see cref="Download"/> is the model the message offers to
/// download, <see cref="AskLanguage"/> moves focus to the language box, and <see cref="OfferCloud"/> adds "Use ElevenLabs
/// instead" (an ElevenLabs key exists); transcription §11.3.</summary>
internal sealed record LocalTranscriptionRoute(TranscriptionPlan? Plan, string Message = "", TranscriptionModel? Download = null,
    bool AskLanguage = false, bool OfferCloud = false, string? Detector = null);

/// <summary>Local model routing for the Transcribe dialog and the welcome tour; transcription §11.2. The dialog's Automatic choice
/// goes through Core's <see cref="TranscriptionRouter"/>: a typed language routes to the first installed model in
/// <c>defaults.byLanguage[lang].windows.local</c>, Auto first detects the language with an installed Whisper large-v3-turbo, and
/// a missing model becomes a download offer (the low-memory download under 8 GB). An explicitly chosen model is used as chosen,
/// still checked against the language.</summary>
internal static class TranscriptionRouting
{
    internal const string Automatic = "Automatic · best installed model for the language";
    internal const string Detecting = "Detecting the language…";
    internal const string ChooseLanguage = "Which language is spoken? Type its code, such as en or et, then choose Transcribe.";
    internal const string Installed = "Model installed and verified. Choose Transcribe to continue.";
    internal const string UseCloud = "Use ElevenLabs instead";

    /// <summary>The installed RAM the low-memory rule compares with <c>defaults.lowMemoryThresholdBytes</c>.</summary>
    internal static long InstalledMemoryBytes => GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;

    /// <summary>The language box text as a choice: empty or "auto" is Auto, anything else is forced.</summary>
    internal static LanguageChoice Language(string text)
    {
        var code = text.Trim().ToLowerInvariant();
        return code.Length == 0 || code == "auto" ? new LanguageChoice.Auto() : new LanguageChoice.Forced(code);
    }

    /// <summary>Route one Transcribe click. <paramref name="explicitModel"/> is null for Automatic. <paramref name="detect"/>
    /// receives the installed multilingual model to detect with and is called only for Auto; when it is null and detection is
    /// needed, the route names the <see cref="LocalTranscriptionRoute.Detector"/> instead, so the caller can extract the audio
    /// first and route again.</summary>
    internal static async Task<LocalTranscriptionRoute> RouteAsync(ModelCatalog catalog, IModelDownloader store, string? explicitModel,
        string languageText, long ramBytes, bool keyPresent, Func<string, CancellationToken, Task<(string Language, double Probability)>>? detect,
        CancellationToken ct)
    {
        var language = Language(languageText);
        var models = await catalog.GetModelsAsync(ct).ConfigureAwait(false);
        var installed = (await store.ListInstalledAsync(ct).ConfigureAwait(false)).Where(model => model.Verified)
            .Select(model => model.Id).ToHashSet(StringComparer.Ordinal);
        var root = await catalog.RootAsync(ct).ConfigureAwait(false);
        var detector = Ids(root, "auto", "local").Select(id => models.FirstOrDefault(model => model.Id == id))
            .FirstOrDefault(model => model is not null && installed.Contains(model.Id) && IsDetectionModel(model));
        if (explicitModel is not null)
            return await ExplicitAsync(catalog, models, installed, explicitModel, language, keyPresent, detect, ct).ConfigureAwait(false);
        if (language is LanguageChoice.Auto && detector is not null && detect is null) return new(null, Detector: detector.Id);
        var decision = await new TranscriptionRouter(catalog, store).RouteAsync("local", language, ramBytes, keyPresent,
            detector is null || detect is null ? null : async token => await detect(detector.Id, token).ConfigureAwait(false), ct).ConfigureAwait(false);
        if (decision.Plan is { } plan) return new(plan);
        if (decision.Readiness is Readiness.NeedsModels needs && models.FirstOrDefault(model => model.Id == needs.Ids[0]) is { } download)
            return new(null, SpeechCopy.ModelMissing(download, download.Id, needs.Bytes).Message, download, false, keyPresent);
        if (decision.Readiness is Readiness.UnsupportedLanguage unsupported)
            return new(null, SpeechCopy.Unsupported(TranscriptEngine.Whispercpp, unsupported.Code).Message, null, true, keyPresent);
        if (detector is not null) return new(null, ChooseLanguage, null, true, keyPresent);
        // No multilingual model to detect with: ask (§11.2), and offer the Auto download that would detect it next time.
        var recommended = models.FirstOrDefault(model => model.Id == Text(root, "auto", "recommendedDownload"));
        return recommended is null ? new(null, ChooseLanguage, null, true, keyPresent)
            : new(null, $"Which language is spoken? Type its code, such as en or et. To detect it automatically, download the {ModelDownloadCopy.DisplayName(recommended)} model ({DownloadSize(recommended, models, installed)}).",
                recommended, true, keyPresent);
    }

    private static async Task<LocalTranscriptionRoute> ExplicitAsync(ModelCatalog catalog, IReadOnlyList<TranscriptionModel> models,
        IReadOnlySet<string> installed, string id, LanguageChoice language, bool keyPresent,
        Func<string, CancellationToken, Task<(string Language, double Probability)>>? detect, CancellationToken ct)
    {
        var model = models.FirstOrDefault(entry => entry.Id == id && entry.Kind == "asr" && entry.Engine == TranscriptEngine.Whispercpp)
            ?? throw SpeechCopy.ModelMissing(null, id, 0);
        if (!installed.Contains(model.Id) || model.Requires.Any(required => !installed.Contains(required)))
            return new(null, SpeechCopy.ModelMissing(model, model.Id, DownloadBytes(model, models, installed)).Message, model, false, keyPresent);
        string code;
        if (language is LanguageChoice.Forced forced) code = await catalog.NormalizeLanguageAsync(forced.Code, ct).ConfigureAwait(false);
        else if (model.ForcedLanguage is { } only) code = only;
        else if (IsDetectionModel(model))
        {
            if (detect is null) return new(null, Detector: model.Id);
            var detected = await detect(model.Id, ct).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(detected.Language) || !(detected.Probability >= 0.5)) return new(null, ChooseLanguage, null, true, keyPresent);
            code = await catalog.NormalizeLanguageAsync(detected.Language, ct).ConfigureAwait(false);
        }
        else return new(null, ChooseLanguage, null, true, keyPresent);
        var supported = (model.ForcedLanguage is null || model.ForcedLanguage == code) &&
            (model.Languages.Contains(code, StringComparer.Ordinal) || model.Languages.Contains("*", StringComparer.Ordinal));
        return supported ? new(Plan(model, code))
            : new(null, SpeechCopy.Unsupported(TranscriptEngine.Whispercpp, code).Message, null, true, keyPresent);
    }

    /// <summary>The model the welcome tour preselects for a language: <c>defaults.byLanguage[lang]</c> (or "*", and "auto" for
    /// Auto) on Windows, its low-memory download when RAM is under the threshold, else its recommended download.</summary>
    internal static string RecommendedDownload(JsonElement root, string languageText, long ramBytes)
    {
        var code = Language(languageText) is LanguageChoice.Forced forced ? forced.Code.Split('-')[0] : "auto";
        var byLanguage = root.GetProperty("defaults").GetProperty("byLanguage");
        if (!byLanguage.TryGetProperty(code, out _)) code = "*";
        var low = ramBytes < root.GetProperty("defaults").GetProperty("lowMemoryThresholdBytes").GetInt64() ? Text(root, code, "lowMemoryDownload") : null;
        return low ?? Text(root, code, "recommendedDownload")!;
    }

    /// <summary>The Windows Whisper plan for a model and a language, with the catalogue's DTW default.</summary>
    internal static TranscriptionPlan Plan(TranscriptionModel model, string code) => new(TranscriptEngine.Whispercpp, model.Id,
        new LanguageChoice.Forced(code), new(Dtw: !model.RawMetadata.GetProperty("whisper").TryGetProperty("dtwDefault", out var dtw) || dtw.GetBoolean()));

    /// <summary>Language detection uses an OpenAI multilingual model, never TalTech; transcription §9.8.</summary>
    internal static bool IsDetectionModel(TranscriptionModel model) => model.Id.StartsWith("whisper-large-v3-turbo-", StringComparison.Ordinal);

    private static long DownloadBytes(TranscriptionModel model, IReadOnlyList<TranscriptionModel> models, IReadOnlySet<string> installed) =>
        new[] { model }.Concat(ModelDownloadCopy.Dependencies(model, models)).Where(entry => !installed.Contains(entry.Id)).Sum(entry => entry.TotalBytes);

    private static string DownloadSize(TranscriptionModel model, IReadOnlyList<TranscriptionModel> models, IReadOnlySet<string> installed) =>
        ModelDownloadCopy.Size(model, ModelDownloadCopy.Dependencies(model, models).Where(entry => !installed.Contains(entry.Id)).ToArray());

    private static IEnumerable<string> Ids(JsonElement root, string language, string name) =>
        root.GetProperty("defaults").GetProperty("byLanguage").TryGetProperty(language, out var entry) &&
        entry.GetProperty("windows").TryGetProperty(name, out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(item => item.GetString()!).ToArray() : [];

    private static string? Text(JsonElement root, string language, string name) =>
        root.GetProperty("defaults").GetProperty("byLanguage").TryGetProperty(language, out var entry) &&
        entry.GetProperty("windows").TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}

/// <summary>The Transcribe dialog's progress line, matching the Mac sheet with "PC" for "Mac"; transcription §13.1 and design
/// §13.</summary>
internal static class TranscriptionProgressCopy
{
    internal const string ReadingVideo = "Reading video…";
    internal const string ExtractingAudio = "Extracting audio…";

    internal static string Label(TranscriptionStage stage, double? fraction, bool cloud)
    {
        var percent = fraction is { } value && double.IsFinite(value) ? (int?)Math.Clamp((int)(value * 100), 0, 100) : null;
        var label = cloud ? "Transcribing with ElevenLabs" : "Transcribing on this PC";
        return stage switch
        {
            TranscriptionStage.Preparing => "Preparing the speech model…",
            TranscriptionStage.Uploading => $"Transcribing with ElevenLabs · {percent ?? 0}%",
            TranscriptionStage.Transcribing => percent is { } shown ? $"{label} · {shown}%" : label + "…",
            _ => "Aligning words…"
        };
    }
}
