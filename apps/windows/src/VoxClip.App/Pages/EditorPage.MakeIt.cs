using Microsoft.UI.Xaml;
using VoxClip.App.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.Pages;

/// <summary>✦ Make it postable's live services and its panel (design §6.7): the planner through the chosen AI (a first or billed send
/// asks inline in the panel, as Find clips does), the voice through Rewrite's own session (<see cref="MakeItRewriteDriver"/>), and a
/// one-click export in the clip style's shapes.</summary>
public sealed partial class EditorPage
{
    private MakeItPanel? makeItPanel;
    /// <summary>A voiced rewrite's session with paid takes the driver could not use: Change on its row shows it in Rewrite.</summary>
    private readonly Dictionary<(int First, int Last), RewriteSession> makeItSessions = [];

    private void InitializeMakeIt()
    {
        var root = App.Services.SharedRoot;
        RewriteToneCatalog? tones = null;
        VoiceLabPriceCatalog? prices = null;
        if (root is not null)
        {
            try { tones = RewriteToneCatalog.Load(root); } catch (Exception exception) when (exception is IOException or VoxClipException) { }
            try { prices = VoiceLabPrices.Load(root); } catch (VoxClipException) { }
        }
        ViewModel.MakeIt.Services = new MakeItServices(MakeItPlanAsync, MakeItVoiceAsync, MakeItVoiceAvailable, MakeItExportAsync, ShareHelpers.Copy)
        {
            SharedRoot = root, Prices = prices, Tones = tones,
            SavedTones = MyRewriteTones.Decode(App.Services.Settings.Values.TryGetValue(RewriteToneCatalog.SettingsKey, out var saved) ? saved : null)
        };
        ViewModel.CaptionStyleNames = id => captions?.Styles.FirstOrDefault(style => style.Id == id)?.Name;
        ViewModel.MakeItShown += (_, _) => ShowMakeItPanel();
        ViewModel.MakeItPlayRequested += (_, time) => _ = RunAsync(() => PlayMakeItAsync(time), "Preview");
        ViewModel.MakeItChangeRequested += (_, change) => MakeItChange(change.Run, change.Row);
        ViewModel.MakeItChanged += (_, _) => DispatcherQueue.TryEnqueue(UpdateMakeItCommand);
    }

    /// <summary>The clip bar's verb: "✦ Make it postable · up to $x" on the open clip, or "✦ Review" once its run has finished.</summary>
    private void UpdateMakeItCommand()
    {
        var active = ViewModel.State?.ActiveClipId;
        var finished = active is not null && ViewModel.MakeIt.Run(active) is { Running: false };
        MakeItCommand.Label = finished ? "✦ Review" : active is null ? "✦ Make it postable" : ViewModel.MakeItTitle(active);
        MakeItCommand.IsEnabled = ShellReady && active is not null && (finished || ViewModel.CanMakeItPostable(active));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(MakeItCommand, MakeItCommand.Label);
    }

    /// <summary>The clip bar's verb: the review of a finished run, else a new run on the open clip.</summary>
    private void OpenMakeItFromClipBar()
    {
        if (ViewModel.State?.ActiveClipId is not { } active) return;
        if (ViewModel.MakeIt.Run(active) is { Running: false }) { ViewModel.MakeIt.ShownClipId = active; ShowMakeItPanel(); return; }
        MakeItPostable(active);
    }

    /// <summary>The row ✦, its menu, the clip bar and the palette: starts the run on <paramref name="clipId"/>.</summary>
    internal bool MakeItPostable(string clipId)
    {
        if (!ShellReady || !ViewModel.MakeItPostable(clipId)) return false;
        Tabs.PinActive();
        return true;
    }

    /// <summary>"✦ Make top 3 postable" under Suggested.</summary>
    internal bool MakeTopPostable() => ShellReady && ViewModel.MakeTopPostable();

    private void ShowMakeItPanel()
    {
        if (makeItPanel is not null) return;
        var panel = new MakeItPanel(ViewModel);
        panel.Dismissed += (_, _) => { if (ReferenceEquals(makeItPanel, panel)) makeItPanel = null; };
        if (!Controls.RightColumn.TryShow(ViewModel, panel)) return;
        makeItPanel = panel;
        SetViewerVisible(true);
        SizeStage();
    }

    private async Task PlayMakeItAsync(double time)
    {
        if (preview is null || ViewModel.IsReadOnly) return;
        ViewModel.SourceTime = time;
        await SourceTransportAsync(async token =>
        {
            await SeekSourceCoreAsync(time, token);
            if (preview is not null && !ViewModel.IsReadOnly) await preview.PlayAsync(token);
        });
    }

