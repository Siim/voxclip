#if WIN_UI_TESTS
using System.Net;
using System.Reflection;
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class VoiceLabRecoveryTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LocalWithdrawalForcesRealJournalRecoveryWithoutWaitingForProvider(bool failFirst)
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-withdrawal-" + Guid.NewGuid().ToString("N"));
        var data = new DataLocations(root, root + "/settings.json", root + "/models", root + "/cache", root + "/autosave", root + "/keys", root + "/logs");
        try
        {
            var store = new VoiceConsentStore(data);
            var record = JsonSerializer.Deserialize<VoiceConsentRecord>(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures/voice-lab/consent-record.json")), new JsonSerializerOptions(JsonSerializerDefaults.Web))!
                with { RecordId = Guid.NewGuid().ToString("D"), VoiceId = "pending", Creator = new(ElevenLabsRegion.Default, VoiceConsentCreator.Fingerprint("synthetic-recovery-key")) };
            using var wave = new MemoryStream();
            using (var writer = new BinaryWriter(wave, System.Text.Encoding.UTF8, true))
            {
                writer.Write("RIFF"u8); writer.Write(160036); writer.Write("WAVEfmt "u8); writer.Write(16);
                writer.Write((short)1); writer.Write((short)1); writer.Write(16000); writer.Write(32000); writer.Write((short)2); writer.Write((short)16);
                writer.Write("data"u8); writer.Write(160000); writer.Write(new byte[160000]);
            }
            var wav = wave.ToArray();
            record = record with { Statement = record.Statement with { AudioSha256 = VoiceConsentStore.Hash(wav) } };
            store.SaveStatement(wav, record.RecordId);
            VoiceOperation operation;
            using (var claim = store.ClaimCreation(record, Guid.NewGuid(), ElevenLabsRegion.Default, DateTimeOffset.UtcNow))
                operation = claim.Operation with { State = VoiceOperationState.Created, WasDispatched = true, RemoteVoiceId = "syntheticRemoteVoice",
                    Audit = claim.Operation.Audit! with { RemoteVoiceId = "syntheticRemoteVoice" } };
            File.WriteAllText(Path.Combine(store.OperationsRoot, operation.Id.ToString("D") + ".json"), JsonSerializer.Serialize(operation, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
            store.WithdrawCreation(record.RecordId, DateTimeOffset.UtcNow);
            Assert.Equal(VoiceOperationState.Withdrawing, Assert.Single(store.Operations()).State);
            Assert.Null(Assert.Single(store.Operations()).NextAttemptAt);
            using var remote = new RecoveryRemote(failFirst);
            var factory = typeof(ElevenLabsVoiceLab).GetMethod("ForTesting", BindingFlags.Static | BindingFlags.NonPublic)!;
            using var client = (ElevenLabsVoiceLab)factory.Invoke(null, [new RecoveryKeys(), remote, ElevenLabsRegion.Default, null, null, null, null, null])!;
            var backend = new JournalBackend(store, client);
            using var session = new VoiceLabSession(backend, action => { action(); return Task.CompletedTask; });
            await session.CreationReturnedAsync("Removing…");
            var recovery = typeof(VoiceLabSession).GetProperty("CreationRecovery", BindingFlags.Instance | BindingFlags.NonPublic);
            Assert.NotNull(recovery);
            Assert.False(((Task)recovery.GetValue(session)!).IsCompleted);
            await remote.Entered.Task.WaitAsync(TestContext.Current.CancellationToken);
            Assert.Single(session.Operations);
            Assert.Equal("Removing…", session.Message);
            remote.Release.TrySetResult();
            await ((Task)recovery.GetValue(session)!).WaitAsync(TestContext.Current.CancellationToken);
            if (failFirst)
            {
                var pending = Assert.Single(session.Operations);
                Assert.True(pending.Failed); Assert.NotNull(pending.NextAttemptAt);
                Assert.Equal("Couldn't finish — Retry", pending.DisplayState);
                Assert.Equal(VoiceLabCopy.RecoveryFailed, session.Message);
                await session.LoadAsync(force: true);
            }
            Assert.Empty(store.Operations()); Assert.Empty(session.Operations);
            Assert.DoesNotContain(record.RecordId, session.Deleting);
            Assert.NotEqual("Removing…", session.Message);
            Assert.NotNull(store.AuditTombstone(record.RecordId));
            Assert.Equal(failFirst ? 2 : 1, remote.Calls);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private sealed class RecoveryKeys : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => Task.FromResult<string?>("synthetic-recovery-key");
    }
    private sealed class RecoveryRemote(bool failFirst) : HttpMessageHandler
    {
        internal int Calls;
        internal TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Assert.Equal(HttpMethod.Delete, request.Method);
            Calls++; Entered.TrySetResult(); await Release.Task.WaitAsync(ct);
            if (failFirst && Calls == 1) throw new HttpRequestException("synthetic offline");
            return new(HttpStatusCode.OK) { Content = new StringContent("{\"status\":\"ok\"}") };
        }
    }
    private sealed class JournalBackend(VoiceConsentStore store, ElevenLabsVoiceLab client) : IVoiceLabBackend
    {
        public bool Enabled => true;
        public Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct) => Task.FromResult(new VoiceLabSnapshot(store.Records(), store.Operations()));
        public Task ReconcileAsync(bool force, CancellationToken ct) => new VoiceOperationReconciler(store, _ => client).ReconcileAsync(force: force, ct: ct);
        public Task PersistProviderConsentAsync(CancellationToken ct) => throw new InvalidOperationException();
        public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct) => throw new InvalidOperationException();
        public Task DeleteAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task RemoveLocalAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task WithdrawAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task SaveAsync(VoiceConsentRecord record, CancellationToken ct) => throw new InvalidOperationException();
        public Task RemoveSpeakerAsync(CancellationToken ct) => throw new InvalidOperationException();
        public Task StopLookingAsync(Guid operationId, CancellationToken ct) => throw new InvalidOperationException();
    }
}
#endif
