#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class VoiceCreationFlowTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private static Task Dispatch(Action action) { action(); return Task.CompletedTask; }
    private static string AppFile(string file) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App", file));
    private static VoiceConsentRecord Record() => JsonSerializer.Deserialize<VoiceConsentRecord>(File.ReadAllBytes(Path.Combine(SharedResources.ResolveRoot(), "fixtures/voice-lab/consent-record.json")), new JsonSerializerOptions(JsonSerializerDefaults.Web))!;

    [Fact]
    public async Task CanCreateRequiresVerifiedTrainingAndEveryGate()
    {
        await using var setup = new Setup();
        Assert.False(setup.Session.CanCreate); await setup.VerifyAsync();
        Assert.True(setup.Session.CanTrain); Assert.False(setup.Session.CanCreate);
        await setup.TrainAsync(); Assert.True(setup.Session.CanCreate);
        Assert.Equal(90, setup.Capture.Maximum); Assert.Equal("Training recording is ready.", setup.Session.Message);
        Assert.Contains(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "voice-lab/scripts-en.txt")), setup.Session.TrainingScript);
        setup.Backend.Enabled = false; Assert.False(setup.Session.CanCreate); setup.Backend.Enabled = true;
        setup.Backend.SpeakerAvailable = false; Assert.False(setup.Session.CanCreate); setup.Backend.SpeakerAvailable = true;
        setup.Backend.PlanMessage = "No slots"; Assert.False(setup.Session.CanCreate); setup.Backend.PlanMessage = null;
        setup.Backend.CreationPending = true; Assert.False(setup.Session.CanCreate); setup.Backend.CreationPending = false;
        await setup.Session.PrepareCreationAsync(); Assert.False(setup.Session.CanCreate);
        await setup.Session.ApproveCreationAsync(false); Assert.True(setup.Session.CanCreate);
        Assert.Equal(0, setup.Backend.Creates);
    }

    [Theory]
    [InlineData(59, false)]
    [InlineData(60, true)]
    [InlineData(90, true)]
    [InlineData(95, true)]
    public async Task TrainingUsesNinetySecondCaptureAndRejectsShortTakes(int seconds, bool valid)
    {
        await using var setup = new Setup(); await setup.VerifyAsync();
        await setup.TrainAsync(seconds);
        Assert.Equal(90, setup.Capture.Maximum); Assert.Equal(valid, setup.Session.TrainingReady);
        Assert.Equal(valid, setup.Session.CanCreate); Assert.True(setup.Capture.Discarded);
        Assert.Equal(Math.Min(seconds, 90), setup.Backend.TrainingSeconds);
        if (!valid) Assert.Equal("Record 5–30 seconds for consent, or 60–90 seconds for the training read-aloud, with clear speech.", setup.Session.Message);
    }

    [Theory]
    [InlineData(VoiceConsentError.SpeakerMismatch, "Some of these recordings don't sound like the voice in your consent statement.")]
    [InlineData(VoiceConsentError.SpeakerUnavailable, "The speaker check isn't available yet. Your voice can't be created until it is.")]
    public async Task PrepareRefusalNeverCreates(VoiceConsentError failure, string copy)
    {
        await using var setup = new Setup(); await setup.ReadyAsync(); setup.Backend.PrepareFailure = failure;
        await setup.Session.PrepareCreationAsync(); await setup.Session.ApproveCreationAsync(true);
        Assert.Equal(copy, setup.Session.Message); Assert.Null(setup.Session.CreationConfirmation); Assert.Equal(0, setup.Backend.Creates);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CreationHasPrimaryDefaultAndCancelSendsNothing(bool verificationRequired)
    {
        await using var setup = new Setup(); await setup.ReadyAsync();
        await setup.Session.PrepareCreationAsync();
        var dialog = VoiceCreationDialog.Create(setup.Session.CreationConfirmation!);
        Assert.True(dialog.PrimaryDefault); Assert.Equal("Cancel", dialog.Close); Assert.Equal("Continue", dialog.Primary);
        Assert.EndsWith("This action is free.", dialog.Message); Assert.DoesNotContain("$0", dialog.Message);
        await setup.Session.ApproveCreationAsync(false); Assert.Equal(0, setup.Backend.Creates); Assert.Equal(0, setup.Backend.PlanChecks);
        setup.Backend.VerificationRequired = verificationRequired;
        await setup.Session.PrepareCreationAsync(); await setup.Session.ApproveCreationAsync(true);
        Assert.Equal(1, setup.Backend.Creates); Assert.Equal(1, setup.Backend.PlanChecks);
        Assert.Equal(verificationRequired ? CreateVoiceSession.VerificationRequiredCopy : CreateVoiceSession.ReadyCopy, setup.Session.Message);
        Assert.True(setup.Session.ReturnToPane); Assert.Equal(setup.Backend.LastRecord!.RecordId, setup.Session.FocusRecordId);
        Assert.False(setup.Session.IsBusyForRestart); Assert.False(setup.Session.CanCreate);
        await setup.Session.AbandonAsync(); Assert.Equal(0, setup.Backend.Abandons);
    }

    [Fact]
    public void CreationConfirmationUsesKindWithoutReformattingOrInventingAnAmount()
    {
        Assert.EndsWith("≈ $0.36", VoiceCreationDialog.Create(new(new(VoiceLabCostPresentationKind.Inline, "≈ $0.36"), new object())).Message);
        const string copy = "VoxClip can't tell what this costs. Check ElevenLabs's pricing.";
        Assert.EndsWith(copy, VoiceCreationDialog.Create(new(new(VoiceLabCostPresentationKind.Confirm, copy), new object())).Message);
    }

    [Fact]
    public async Task ExpiredQuoteExplainsNothingWasSentAndAllowsFreshPreparation()
    {
        await using var setup = new Setup(); await setup.ReadyAsync(); await setup.Session.PrepareCreationAsync();
        setup.Backend.Fresh = false; await setup.Session.ApproveCreationAsync(true);
        Assert.Equal(CreateVoiceSession.ExpiredCopy, setup.Session.Message); Assert.Equal(0, setup.Backend.Creates); Assert.Equal(0, setup.Backend.PlanChecks);
        Assert.True(setup.Session.CanCreate); setup.Backend.Fresh = true;
        await setup.Session.PrepareCreationAsync(); await setup.Session.ApproveCreationAsync(true); Assert.Equal(1, setup.Backend.Creates);
    }

    [Fact]
    public async Task SaveFailureCanWithdrawWithoutServicesOrASecondCreate()
    {
        await using var setup = new Setup(); await setup.ReadyAsync(); setup.Backend.SaveFailure = true;
        await setup.Session.PrepareCreationAsync(); await setup.Session.ApproveCreationAsync(true);
        Assert.NotNull(setup.Session.UnsavedRecord); Assert.Contains("Do not create the voice again.", setup.Session.Message);
        Assert.False(setup.Session.CanCreate); Assert.True(setup.Session.IsBusyForRestart);
        setup.Backend.ServicesAvailable = false;
        await setup.Session.RemoveUnsavedVoiceAsync();
        Assert.Null(setup.Session.UnsavedRecord); Assert.True(setup.Session.ReturnToPane);
        Assert.Equal(1, setup.Backend.Abandons); Assert.Equal(1, setup.Backend.Creates);
    }

    [Fact]
    public async Task RetrySavingKeepsFailureAndNeverRepeatsCreation()
    {
        await using var setup = new Setup(); await setup.ReadyAsync(); setup.Backend.SaveFailure = true;
        await setup.Session.PrepareCreationAsync(); await setup.Session.ApproveCreationAsync(true);
        setup.Backend.RetryFailure = true; await setup.Session.RetrySavingRecordAsync();
        Assert.NotNull(setup.Session.UnsavedRecord); Assert.StartsWith("The consent record still could not be saved.", setup.Session.Message);
        setup.Backend.RetryFailure = false; await setup.Session.RetrySavingRecordAsync();
        Assert.Null(setup.Session.UnsavedRecord); Assert.True(setup.Session.ReturnToPane);
        Assert.Equal("Consent record saved. No create request was repeated.", setup.Session.Message);
        Assert.Equal(1, setup.Backend.Creates); Assert.Equal(2, setup.Backend.Saves);
    }

    [Fact]
    public async Task UncertainCreationReturnsToRecoveryAndCannotCreateTwice()
    {
        await using var setup = new Setup(); await setup.ReadyAsync(); setup.Backend.Uncertain = true;
        await setup.Session.PrepareCreationAsync(); await setup.Session.ApproveCreationAsync(true);
        Assert.Equal(CreateVoiceSession.UncertainCopy, setup.Session.Message); Assert.True(setup.Session.ReturnToPane);
        Assert.True(setup.Backend.CreationPending); Assert.NotNull(setup.Session.FocusRecordId);
        await setup.Session.PrepareCreationAsync(); await setup.Session.ApproveCreationAsync(true);
        Assert.Equal(1, setup.Backend.Creates); Assert.Equal(0, setup.Backend.Abandons);
    }

    [Fact]
    public void NativeR5ProbeCoversTrainingCapCancelSaveRecoveryAndZeroHttp()
    {
        var root = Path.GetDirectoryName(SharedResources.ResolveRoot())!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/native-voicelab-walk.ps1"));
        foreach (var text in new[] { "Training-Creation-Step", "training-cap", "creation-cancel", "creation-savefail", "creation-uncertain", "creation-expired", "TrainingSeconds -lt 60", "TrainingSeconds -ge 90", "training.seconds-90", "FocusedElement.Current.AutomationId", "voice-create-submit", "voice-card-", "receipt.createCalls", "receipt.planChecks", "receipt.httpCalls -ne 0", "again.createCalls -ne 1" }) Assert.Contains(text, source);
        Assert.All(File.ReadAllBytes(Path.Combine(root, "apps/windows/tests/VoxClip.Core.Tests/Tracks/win-ui/native-voicelab-walk.ps1")), value => Assert.True(value < 128));
    }

    [Theory]
    [InlineData(59, false)]
    [InlineData(60, true)]
    [InlineData(90, true)]
    [InlineData(120, true)]
    [InlineData(121, false)]
    public async Task ProductionTrainingBackendUsesReadAloudValidationWithoutServices(int seconds, bool valid)
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-r5-training-" + Guid.NewGuid().ToString("N"));
        var data = new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "models"), Path.Combine(root, "cache"), Path.Combine(root, "autosave"), Path.Combine(root, "secrets"), Path.Combine(root, "logs"));
        using var backend = new VoiceStatementBackend(data, new NoKeys(), new QuietLog(), ElevenLabsRegion.Default, () => true, () => null, _ => Task.CompletedTask, speakerAvailable: () => true);
        await using var capture = new FlowCapture { Seconds = seconds };
        var take = capture.Stop();
        if (valid) await backend.SaveTrainingAsync(take, Token);
        else await Assert.ThrowsAsync<VoiceLabException>(() => backend.SaveTrainingAsync(take, Token));
        capture.Discard(); Assert.All(take.Mono, value => Assert.Equal(0, value));
        Assert.False(Directory.Exists(root));
    }

    [Fact]
    public void ProductionUsesOneClientAndCoreJournalWhilePageExposesNativeActions()
    {
        var source = AppFile("Services/VoiceStatementBackend.cs");
        Assert.Contains("VoiceTrainingAudio.ReadAloud(samples)", source);
        Assert.Contains("recorder.StartAsync(90, ct)", source);
        Assert.True(source.IndexOf("client.DiscoverSubscriptionAsync", StringComparison.Ordinal) < source.IndexOf("enrollment.CreateAsync", StringComparison.Ordinal));
        Assert.Contains("enrollment.PrepareAsync", source); Assert.Contains("client.QuotesAreFresh", source);
        Assert.Contains("VoiceSpeakerCheck.Unavailable.Available", source);
        var page = AppFile("Controls/CreateVoicePage.cs");
        foreach (var text in new[] { "Record training read-aloud", "Record training again", "Create voice…", "AccentButtonStyle", "SetName(working, \"Working\")", "create.IsEnabled = session.CanCreate", "create.Focus(FocusState.Programmatic)", "Remove This Voice", "Retry saving consent record", "StageUnsaved", "CompleteCreateVoice" }) Assert.Contains(text, page);
        Assert.Contains("voice-card-", AppFile("Controls/VoiceLabSettingsPane.cs"));
        Assert.Contains("new(this, lifetime.Token, recordId)", AppFile("SettingsWindow.xaml.cs"));
    }

