using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.Controls;

internal sealed partial class RewritePanel
{
    /// <summary>The thread's live send (design.md §6.3 "Talk back to Claude"): the open Rewrite's AI under the project's one AI lease, after
    /// the Rewrite consent inline in the thread where the provider needs one (a first send, or one billed to a key), then one checked
    /// request. Nothing is voiced or paid.</summary>
    private async Task<RewriteFollowupReply> ThreadSendAsync(RewriteFollowupRequest request, CancellationToken ct)
    {
        if (session.Connector is not { } connector)
            throw new InvalidOperationException($"Choose a connector in Settings → {SettingsSections.ProvidersAndKeys}. Nothing was sent.");
        if (App.Services.SharedRoot is not { } root) throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        using var lease = session.Editor.LlmRuns.TryAcquire()
            ?? throw new InvalidOperationException("Another AI request on this project is still running. Try Again when it finishes.");
        if (!await ApproveThreadSendAsync(connector, ct)) throw new OperationCanceledException(ct);
        var catalog = LlmCatalog.Load(root);
        var service = new RewriteFollowupService(new LlmRunner(App.Services.Keys, catalog, new Redactor()), catalog, RewriteFollowupPrompt.Load(root));
        return await service.SendAsync(request, connector.Connector, connector.Model, ct);
    }

    /// <summary>A first send to a cloud or CLI connector, or one billed to an API key, asks inline in the thread, as the Rewrite does.</summary>
    private async Task<bool> ApproveThreadSendAsync(RewriteConnector connector, CancellationToken ct)
    {
        var signIn = RewriteSession.SignIn((connector.Connector as LlmConnector)?.CliDetection);
        if (connector.Group == "cli" && signIn is null) throw new InvalidOperationException("Check the connector's sign-in method before sending a request.");
        var firstUse = !InlinePrivacyGranted();
        var billed = VoiceLabCostPresentation.KindForLlmSend(connector.Connector.Id, signIn, connector.Connector.Id switch
            { ConnectorId.ClaudeCode => "Anthropic", ConnectorId.Codex => "OpenAI", _ => connector.Name }).Kind == VoiceLabCostPresentationKind.Confirm;
        if (!firstUse && !billed) return true;
        var privacy = PrivacyText(connector, firstUse);
        if (firstUse && privacy is null) throw new InvalidOperationException("Check the connector's sign-in method before sending a request.");
        var snapshot = session.Project;
        bool Current() => session.IsOpen && ReferenceEquals(snapshot, session.Editor.Project);
        using var pending = new InlineApproval(new(Guid.NewGuid(), snapshot, firstUse ? "Allow this connector" : "Send this message to " + connector.Name + "?",
            SendLine, string.Join("\n", new[] { privacy, "No audio or video. " + connector.Model + "." }.Where(text => !string.IsNullOrWhiteSpace(text))),
            firstUse ? "Allow and Send" : "Send", billed, PricingPage(connector.Connector.Id)), Current, ct, Environment.TickCount);
        session.ShowThreadConfirmation(pending);
        try
        {
            if (!await pending.Completion || !Current()) return false;
            if (RemoteLocal) remoteLocalAllowed = true;
            else if (firstUse && ProviderWireId(connector.Connector.Id) is { } wire) await App.Services.SetAsync("llm.cloudConsent." + wire, true, ct);
            return true;
        }
        finally { session.ShowThreadConfirmation(null); }
    }
}
