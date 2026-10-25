namespace VoxClip.Core.Services.LLM;

public sealed partial class LlmRunner
{
    internal async Task<LlmResult> RunCoreAsync(LlmRequest request, ILlmConnector connector, string model, CancellationToken ct, bool reportErrors = true)
    {
        try
        {
            var label = await PreflightCoreAsync(connector, model, request.Feature, ct).ConfigureAwait(false);
            var chosen = model;
            var fallbackUsed = false;
            for (var fallbackAttempt = 0; ; fallbackAttempt++)
            {
                try
                {
                    var currentRequest = request;
                    for (var correction = 0; ; correction++)
                    {
                        var raw = await connector.SendAsync(currentRequest, chosen, ct).ConfigureAwait(false);
                        if (raw.Stop is StopKind.Truncated) throw LlmErrors.Create(LlmErrorKind.Truncated, label, chosen, request.Feature, redactor: log);
                        if (raw.Stop is StopKind.Refused refused) throw LlmErrors.Create(LlmErrorKind.Refused, label, chosen, request.Feature, detail: refused.Category, redactor: log);
                        var validated = LlmOutput.Validate(raw, request.Schema);
                        if (validated.Object is { } result) return new(result, validated.Dropped, raw.Model, fallbackUsed || (connector.Id == ConnectorId.ClaudeCode && chosen != "default" && !ClaudeModelMatches(chosen, raw.Model)), raw.Usage, raw.RequestId);
                        if (correction > 0) throw LlmErrors.Create(LlmErrorKind.InvalidOutput, label, chosen, request.Feature, detail: validated.Reason, redactor: log);
                        currentRequest = request with { Instruction = request.Instruction + $"\n\nYour previous reply was not valid JSON for the required schema ({validated.Reason}). Reply with only the JSON object." };
                    }
                }
                catch (LlmException exception) when (fallbackAttempt == 0 && connector.Id != ConnectorId.ClaudeCode &&
                    (exception.Error.Kind is LlmErrorKind.RateLimited or LlmErrorKind.Overloaded || connector.Id == ConnectorId.Codex && exception.Error.Kind == LlmErrorKind.PlanLimit))
                {
                    var fallback = catalog.Fallback(connector.Id, chosen);
                    if (fallback is null) throw;
                    chosen = fallback;
                    fallbackUsed = true;
                }
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            var failure = LlmErrors.Create(LlmErrorKind.Cancelled, "");
            if (reportErrors) ReportError(failure);
            throw failure;
        }
        catch (LlmException exception) { if (reportErrors) ReportError(exception); throw; }
    }

    internal async Task<string> PreflightAsync(ILlmConnector connector, string model, LlmFeature feature, CancellationToken ct, bool reportErrors = true)
    {
        try { return await PreflightCoreAsync(connector, model, feature, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            var failure = LlmErrors.Create(LlmErrorKind.Cancelled, "");
            if (reportErrors) ReportError(failure);
            throw failure;
        }
        catch (LlmException exception) { if (reportErrors) ReportError(exception); throw; }
    }

    internal void ReportError(LlmException exception)
    {
        if (onError is null) return;
        var safe = new Domain.Shared.Redactor().Redact(log.Redact(exception.Error.UserMessage));
        try { onError(exception.Error.Kind, safe[..Math.Min(200, safe.Length)]); }
        catch (Exception) { }
    }

    private async Task<string> PreflightCoreAsync(ILlmConnector connector, string model, LlmFeature feature, CancellationToken ct)
    {
        if (connector is LlmConnector concrete) concrete.Configure(keys, log);
        var status = await connector.GetStatusAsync(ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var label = catalog.Provider(connector.Id)["label"]!.GetValue<string>();
        var kind = status switch
        {
            ConnectorStatus.Ready => (LlmErrorKind?)null,
            ConnectorStatus.NeedsKey => LlmErrorKind.MissingKey,
            ConnectorStatus.NotRunning => LlmErrorKind.NotRunning,
            ConnectorStatus.NoModels => LlmErrorKind.NoModels,
            ConnectorStatus.CliMissing => LlmErrorKind.CliMissing,
            ConnectorStatus.CliTooOld => LlmErrorKind.CliTooOld,
            ConnectorStatus.CliSignedOut => LlmErrorKind.CliSignedOut,
            _ => LlmErrorKind.Unavailable
        };
        if (kind is { } failure) throw LlmErrors.Create(failure, label, model, feature,
            detail: status switch { ConnectorStatus.NotRunning local => local.Url, ConnectorStatus.CliTooOld old => old.Version, ConnectorStatus.Unavailable unavailable => unavailable.Reason, ConnectorStatus.CliMissing => catalog.Provider(connector.Id)["cli"]?["installHint"]?.GetValue<string>(), _ => null }, redactor: log);
        return label;
    }
    private static bool ClaudeModelMatches(string chosen, string answering) => answering == chosen ||
        answering.StartsWith((chosen.StartsWith("claude-", StringComparison.Ordinal) ? chosen : "claude-" + chosen) + "-", StringComparison.Ordinal);
}
