using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>One selected connector and model, one billed send, and inert review data for a passage or full take.</summary>
public sealed class VoiceRewriteService
{
    private static readonly Regex LanguageCode = new("^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Url = new("https?://", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
    private readonly LlmCatalog catalog;
    private readonly VoiceLabActionGate actions;
    /// <summary>Use the shared LLM catalogue and its canonical rewrite prompt.</summary>
    public VoiceRewriteService(LlmCatalog catalog)
    {
        this.catalog = catalog ?? throw new ArgumentNullException(nameof(catalog));
        actions = new VoiceLabActionGate();
    }

    /// <summary>Preflight and estimate are explicit caller actions; they do not generate a rewrite.</summary>
    public Task<VoiceLabPreparedAction> PrepareAsync(VoiceRewriteRequest input, ILlmConnector connector, string model, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(connector);
        if (input is null || input.SourceWords is null) throw Invalid();
        var snapshot = input with { SourceWords = input.SourceWords.ToArray() };
        var source = Validate(snapshot);
        if (string.IsNullOrWhiteSpace(model) || model == "default" || model.Length > 128) throw Invalid();
        var request = BuildRequest(snapshot, source, connector.Id, model);
        var units = catalog.Estimate(source + snapshot.Instruction + request.System + request.Schema.ToJsonString());
        return Task.FromResult(actions.Prepare(Fingerprint(snapshot, connector.Id, model, request),
            new(LlmCatalog.WireId(connector.Id), VoiceLabOperation.VoiceRewrite, units, "estimated input token", null, null,
                "Provider price and final token usage are unknown; review usage before approval."),
            new(VoiceLabOperation.VoiceRewrite, snapshot.RequestId, LlmCatalog.WireId(connector.Id), null,
                "voice-rewrite", model, null, new(VoiceLabLanguageModeKind.Explicit, snapshot.Language),
                VoiceLabActionGate.ContentHash(Encoding.UTF8.GetBytes(source)), null)));
    }

    /// <summary>Approval is affirmative for the exact prepared source, instruction, connector, model and prompt.</summary>
    public VoiceLabAuthorization Approve(VoiceLabPreparedAction action, bool affirmative) => actions.Approve(action, affirmative);

    /// <summary>Generate only a proposal. This method never changes a project or invokes speech synthesis.</summary>
    public async Task<VoiceRewriteProposal> ProposeAsync(VoiceRewriteRequest input, ILlmConnector connector, string model,
        VoiceLabAuthorization authorization, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(connector);
        if (input is null || input.SourceWords is null) throw Invalid();
        var snapshot = input with { SourceWords = input.SourceWords.ToArray() };
        var source = Validate(snapshot);
        // Bind the approved input before discovery, without consuming it for a nonbillable preflight failure.
        var request = BuildRequest(snapshot, source, connector.Id, model);
        var fingerprint = Fingerprint(snapshot, connector.Id, model, request);
        actions.Verify(authorization, fingerprint, VoiceLabOperation.VoiceRewrite, snapshot.RequestId);
        var status = await connector.GetStatusAsync(ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (status is not ConnectorStatus.Ready) throw StatusFailure(status, connector.Id, model);
        var models = await connector.GetModelsAsync(false, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var selected = models.FirstOrDefault(candidate => candidate.Id == model);
        if (selected is null) throw LlmErrors.Create(LlmErrorKind.ModelNotFound, "", model, LlmFeature.VoiceRewrite);
        var context = await connector.GetContextTokensAsync(model, ct).ConfigureAwait(false) ?? selected.ContextTokens ??
            catalog.Model(connector.Id, model)?["contextTokens"]?.GetValue<int>() ?? 4096;
        ct.ThrowIfCancellationRequested();
        CheckContext(request, model, context);
        ct.ThrowIfCancellationRequested();
        // Claim is atomic and immediately precedes the only call that may dispatch a paid request.
        actions.Claim(authorization, fingerprint, VoiceLabOperation.VoiceRewrite, snapshot.RequestId);
        RawCompletion answer;
        try { answer = await connector.SendAsync(request, model, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw LlmErrors.Create(LlmErrorKind.Cancelled, "", model, LlmFeature.VoiceRewrite); }
        ct.ThrowIfCancellationRequested();
        if (answer.Model != model || answer.Stop is not StopKind.Complete)
            throw LlmErrors.Create(answer.Stop is StopKind.Truncated ? LlmErrorKind.Truncated : LlmErrorKind.InvalidOutput, "", model, LlmFeature.VoiceRewrite);
        var parsed = LlmOutput.Validate(answer, request.Schema);
        if (parsed.Object is null || parsed.Dropped != 0 || parsed.Object.Count != 1 || parsed.Object["rewrite"] is not JsonValue value ||
            !value.TryGetValue<string>(out var rewrite) || string.IsNullOrWhiteSpace(rewrite) || Encoding.UTF8.GetByteCount(rewrite) > 20000 ||
            Url.IsMatch(rewrite) || rewrite.Any(character => char.IsControl(character) && character != '\n'))
            throw LlmErrors.Create(LlmErrorKind.InvalidOutput, "", model, LlmFeature.VoiceRewrite);
        return new(Guid.NewGuid(), snapshot.Scope, snapshot.SourceWords, source, rewrite, connector.Id, model, answer.RequestId);
    }

    private LlmRequest BuildRequest(VoiceRewriteRequest input, string source, ConnectorId connector, string model)
    {
        JsonObject prompt;
        try { prompt = catalog.ReadAsset("prompts/voice-rewrite.json"); }
        catch (VoxClipException) { throw; }
        var system = prompt["system"]?.GetValue<string>();
        var name = prompt["schemaName"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(system) || string.IsNullOrWhiteSpace(name) || prompt["schema"] is not JsonObject schema ||
            schema["type"]?.GetValue<string>() != "object" || schema["properties"]?["rewrite"]?["type"]?.GetValue<string>() != "string" ||
            prompt["maxOutputTokens"] is not JsonValue outputValue || !outputValue.TryGetValue<int>(out var promptCap) || promptCap is < 1 or > 16000)
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        var sourceTokens = catalog.Estimate(source);
        var maxOutput = Math.Min(Math.Min(promptCap, catalog.Cap(connector, promptCap)),
            Math.Max(512, (int)Math.Ceiling(sourceTokens * 1.5)));
        if (maxOutput < sourceTokens)
            throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", model, LlmFeature.VoiceRewrite);
        var sourceBlock = $"SOURCE TRANSCRIPT ({ScopeWire(input.Scope)}, {input.Language}):\n{source}";
        var instruction = "USER EDIT REQUEST:\n" + input.Instruction + "\n\nReturn rewritten spoken words for the entire selected source.";
        var timeout = catalog.Timeout(connector is ConnectorId.ClaudeCode or ConnectorId.Codex ? "cli" :
            connector is ConnectorId.Ollama or ConnectorId.LmStudio ? "localServer" : "cloud");
        return new(LlmFeature.VoiceRewrite, system, sourceBlock, instruction, name, schema.DeepClone().AsObject(),
            maxOutput, Effort.Medium, timeout, input.Language, "voice-rewrite");
    }

    private void CheckContext(LlmRequest request, string model, int context)
    {
        var required = catalog.Estimate(request.System + request.CachedBlock + request.Instruction + request.Schema.ToJsonString()) +
            request.MaxOutputTokens + 64;
        if (context < 512 || required >= context * catalog.Data["policy"]!["tokenEstimate"]!["contextSafetyFactor"]!.GetValue<double>())
            throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", model, LlmFeature.VoiceRewrite);
    }

    private LlmException StatusFailure(ConnectorStatus status, ConnectorId connector, string model)
    {
        var kind = status switch
        {
            ConnectorStatus.NeedsKey => LlmErrorKind.MissingKey,
            ConnectorStatus.NotRunning => LlmErrorKind.NotRunning,
            ConnectorStatus.NoModels => LlmErrorKind.NoModels,
            ConnectorStatus.CliMissing => LlmErrorKind.CliMissing,
            ConnectorStatus.CliTooOld => LlmErrorKind.CliTooOld,
            ConnectorStatus.CliSignedOut => LlmErrorKind.CliSignedOut,
            _ => LlmErrorKind.Unavailable
        };
        var detail = status switch
        {
            ConnectorStatus.NotRunning local => local.Url,
            ConnectorStatus.CliTooOld old => old.Version,
            ConnectorStatus.CliMissing => catalog.Provider(connector)["cli"]?["installHint"]?.GetValue<string>(),
            ConnectorStatus.Unavailable unavailable => unavailable.Reason,
            _ => null
        };
        return LlmErrors.Create(kind, catalog.Provider(connector)["label"]!.GetValue<string>(), model, LlmFeature.VoiceRewrite, detail: detail);
    }

    private static string Validate(VoiceRewriteRequest input)
    {
        if (input is null || input.RequestId == Guid.Empty || !Enum.IsDefined(input.Scope) || input.SourceWords is null || input.SourceWords.Count is < 1 or > 3000 ||
            input.Instruction is null || Encoding.UTF8.GetByteCount(input.Instruction) > 1000 ||
            input.Language is null || !LanguageCode.IsMatch(input.Language)) throw Invalid();
        var previous = 0.0;
        foreach (var word in input.SourceWords)
        {
            if (word is null || word.Kind != WordKind.Word || string.IsNullOrWhiteSpace(word.Id) || string.IsNullOrWhiteSpace(word.Text) ||
                !double.IsFinite(word.Start) || !double.IsFinite(word.End) || word.Start < previous || word.End < word.Start ||
                word.RawStart is { } rawStart && !double.IsFinite(rawStart) || word.RawEnd is { } rawEnd && !double.IsFinite(rawEnd)) throw Invalid();
            previous = word.Start;
        }
        var source = string.Join(" ", input.SourceWords.Select(word => word.Text));
        if (Encoding.UTF8.GetByteCount(source) > 20000) throw Invalid();
        return source;
    }
    private static string Fingerprint(VoiceRewriteRequest input, ConnectorId connector, string model, LlmRequest request)
    {
        var parts = new List<string?> { "voice-rewrite", input.RequestId.ToString("D"), LlmCatalog.WireId(connector), model, ScopeWire(input.Scope),
            input.Instruction, input.Language, request.System, request.CachedBlock, request.Instruction, request.SchemaName,
            request.Schema.ToJsonString(), request.MaxOutputTokens.ToString(CultureInfo.InvariantCulture) };
        foreach (var word in input.SourceWords)
        {
            parts.AddRange([word.Id, word.Text, word.Kind.ToString(), word.Start.ToString("R", CultureInfo.InvariantCulture),
                word.End.ToString("R", CultureInfo.InvariantCulture), word.RawStart?.ToString("R", CultureInfo.InvariantCulture),
                word.RawEnd?.ToString("R", CultureInfo.InvariantCulture), word.Conf?.ToString("R", CultureInfo.InvariantCulture),
                word.Speaker, word.Timing.ToString()]);
        }
        return VoiceLabActionGate.Fingerprint(parts.ToArray());
    }
    private static string ScopeWire(VoiceRewriteScope scope) => scope switch
    {
        VoiceRewriteScope.Passage => "passage", VoiceRewriteScope.FullTake => "fullTake", _ => throw Invalid()
    };
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
}
