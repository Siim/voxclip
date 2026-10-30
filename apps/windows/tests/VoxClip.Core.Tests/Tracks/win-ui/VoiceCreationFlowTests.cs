#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
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

    private sealed class Setup : IAsyncDisposable
    {
        internal readonly FlowBackend Backend = new();
        internal readonly FlowCapture Capture = new();
        internal readonly VoiceSessionClock Clock = new();
        internal readonly CreateVoiceSession Session;
        internal Setup() => Session = new(Backend, Capture, Dispatch, Clock);
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
        public string? PlanMessage { get; set; }
        public string VerificationCost => "< $0.01";
        public bool CreationPending { get; set; }
        internal bool Fresh = true, SaveFailure, RetryFailure, Uncertain, VerificationRequired, ServicesAvailable = true;
        internal VoiceConsentError? PrepareFailure;
        internal int Creates, PlanChecks, Abandons, Saves, TrainingSeconds;
        internal VoiceConsentRecord? LastRecord;
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
        public Task<VoiceCreationQuote> PrepareCreationAsync(string recordId, string name, CancellationToken ct)
        {
            if (PrepareFailure is { } error) throw new VoiceConsentException(error);
            return Task.FromResult(new VoiceCreationQuote(new(VoiceLabCostPresentationKind.Inline, ""), new object()));
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
