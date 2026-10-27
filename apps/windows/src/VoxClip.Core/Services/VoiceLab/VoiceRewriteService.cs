using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>One selected connector and model, one billed send, and inert review data for a passage or full take.</summary>
public sealed class VoiceRewriteService
{
    private static readonly Regex LanguageCode = new(@"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
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
        if (!VoiceLabLlmChecks.IsValidModel(model)) throw Invalid();
        var prompt = VoiceLabLlmChecks.ReadPrompt(catalog, PromptFile);
        var request = BuildRequest(snapshot, source, prompt.Document, connector.Id, model);
        return Task.FromResult(actions.Prepare(Fingerprint(snapshot, connector.Id, model, request, prompt.Sha256),
            VoiceLabLlmChecks.Estimate(catalog, connector.Id, VoiceLabOperation.VoiceRewrite, request),
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
        var prompt = VoiceLabLlmChecks.ReadPrompt(catalog, PromptFile);
        var request = BuildRequest(snapshot, source, prompt.Document, connector.Id, model);
        var fingerprint = Fingerprint(snapshot, connector.Id, model, request, prompt.Sha256);
        actions.Verify(authorization, fingerprint, VoiceLabOperation.VoiceRewrite, snapshot.RequestId);
        var status = await connector.GetStatusAsync(ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (status is not ConnectorStatus.Ready) throw VoiceLabLlmChecks.StatusFailure(catalog, status, connector.Id, model);
        var models = await connector.GetModelsAsync(false, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var selected = models.FirstOrDefault(candidate => candidate.Id == model);
        if (selected is null) throw LlmErrors.Create(LlmErrorKind.ModelNotFound, "", model, LlmFeature.VoiceRewrite);
        var context = await catalog.ResolveContextTokensAsync(connector, model, ct, models).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        VoiceLabLlmChecks.CheckContext(catalog, request, model, context);
        ct.ThrowIfCancellationRequested();
        // Claim is atomic and immediately precedes the only call that may dispatch a paid request.
        actions.Claim(authorization, fingerprint, VoiceLabOperation.VoiceRewrite, snapshot.RequestId);
        RawCompletion answer;
        try { answer = await connector.SendAsync(request, model, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw LlmErrors.Create(LlmErrorKind.Cancelled, "", model, LlmFeature.VoiceRewrite); }
        ct.ThrowIfCancellationRequested();
        VoiceLabLlmChecks.CheckAnswer(connector.Id, model, answer);
        // §8.9.1: one spoken passage; extra keys are ignored, as in every reply (ai.md §2.3).
        var parsed = LlmOutput.Validate(answer, request.Schema);
        if (parsed.Object is null || parsed.Dropped != 0 || parsed.Object["rewrite"] is not JsonValue value ||
            !value.TryGetValue<string>(out var rewrite) || EditingAlgorithms.JsTrim(rewrite).Length == 0 || Encoding.UTF8.GetByteCount(rewrite) > 20000 ||
            Url.IsMatch(rewrite) || rewrite.Any(character => char.IsControl(character) && character != '\n'))
            throw LlmErrors.Create(LlmErrorKind.InvalidOutput, "", model, LlmFeature.VoiceRewrite);
        var length = VoiceLabTextLength.Length(rewrite);
        return new(Guid.NewGuid(), snapshot.Scope, snapshot.SourceWords, source, rewrite, connector.Id, answer.Model, answer.RequestId,
            length, length >= snapshot.MinChars && length <= snapshot.MaxChars);
    }

    private const string PromptFile = "prompts/voice-rewrite.json";

    private LlmRequest BuildRequest(VoiceRewriteRequest input, string source, JsonObject prompt, ConnectorId connector, string model)
    {
        var system = prompt["system"]?.GetValue<string>();
        var name = prompt["schemaName"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(system) || string.IsNullOrWhiteSpace(name) || prompt["schema"] is not JsonObject schema ||
            schema["type"]?.GetValue<string>() != "object" || schema["properties"]?["rewrite"]?["type"]?.GetValue<string>() != "string" ||
            prompt["maxOutputTokens"] is not JsonValue outputValue || !outputValue.TryGetValue<int>(out var promptCap) || promptCap is < 1 or > 16000)
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        var sourceTokens = catalog.Estimate(source);
        var maxOutput = VoiceLabLlmChecks.MaxOutputTokens(sourceTokens, promptCap, catalog.Cap(connector, promptCap)) ??
            throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", model, LlmFeature.VoiceRewrite);
        var (sourceBlock, instruction) = RequestText(input, source, prompt);
        var timeout = catalog.Timeout(connector is ConnectorId.ClaudeCode or ConnectorId.Codex ? "cli" :
            connector is ConnectorId.Ollama or ConnectorId.LmStudio ? "localServer" : "cloud");
        return new(LlmFeature.VoiceRewrite, system, sourceBlock, instruction, name, schema.DeepClone().AsObject(),
            maxOutput, Effort.Medium, timeout, input.Language, "voice-rewrite");
    }

    /// <summary>Renders the request from the shared prompt's templates (voice-lab §8.9.1); no prompt text lives in code.</summary>
    internal static (string CachedBlock, string Instruction) RequestText(VoiceRewriteRequest input, string source, JsonObject prompt)
    {
        string? Template(string key) => prompt["request"]?[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
        if (Template("sourceBlock") is not { } sourceBlock || Template("instructionBlock") is not { } requestBlock ||
            Template("returnLine") is not { } returnLine || Template("lengthLine") is not { } lengthLine ||
            !new[] { "{scope}", "{language}", "{source}" }.All(name => sourceBlock.Contains(name, StringComparison.Ordinal)) ||
            !requestBlock.Contains("{instruction}", StringComparison.Ordinal) ||
            !new[] { "{targetSeconds}", "{minChars}", "{maxChars}" }.All(name => lengthLine.Contains(name, StringComparison.Ordinal)))
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        // User text goes in last, so it is never read as a placeholder.
        var block = sourceBlock.Replace("{scope}", ScopeWire(input.Scope), StringComparison.Ordinal)
            .Replace("{language}", input.Language, StringComparison.Ordinal).Replace("{source}", source, StringComparison.Ordinal);
        var length = lengthLine.Replace("{targetSeconds}", EditingFormat.ToFixed1(input.TargetSeconds), StringComparison.Ordinal)
            .Replace("{minChars}", input.MinChars.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("{maxChars}", input.MaxChars.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);
        var request = EditingAlgorithms.JsTrim(input.Instruction);
        return (block, (request.Length == 0 ? "" : requestBlock.Replace("{instruction}", request, StringComparison.Ordinal) + "\n\n") + returnLine + "\n" + length);
    }

    private static string Validate(VoiceRewriteRequest input)
    {
        if (input is null || input.RequestId == Guid.Empty || !Enum.IsDefined(input.Scope) || input.SourceWords is null || input.SourceWords.Count is < 1 or > 3000 ||
            input.Instruction is null || Encoding.UTF8.GetByteCount(input.Instruction) > 1000 ||
            input.Language is null || !LanguageCode.IsMatch(input.Language) ||
            !double.IsFinite(input.TargetSeconds) || input.TargetSeconds is <= 0 or > 600 ||
            input.MinChars < 1 || input.MinChars > input.MaxChars || input.MaxChars > 5000) throw Invalid();
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
    private static string Fingerprint(VoiceRewriteRequest input, ConnectorId connector, string model, LlmRequest request, string promptSha256)
    {
        var parts = new List<string?> { "voice-rewrite", input.RequestId.ToString("D"), LlmCatalog.WireId(connector), model, ScopeWire(input.Scope),
            input.Instruction, input.Language, input.TargetSeconds.ToString("R", CultureInfo.InvariantCulture),
            input.MinChars.ToString(CultureInfo.InvariantCulture), input.MaxChars.ToString(CultureInfo.InvariantCulture), promptSha256,
            request.System, request.CachedBlock, request.Instruction, request.SchemaName,
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
