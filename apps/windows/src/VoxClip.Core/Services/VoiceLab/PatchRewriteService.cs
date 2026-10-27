using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>Fix with AI (voice-lab §8.1, path 3): one selected connector and model, one billed send, and validated, inert line edits.
/// It never edits a project, invokes Voice Lab generation or asks again by itself.</summary>
public sealed class PatchRewriteService
{
    private static readonly Regex LanguageCode = new(@"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private readonly LlmCatalog catalog;
    private readonly VoiceLabActionGate actions = new();

    /// <summary>Use the shared LLM catalogue and the Fix with AI prompt.</summary>
    public PatchRewriteService(LlmCatalog catalog) => this.catalog = catalog ?? throw new ArgumentNullException(nameof(catalog));

    /// <summary>Preflight and estimate are explicit caller actions; they do not generate edits.</summary>
    public Task<VoiceLabPreparedAction> PrepareAsync(PatchRewriteRequest input, ILlmConnector connector, string model, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(connector);
        var snapshot = Snapshot(input);
        var lines = Validate(snapshot);
        if (!VoiceLabLlmChecks.IsValidModel(model)) throw Invalid();
        var prompt = ReadPrompt();
        var request = BuildRequest(snapshot, lines, prompt, connector.Id, model);
        return Task.FromResult(actions.Prepare(Fingerprint(snapshot, connector.Id, model, request, prompt.Sha256),
            VoiceLabLlmChecks.Estimate(catalog, connector.Id, VoiceLabOperation.PatchRewrite, request),
            new(VoiceLabOperation.PatchRewrite, snapshot.RequestId, LlmCatalog.WireId(connector.Id), null,
                "patch-rewrite", model, null, new(VoiceLabLanguageModeKind.Explicit, snapshot.Language),
                VoiceLabActionGate.ContentHash(Encoding.UTF8.GetBytes(request.CachedBlock!)), null)));
    }

    /// <summary>Approval is affirmative for the exact prepared transcript, ranges, instruction, connector, model and prompt.</summary>
    public VoiceLabAuthorization Approve(VoiceLabPreparedAction action, bool affirmative) => actions.Approve(action, affirmative);

    /// <summary>Generate only proposed edits. This method never changes a project or invokes speech synthesis.</summary>
    public async Task<PatchRewriteProposal> ProposeAsync(PatchRewriteRequest input, ILlmConnector connector, string model,
        VoiceLabAuthorization authorization, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(connector);
        var snapshot = Snapshot(input);
        var lines = Validate(snapshot);
        // Bind the approved input before discovery, without consuming it for a nonbillable preflight failure.
        var prompt = ReadPrompt();
        var request = BuildRequest(snapshot, lines, prompt, connector.Id, model);
        var fingerprint = Fingerprint(snapshot, connector.Id, model, request, prompt.Sha256);
        actions.Verify(authorization, fingerprint, VoiceLabOperation.PatchRewrite, snapshot.RequestId);
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
        actions.Claim(authorization, fingerprint, VoiceLabOperation.PatchRewrite, snapshot.RequestId);
        RawCompletion answer;
        try { answer = await connector.SendAsync(request, model, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw LlmErrors.Create(LlmErrorKind.Cancelled, "", model, LlmFeature.VoiceRewrite); }
        ct.ThrowIfCancellationRequested();
        VoiceLabLlmChecks.CheckAnswer(connector.Id, model, answer);
        var parsed = LlmOutput.Validate(answer, request.Schema);
        if (parsed.Object?["edits"] is not JsonArray items) throw InvalidOutput(model);
        PatchRewriteValidator.Result result;
        try { result = PatchRewriteValidator.Validate(items, snapshot.Ranges, snapshot.Entries.Select(entry => entry.Text).Append(snapshot.Instruction)); }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or RegexMatchTimeoutException) { throw InvalidOutput(model); }
        // The whole reply keeps the 20,000-byte rule: the kept edits' texts hold at most that much together (§8.1).
        if (result.Edits.Sum(edit => Encoding.UTF8.GetByteCount(edit.Text)) > PatchRewriteValidator.MaxTextBytes) throw InvalidOutput(model);
        return new(Guid.NewGuid(), result.Edits, result.UnknownLines, result.DuplicateLines, parsed.Dropped + result.MalformedItems, prompt.CheckThis,
            connector.Id, answer.Model, answer.RequestId);
    }

    private sealed record Prompt(JsonObject Document, string System, string SchemaName, JsonObject Schema, int OutputCap, string CheckThis, string Sha256);

    private Prompt ReadPrompt()
    {
        var (document, sha256) = VoiceLabLlmChecks.ReadPrompt(catalog, "prompts/patch-rewrite.json");
        if (Text(document["system"]) is not { Length: > 0 } system || Text(document["schemaName"]) is not { Length: > 0 } name ||
            document["schema"] is not JsonObject schema || schema["properties"]?["edits"]?["type"]?.GetValue<string>() != "array" ||
            Text((document["messages"] as JsonObject)?["checkThis"]) is not { Length: > 0 } checkThis ||
            document["maxOutputTokens"] is not JsonValue outputValue || !outputValue.TryGetValue<int>(out var outputCap) || outputCap is < 1 or > 16000)
            throw Missing();
        return new(document, system, name, schema, outputCap, checkThis, sha256);
    }

    private LlmRequest BuildRequest(PatchRewriteRequest input, IReadOnlyList<NumberedLine> lines, Prompt prompt, ConnectorId connector, string model)
    {
        var rendered = ClipText.Render(lines);
        var sourceTokens = catalog.Estimate(rendered);
        var maxOutput = VoiceLabLlmChecks.MaxOutputTokens(sourceTokens, prompt.OutputCap, catalog.Cap(connector, prompt.OutputCap)) ??
            throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", model, LlmFeature.VoiceRewrite);
        var (cachedBlock, instruction) = RequestText(input, rendered, prompt.Document);
        var timeout = catalog.Timeout(connector is ConnectorId.ClaudeCode or ConnectorId.Codex ? "cli" :
            connector is ConnectorId.Ollama or ConnectorId.LmStudio ? "localServer" : "cloud");
        // A Voice Lab rewrite send, so each connector makes it once, like the passage rewrite.
        return new(LlmFeature.VoiceRewrite, prompt.System, cachedBlock, instruction, prompt.SchemaName, prompt.Schema.DeepClone().AsObject(),
            maxOutput, Effort.Medium, timeout, input.Language, "patch-rewrite");
    }

    /// <summary>Renders the request from the shared prompt (voice-lab §8.1): the clip finder's transcript block, then one range per
    /// line and the instruction. No prompt text lives in code.</summary>
    internal static (string CachedBlock, string Instruction) RequestText(PatchRewriteRequest input, string rendered, JsonObject prompt)
    {
        string? Template(string group, string key) => prompt[group] is JsonObject block ? Text(block[key]) : null;
        if (Template("transcriptBlock", "prefix") is not { } prefix || Template("transcriptBlock", "suffix") is not { } suffix ||
            Template("request", "rangesLine") is not { } rangesLine || Template("request", "rangeLine") is not { } rangeLine ||
            Template("request", "instructionLine") is not { } instructionLine ||
            !new[] { "{line}", "{minChars}", "{maxChars}" }.All(name => rangeLine.Contains(name, StringComparison.Ordinal)) ||
            !instructionLine.Contains("{instruction}", StringComparison.Ordinal)) throw Missing();
        var ranges = input.Ranges.Select(range => rangeLine.Replace("{line}", range.Line, StringComparison.Ordinal)
            .Replace("{minChars}", range.MinChars.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("{maxChars}", range.MaxChars.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal));
        var instruction = instructionLine.Replace("{instruction}", EditingAlgorithms.JsTrim(input.Instruction), StringComparison.Ordinal);
        return (prefix + rendered + suffix, string.Join("\n", ranges.Prepend(rangesLine)) + "\n\n" + instruction);
    }

    private static PatchRewriteRequest Snapshot(PatchRewriteRequest? input) => input?.Entries is null || input.Ranges is null
        ? throw Invalid() : input with { Entries = input.Entries.ToArray(), Ranges = input.Ranges.ToArray() };

    /// <summary>Checks every input bound and returns the request's transcript lines (ai.md §11.3), one per range.</summary>
    private static IReadOnlyList<NumberedLine> Validate(PatchRewriteRequest input)
    {
        if (input.RequestId == Guid.Empty || input.Entries.Count is < 1 or > 3000 || input.Instruction is null ||
            EditingAlgorithms.JsTrim(input.Instruction).Length == 0 || Encoding.UTF8.GetByteCount(input.Instruction) > 1000 ||
            input.Language is null || !LanguageCode.IsMatch(input.Language)) throw Invalid();
        for (var position = 0; position < input.Entries.Count; position++)
        {
            var entry = input.Entries[position];
            if (entry?.Text is null || EditingAlgorithms.JsTrim(entry.Text).Length == 0 || !double.IsFinite(entry.Start) || !double.IsFinite(entry.End) ||
                entry.Start < 0 || entry.End < entry.Start || (position == 0 ? entry.Index < 0 : entry.Index <= input.Entries[position - 1].Index)) throw Invalid();
        }
        if (Encoding.UTF8.GetByteCount(string.Join(" ", input.Entries.Select(entry => entry.Text))) > 20000 ||
            input.Ranges.Any(range => range?.Line is null || range.MinChars < 1 || range.MinChars > range.MaxChars || range.MaxChars > 5000)) throw Invalid();
        var lines = ClipText.Lines(input.Entries);
        if (lines.Count != input.Ranges.Count ||
            lines.Where((line, index) => $"[{line.Line.FirstIndex}-{line.Line.LastIndex}]" != input.Ranges[index].Line).Any()) throw Invalid();
        return lines;
    }

    private static string Fingerprint(PatchRewriteRequest input, ConnectorId connector, string model, LlmRequest request, string promptSha256)
    {
        var parts = new List<string?> { "patch-rewrite", input.RequestId.ToString("D"), LlmCatalog.WireId(connector), model, input.Instruction,
            input.Language, promptSha256, request.System, request.CachedBlock, request.Instruction, request.SchemaName, request.Schema.ToJsonString(),
            request.MaxOutputTokens.ToString(CultureInfo.InvariantCulture) };
        foreach (var entry in input.Entries)
            parts.AddRange([entry.Index.ToString(CultureInfo.InvariantCulture), entry.Text, entry.Start.ToString("R", CultureInfo.InvariantCulture),
                entry.End.ToString("R", CultureInfo.InvariantCulture)]);
        foreach (var range in input.Ranges)
            parts.AddRange([range.Line, range.MinChars.ToString(CultureInfo.InvariantCulture), range.MaxChars.ToString(CultureInfo.InvariantCulture)]);
        return VoiceLabActionGate.Fingerprint(parts.ToArray());
    }

    private static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
    private static LlmException InvalidOutput(string model) => LlmErrors.Create(LlmErrorKind.InvalidOutput, "", model, LlmFeature.VoiceRewrite);
    private static VoxClipException Missing() => new(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
}
