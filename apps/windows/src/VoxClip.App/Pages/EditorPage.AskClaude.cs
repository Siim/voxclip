using VoxClip.App.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.Pages;

/// <summary>✦ Ask Claude's live services and panel (design §6.8): the request through the chosen AI (a first or billed send asks inline
/// in the panel, consent action Ask Claude), Windows Vision on the source for detections and face tracks, and the panel in the right
/// column with the viewer shown.</summary>
public sealed partial class EditorPage
{
    private AskClaudePanel? askClaudePanel;

    private void InitializeAskClaude()
    {
        var root = App.Services.SharedRoot;
        VoiceLabPriceCatalog? prices = null;
        try { prices = root is null ? null : VoiceLabPrices.Load(root); } catch (VoxClipException) { }
        ViewModel.AskClaudeServices = new AskClaudeServices
        {
            Ask = AskClaudeSendAsync,
            Available = () => root is not null && App.Services.Get("llm.connector", "").Length > 0,
            CostLine = () => AskClaudeCost(App.Services.Get("llm.connector", "")),
            Vision = new WindowsAskClaudeVision(() => !demo && media is { Video: not null } info && MediaPath is { } path ? (path, info.Video.RotationDegrees, info.OrientedSize) : null),
            Prices = prices
        };
        ViewModel.AskClaudeShown += (_, _) => ShowAskClaudePanel();
        ViewModel.AskClaudeClosed += (_, _) => askClaudePanel?.RequestClose();
        ViewModel.AskClaudePlayRequested += (_, time) => _ = RunAsync(() => PlayMakeItAsync(time), "Preview");
        ViewModel.AskClaudeMusicRequested += (_, cue) =>
        {
            ShowCaptions();
            _ = ViewModel.Music.SuggestAsync(VoxClip.Core.Domain.Music.MusicBrief.From(cue.Picked));
        };
        AskClaudeBox.Attach(ViewModel);
    }

    /// <summary>"Free on your Claude plan" on Claude Code, "Free on your ChatGPT plan" on Codex, "Free on this PC" for a local model, else
    /// "Billed to your {provider} key".</summary>
    internal static string AskClaudeCost(string connector) => connector switch
    {
        "claude-code" => "Free on your Claude plan",
        "codex" => "Free on your ChatGPT plan",
        "ollama" or "lmstudio" => "Free on this PC",
        "anthropic" => "Billed to your Anthropic key",
        "openai" => "Billed to your OpenAI key",
        "xai" => "Billed to your xAI key",
        "gemini" => "Billed to your Gemini key",
        _ => ""
    };

    private void ShowAskClaudePanel()
    {
        if (askClaudePanel is not null) return;
        var panel = new AskClaudePanel(ViewModel);
        panel.Dismissed += (_, _) => { if (ReferenceEquals(askClaudePanel, panel)) askClaudePanel = null; };
        if (!Controls.RightColumn.TryShow(ViewModel, panel)) return;
        askClaudePanel = panel;
        SetViewerVisible(true);
        SizeStage();
    }

    /// <summary>One send: the chosen connector is probed, a first or billed send asks inline in the panel, then the Ask Claude service
    /// sends at extra high effort and checks the reply. The project's AI lease is held throughout.</summary>
    private async Task<AskClaudeAnswer> AskClaudeSendAsync(AskClaudeAsk ask, CancellationToken ct)
    {
        if (App.Services.SharedRoot is not { } root) throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        var selected = App.Services.Get("llm.connector", "");
        var chosen = selected.Length == 0 ? null : ClipCallouts.Chosen(selected, await ProviderCatalog.ReadAsync(ct), item => item.WireId);
        if (chosen is null) throw new InvalidOperationException("Choose an AI in Settings first. Nothing was sent.");
        var connector = App.Services.Connector(chosen.Id);
        var status = await ProviderCatalog.ProbeAsync(chosen, connector, ct);
        if (status is not ConnectorStatus.Ready) throw new InvalidOperationException(ProviderCatalog.Status(status));
        using var lease = ViewModel.LlmRuns.TryAcquire() ?? throw new InvalidOperationException("Another AI request on this project is still running. Try again when it finishes.");
        if (!await ApproveAskClaudeSendAsync(chosen, connector, ask.WordCount, ct)) throw new OperationCanceledException(ct);
        var model = App.Services.Get("llm.model." + chosen.WireId, chosen.DefaultModel);
        var catalog = LlmCatalog.Load(root);
        var service = new AskClaudeService(new LlmRunner(App.Services.Keys, catalog, new Redactor()), catalog, AskClaudePrompt.Load(root));
        return (await service.AskAsync(ask.Instruction, ask.Selection, ask.Project, ask.Detections, ask.Aspect, connector, model, ct)).Answer;
    }

    /// <summary>A first send to a cloud or CLI connector, or one billed to an API key, asks inline in the Ask Claude panel.</summary>
    private async Task<bool> ApproveAskClaudeSendAsync(ProviderEntry chosen, LlmConnector connector, int words, CancellationToken ct)
    {
        var signIn = RewriteSession.SignIn(connector.CliDetection);
        if (chosen.Cli && signIn is null) throw new InvalidOperationException("Check the connector's sign-in method before sending.");
        var firstUse = (chosen.Cloud || chosen.Cli) && !ProviderCatalog.HasConsent(chosen);
        var billing = VoiceLabCostPresentation.KindForLlmSend(chosen.Id, signIn,
            chosen.Cli ? chosen.Id == ConnectorId.ClaudeCode ? "Anthropic" : "OpenAI" : chosen.ShortName);
        var paid = billing.Kind == VoiceLabCostPresentationKind.Confirm;
        if (!firstUse && !paid) return true;
        var disclosure = ConnectorConsent.Text(ConnectorConsentAction.AskClaude, chosen.Id, chosen.Label, words, connector.CliDetection)
            ?? (chosen.Cloud || chosen.Cli ? throw new InvalidOperationException("Check the connector's sign-in method before sending.") : "Runs on this PC. Nothing leaves it.");
        if (askClaudePanel is not { } panel) return false;
        var snapshot = ViewModel.Project;
        bool Current() => ReferenceEquals(snapshot, ViewModel.Project) && !ViewModel.IsLeaving && App.Services.Get("llm.connector", "") == chosen.WireId;
        using var pending = new InlineApproval(new(Guid.NewGuid(), snapshot, "Ask Claude with this connector?", disclosure, billing.Text,
            firstUse ? "Allow and Ask Claude" : "Ask Claude", paid), Current, ct, Environment.TickCount);
        if (!await panel.AskAsync(pending) || !Current()) return false;
        if (firstUse) await App.Services.SetAsync("llm.cloudConsent." + chosen.WireId, true, ct);
        return true;
    }
}
