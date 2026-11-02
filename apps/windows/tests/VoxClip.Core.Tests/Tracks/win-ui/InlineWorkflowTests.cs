#if WIN_UI_TESTS
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class InlineWorkflowTests
{
    [Theory]
    [InlineData((int)InlineActivation.Return, false, 1499, false)]
    [InlineData((int)InlineActivation.Return, false, 1500, true)]
    [InlineData((int)InlineActivation.Return, true, 9000, false)]
    [InlineData((int)InlineActivation.ControlReturn, false, 1000, true)]
    [InlineData((int)InlineActivation.ControlReturn, true, 9000, false)]
    [InlineData((int)InlineActivation.Space, false, 9000, false)]
    [InlineData((int)InlineActivation.Pointer, false, 1000, true)]
    [InlineData((int)InlineActivation.Return, false, 999, false)]
    [InlineData(99, false, 9000, false)]
    public void ApprovalUsesOriginalEventTimeNotDelayedHandlerTime(int activation, bool repeated, int eventTime, bool expected)
        => Assert.Equal(expected, InlineApproval.Allows((InlineActivation)activation, repeated, eventTime, 1000));

    [Fact]
    public void FreshnessSurvivesMessageClockRollover()
    {
        Assert.True(InlineApproval.Allows(InlineActivation.Return, false, int.MinValue + 400, int.MaxValue - 100));
        Assert.False(InlineApproval.Allows(InlineActivation.Return, false, int.MinValue + 398, int.MaxValue - 100));
    }

    [Fact]
    public async Task ApprovalIsSingleUseAndPinsTheDisplayedSnapshot()
    {
        var snapshot = new object();
        using var approval = Approval(snapshot, token: TestContext.Current.CancellationToken);
        Assert.Same(snapshot, approval.Request.Snapshot);
        Assert.True(approval.Approve(InlineActivation.Pointer, false, 1000));
        Assert.False(approval.Approve(InlineActivation.Pointer, false, 2000));
        Assert.True(await approval.Completion);
    }

    [Fact]
    public async Task StaleInputAndOwnerCancellationCannotApproveOrSend()
    {
        var current = true;
        using var cancellation = new CancellationTokenSource();
        using var approval = Approval(new object(), () => current, cancellation.Token);
        current = false;
        Assert.False(approval.Approve(InlineActivation.Pointer, false, 2000));
        Assert.False(await approval.Completion);
        using var cancelled = Approval(new object(), token: cancellation.Token);
        cancellation.Cancel();
        Assert.False(await cancelled.Completion);
        Assert.False(cancelled.Approve(InlineActivation.ControlReturn, false, 2000));
    }

    [Fact]
    public async Task ReturningToAnApprovalRestartsItsFreshnessWindow()
    {
        using var approval = Approval(new object(), token: TestContext.Current.CancellationToken);
        approval.MarkShown(3000);
        Assert.False(approval.Approve(InlineActivation.Return, false, 3100));
        Assert.True(approval.Approve(InlineActivation.Return, false, 3500));
        Assert.True(await approval.Completion);
    }

    [Fact]
    public async Task RetirementWaitsForEveryWorkerAndNeverDeletesOnTimeout()
    {
        using var lifetime = new InlineJobLifetime();
        var first = lifetime.Enter(); var second = lifetime.Enter();
        lifetime.Retire();
        Assert.True(lifetime.Token.IsCancellationRequested);
        Assert.False(await lifetime.DrainAsync(TimeSpan.Zero));
        Assert.Throws<OperationCanceledException>(() => lifetime.Enter());
        first.Dispose(); first.Dispose();
        Assert.False(lifetime.Drained.IsCompleted);
        second.Dispose();
        Assert.True(await lifetime.DrainAsync(TimeSpan.Zero));
    }

    [Theory]
    [InlineData("cut")]
    [InlineData("caption")]
    [InlineData("readonly")]
    [InlineData("leave")]
    public void RequestBaselineRejectsEverySemanticOrLifecycleChange(string change)
    {
        var editor = Editor(); var baseline = new EditorWorkflowSnapshot(editor);
        switch (change)
        {
            case "cut": editor.Apply(new EditOperation.SetWordCuts(["w1"], true)); break;
            case "caption": editor.SetCaptionStyle("off"); break;
            case "readonly": editor.SetMediaUnavailable(true); break;
            default: editor.BeginLeaving(); break;
        }
        Assert.False(baseline.IsCurrent);
        Assert.Throws<OperationCanceledException>(baseline.RequireCurrent);
    }

    [Fact]
    public void TransportAndSelectionDoNotRetargetARequest()
    {
        var editor = Editor(); var baseline = new EditorWorkflowSnapshot(editor);
        editor.SourceTime = 12;
        editor.Select(4); editor.Select(7, true);
        Assert.True(baseline.IsCurrent);
        Assert.Same(baseline.Project, editor.Project);
    }

    [Fact]
    public void UploadEvidenceArrivesBeforeQueuedPresentation()
    {
        var uploaded = false; var rendered = false; Action? queued = null;
        IProgress<bool> progress = new WorkflowProgress<bool>(value => uploaded = value, value => rendered = value, action => queued = action);
        progress.Report(true);
        Assert.True(uploaded); Assert.False(rendered);
        queued!(); Assert.True(rendered);
    }

    [Fact]
    public void LateAcceptedBillingUpdatesTheLedgerBeforeAnyCurrentRowFilterAndDeduplicates()
    {
        var spend = new TranscriptionSpendState(); var job = Guid.NewGuid(); var day = new DateOnly(2026, 11, 2);
        spend.Begin(job, 0.02m); spend.End(job, true);
        Assert.Equal(1, spend.UnconfirmedCount);
        spend.Accepted(job, "accepted-request", day, 0.02m);
        spend.Accepted(job, "accepted-request", day, 0.02m);
        Assert.Equal(0, spend.UnconfirmedCount);
        Assert.Contains("$0.02 estimated", spend.Copy(day));
        Assert.DoesNotContain("$0.04", spend.Copy(day));
        Assert.False(spend.HasPending);
    }

    [Fact]
    public void CacheOrPreUploadCancellationDoesNotInventACharge()
    {
        var spend = new TranscriptionSpendState(); var job = Guid.NewGuid();
        spend.Begin(job, 0.02m); spend.End(job, false);
        Assert.Equal(0, spend.UnconfirmedCount);
        Assert.False(spend.HasPending);
    }

    [Fact]
    public void SuccessfulNoncachedCompletionCountsOnceAndCacheReuseCountsNothing()
    {
        var spend = new TranscriptionSpendState(); var day = new DateOnly(2026, 11, 2); var first = Guid.NewGuid(); var cached = Guid.NewGuid();
        spend.Begin(first, 0.02m); spend.Completed(first, day, 0.02m, false); spend.Completed(first, day, 0.02m, false);
        spend.Begin(cached, 0.02m); spend.Completed(cached, day, 0.02m, true); spend.End(cached, true);
        Assert.Contains("$0.02 estimated", spend.Copy(day));
        Assert.Equal(0, spend.UnconfirmedCount); Assert.False(spend.HasPending);
    }

    [Fact]
    public async Task LocalTextRewriteNeedsNoSpeakerOrAudioEnvelopeAndAcceptsInOneUndo()
    {
        var editor = Editor(); var before = ProjectSerialization.Serialize(editor.Project); var connector = new LocalConnector();
        using var session = new RewriteSession(editor, 0, 2, null, new(connector, "chosen", "Local", "local", ""));
        await session.SetInstructionAsync("Remove the middle word");
        var action = Assert.IsType<VoiceLabPreparedAction>(session.Prepared);
        Assert.Equal(VoiceLabCostPresentationKind.Inline, session.Estimate!.Kind);
        session.MarkEstimateShown(action);
        Assert.True(await session.ProposeAsync(action, true));
        Assert.Equal(1, connector.Sends);
        Assert.Equal("Apply Cuts", session.LocalAction);
        Assert.True(session.ApplyLocalChanges());
        Assert.Contains("w1", editor.State!.CutWordIds);
        editor.Undo();
        Assert.Equal(before, ProjectSerialization.Serialize(editor.Project));
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public async Task PrivacyConsentDoesNotAuthorizeAFutureBilledRequest()
    {
        var connector = new LocalConnector { Id = ConnectorId.OpenAI };
        using var session = new RewriteSession(Editor(), 0, 2, null, new(connector, "chosen", "OpenAI", "apiKey", ""),
            consent: _ => Task.FromResult(true));
        await session.SetInstructionAsync("Remove the middle word");
        var action = Assert.IsType<VoiceLabPreparedAction>(session.Prepared); session.MarkEstimateShown(action);
        Assert.Equal(VoiceLabCostPresentationKind.Confirm, session.Estimate!.Kind);
        Assert.False(await session.ProposeAsync(action, false));
        Assert.Equal(0, connector.Sends);
    }

    [Fact]
    public async Task UnknownCliBillingCannotPrepareOrSendEvenWithStoredPrivacyConsent()
    {
        var connector = new LocalConnector { Id = ConnectorId.Codex };
        using var session = new RewriteSession(Editor(), 0, 2, null, new(connector, "chosen", "Codex", "cli", "ChatGPT plan"),
            consent: _ => Task.FromResult(true));
        await session.SetInstructionAsync("Remove the middle word");
        Assert.Null(session.Prepared); Assert.False(session.CanPropose);
        Assert.Contains("sign-in method", session.Problem); Assert.Equal(0, connector.Sends);
    }

    [Fact]
    public async Task DirectorIdentityAndLocalReviewSurviveVoiceBeingTurnedOff()
    {
        using var session = new RewriteSession(Editor(), 0, 2, null, null);
        using var task = new DirectorTask(session); var identity = task.Id;
        task.SetApproval(true); Assert.Equal(DirectorTaskPhase.AwaitingApproval, task.Snapshot.Phase);
        task.SetApproval(false); session.Edit("word0 word2"); session.SettingsChanged(false);
        Assert.True(session.IsOpen); Assert.Equal(identity, task.Snapshot.Id);
        Assert.Equal(DirectorTaskPhase.Review, task.Snapshot.Phase); Assert.True(task.Snapshot.CanApply);
        session.Dispose(); Assert.Equal(DirectorTaskPhase.Closed, task.Snapshot.Phase);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task SuspendedCandidateStartupIsStoppedBeforeSourceCanPlay()
    {
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var candidatePlaying = false; var sourcePlaying = false;
        await using var transport = new PreviewTransportCoordinator(_ => { sourcePlaying = false; return Task.CompletedTask; },
            _ => { candidatePlaying = false; return Task.CompletedTask; });
        var candidate = transport.CandidateAsync(async _ => { started.SetResult(); await finish.Task; candidatePlaying = true; }, TestContext.Current.CancellationToken);
        await started.Task;
        var source = transport.SourceAsync(_ => { Assert.False(candidatePlaying); sourcePlaying = true; return Task.CompletedTask; }, TestContext.Current.CancellationToken);
        Assert.False(sourcePlaying); finish.SetResult(); await candidate; await source;
        Assert.True(sourcePlaying); Assert.False(candidatePlaying);
    }

    [Fact]
    public void OwnedEditorWorkflowsHaveNoPopupOrEnabledNativeVoiceBypass()
    {
        foreach (var name in new[] { "ExportDialog.cs", "TranscriptionDialog.cs", "RewritePanel.cs" })
        {
            var text = Source(name);
            Assert.DoesNotContain(": ContentDialog", text);
            Assert.DoesNotContain("new ContentDialog", text);
            Assert.DoesNotContain("Ui.ConfirmAsync", text);
        }
        Assert.DoesNotContain("ShowCloudConsent", Source("TranscriptionDialog.cs"));
        Assert.Contains("if (send.IsEnabled) approval.Approve", Source("InlineConfirmation.cs"));
        Assert.Contains("saveKey = null; textFocus.Dispose()", Source("InlineConfirmation.cs"));
        Assert.Contains("if (textFocus.OwnsComposition) return", Source("InlineConfirmation.cs"));
        Assert.Contains("VoiceLabCopy.SpeakerUnavailable", Source("DirectorVoiceSteps.cs"));
        Assert.Contains("VoiceSpeakerCheck.WindowsNativeParityVerified && session.CanGenerateAll", Source("RewritePanel.cs"));
        var host = Source("RightColumn.cs");
        Assert.True(host.IndexOf("captionsTab.Focus", StringComparison.Ordinal) < host.IndexOf("job = null; surface.Child", StringComparison.Ordinal));
    }

    private static InlineApproval Approval(object snapshot, Func<bool>? current = null, CancellationToken token = default) =>
        new(new(Guid.NewGuid(), snapshot, "Send?", "Transcript only", "Price unknown", "Send", true), current ?? (() => true), token, 1000);
    private static string Source(string name) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps", "windows", "src", "VoxClip.App", "Controls", name));
    private static EditorViewModel Editor()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "interview-take.voxclip")));
        var words = Enumerable.Range(0, 10).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word,
            index + 1, index + 1.4, null, null, 1, null, TimingSource.Native)).ToArray();
        return new(project with { Transcript = project.Transcript! with { Words = words },
            Captions = project.Captions with { StyleId = "bold" },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } });
    }
    private sealed class LocalConnector : ILlmConnector
    {
        public ConnectorId Id { get; init; } = ConnectorId.Ollama;
        internal int Sends { get; private set; }
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken token) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken token) =>
            Task.FromResult<IReadOnlyList<LlmModel>>([new("chosen", "Chosen", null, 32768, ModelSource.Discovered)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken token) => Task.FromResult<int?>(32768);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken token)
        {
            Sends++;
            return Task.FromResult(new RawCompletion(null, new JsonObject { ["rewrite"] = "word0 word2" }, model, new StopKind.Complete(), null, "fixture-only"));
        }
    }
}
#endif
