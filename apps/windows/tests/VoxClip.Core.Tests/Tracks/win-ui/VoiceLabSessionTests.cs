#if WIN_UI_TESTS
using System.Globalization;
using System.Text.Json;
using System.Security.Cryptography;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class VoiceLabSessionTests
{
    private static Task Dispatch(Action action) { action(); return Task.CompletedTask; }
    private static VoiceConsentRecord Record() => JsonSerializer.Deserialize<VoiceConsentRecord>(
        File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "voice-lab", "consent-record.json")),
        new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
    private static VoiceOperation Operation(VoiceSessionClock clock, VoiceOperationKind kind = VoiceOperationKind.Create) => new(
        Guid.NewGuid(), kind, Guid.NewGuid().ToString("D"), "nonce", ElevenLabsRegion.Default, clock.GetUtcNow(), clock.GetUtcNow(),
        kind == VoiceOperationKind.Create ? VoiceOperationState.Dispatched : VoiceOperationState.Intent, null, true, null, 0, null, false, null, null);

    [Fact]
    public async Task EnablingLoadsLocalRecordsBeforeAnyAccountApproval()
    {
        var backend = new FakeBackend { Snapshot = new([Record()], []) };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.RefreshEnabledStateAsync();
        Assert.Single(session.Records); Assert.Equal(new[] { "reconcile", "read" }, backend.Calls);
        session.Request(new(VoiceLabRequestKind.Subscription));
        await session.ApproveAsync(false);
        Assert.DoesNotContain("consent", backend.Calls);
        session.Request(new(VoiceLabRequestKind.Subscription));
        await session.ApproveAsync(true);
        Assert.True(backend.Calls.IndexOf("consent") < backend.Calls.IndexOf("subscription"));
        Assert.NotNull(session.Subscription);
    }
    [Fact]
    public async Task JournalRowsWithoutRecordsAndManualReviewRemainVisible()
    {
        var clock = new VoiceSessionClock();
        var removing = Operation(clock, VoiceOperationKind.Delete);
        var review = Operation(clock) with { RecoveryNeedsReview = true };
        var boundReview = Operation(clock) with { RecoveryNeedsReview = true, CreatorKeyFingerprint = new string('a', 16) };
        var mismatch = Operation(clock) with { RecoveryNeedsCreatorKey = true };
        var backend = new FakeBackend { Snapshot = new([], [removing, review, mismatch, boundReview]) };
        using (var first = new VoiceLabSession(backend, Dispatch, clock))
        {
            await first.ReconcileStartupAsync();
            Assert.Equal("Removing…", first.Operations[0].DisplayState);
            Assert.Equal("Recovery needs the ElevenLabs key that started this voice.", first.Operations[1].DisplayState);
            Assert.Equal("Checking paused — review the unfinished voice in your ElevenLabs account.", first.Operations[3].DisplayState);
        }
        clock.Advance(TimeSpan.FromDays(3));
        using var restarted = new VoiceLabSession(backend, Dispatch, clock);
        await restarted.ReconcileStartupAsync();
        Assert.Equal(4, restarted.Operations.Count);
        Assert.False(restarted.Operations[2].Finished);
        Assert.Equal("Recovery needs the ElevenLabs key that started this voice.", restarted.Operations[2].DisplayState);
    }
    [Fact]
    public async Task VisibleRecordsFilterPendingCreatingAndDeletedButKeepDeleting()
    {
        var record = Record(); var clock = new VoiceSessionClock();
        var creating = record with { RecordId = Guid.NewGuid().ToString("D") };
        var deleted = record with { RecordId = Guid.NewGuid().ToString("D"), Status = VoiceConsentStatus.Deleted, DeletedAt = clock.GetUtcNow() };
        var removing = deleted with { RecordId = Guid.NewGuid().ToString("D") };
        var backend = new FakeBackend { Snapshot = new([record, creating, deleted, removing, record with { VoiceId = "pending" }],
            [Operation(clock) with { RecordId = creating.RecordId }, Operation(clock, VoiceOperationKind.Delete) with { RecordId = removing.RecordId }]) };
        using var session = new VoiceLabSession(backend, Dispatch, clock);
        await session.LoadAsync(false);
        Assert.Equal(new[] { record.RecordId, removing.RecordId }, session.VisibleRecords.Select(value => value.RecordId));
    }
    [Fact]
    public async Task PendingCreationsExpireAtExactly24HoursWithoutHidingReview()
    {
        var clock = new VoiceSessionClock(); var operation = Operation(clock) with { RecoveryNeedsReview = true };
        using var session = new VoiceLabSession(new FakeBackend { Snapshot = new([], [operation]) }, Dispatch, clock);
        await session.LoadAsync(false);
        clock.Advance(TimeSpan.FromHours(24) - TimeSpan.FromTicks(1));
        Assert.Single(session.PendingCreations);
        clock.Advance(TimeSpan.FromTicks(1));
        Assert.Empty(session.PendingCreations); Assert.Single(session.Operations);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task WithheldCalibrationNeverAdvertisesAvailability(bool installed)
    {
        using var session = new VoiceLabSession(new FakeBackend { Snapshot = new([], [], installed) }, Dispatch);
        await session.LoadAsync(false);
        Assert.False(VoiceSpeakerCheck.WindowsNativeParityVerified);
        Assert.Equal(VoiceLabCopy.SpeakerUnavailable, session.SpeakerMessage);
        Assert.Equal(VoiceLabCopy.SpeakerUnavailable, session.CreateBlockedReason);
        Assert.Equal(installed, session.SpeakerInstalled);
    }
    /// <summary>voice-lab.md §6.5.2: a voice is bound to its statement language, so with only English calibrated an Estonian project's
    /// Rewrite panel explains instead of offering one. Without a calibrated check it offers Create Your Voice… as before.</summary>
    [Fact]
    public void RewriteExplainsWhenTheProjectLanguageHasNoSpeakerCheck()
    {
        Func<string, bool> english = language => language == "en";
        Assert.True(VoiceLabSession.VoicesUnavailable("et", english)); Assert.True(VoiceLabSession.VoicesUnavailable("fr", english));
        Assert.False(VoiceLabSession.VoicesUnavailable("en", english)); Assert.False(VoiceLabSession.VoicesUnavailable(null, english));
        Assert.False(VoiceLabSession.VoicesUnavailable("et", language => language is "en" or "et"));
        Assert.False(VoiceLabSession.VoicesUnavailable("et", _ => false)); Assert.False(VoiceLabSession.VoicesUnavailable("et", language => language == "et"));
        Assert.Equal("Your voice can't be used in this project's language yet. It works in English projects.", VoiceLabCopy.LanguageUnavailable);
        // A8 keeps the Windows check closed, so for now no language counts as calibrated and every project offers Create Your Voice….
        Assert.False(VoiceSpeakerCheck.WindowsNativeParityVerified);
        Assert.False(VoiceLabSession.SpeakerCalibrated("en")); Assert.False(VoiceLabSession.SpeakerCalibrated("et"));
        Assert.NotNull(new SpeakerModelCatalog().Entry.CalibratedThreshold("en")); Assert.Null(new SpeakerModelCatalog().Entry.CalibratedThreshold("et"));
    }
    [Fact]
    public async Task GateClosedMakesZeroBackendCallsAndClearsApproval()
    {
        var backend = new FakeBackend { Enabled = false };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.ReconcileStartupAsync(); await session.RefreshEnabledStateAsync();
        session.Request(new(VoiceLabRequestKind.Delete, "record")); await session.ApproveAsync(true);
        await session.WithdrawOperationAsync("record");
        Assert.Empty(backend.Calls); Assert.Null(session.Confirmation);
    }
    [Fact]
    public async Task DeleteRequiresApprovalAndMismatchRefusesWithExactCopy()
    {
        var backend = new FakeBackend { DeleteMismatch = true };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.ApproveAsync(true);
        Assert.Empty(backend.Calls);
        session.Request(new(VoiceLabRequestKind.Delete, "record")); await session.ApproveAsync(false);
        Assert.Empty(backend.Calls);
        session.Request(new(VoiceLabRequestKind.Delete, "record")); await session.ApproveAsync(true);
        Assert.Contains("delete", backend.Calls); Assert.Equal(VoiceCreatorMismatchException.Explanation, session.Message);
        session.Request(new(VoiceLabRequestKind.RemoveLocal, "record")); await session.ApproveAsync(true);
        Assert.Contains("local", backend.Calls); Assert.Equal(VoiceLabCopy.RemovedLocal, session.Message);
    }
    [Fact]
    public async Task AccountCheckRefreshesVerificationOnlyWhenRequired()
    {
        var backend = new FakeBackend { Snapshot = new([Record() with { Status = VoiceConsentStatus.VerificationRequired }], []) };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.LoadAsync(false);
        session.Request(new(VoiceLabRequestKind.Subscription)); await session.ApproveAsync(true);
        Assert.True(backend.RefreshedVerification);
    }
    [Fact]
    public async Task TimerUsesFakeTimeAndIsCancelledOnDisableAndDispose()
    {
        var clock = new VoiceSessionClock();
        var backend = new FakeBackend { Snapshot = new([], [Operation(clock) with { NextAttemptAt = clock.GetUtcNow().AddMinutes(1) }]) };
        using var session = new VoiceLabSession(backend, Dispatch, clock);
        await session.LoadAsync(false); Assert.Equal(1, clock.ActiveTimers);
        backend.Enabled = false; await session.RefreshEnabledStateAsync();
        Assert.Equal(0, clock.ActiveTimers); clock.Advance(TimeSpan.FromDays(1));
        Assert.Equal(new[] { "read" }, backend.Calls);
        backend.Enabled = true; await session.RefreshEnabledStateAsync();
        Assert.Equal(1, clock.ActiveTimers);
        session.Dispose(); Assert.Equal(0, clock.ActiveTimers);
    }
    [Fact]
    public async Task TimerReconcilesAtDeadlineWithoutSleeping()
    {
        var clock = new VoiceSessionClock();
        var backend = new FakeBackend { Snapshot = new([], [Operation(clock) with { NextAttemptAt = clock.GetUtcNow().AddMinutes(1) }]) };
        using var session = new VoiceLabSession(backend, Dispatch, clock);
        await session.LoadAsync(false);
        Assert.Equal(1, clock.ActiveTimers);
        backend.Snapshot = new([], []);
        var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        session.Changed += (_, _) => { if (session.Operations.Count == 0) loaded.TrySetResult(); };
        clock.Advance(TimeSpan.FromMinutes(1));
        await loaded.Task.WaitAsync(TestContext.Current.CancellationToken);
        Assert.Contains("reconcile", backend.Calls);
        Assert.Equal(0, clock.ActiveTimers);
    }
    [Fact]
    public async Task DisableRejectsStaleResultsAndReenableReloadsAfterPendingRead()
    {
        var backend = new FakeBackend { Snapshot = new([Record()], []), HoldRead = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var session = new VoiceLabSession(backend, Dispatch);
        var loading = session.LoadAsync(false);
        await backend.ReadStarted.Task.WaitAsync(TestContext.Current.CancellationToken);
        backend.Enabled = false; await session.RefreshEnabledStateAsync();
        Assert.Empty(session.Records);
        backend.Enabled = true; await session.RefreshEnabledStateAsync();
        backend.HoldRead.SetResult(); await loading;
        Assert.Single(session.Records);
        Assert.Equal(2, backend.Calls.Count(call => call == "read"));
    }
    [Fact]
    public async Task StateNotificationsUseDispatcherAndAcceptedWorkSurvivesPaneLifetime()
    {
        var inDispatcher = new AsyncLocal<bool>();
        Task OnUi(Action action)
        {
            Assert.False(inDispatcher.Value); inDispatcher.Value = true;
            try { action(); } finally { inDispatcher.Value = false; }
            return Task.CompletedTask;
        }
        var backend = new FakeBackend { HoldDelete = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var session = new VoiceLabSession(backend, OnUi);
        session.Changed += (_, _) => Assert.True(inDispatcher.Value);
        await session.LoadAsync(false);
        inDispatcher.Value = true; session.Request(new(VoiceLabRequestKind.Delete, "record")); inDispatcher.Value = false;
        var approved = session.ApproveAsync(true);
        await backend.DeleteStarted.Task.WaitAsync(TestContext.Current.CancellationToken);
        Assert.True(session.Busy);
        backend.HoldDelete.SetResult(); await approved;
        Assert.Equal(VoiceLabCopy.Deleted, session.Message); Assert.False(session.Busy);
    }
    [Fact]
    public async Task BackendDeleteUsesDiscoveryThenDeleteOnOneAccountAndDisposesIt()
    {
        using var folder = new TestFolder(); var calls = new List<string>(); var created = 0;
        var backend = Backend(folder, () => true, _ => { created++; return new FakeAccount(calls); });
        await backend.DeleteAsync("record", TestContext.Current.CancellationToken);
        Assert.Equal(1, created); Assert.Equal(new[] { "discover", "delete", "dispose" }, calls);
    }
    [Fact]
    public async Task EmptyStartupAndClosedProductionGateNeverConstructAccountsOrReadKeys()
    {
        using var folder = new TestFolder(); var created = 0; var enabled = true;
        var backend = Backend(folder, () => enabled, _ => { created++; return new FakeAccount([]); });
        await backend.ReconcileAsync(false, TestContext.Current.CancellationToken);
        Assert.Equal(0, created);
        enabled = false;
        await Assert.ThrowsAsync<VoiceLabException>(() => backend.DeleteAsync("record", TestContext.Current.CancellationToken));
        Assert.Equal(0, created);
    }
    [Fact]
    public async Task LocalRemovalWritesCoreTombstoneWithoutCreatingAnAccount()
    {
        using var folder = new TestFolder(); var store = new VoiceConsentStore(folder.Locations);
        var wav = Wave(); var record = Record() with { Statement = Record().Statement with { AudioSha256 = Convert.ToHexStringLower(SHA256.HashData(wav)) } };
        store.SaveStatement(wav, record.RecordId); store.Save(record);
        var backend = Backend(folder, () => true, _ => throw new InvalidOperationException("No remote account allowed"));
        await backend.RemoveLocalAsync(record.RecordId, TestContext.Current.CancellationToken);
        var tombstone = store.AuditTombstone(record.RecordId);
        Assert.NotNull(tombstone);
        Assert.True(tombstone.RemoteStateUnknown); Assert.NotNull(tombstone.DeletedAt);
        Assert.False(File.Exists(Path.Combine(store.Root, record.RecordId, "statement.wav")));
        Assert.All(store.Operations(), operation => Assert.True(operation.Finished));
    }
    [Fact]
    public async Task CoreCreatorMismatchNeverAbandonsAcrossRestartBeyond24Hours()
    {
        using var folder = new TestFolder(); var clock = new VoiceSessionClock();
        var store = new VoiceConsentStore(folder.Locations, clock);
        var wav = Wave();
        var record = Record() with { VoiceId = "pending", Statement = Record().Statement with { AudioSha256 = Convert.ToHexStringLower(SHA256.HashData(wav)) } };
        store.SaveStatement(wav, record.RecordId);
        VoiceOperation operation;
        using (var claim = store.ClaimCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, clock.GetUtcNow()))
            operation = claim.Operation with { State = VoiceOperationState.Dispatched, WasDispatched = true };
        File.WriteAllText(Path.Combine(store.OperationsRoot, operation.Id.ToString("D") + ".json"),
            JsonSerializer.Serialize(operation, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
        for (var restart = 0; restart < 3; restart++)
        {
            clock.Advance(TimeSpan.FromDays(2));
            store = new VoiceConsentStore(folder.Locations, clock);
            await new VoiceOperationReconciler(store, _ => throw new VoiceCreatorMismatchException(), clock)
                .ReconcileAsync(force: true, ct: TestContext.Current.CancellationToken);
            var pending = Assert.Single(store.Operations());
            Assert.True(pending.RecoveryNeedsCreatorKey); Assert.False(pending.Finished);
            Assert.Equal("Recovery needs the ElevenLabs key that started this voice.", pending.DisplayState);
            Assert.Null(store.AuditTombstone(record.RecordId));
        }
    }
    [Fact]
    public async Task StopLookingRequiresManualIdentitylessReviewAndCancelDoesNothing()
    {
        var clock = new VoiceSessionClock();
        var allowed = Operation(clock) with { RecoveryNeedsReview = true, ExpectedVoiceName = "Example (VoxClip)" };
        var peers = new[] { allowed, allowed with { Id = Guid.NewGuid() } };
        foreach (var denied in new[] { allowed with { RecoveryNeedsReview = false }, allowed with { CreatorKeyFingerprint = new string('a', 16) }, allowed with { RemoteVoiceId = "known" }, allowed with { State = VoiceOperationState.Abandoned }, allowed with { WasDispatched = false } })
            Assert.False(VoiceLabSession.CanStopLooking(denied));
        Assert.True(VoiceLabSession.CanStopLooking(allowed));
        var labels = peers.Select(operation => VoiceLabActionNames.ForOperation(VoiceLabCopy.StopLooking, operation, peers, [])).ToArray();
        Assert.Equal(2, labels.Distinct().Count());
        Assert.Contains("Example (VoxClip), created 30 October 2026, attempt 1", labels[0]);
        var backend = new FakeBackend { Snapshot = new([], peers) };
        using var session = new VoiceLabSession(backend, Dispatch, clock);
        await session.LoadAsync(recover: false); backend.Calls.Clear();
        session.Request(new(VoiceLabRequestKind.StopLooking, OperationId: allowed.Id));
        await session.ApproveAsync(false); Assert.Empty(backend.Calls);
        session.Request(new(VoiceLabRequestKind.StopLooking, OperationId: allowed.Id));
        await session.ApproveAsync(true);
        Assert.Equal(new[] { "stop-looking", "read" }, backend.Calls);
        Assert.Equal(VoiceLabCopy.StoppedLooking, session.Message);
        Assert.True(session.Operations[0].RemoteStateUnknown);
        await session.ApproveAsync(true);
        Assert.Equal(1, backend.Calls.Count(call => call == "stop-looking"));
    }

    [Fact]
    public async Task StopLookingUsesCoreOnceWithoutKeysOrProviderAndPersistsUnknownState()
    {
        using var folder = new TestFolder(); var clock = new VoiceSessionClock();
        var store = new VoiceConsentStore(folder.Locations, clock); var wav = Wave();
        var record = Record() with { VoiceId = "pending", Creator = null, Statement = Record().Statement with { AudioSha256 = VoiceConsentStore.Hash(wav) } };
        store.SaveStatement(wav, record.RecordId);
        VoiceOperation operation;
        using (var claim = store.ClaimCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, clock.GetUtcNow()))
            operation = claim.Operation with { State = VoiceOperationState.Dispatched, WasDispatched = true, RecoveryNeedsReview = true };
        File.WriteAllText(Path.Combine(store.OperationsRoot, operation.Id.ToString("D") + ".json"), JsonSerializer.Serialize(operation, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
        var backend = Backend(folder, () => true, _ => throw new InvalidOperationException("No provider allowed"));
        await backend.StopLookingAsync(operation.Id, TestContext.Current.CancellationToken);
        var finished = Assert.Single(new VoiceConsentStore(folder.Locations, clock).Operations());
        Assert.True(finished.RemoteStateUnknown); Assert.Equal(VoiceOperationState.Abandoned, finished.State);
        await Assert.ThrowsAsync<VoiceConsentException>(() => backend.StopLookingAsync(operation.Id, TestContext.Current.CancellationToken));
        Assert.NotNull(finished.Audit);
    }

    [Fact]
    public void DatesUseFixedEnglishMonthsRegardlessOfCurrentCulture()
    {
        var previous = CultureInfo.CurrentCulture;
        try { CultureInfo.CurrentCulture = new("et-EE"); Assert.Equal("Example (VoxClip), created 29 October 2026", VoiceLabSession.CardName(Record())); }
        finally { CultureInfo.CurrentCulture = previous; }
    }
    [Fact]
    public async Task RemoveSpeakerUsesOnlyItsModelDirectoryAndNoAccount()
    {
        using var folder = new TestFolder();
        var model = Path.Combine(folder.Locations.Models, new SpeakerModelCatalog().Entry.Id);
        Directory.CreateDirectory(model); File.WriteAllText(Path.Combine(model, "partial-model"), "synthetic");
        Directory.CreateDirectory(folder.Locations.Cache); var keep = Path.Combine(folder.Locations.Cache, "keep"); File.WriteAllText(keep, "keep");
        var backend = Backend(folder, () => true, _ => throw new InvalidOperationException());
        await backend.RemoveSpeakerAsync(TestContext.Current.CancellationToken);
        Assert.False(Directory.Exists(model)); Assert.True(File.Exists(keep));
    }
#if DEBUG
    [Fact]
    public async Task DebugFixturesSeedEveryRowAndRefuseMismatchedCreatorWithoutHttp()
    {
        var backend = DebugVoiceLabBackend.FromFixtures(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "voice-lab"), () => true, _ => Task.CompletedTask);
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.ReconcileStartupAsync();
        Assert.Equal(3, session.VisibleRecords.Count); Assert.Equal(3, session.Operations.Count);
        Assert.Contains(session.Records, record => record.Status == VoiceConsentStatus.Deleted);
        var different = Assert.Single(session.VisibleRecords, record => record.VoiceId == "creatorFixture");
        session.Request(new(VoiceLabRequestKind.Delete, different.RecordId)); await session.ApproveAsync(true);
        Assert.Equal(VoiceCreatorMismatchException.Explanation, session.Message);
        session.Request(new(VoiceLabRequestKind.RemoveLocal, different.RecordId)); await session.ApproveAsync(true);
        Assert.DoesNotContain(session.VisibleRecords, record => record.RecordId == different.RecordId);
        Assert.Equal(0, backend.HttpCalls);
    }
#endif
    [Fact]
    public void NativeAndSettingsSourceContracts()
    {
        var app = Path.Combine(Directory.GetParent(SharedResources.ResolveRoot())!.FullName, "apps", "windows", "src", "VoxClip.App");
        var pane = File.ReadAllText(Path.Combine(app, "Controls", "VoiceLabSettingsPane.cs"));
        Assert.Contains("SetHeadingLevel", pane); Assert.DoesNotContain("Colors.Red", pane);
        Assert.Contains("VoiceLabActionNames.ForRecord(\"Delete voice\"", pane);
        Assert.Contains("\"Retry voice creation\"", pane); Assert.Contains("\"Remove unfinished voice\"", pane);
        Assert.Contains("VoiceLabSession.CanStopLooking(operation)", pane);
        Assert.Contains("VoiceLabCopy.StopLookingExplanation", pane);
        Assert.Contains("Ui.ConfirmAsync", pane);
        Assert.Contains("DefaultButton = ContentDialogButton.Close", File.ReadAllText(Path.Combine(app, "Controls", "Ui.cs")));
        Assert.Contains("CloseButtonText = \"Cancel\"", File.ReadAllText(Path.Combine(app, "Controls", "Ui.cs")));
        Assert.Equal(1, pane.Split("SetLiveSetting").Length - 1);
        Assert.Contains("SetLiveSetting(state, AutomationLiveSetting.Polite)", pane);
        Assert.Contains("SetHelpText(create, session.CreateBlockedReason)", pane);
        Assert.Contains("SetName(name, VoiceLabSession.CardName(record))", pane);
        Assert.Contains("Ui.Announce(previous, operation.DisplayState", pane);
        Assert.Contains("session.Changed -= SessionChanged", pane);
        var ui = File.ReadAllText(Path.Combine(app, "Controls", "Ui.cs"));
        Assert.Contains("DefaultButton = ContentDialogButton.Close", ui);
        Assert.Contains("CloseButtonText = \"Cancel\"", ui);
        Assert.Contains("--voice-lab-probe", File.ReadAllText(Path.Combine(app, "App.xaml.cs")));
        var probe = File.ReadAllText(Path.Combine(app, "Services", "VoiceLabNativeProbe.cs"));
        Assert.Contains("voice-lab-native-result.json", probe); Assert.Contains("DebugVoiceLabHttpCalls != 0", probe);
        var services = File.ReadAllText(Path.Combine(app, "Services", "AppServices.cs"));
        Assert.Contains("RewriteEntryPolicy.Available", services);
        Assert.Contains("VoiceLabBeta.IsAvailable", File.ReadAllText(Path.Combine(app, "ViewModels", "RewriteEntryPolicy.cs")));
        Assert.Contains("await VoiceLab.ReconcileStartupAsync()", services);
        Assert.Contains("voiceLab?.Dispose()", services);
        var harness = File.ReadAllBytes(Path.Combine(app, "..", "..", "tests", "VoxClip.Core.Tests", "Tracks", "win-ui", "native-voicelab-walk.ps1"));
        Assert.All(harness, value => Assert.InRange(value, (byte)0, (byte)127));
        var script = System.Text.Encoding.ASCII.GetString(harness);
        Assert.Contains("'session','account-cancel','delete-cancel','zero-http'", script);
        Assert.Contains("::Key(0x1B)", script);
    }

    private static VoiceLabBackend Backend(TestFolder folder, Func<bool> enabled, Func<ElevenLabsRegion, IVoiceLabAccount> factory) =>
        new(folder.Locations, new NoKeys(), new QuietLog(), enabled, () => ElevenLabsRegion.Default, _ => Task.CompletedTask, accountFactory: factory);
    private static byte[] Wave()
    {
        using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8); writer.Write(160036); writer.Write("WAVEfmt "u8); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(16000); writer.Write(32000); writer.Write((short)2); writer.Write((short)16);
        writer.Write("data"u8); writer.Write(160000); writer.Write(new byte[160000]); return stream.ToArray();
    }
    private sealed class FakeBackend : IVoiceLabBackend
    {
        public bool Enabled { get; set; } = true;
        internal VoiceLabSnapshot Snapshot = new([], []);
        internal readonly List<string> Calls = [];
        internal bool DeleteMismatch, RefreshedVerification;
        internal TaskCompletionSource? HoldDelete;
        internal TaskCompletionSource? HoldRead;
        internal readonly TaskCompletionSource DeleteStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource ReadStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct)
        {
            Calls.Add("read"); ReadStarted.TrySetResult();
            if (HoldRead is not null) await HoldRead.Task;
            return Snapshot;
        }
        public Task ReconcileAsync(bool force, CancellationToken ct) { Calls.Add("reconcile"); return Task.CompletedTask; }
        public Task PersistProviderConsentAsync(CancellationToken ct) { Calls.Add("consent"); return Task.CompletedTask; }
        public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct)
        { Calls.Add("subscription"); RefreshedVerification = refreshVerification; return Task.FromResult(new VoiceLabSubscription("starter", "active", 0, 30000, null, true, 1, 10)); }
        public async Task DeleteAsync(string recordId, CancellationToken ct)
        {
            Calls.Add("delete"); DeleteStarted.TrySetResult();
            if (HoldDelete is not null) await HoldDelete.Task.WaitAsync(ct);
            if (DeleteMismatch) throw new VoiceCreatorMismatchException();
        }
        public Task RemoveLocalAsync(string recordId, CancellationToken ct) { Calls.Add("local"); return Task.CompletedTask; }
        public Task WithdrawAsync(string recordId, CancellationToken ct) { Calls.Add("withdraw"); return Task.CompletedTask; }
        public Task SaveAsync(VoiceConsentRecord record, CancellationToken ct) { Calls.Add("save"); return Task.CompletedTask; }
        public Task RemoveSpeakerAsync(CancellationToken ct) { Calls.Add("remove-speaker"); return Task.CompletedTask; }
        public Task StopLookingAsync(Guid operationId, CancellationToken ct) { Calls.Add("stop-looking"); Snapshot = Snapshot with { Operations = Snapshot.Operations.Select(operation => operation.Id == operationId ? operation with { State = VoiceOperationState.Abandoned, RemoteStateUnknown = true } : operation).ToArray() }; return Task.CompletedTask; }
    }
    private sealed class FakeAccount(List<string> calls) : IVoiceLabAccount
    {
        public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(CancellationToken ct) => throw new InvalidOperationException();
        public Task<IReadOnlyList<VoiceLabVoice>> DiscoverVoicesAsync(CancellationToken ct) { calls.Add("discover"); return Task.FromResult<IReadOnlyList<VoiceLabVoice>>([]); }
        public Task DeleteAsync(string recordId, CancellationToken ct) { calls.Add("delete"); return Task.CompletedTask; }
        public void Dispose() => calls.Add("dispose");
    }
    private sealed class NoKeys : IKeyProvider { public Task<string?> GetKeyAsync(string account, CancellationToken ct) => throw new InvalidOperationException("No key reads allowed"); }
    private sealed class QuietLog : ILog
    {
        public void RegisterSecret(string secret) { }
        public void Write(LogLevel level, string category, string message) { }
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class TestFolder : IDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-ui-session-" + Guid.NewGuid().ToString("N"));
        internal DataLocations Locations => new(root, Path.Combine(root, "settings.json"), Path.Combine(root, "Models"), Path.Combine(root, "cache"), Path.Combine(root, "autosave"), Path.Combine(root, "secrets"), Path.Combine(root, "logs"));
        public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}

internal sealed class VoiceSessionClock : TimeProvider
{
    private DateTimeOffset now = new(2026, 10, 30, 12, 0, 0, TimeSpan.Zero);
    private readonly List<ManualTimer> timers = [];
    internal int ActiveTimers => timers.Count(timer => !timer.Disposed);
    public override DateTimeOffset GetUtcNow() => now;
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state, now + dueTime); timers.Add(timer); return timer;
    }
    internal void Advance(TimeSpan amount)
    {
        now += amount;
        foreach (var timer in timers.Where(timer => !timer.Disposed && timer.Due <= now).ToArray())
        { timer.Disposed = true; timer.Callback(timer.State); }
    }
    private sealed class ManualTimer(VoiceSessionClock owner, TimerCallback callback, object? state, DateTimeOffset due) : ITimer
    {
        internal readonly TimerCallback Callback = callback;
        internal readonly object? State = state;
        internal DateTimeOffset Due = due;
        internal bool Disposed;
        public bool Change(TimeSpan dueTime, TimeSpan period) { Due = owner.now + dueTime; return !Disposed; }
        public void Dispose() => Disposed = true;
        public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
}
#endif
