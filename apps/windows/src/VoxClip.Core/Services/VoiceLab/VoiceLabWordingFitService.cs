using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>One review-only wording-fit request per round, from <c>shared/prompts/voice-rewrite-fit.json</c>. A fit request never
/// synthesizes audio and never changes a project; its reply contains exactly the requested ordinals.</summary>
public sealed class VoiceLabWordingFitService
{
    private const string PromptFile = "prompts/voice-rewrite-fit.json";
    private static readonly Regex LanguageCode = new(@"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Placeholder = new(@"\{([A-Za-z]+)\}", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Url = new("https?://", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
    private readonly LlmCatalog catalog;
    private readonly VoiceLabActionGate actions = new();

    /// <summary>Use the shared LLM catalogue and the shared fit prompt.</summary>
    public VoiceLabWordingFitService(LlmCatalog catalog) => this.catalog = catalog ?? throw new ArgumentNullException(nameof(catalog));

    /// <summary>The canonical request for these phrases; every word of its text comes from the shared prompt's templates.</summary>
    public LlmRequest Request(IReadOnlyList<VoiceLabFitPhrase> phrases, ConnectorId connector, string language)
    {
        var snapshot = Validate(phrases, language);
        var document = VoiceLabLlmChecks.ReadPrompt(catalog, PromptFile).Document;
        if (document["promptVersion"]?.GetValue<int>() is not >= 1 || document["system"]?.GetValue<string>() is not { Length: > 0 } system ||
            document["schemaName"]?.GetValue<string>() is not { Length: > 0 } name || document["schema"] is not JsonObject schema ||
            schema["properties"]?["phrases"]?["type"]?.GetValue<string>() != "array" ||
            document["maxOutputTokens"] is not JsonValue capValue || !capValue.TryGetValue<int>(out var promptCap) || promptCap is < 1 or > 16000)
            throw Missing();
        string Fill(string key, IReadOnlyDictionary<string, string> values)
        {
            if (document["request"]?[key] is not JsonValue value || !value.TryGetValue<string>(out var template)) throw Missing();
            return Placeholder.Replace(template, match => values.TryGetValue(match.Groups[1].Value, out var replacement) ? replacement : match.Value);
        }
        var paceLine = document["request"]?["calibratedPaceLine"] is JsonValue pace && pace.TryGetValue<string>(out var calibrated) ? calibrated : "";
        var lines = snapshot.Select(phrase =>
        {
            var direction = Fill(phrase.Direction + "PhraseLine", new Dictionary<string, string>
                { ["differenceWords"] = VoiceLabWordingFit.DifferenceWords(phrase).ToString(CultureInfo.InvariantCulture) });
            var line = Fill("phraseLine", new Dictionary<string, string>
            {
                ["ordinal"] = phrase.Ordinal.ToString(CultureInfo.InvariantCulture), ["original"] = phrase.Original, ["proposed"] = phrase.Proposed,
                ["estimateSeconds"] = EditingFormat.ToFixed1(phrase.EstimateSeconds), ["slotSeconds"] = EditingFormat.ToFixed1(phrase.SlotSeconds),
                ["directionLine"] = direction, ["minimumWords"] = phrase.Target.Minimum.ToString(CultureInfo.InvariantCulture),
                ["maximumWords"] = phrase.Target.Maximum.ToString(CultureInfo.InvariantCulture), ["paceLine"] = phrase.Calibrated ? paceLine : ""
            });
            if (phrase.MeasuredSeconds is { } measured)
                line += "\n" + Fill("measuredPhraseLine", new Dictionary<string, string>
                    { ["measuredSeconds"] = EditingFormat.ToFixed1(measured), ["slotSeconds"] = EditingFormat.ToFixed1(phrase.SlotSeconds) });
            return line;
        }).ToArray();
        var cached = Fill("sourceBlock", new Dictionary<string, string> { ["language"] = language, ["phrases"] = string.Join("\n\n", lines) });
        var instruction = Fill(snapshot.Any(phrase => phrase.MeasuredSeconds is not null) ? "measuredFeedbackBlock" : "fitFeedbackBlock", new Dictionary<string, string>());
        if (Encoding.UTF8.GetByteCount(system + cached + instruction) > 100_000) throw Invalid();
        var maxOutput = VoiceLabLlmChecks.MaxOutputTokens(catalog.Estimate(string.Join(" ", snapshot.Select(phrase => phrase.Proposed))),
            promptCap, catalog.Cap(connector, promptCap)) ?? throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", "", LlmFeature.VoiceRewrite);
        var timeout = catalog.Timeout(connector is ConnectorId.ClaudeCode or ConnectorId.Codex ? "cli" :
            connector is ConnectorId.Ollama or ConnectorId.LmStudio ? "localServer" : "cloud");
        return new(LlmFeature.VoiceRewrite, system, cached, instruction, name, schema.DeepClone().AsObject(), maxOutput, Effort.Medium, timeout,
            language, "voice-rewrite-fit");
    }

    /// <summary>Binds the exact phrases, connector, model, language and prompt bytes to one send; it sends nothing.</summary>
    public VoiceLabPreparedAction Prepare(IReadOnlyList<VoiceLabFitPhrase> phrases, ConnectorId connector, string model, string language)
    {
        if (!VoiceLabLlmChecks.IsValidModel(model)) throw Invalid();
        var request = Request(phrases, connector, language);
        return actions.Prepare(Fingerprint(phrases, connector, model, language, request),
            VoiceLabLlmChecks.Estimate(catalog, connector, VoiceLabOperation.VoiceRewrite, request),
            new(VoiceLabOperation.VoiceRewrite, Guid.NewGuid(), LlmCatalog.WireId(connector), null, "voice-rewrite-fit", model, null,
                new(VoiceLabLanguageModeKind.Explicit, language), VoiceLabActionGate.ContentHash(Encoding.UTF8.GetBytes(request.CachedBlock ?? "")), null));
    }

    /// <summary>Approval covers exactly one prepared fit send.</summary>
    public VoiceLabAuthorization Approve(VoiceLabPreparedAction action, bool affirmative) => actions.Approve(action, affirmative);

    /// <summary>Sends one approved fit round and returns one update per requested ordinal; it never changes a project.</summary>
    public async Task<IReadOnlyList<VoiceLabFitUpdate>> ProposeAsync(IReadOnlyList<VoiceLabFitPhrase> phrases, ILlmConnector connector, string model,
        string language, VoiceLabAuthorization authorization, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(connector);
        var request = Request(phrases, connector.Id, language);
        var fingerprint = Fingerprint(phrases, connector.Id, model, language, request);
        actions.Verify(authorization, fingerprint, VoiceLabOperation.VoiceRewrite);
        var status = await connector.GetStatusAsync(ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (status is not ConnectorStatus.Ready) throw VoiceLabLlmChecks.StatusFailure(catalog, status, connector.Id, model);
        var models = await connector.GetModelsAsync(false, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (models.All(candidate => candidate.Id != model)) throw LlmErrors.Create(LlmErrorKind.ModelNotFound, "", model, LlmFeature.VoiceRewrite);
        var context = await catalog.ResolveContextTokensAsync(connector, model, ct, models).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        VoiceLabLlmChecks.CheckContext(catalog, request, model, context);
        actions.Claim(authorization, fingerprint, VoiceLabOperation.VoiceRewrite);
        RawCompletion answer;
        try { answer = await connector.SendAsync(request, model, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw LlmErrors.Create(LlmErrorKind.Cancelled, "", model, LlmFeature.VoiceRewrite); }
        ct.ThrowIfCancellationRequested();
        VoiceLabLlmChecks.CheckAnswer(connector.Id, model, answer);
        var parsed = LlmOutput.Validate(answer, request.Schema);
        if (parsed.Object is null || parsed.Dropped != 0 || parsed.Object["phrases"] is not JsonArray rows) throw Output(model);
        var updates = rows.Select(row =>
        {
            if (row is not JsonObject item || item["ordinal"] is not JsonValue ordinalValue || !ordinalValue.TryGetValue<double>(out var number) ||
                number != Math.Floor(number) || number is < 1 or > int.MaxValue || item["action"] is not JsonValue actionValue ||
                !actionValue.TryGetValue<string>(out var action) || action is not ("reword" or "keepOriginal") ||
                item["text"] is not JsonValue textValue || !textValue.TryGetValue<string>(out var text) || Encoding.UTF8.GetByteCount(text) > 20_000 ||
                (action == "keepOriginal" ? text.Length != 0 : EditingAlgorithms.JsTrim(text).Length == 0 ||
                    text != VoiceLabAudioTags.SanitizedRequest(text, "") || Url.IsMatch(text) || text.Any(character => char.IsControl(character) && character != '\n')))
                throw Output(model);
            return new VoiceLabFitUpdate((int)number, action == "keepOriginal", text);
        }).ToArray();
        if (updates.Length != phrases.Count || !updates.Select(update => update.Ordinal).ToHashSet().SetEquals(phrases.Select(phrase => phrase.Ordinal)))
            throw Output(model);
        return updates;
    }

    private static VoiceLabFitPhrase[] Validate(IReadOnlyList<VoiceLabFitPhrase> phrases, string language)
    {
        if (phrases is null || phrases.Count is < 1 or > 60 || language is null || !LanguageCode.IsMatch(language)) throw Invalid();
        var snapshot = phrases.ToArray();
        if (snapshot.Any(phrase => phrase is null) || snapshot.Select(phrase => phrase.Ordinal).Distinct().Count() != snapshot.Length ||
            snapshot.Any(phrase => phrase.Ordinal <= 0 || string.IsNullOrEmpty(phrase.Original) || string.IsNullOrEmpty(phrase.Proposed) ||
                Encoding.UTF8.GetByteCount(phrase.Original) > 20_000 || Encoding.UTF8.GetByteCount(phrase.Proposed) > 20_000 ||
                !double.IsFinite(phrase.EstimateSeconds) || phrase.EstimateSeconds <= 0 || !double.IsFinite(phrase.SlotSeconds) || phrase.SlotSeconds <= 0 ||
                phrase.Direction is not ("longer" or "shorter") || phrase.Target is null || phrase.Target.Minimum <= 0 ||
                phrase.Target.Maximum < phrase.Target.Minimum || phrase.Target.Maximum > 2_000 ||
                phrase.MeasuredSeconds is { } measured && (!double.IsFinite(measured) || measured <= 0))) throw Invalid();
        return snapshot;
    }

    private string Fingerprint(IReadOnlyList<VoiceLabFitPhrase> phrases, ConnectorId connector, string model, string language, LlmRequest request)
    {
        var parts = new List<string?> { "voice-rewrite-fit", LlmCatalog.WireId(connector), model, language, VoiceLabLlmChecks.ReadPrompt(catalog, PromptFile).Sha256,
            request.System, request.CachedBlock, request.Instruction, request.SchemaName, request.Schema.ToJsonString(),
            request.MaxOutputTokens.ToString(CultureInfo.InvariantCulture) };
        foreach (var phrase in phrases)
            parts.AddRange([phrase.Ordinal.ToString(CultureInfo.InvariantCulture), phrase.Original, phrase.Proposed,
                phrase.EstimateSeconds.ToString("R", CultureInfo.InvariantCulture), phrase.SlotSeconds.ToString("R", CultureInfo.InvariantCulture),
                phrase.Direction, phrase.Target.Minimum.ToString(CultureInfo.InvariantCulture), phrase.Target.Maximum.ToString(CultureInfo.InvariantCulture),
                phrase.MeasuredSeconds?.ToString("R", CultureInfo.InvariantCulture), phrase.Calibrated ? "calibrated" : "default"]);
        return VoiceLabActionGate.Fingerprint(parts.ToArray());
    }

    private static VoxClipException Missing() => new(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
    private static LlmException Output(string model) => LlmErrors.Create(LlmErrorKind.InvalidOutput, "", model, LlmFeature.VoiceRewrite);
}