#if DEBUG
    [Theory]
    [InlineData("ready")]
    [InlineData("verification")]
    [InlineData("save-failure")]
    [InlineData("uncertain")]
    [InlineData("expired")]
    [InlineData("speaker-mismatch")]
    [InlineData("speaker-unavailable")]
    public async Task DebugCreationFixturesExerciseRealTrainingAndNeverReadKeys(string scenario)
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-r5-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var fixtures = Path.Combine(root, "fixtures"); Directory.CreateDirectory(fixtures);
            foreach (var file in new[] { "consent-record.json", "consent-record-creator.json", "consent-scribe.json" })
                File.Copy(Path.Combine(SharedResources.ResolveRoot(), "fixtures/voice-lab", file), Path.Combine(fixtures, file));
            File.WriteAllText(Path.Combine(fixtures, "creation-scenario.json"), JsonSerializer.Serialize(new { scenario }));
            var data = new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "models"), Path.Combine(root, "cache"), Path.Combine(root, "autosave"), Path.Combine(root, "secrets"), Path.Combine(root, "logs"));
            var clock = new VoiceSessionClock(); var capture = new FlowCapture();
            var scribe = new DebugConsentScribe(fixtures);
            var inner = new VoiceStatementBackend(data, new NoKeys(), new QuietLog(), ElevenLabsRegion.Default, () => true, () => null, _ => Task.CompletedTask,
                clock, () => DebugAvailableSpeakerCheck.Available, scribe.TranscribeAsync);
            var client = DebugVoiceLabBackend.FromFixtures(fixtures, () => true, _ => Task.CompletedTask);
            await client.ReadAsync(Token);
            var backend = new DebugVoiceCreationBackend(inner, client, data, fixtures, clock);
            await using var session = new CreateVoiceSession(backend, capture, Dispatch, clock);
            var recording = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            session.Changed += (_, _) => { if (session.Recording) recording.TrySetResult(); };
            session.SetInputs("Example", "en", true, true, true);
            var take = session.RecordAsync(); clock.Advance(TimeSpan.FromMilliseconds(600));
            await recording.Task.WaitAsync(Token); session.StopRecording(); await take;
            Assert.True(session.RequestVerification()); await session.ApproveVerificationAsync(true); Assert.True(session.Verified);
            recording = new(TaskCreationOptions.RunContinuationsAsynchronously); capture.Seconds = 60;
            take = session.RecordTrainingAsync(); await recording.Task.WaitAsync(Token); session.StopRecording(); await take;
            Assert.True(session.TrainingReady);
            await session.PrepareCreationAsync();
            await session.ApproveCreationAsync(true);
            if (scenario.StartsWith("speaker-", StringComparison.Ordinal))
            { Assert.Null(session.CreationConfirmation); Assert.Contains(scenario == "speaker-mismatch" ? "don't sound like" : "isn't available", session.Message); }
            else if (scenario == "expired") Assert.Equal(CreateVoiceSession.ExpiredCopy, session.Message);
            else if (scenario == "save-failure") { Assert.NotNull(session.UnsavedRecord); await session.RetrySavingRecordAsync(); Assert.True(session.ReturnToPane); }
            else { Assert.True(session.ReturnToPane); Assert.Equal(scenario == "uncertain" ? CreateVoiceSession.UncertainCopy : scenario == "verification" ? CreateVoiceSession.VerificationRequiredCopy : CreateVoiceSession.ReadyCopy, session.Message); }
            using var receipt = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(data.Cache, "creation-result.json")));
            Assert.Equal(0, receipt.RootElement.GetProperty("httpCalls").GetInt32());
            Assert.Equal(scenario is "expired" or "speaker-mismatch" or "speaker-unavailable" ? 0 : 1, receipt.RootElement.GetProperty("createCalls").GetInt32());
            Assert.Equal(0, client.HttpCalls);
            if (scenario == "uncertain")
            {
                var pending = Assert.Single((await client.ReadAsync(Token)).Operations, operation => operation.ProviderNonce == "r5-fixture");
                Assert.Equal(session.FocusRecordId, pending.RecordId); Assert.True(VoiceLabSession.CanStopLooking(pending));
                await client.ReconcileAsync(true, Token);
                Assert.True(backend.CreationPending);
            }
            Assert.False(VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.Unavailable.Available);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