    /// <summary>Change on a row the page owns: the captions panel, Rename, or Rewrite on the phrase's words.</summary>
    private void MakeItChange(MakeItRun run, MakeItRow row)
    {
        switch (row.Change)
        {
            case ViewModels.MakeItChange.Captions: makeItPanel?.RequestClose(); ShowCaptions(); break;
            case ViewModels.MakeItChange.Rename: _ = owner.RenameClipFromPageAsync(run.ClipId); break;
            case ViewModels.MakeItChange.Phrase when row.Words is { } words:
                makeItPanel?.RequestClose();
                if (makeItSessions.Remove(words, out var kept) && kept.IsOpen) { ShowRewriteSession(kept, null); break; }
                ViewModel.Select(words.First);
                ViewModel.Select(words.Last, extend: true);
                _ = RunAsync(() => OpenShellJobAsync(ShellJob.Rewrite), "Rewrite");
                break;
        }
    }

    // MARK: Live services

    private bool MakeItVoiceAvailable() => !demo && App.Services.VoiceLabEnabled && VoiceSpeakerCheck.WindowsNativeParityVerified;

    private async Task<ClipAutopilotSeries> MakeItPlanAsync(ClipAutopilotRequest request, IProgress<ClipAutopilotProgress> progress, CancellationToken ct)
    {
        if (App.Services.SharedRoot is not { } root) throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        var selected = App.Services.Get("llm.connector", "");
        var chosen = selected.Length == 0 ? null : ClipCallouts.Chosen(selected, await ProviderCatalog.ReadAsync(ct), item => item.WireId);
        if (chosen is null) throw new InvalidOperationException("Choose an AI in Settings first. Nothing was sent.");
        var connector = App.Services.Connector(chosen.Id);
        var status = await ProviderCatalog.ProbeAsync(chosen, connector, ct);
        if (status is not ConnectorStatus.Ready) throw new InvalidOperationException(ProviderCatalog.Status(status));
        using var lease = ViewModel.LlmRuns.TryAcquire() ?? throw new InvalidOperationException("Another AI request on this project is still running. Try again when it finishes.");
        if (!await ApproveMakeItSendAsync(chosen, connector, request, ct)) throw new OperationCanceledException(ct);
        var model = App.Services.Get("llm.model." + chosen.WireId, chosen.DefaultModel);
        var catalog = LlmCatalog.Load(root);
        var service = new ClipAutopilotService(new LlmRunner(App.Services.Keys, catalog, new Redactor()), catalog, root);
        // Claude Code runs one process per connector: two more lanes plan a series' clips three at once.
        IReadOnlyList<ILlmConnector> lanes = [];
        if (chosen.Id == ConnectorId.ClaudeCode && request.Mode is ClipAutopilotMode.Clips)
        {
            var more = new[] { App.Services.Connector(chosen.Id), App.Services.Connector(chosen.Id) };
            if (more.All(lane => !ReferenceEquals(lane, connector)) && !ReferenceEquals(more[0], more[1])) lanes = more;
        }
        return (await service.PlanAsync(request, connector, model, lanes, progress.Report, ct)).Series;
    }

    /// <summary>A first send to a cloud or CLI connector, or one billed to an API key, asks inline in the Make it postable panel.</summary>
    private async Task<bool> ApproveMakeItSendAsync(ProviderEntry chosen, LlmConnector connector, ClipAutopilotRequest request, CancellationToken ct)
    {
        var signIn = RewriteSession.SignIn(connector.CliDetection);
        if (chosen.Cli && signIn is null) throw new InvalidOperationException("Check the connector's sign-in method before sending.");
        var firstUse = (chosen.Cloud || chosen.Cli) && !ProviderCatalog.HasConsent(chosen);
        var billing = VoiceLabCostPresentation.KindForLlmSend(chosen.Id, signIn,
            chosen.Cli ? chosen.Id == ConnectorId.ClaudeCode ? "Anthropic" : "OpenAI" : chosen.ShortName);
        var paid = billing.Kind == VoiceLabCostPresentationKind.Confirm;
        if (!firstUse && !paid) return true;
        var words = request.Transcript.Words.Count(word => word.Kind == WordKind.Word);
        var disclosure = ConnectorConsent.Text(ConnectorConsentAction.FindClips, chosen.Id, chosen.Label, words, connector.CliDetection)
            ?? (chosen.Cloud || chosen.Cli ? throw new InvalidOperationException("Check the connector's sign-in method before sending.") : "Runs on this PC. Nothing leaves it.");
        if (makeItPanel is not { } panel) return false;
        var snapshot = ViewModel.Project;
        bool Current() => ReferenceEquals(snapshot.Edits, ViewModel.Project.Edits) && !ViewModel.IsLeaving && App.Services.Get("llm.connector", "") == chosen.WireId;
        using var pending = new InlineApproval(new(Guid.NewGuid(), snapshot, "Make it postable with this connector?", disclosure, billing.Text,
            firstUse ? "Allow and Send" : "Send", paid), Current, ct, Environment.TickCount);
        if (!await panel.AskAsync(pending) || !Current()) return false;
        if (firstUse) await App.Services.SetAsync("llm.cloudConsent." + chosen.WireId, true, ct);
        return true;
    }

