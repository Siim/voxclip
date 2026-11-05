using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Core.Services.LLM;

/// <summary>A checked Ask Claude answer and where it came from (ai.md §18).</summary>
public sealed record AskClaudeResult(AskClaudeAnswer Answer, string Model, bool UsedFallback, int DroppedItems, LlmUsage? Usage, int PromptVersion, string PromptSha256);

/// <summary>Ask Claude (ai.md §18): one instruction on a selection, clip or time range, answered with toolbox operations at extra high
/// effort and checked op by op. It never applies, generates or bills anything: the change list applies the free operations as one
/// undo step and keeps paid ones behind their priced click. Twin of the Mac <c>AskClaudeService</c>.</summary>
public sealed class AskClaudeService(LlmRunner runner, LlmCatalog catalog, AskClaudePrompt prompt)
{
    /// <summary>Every Ask Claude send's effort.</summary>
    public const Effort AskEffort = EffortLevel.Decision;

    /// <summary>The prompt the service renders.</summary>
    public AskClaudePrompt Prompt => prompt;

    /// <summary>The request <see cref="AskAsync"/> sends, for previews and tests.</summary>
    public LlmRequest Request(string instruction, AskClaudeSelection selection, VoxClip.Core.Domain.Shared.Project project, IReadOnlyList<AskClaudeDetection> detections, string aspect, ConnectorId connector)
    {
        var scope = AskClaudeScope.Resolve(selection, project);
        var parts = prompt.Request(instruction, scope, project, detections, aspect);
        return new(LlmFeature.AskClaude, parts.System, null, parts.Instruction, parts.SchemaName, parts.Schema, catalog.Cap(connector, parts.MaxOutputTokens),
            AskEffort, catalog.Timeout(TimeoutKind(connector)), project.Transcript?.Language, "ask-claude");
    }

    /// <summary>Sends <paramref name="instruction"/> once and checks the reply; an empty instruction sends nothing and throws.</summary>
    public async Task<AskClaudeResult> AskAsync(string instruction, AskClaudeSelection selection, VoxClip.Core.Domain.Shared.Project project, IReadOnlyList<AskClaudeDetection> detections,
        string aspect, ILlmConnector connector, string model, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(instruction) || !VoiceLabLlmChecks.IsValidModel(model)) throw AskClaudeScope.Invalid();
        var scope = AskClaudeScope.Resolve(selection, project);
        var request = Request(instruction, selection, project, detections, aspect, connector.Id);
        ct.ThrowIfCancellationRequested();
        var reply = await runner.RunAsync(request, connector, model, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var answer = new AskClaudeValidator(prompt, scope, project, detections).Answer(reply.Object);
        return new(answer, reply.Model, reply.UsedFallback, reply.DroppedItems, reply.Usage, prompt.PromptVersion, prompt.Sha256);
    }

    private static string TimeoutKind(ConnectorId id) => id switch
    {
        ConnectorId.ClaudeCode or ConnectorId.Codex => "cli", ConnectorId.Ollama or ConnectorId.LmStudio => "localServer",
        ConnectorId.AppleFoundation => "appleFoundation", _ => "cloud"
    };
}