#endif

    private static VoiceTrainingProject Project(bool transcript = true, string? media = "take.mov")
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures/voice-lab/passage-project.voxclip")));
        return new("Demo take", transcript ? project : project with { Transcript = null }, media);
    }
    private static VoiceTrainingSpanSelection Selection(long availableMs) => availableMs < 30_000
        ? new(VoiceTrainingSpanStatus.BelowMinimum, availableMs, 0, [], [], [])
        : new(VoiceTrainingSpanStatus.Ok, availableMs, Math.Min(availableMs, 30_000), [new(1_000, 31_000, 40)], [new(1_000, 31_000, 40)], []);

    [Fact]
    public async Task ProjectWithATranscriptIsTheDefaultSourceAndNeedsNoRecording()
    {
        await using var setup = new Setup(Project());
        Assert.Equal(VoiceTrainingSource.Project, setup.Session.TrainingSource);
        Assert.Equal(VoiceProjectAudioState.Finding, setup.Session.ProjectAudio);
        Assert.Equal("Finding clear speech in Demo take…", setup.Session.ProjectLine);
        await WaitForAsync(() => setup.Backend.Analyses == 1); Assert.True(setup.Session.ProjectOffered);
        await setup.VerifyAsync();
        Assert.Equal("Statement verified. Choose your training audio next.", setup.Session.Message);
        Assert.True(setup.Session.CanSelectProject); Assert.False(setup.Session.CanCreate); Assert.False(setup.Session.CanRecordTraining);
        setup.Backend.Analysis.SetResult(Selection(47_900));
        await WaitForAsync(() => setup.Session.ProjectAudio == VoiceProjectAudioState.Ready);
        Assert.Equal("47 s of clear speech found in Demo take", setup.Session.ProjectLine);
        Assert.True(setup.Session.CanCreate); Assert.False(setup.Session.TrainingReady);
        await setup.Session.PrepareCreationAsync();
        Assert.Same(setup.Session.ProjectAnalysis, setup.Backend.PreparedProject);
        var dialog = VoiceCreationDialog.Create(setup.Session.CreationConfirmation!);
        Assert.EndsWith("\n\nChecks your plan, then sends the consent recording and 31 s of speech from Demo take to create your own voice. No video is sent. This action is free.", dialog.Message);
        await setup.Session.ApproveCreationAsync(true);
        Assert.Equal(1, setup.Backend.Creates); Assert.Equal(CreateVoiceSession.ReadyCopy, setup.Session.Message);
        Assert.Equal(0, setup.Backend.TrainingSeconds);
    }

    [Fact]
    public async Task ReadAloudStaysTheAlternativeAndUsesItsOwnRecording()
    {
        await using var setup = new Setup(Project());
        setup.Backend.Analysis.SetResult(Selection(60_000));
        await WaitForAsync(() => setup.Session.ProjectAudio == VoiceProjectAudioState.Ready);
        setup.Session.SelectTrainingSource(VoiceTrainingSource.ReadAloud);
        Assert.Equal(VoiceTrainingSource.Project, setup.Session.TrainingSource);
        await setup.VerifyAsync();
        setup.Session.SelectTrainingSource(VoiceTrainingSource.ReadAloud);
        Assert.Equal(VoiceTrainingSource.ReadAloud, setup.Session.TrainingSource);
        Assert.True(setup.Session.CanRecordTraining); Assert.False(setup.Session.CanCreate);
        await setup.TrainAsync(); Assert.True(setup.Session.CanCreate);
        await setup.Session.PrepareCreationAsync();
        Assert.Null(setup.Backend.PreparedProject); Assert.Null(setup.Session.CreationConfirmation!.Project);
        Assert.Contains("sends the consent recording and training audio to create your own voice. No video is sent.", VoiceCreationDialog.Create(setup.Session.CreationConfirmation).Message);
        await setup.Session.ApproveCreationAsync(false);
        setup.Session.SelectTrainingSource(VoiceTrainingSource.Project);
        Assert.Equal(VoiceTrainingSource.Project, setup.Session.TrainingSource); Assert.True(setup.Session.CanCreate);
    }

    [Theory]
    [InlineData(29_999, "This project has only 29 s of clear speech. Record a read-aloud instead.")]
    [InlineData(999, "This project has no clear speech to use. Record a read-aloud instead.")]
    [InlineData(0, "This project has no clear speech to use. Record a read-aloud instead.")]
    public async Task TooLittleClearSpeechDisablesTheProjectChoice(long availableMs, string copy)
    {
        await using var setup = new Setup(Project());
        setup.Backend.Analysis.SetResult(Selection(availableMs));
        await WaitForAsync(() => setup.Session.ProjectAudio == VoiceProjectAudioState.TooLittle);
        await setup.VerifyAsync();
        Assert.Equal(copy, setup.Session.ProjectLine); Assert.True(setup.Session.ProjectOffered);
        Assert.Equal(VoiceTrainingSource.ReadAloud, setup.Session.TrainingSource);
        Assert.False(setup.Session.CanSelectProject); Assert.Equal("Statement verified. Choose your training audio next.", setup.Session.Message);
        setup.Session.SelectTrainingSource(VoiceTrainingSource.Project);
        Assert.Equal(VoiceTrainingSource.ReadAloud, setup.Session.TrainingSource); Assert.True(setup.Session.CanRecordTraining);
    }

    [Fact]
    public async Task UnreadableProjectAudioFallsBackToTheReadAloud()
    {
        await using var setup = new Setup(Project(media: null));
        await WaitForAsync(() => setup.Session.ProjectAudio == VoiceProjectAudioState.Unreadable);
        Assert.Equal("VoxClip can't read this project's audio. Record a read-aloud instead.", setup.Session.ProjectLine);
        Assert.Equal(VoiceTrainingSource.ReadAloud, setup.Session.TrainingSource); Assert.False(setup.Session.CanSelectProject);
        await using var cut = new Setup(Project());
        cut.Backend.Analysis.SetResult(Selection(45_000)); cut.Backend.ProjectFailure = new VoxClip.Media.VoiceLab.VoiceLabSourceAudioException(VoxClip.Media.VoiceLab.VoiceLabSourceAudioErrorCode.Unreadable);
        await WaitForAsync(() => cut.Session.ProjectAudio == VoiceProjectAudioState.Ready);
        await cut.VerifyAsync(); await cut.Session.PrepareCreationAsync();
        Assert.Equal("VoxClip can't read this project's audio. Record a read-aloud instead.", cut.Session.Message);
        Assert.Equal(VoiceTrainingSource.ReadAloud, cut.Session.TrainingSource); Assert.Null(cut.Session.CreationConfirmation);
        Assert.True(cut.Session.Verified); Assert.Equal(0, cut.Backend.Creates);
    }

    [Theory]
    [InlineData(false, "Open a project to use its audio instead.")]
    [InlineData(true, "Transcribe this project to use its audio instead.")]
    public async Task WithoutAProjectTranscriptOnlyTheReadAloudIsOffered(bool open, string copy)
    {
        await using var setup = new Setup(open ? Project(transcript: false) : null);
        Assert.Equal(open ? VoiceProjectAudioState.NoTranscript : VoiceProjectAudioState.NoProject, setup.Session.ProjectAudio);
        Assert.Equal(copy, setup.Session.ProjectLine);
        Assert.False(setup.Session.ProjectOffered); Assert.Equal(VoiceTrainingSource.ReadAloud, setup.Session.TrainingSource);
        Assert.Equal(0, setup.Backend.Analyses);
        await setup.VerifyAsync(); Assert.Equal("Statement verified. Record your training read-aloud next.", setup.Session.Message);
        setup.Session.SelectTrainingSource(VoiceTrainingSource.Project);
        Assert.Equal(VoiceTrainingSource.ReadAloud, setup.Session.TrainingSource);
    }

    [Fact]
    public async Task ProjectSpeakerMismatchBlocksAndSwitchesToAReadAloudWithTheSameStatement()
    {
        await using var setup = new Setup(Project());
        setup.Backend.Analysis.SetResult(Selection(90_000));
        await WaitForAsync(() => setup.Session.ProjectAudio == VoiceProjectAudioState.Ready);
        await setup.VerifyAsync(); setup.Backend.PrepareFailure = VoiceConsentError.SpeakerMismatch;
        await setup.Session.PrepareCreationAsync();
        Assert.Equal("Some of this project's audio doesn't sound like the voice in your consent statement. Record a read-aloud instead.", setup.Session.Message);
        Assert.True(setup.Session.HasFailure); Assert.True(setup.Session.ProjectMismatch); Assert.Null(setup.Session.CreationConfirmation);
        Assert.False(setup.Session.CanCreate); Assert.False(setup.Session.CanSelectProject); Assert.Equal(0, setup.Backend.Creates);
        setup.Session.SelectTrainingSource(VoiceTrainingSource.ReadAloud);
        Assert.Equal(VoiceTrainingSource.ReadAloud, setup.Session.TrainingSource); Assert.Null(setup.Session.Message);
        Assert.True(setup.Session.Verified); Assert.True(setup.Session.CanRecordTraining);
        setup.Session.SelectTrainingSource(VoiceTrainingSource.Project); Assert.Equal(VoiceTrainingSource.ReadAloud, setup.Session.TrainingSource);
        setup.Backend.PrepareFailure = null; await setup.TrainAsync();
        await setup.Session.PrepareCreationAsync(); await setup.Session.ApproveCreationAsync(true);
        Assert.Null(setup.Backend.PreparedProject); Assert.Equal(1, setup.Backend.Creates); Assert.Equal(0, setup.Backend.Abandons);
    }

    [Fact]
    public async Task ClosedWindowsSpeakerGateKeepsTheUnavailableCopyAndNeverAnalyses()
    {
        Assert.False(VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.WindowsNativeParityVerified);
        await using var setup = new Setup(Project());
        await WaitForAsync(() => setup.Backend.Analyses == 1);
        await using var closed = new Setup(Project(), open: false);
        closed.Backend.SpeakerAvailable = false;
        closed.Session.OpenProject(Project());
        closed.Session.SetInputs("Example", "en", true, true, true);
        Assert.Equal(VoiceLabCopy.SpeakerUnavailable, closed.Session.BlockedReason);
        Assert.Equal("The speaker check is not ready on Windows yet. Creating a voice is unavailable.", closed.Session.BlockedReason);
        Assert.False(closed.Session.CanRecord); await closed.Session.RecordAsync();
        Assert.False(closed.Session.HasStatementRecording); Assert.Equal(0, closed.Capture.Maximum);
        Assert.Equal(0, closed.Backend.Analyses); Assert.Equal(VoiceTrainingSource.Project, closed.Session.TrainingSource);
        Assert.False(closed.Session.CanCreate); Assert.False(closed.Session.CanChooseSource);
        await Task.Delay(50, Token); Assert.Equal(0, closed.Backend.Analyses);
        var root = Path.Combine(Path.GetTempPath(), "voxclip-gate-" + Guid.NewGuid().ToString("N"));
        var data = new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "models"), Path.Combine(root, "cache"), Path.Combine(root, "autosave"), Path.Combine(root, "secrets"), Path.Combine(root, "logs"));
        using var production = new VoiceStatementBackend(data, new NoKeys(), new QuietLog(), ElevenLabsRegion.Default, () => true, () => null, _ => Task.CompletedTask);
        Assert.False(production.SpeakerAvailable); Assert.False(production.SpeakerCalibrated("en")); Assert.False(production.SpeakerCalibrated("et"));
        Assert.False(Directory.Exists(root));
    }

    [Fact]
    public async Task AnalysisHeldBackByTheGateStartsWhenTheGateOpensOrAStatementIsRecorded()
    {
        await using var announced = new Setup(Project(), open: false);
        announced.Backend.SpeakerAvailable = false;
        announced.Session.OpenProject(Project());
        await announced.Session.GateChangedAsync(); Assert.Equal(0, announced.Backend.Analyses);
        announced.Backend.SpeakerAvailable = true;
        await announced.Session.GateChangedAsync();
        await WaitForAsync(() => announced.Backend.Analyses == 1);
        announced.Backend.Analysis.SetResult(Selection(45_000));
        await WaitForAsync(() => announced.Session.ProjectAudio == VoiceProjectAudioState.Ready);
        await announced.Session.GateChangedAsync(); Assert.Equal(1, announced.Backend.Analyses);
        await using var unannounced = new Setup(Project(), open: false);
        unannounced.Backend.SpeakerAvailable = false;
        unannounced.Session.OpenProject(Project());
        unannounced.Backend.SpeakerAvailable = true;
        Assert.Equal(0, unannounced.Backend.Analyses);
        await unannounced.VerifyAsync();
        await WaitForAsync(() => unannounced.Backend.Analyses == 1);
        unannounced.Backend.Analysis.SetResult(Selection(45_000));
        await WaitForAsync(() => unannounced.Session.ProjectAudio == VoiceProjectAudioState.Ready);
        Assert.Equal(VoiceTrainingSource.Project, unannounced.Session.TrainingSource); Assert.True(unannounced.Session.CanCreate);
        // The page forwards every announced change to the session, not only Voice Lab turning off.
        var page = AppFile("Controls/CreateVoicePage.cs").ReplaceLineEndings("\n");
        Assert.Contains("        }\n        // Abandons when Voice Lab is off; otherwise starts the project analysis if the gate has opened.\n        await session.GateChangedAsync();\n        Refresh();", page);
    }

    [Theory]
    [InlineData("et", "", "en")]
    [InlineData("et", "et", "et")]
    [InlineData("ET-ee", "et", "et")]
    [InlineData("et", "en", "en")]
    [InlineData("en-GB", "en", "en")]
    [InlineData("en", "", "en")]
    [InlineData("fr", "fr", "en")]
    [InlineData(null, "et", "en")]
    [InlineData("", "", "en")]
    public void StatementUsesTheTranscriptLanguageOnlyWhenItsSpeakerCheckIsCalibrated(string? transcript, string calibrated, string expected)
        => Assert.Equal(expected, CreateVoiceSession.StatementLanguage(transcript, language => language == calibrated));

    [Fact]
    public async Task CalibratedEstonianWouldStillWaitForTheReviewedStatement()
    {
        await using var setup = new Setup();
        setup.Backend.Calibrated = language => language == "et";
        setup.Session.SetInputs("Example", "et", true, true, true);
        Assert.Equal("et", setup.Session.Statement!.Language);
        Assert.Equal("Estonian draft — pending the user's review.", setup.Session.BlockedReason);
        await setup.Session.RecordAsync(); Assert.Equal(0, setup.Capture.Maximum);
        setup.Backend.Calibrated = _ => false;
        setup.Session.SetInputs("Example", "et", true, true, true);
        Assert.Equal("en", setup.Session.Statement!.Language); Assert.Null(setup.Session.BlockedReason);
    }

    /// <summary>§6.5.2: in a project whose language has no calibrated speaker check, Rewrite explains instead of offering a voice, but
    /// Create Your Voice from Settings still defaults to that project's audio, with an English statement.</summary>
    [Fact]
    public async Task ProjectInAnUncalibratedLanguageStillTrainsFromSettings()
    {
        var opened = Project();
        await using var setup = new Setup(opened with { Project = opened.Project with { Transcript = opened.Project.Transcript! with { Language = "et" } } });
        setup.Backend.Calibrated = language => language == "en";
        Assert.True(VoiceLabSession.VoicesUnavailable("et", setup.Backend.Calibrated));
        Assert.Equal(VoiceTrainingSource.Project, setup.Session.TrainingSource); Assert.True(setup.Session.ProjectOffered);
        await WaitForAsync(() => setup.Backend.Analyses == 1);
        setup.Session.SetInputs("Example", "et", true, true, true);
        Assert.Equal("en", setup.Session.Statement!.Language); Assert.Null(setup.Session.BlockedReason);
        setup.Backend.Analysis.SetResult(Selection(47_900));
        await WaitForAsync(() => setup.Session.ProjectAudio == VoiceProjectAudioState.Ready);
        Assert.Equal(VoiceTrainingSource.Project, setup.Session.TrainingSource);
        Assert.Contains("?? App.Windows.FirstOrDefault(window => window.VoiceTrainingProject is not null)", AppFile("Controls/CreateVoicePage.cs"));
    }

    [Fact]
    public void PageOffersBothSourcesWithTheirExactCopy()
    {
        var page = AppFile("Controls/CreateVoicePage.cs");
        foreach (var text in new[] { "session.OpenProject(window?.VoiceTrainingProject)", "VoiceLabCopy.ProjectChoice", "VoiceLabCopy.ReadAloudChoice", "VoiceLabCopy.RecordReadAloud",
            "session.ProjectLine", "projectChoice.IsEnabled = session.CanSelectProject", "training.IsEnabled = session.CanRecordTraining", "voice-training-source" })
            Assert.Contains(text, page);
        Assert.Equal("Use this project's audio (recommended)", VoiceLabCopy.ProjectChoice);
        Assert.Equal("Record a read-aloud (about 90 s)", VoiceLabCopy.ReadAloudChoice);
        Assert.Equal("Record a Read-Aloud", VoiceLabCopy.RecordReadAloud);
        Assert.Contains("VoiceTrainingProject => editor is", AppFile("MainWindow.xaml.cs"));
        // The window that opened the sheet gives its project; with none offered, the picker is hidden and only its line shows.
        Assert.Contains("var window = (from is not null && App.Windows.Contains(from) ? from : null)", page);
        Assert.Contains("source.Visibility = picking && session.ProjectOffered ? Visibility.Visible : Visibility.Collapsed;", page);
        Assert.Contains("sourceLine.Visibility = picking && !session.ProjectOffered ? Visibility.Visible : Visibility.Collapsed;", page);
        Assert.Contains("createVoicePage = new(this, session, from);", AppFile("SettingsWindow.xaml.cs"));
        var backend = AppFile("Services/VoiceStatementBackend.cs");
        Assert.Contains("VoiceTrainingAudio.AnalyzeAsync", backend); Assert.Contains("VoiceTrainingSpans.Inputs(project.Project)", backend);
        Assert.Contains("VoiceTrainingAudio.ProjectSpansAsync", backend);
    }

    private static async Task WaitForAsync(Func<bool> condition)
    {
        for (var attempt = 0; !condition(); attempt++)
        {
            Assert.True(attempt < 500, "The project analysis did not finish.");
            await Task.Delay(10, Token);
        }
    }

    private sealed class Setup : IAsyncDisposable
    {
        internal readonly FlowBackend Backend = new();
        internal readonly FlowCapture Capture = new();
        internal readonly VoiceSessionClock Clock = new();
        internal readonly CreateVoiceSession Session;
        internal Setup(VoiceTrainingProject? project = null, bool open = true)
        {
            Session = new(Backend, Capture, Dispatch, Clock);
            if (open) Session.OpenProject(project);
        }
        private Task Recording()
        {
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            Session.Changed += (_, _) => { if (Session.Recording) ready.TrySetResult(); };
            return ready.Task;
        }
        internal async Task VerifyAsync()
        {
            Session.SetInputs("Example", "en", true, true, true);
            var recording = Recording(); var work = Session.RecordAsync(); Clock.Advance(TimeSpan.FromMilliseconds(600));
            await recording.WaitAsync(Token); Session.StopRecording(); await work;
            Assert.True(Session.RequestVerification()); await Session.ApproveVerificationAsync(true); Assert.True(Session.Verified);
        }
        internal async Task TrainAsync(int seconds = 60)
        {
            Capture.Seconds = seconds; var recording = Recording(); var work = Session.RecordTrainingAsync();
            await recording.WaitAsync(Token); Assert.False(Session.CanCreate); Session.StopRecording(); await work;
        }
        internal async Task ReadyAsync() { await VerifyAsync(); await TrainAsync(); }
        public ValueTask DisposeAsync() => Session.DisposeAsync();
    }
    private sealed class FlowBackend : IVoiceCreationBackend
    {
        public bool Enabled { get; set; } = true;
        public bool SpeakerAvailable { get; set; } = true;
        public bool SpeakerCalibrated(string language) => Calibrated(language);
        public string? PlanMessage { get; set; }
        public string VerificationCost => "< $0.01";
        public bool CreationPending { get; set; }
        internal bool Fresh = true, SaveFailure, RetryFailure, Uncertain, VerificationRequired, ServicesAvailable = true;
        internal VoiceConsentError? PrepareFailure;
        internal Exception? ProjectFailure;
        internal int Creates, PlanChecks, Abandons, Saves, TrainingSeconds, Analyses, Prepares;
        internal VoiceConsentRecord? LastRecord;
        internal Func<string, bool> Calibrated = _ => false;
        internal TaskCompletionSource<VoiceTrainingSpanSelection> Analysis = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal VoiceProjectAudio? PreparedProject;
        internal long KeptSeconds = 31;
        private string? id;
        public VoiceConsentStatement Statement(string name, string language, DateOnly date) => new(language, "Synthetic statement", ["alpha", "beta", "gamma", "delta"]);
        public Task SaveStatementAsync(string recordId, MicrophoneTake take, CancellationToken ct) { id = recordId; return Task.CompletedTask; }
        public Task VerifyAsync(string recordId, VoiceConsentStatement statement, VoiceConsentAttestations attestations, CancellationToken ct) => Task.CompletedTask;
        public Task AbandonAsync(string recordId) { Abandons++; return Task.CompletedTask; }
        public Task SaveTrainingAsync(MicrophoneTake take, CancellationToken ct)
        {
            TrainingSeconds = take.Mono.Length / take.Rate;
            if (take.Mono.Length < 60 * take.Rate || take.Mono.Length > 120 * take.Rate) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            return Task.CompletedTask;
        }
        public async Task<VoiceProjectAudio> AnalyzeProjectAsync(VoiceTrainingProject project, CancellationToken ct)
        {
            Analyses++;
            if (project.MediaPath is not { } media) throw new IOException("Missing media");
            return new(project.Name, media, 48000, await Analysis.Task.WaitAsync(ct));
        }
        public Task<VoiceCreationQuote> PrepareCreationAsync(string recordId, string name, VoiceProjectAudio? project, CancellationToken ct)
        {
            Prepares++; PreparedProject = project;
            if (project is not null && ProjectFailure is { } failure) throw failure;
            if (PrepareFailure is { } error) throw new VoiceConsentException(error);
            return Task.FromResult(new VoiceCreationQuote(new(VoiceLabCostPresentationKind.Inline, ""), new object(), project is null ? null : new(project.Name, KeptSeconds)));
        }
        public bool QuoteIsFresh(VoiceCreationQuote quote) => Fresh;
        public Task<VoiceConsentRecord> CreateAsync(VoiceCreationQuote quote, CancellationToken ct)
        {
            if (!ServicesAvailable) throw new InvalidOperationException("Services unavailable");
            PlanChecks++; Creates++;
            LastRecord = Record() with { RecordId = id!, Status = VerificationRequired ? VoiceConsentStatus.VerificationRequired : VoiceConsentStatus.Active };
            if (Uncertain) { CreationPending = true; throw new VoiceConsentException(VoiceConsentError.CreationPending); }
            if (SaveFailure) throw new VoiceConsentSaveException(LastRecord);
            return Task.FromResult(LastRecord);
        }
        public Task SaveCreationRecordAsync(VoiceConsentRecord record, CancellationToken ct)
        { Saves++; if (RetryFailure) throw new IOException("Injected save failure"); return Task.CompletedTask; }
        public void Dispose() { }
    }
    private sealed class FlowCapture : IVoiceStatementCapture
    {
        private TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private MicrophoneTake? take;
        internal int Seconds = 5, Maximum;
        internal bool Discarded;
        public Task StartAsync(CancellationToken ct) => Start(30);
        public Task StartTrainingAsync(CancellationToken ct) => Start(90);
        private Task Start(int maximum) { completion = new(TaskCreationOptions.RunContinuationsAsynchronously); Maximum = maximum; Discarded = false; return Task.CompletedTask; }
        public Task Completion => completion.Task;
        public MicrophoneSnapshot Snapshot => new(false, false, Seconds, .2, null, "Fake microphone");
        public MicrophoneTake Stop()
        {
            if (take is null)
            {
                var samples = new float[8000 * (Maximum > 0 ? Math.Min(Seconds, Maximum) : Seconds)];
                for (var index = 0; index < samples.Length; index++) samples[index] = (float)(.1 * Math.Sin(2 * Math.PI * 220 * index / 8000));
                take = new(samples, 8000);
            }
            completion.TrySetResult(); return take;
        }
        public void Discard() { if (take is not null) Array.Clear(take.Mono); take = null; Discarded = true; completion.TrySetResult(); }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class NoKeys : IKeyProvider
    { public Task<string?> GetKeyAsync(string account, CancellationToken ct) => throw new InvalidOperationException("No key reads allowed"); }
    private sealed class QuietLog : ILog
    {
        public void RegisterSecret(string secret) { }
        public void Write(LogLevel level, string category, string message) { }
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
#endif