    private async Task<MakeItRewriteOutcome> MakeItVoiceAsync(MakeItRewriteRequest request, CancellationToken ct)
    {
        if (!MakeItVoiceAvailable())
            return new(new MakeItRewriteResult.Unavailable("Turn on Voice Lab and make your voice to voice rewrites. Nothing was sent."));
        if (!App.Services.Get("voiceLab.providerConsent.elevenlabs", false))
            return new(new MakeItRewriteResult.NeedsYou("Allow ElevenLabs in Rewrite to voice this fix. Nothing was sent."));
        if (rewrite is { IsOpen: true, HasPaidTakes: true })
            return new(new MakeItRewriteResult.NeedsYou("Finish the open Rewrite first; its paid takes are kept."));
        var driver = new MakeItRewriteDriver(ViewModel, request, OpenMakeItRewriteAsync, ReadMakeItVoiceCapAsync, session => makeItSessions[(request.First, request.Last)] = session);
        return await driver.RunAsync(ct);
    }

    /// <summary>Rewrite's own session on the planned words, with the page's take windows and no AI connector: the planner's words are
    /// the reply, so nothing is sent to the AI again.</summary>
    private async Task<RewriteSession?> OpenMakeItRewriteAsync(MakeItRewriteRequest request)
    {
        if (rightContent is null || ViewModel.IsReadOnly || ViewModel.IsLeaving || disposed) return null;
        RetireRewrite();
        var project = ViewModel.Project;
        var envelope = !demo && media is not null ? await App.Services.Waveform.GetEnvelopeAsync(media, project.Media.Source.ContentKey, lifetime.Token) : null;
        if (disposed || ViewModel.IsLeaving) return null;
        var session = new RewriteSession(ViewModel, request.First, request.Last, envelope, null, prices: VoiceLabPrices.Load());
        ConfigureRewriteGeneration(session);
        return session;
    }

    private static async Task<VoiceLabMonthlyCap?> ReadMakeItVoiceCapAsync(CancellationToken token)
    {
        await WorkflowSpendCache.RefreshAsync(App.Services.Data);
        token.ThrowIfCancellationRequested();
        var limit = App.Services.Settings.GetVoiceLabMonthlyCap("elevenlabs");
        if (limit is null) return null;
        if (WorkflowSpendCache.Monthly is not { } total) throw new RewriteGenerationException("Monthly spend is unavailable. Nothing has been sent.");
        return new(limit.Value, total.Usd);
    }

    /// <summary>Export in the clip style's shapes, one file each, with no dialog; the view model writes the post text beside each.</summary>
    private async Task<IReadOnlyList<string>> MakeItExportAsync(string clipId, IReadOnlyList<ExportAspect> shapes, CancellationToken ct)
    {
        if (demo || MediaPath is null || media is null) throw new InvalidOperationException("Find the original video before exporting. Your edits are saved.");
        var folder = ViewModel.Project.Export.Folder ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "VoxClip");
        var pattern = App.Services.Get("export.fileNamePattern", "{project}-{clip}-{aspect}");
        List<string> files = [];
        ExportTarget? current = null;
        ViewModel.Busy = true;
        App.Services.BusyOperations++;
        try
        {
            Directory.CreateDirectory(folder);
            var source = ViewModel.Project.Media.Source;
            if (await App.Services.Projects.ComputeContentKeyAsync(source.AbsolutePath, null, ct) != source.ContentKey)
                throw new InvalidOperationException("This video changed. Find the original video before exporting. Your edits are saved.");
            foreach (var shape in shapes)
            {
                var route = new ExportDialogRouting(ViewModel, clipId, 0, EditorLayout.Frames.ToList().IndexOf(shape), (int)ViewModel.Project.Export.Quality,
                    ViewModel.Project.Export.Srt, folder, pattern);
                var target = route.Targets.Single();
                current = target;
                ViewModel.SetExportActivity(target, ClipExportState.Exporting, 0);
                var job = await route.JobAsync(target, (project, state, token) => SnapshotAsync(token, state, project), ct);
                var result = await App.Services.Exporter.ExportAsync(job, new Progress<ExportProgress>(value => ViewModel.SetExportActivity(target, ClipExportState.Exporting, value.Fraction)), ct);
                await App.Services.ExportLedger.RecordAsync(route.Project, target, result.Output, CancellationToken.None,
                    job.Snapshot.VoiceLab?.Prepared.Disclosure.Position ?? VoiceLabSettingsState.LabelPosition(App.Services.Settings.GetString("voiceLab.labelPosition")));
                ViewModel.SetExportRecords(App.Services.ExportLedger.Records);
                ViewModel.SetExportActivity(target, ClipExportState.None);
                current = null;
                files.Add(result.Output);
            }
            return files;
        }
        catch
        {
            if (current is not null) ViewModel.SetExportActivity(current, ClipExportState.Failed);
            throw;
        }
        finally
        {
            ViewModel.Busy = false;
            App.Services.BusyOperations--;
        }
    }
}
