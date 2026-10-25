using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Models;

namespace VoxClip.Core.Services.Speech;

/// <summary>Noninteractive catalogue-backed Windows plan selection; plan W5 and transcription §11.</summary>
public static class LanguageRouter
{
    /// <summary>Select an explicit cloud plan or local model; readiness still owns downloads and consent.</summary>
    public static TranscriptionPlan Route(LanguageChoice language, TranscriptEngine preferred, IReadOnlyList<string> installedModels)
    {
        if (preferred == TranscriptEngine.Elevenlabs) return new(preferred, "scribe_v2", language, new());
        if (preferred != TranscriptEngine.Whispercpp)
            throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "Transcription stopped: this transcription engine is unavailable. Your video is still here.");
        var catalog = new ModelCatalog();
        var models = catalog.GetModelsAsync(CancellationToken.None).ConfigureAwait(false).GetAwaiter().GetResult();
        var installed = installedModels.ToHashSet(StringComparer.Ordinal);
        if (language is LanguageChoice.Auto)
        {
            var detection = models.FirstOrDefault(model => installed.Contains(model.Id) && model.Id.StartsWith("whisper-large-v3-turbo-", StringComparison.Ordinal));
            if (detection is null)
                throw SpeechCopy.ChooseLanguage();
            return Plan(detection, language);
        }
        var code = catalog.NormalizeLanguageAsync(((LanguageChoice.Forced)language).Code, CancellationToken.None).ConfigureAwait(false).GetAwaiter().GetResult();
        var root = catalog.RootAsync(CancellationToken.None).ConfigureAwait(false).GetAwaiter().GetResult();
        var defaults = root.GetProperty("defaults").GetProperty("byLanguage");
        var choices = (defaults.TryGetProperty(code, out var chosen) ? chosen : defaults.GetProperty("*")).GetProperty("windows");
        var ordered = choices.GetProperty("local").EnumerateArray().Select(item => models.Single(model => model.Id == item.GetString())).ToArray();
        var selected = SelectInstalled(ordered, code, installed) ?? models.Single(model => model.Id == choices.GetProperty("recommendedDownload").GetString());
        return Plan(selected, new LanguageChoice.Forced(code));
    }

    internal static TranscriptionModel? SelectInstalled(IReadOnlyList<TranscriptionModel> ordered, string code, IReadOnlySet<string> installed) =>
        ordered.FirstOrDefault(model => installed.Contains(model.Id) && model.Languages.Count == 1 && model.Languages[0] == code) ??
        ordered.FirstOrDefault(model => installed.Contains(model.Id) && (model.Languages.Contains(code, StringComparer.Ordinal) || model.Languages.Contains("*", StringComparer.Ordinal)));

    internal static TranscriptionPlan Plan(TranscriptionModel model, LanguageChoice language) => new(TranscriptEngine.Whispercpp, model.Id, language,
        new(Dtw: !model.RawMetadata.GetProperty("whisper").TryGetProperty("dtwDefault", out var dtw) || dtw.GetBoolean()));
}
