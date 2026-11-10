using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>Talk back to the AI about one change (design.md §6.3 "Talk back to Claude", ai.md §12.10, ADR-R50): one request on the chosen
/// connector, answered with checked spoken words, a note and next steps. It never voices, prices or applies anything: the thread puts a
/// new version in the change's place through the local edit, and only the version that is kept goes on to Rewrite's voice and price steps.
/// Twin of the Mac <c>RewriteFollowupService</c>.</summary>
public sealed class RewriteFollowupService(LlmRunner runner, LlmCatalog catalog, RewriteFollowupPrompt prompt)
{
    /// <summary>The prompt the service renders.</summary>
    public RewriteFollowupPrompt Prompt => prompt;

    /// <summary>The request <see cref="SendAsync"/> sends, for previews and tests.</summary>
    public LlmRequest Request(RewriteFollowupRequest input, ConnectorId connector) =>
        prompt.Request(input, catalog.Timeout(TimeoutKind(connector)), catalog.Cap(connector, prompt.MaxOutputTokens));

    /// <summary>Sends <paramref name="input"/> once and checks the reply; a request with no version or message sends nothing and throws.</summary>
    public async Task<RewriteFollowupReply> SendAsync(RewriteFollowupRequest input, ILlmConnector connector, string model, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(connector);
        if (!VoiceLabLlmChecks.IsValidModel(model)) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var request = Request(input, connector.Id);
        ct.ThrowIfCancellationRequested();
        var result = await runner.RunAsync(request, connector, model, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return prompt.Reply(result.Object, input);
    }

    private static string TimeoutKind(ConnectorId id) => id switch
    {
        ConnectorId.ClaudeCode or ConnectorId.Codex => "cli", ConnectorId.Ollama or ConnectorId.LmStudio => "localServer",
        ConnectorId.AppleFoundation => "appleFoundation", _ => "cloud"
    };
}
