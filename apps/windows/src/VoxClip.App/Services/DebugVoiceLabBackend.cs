#if DEBUG
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.Services;

internal sealed class DebugVoiceLabBackend(Func<bool> enabled, Func<CancellationToken, Task> persistConsent) : IVoiceLabBackend
{
    private readonly List<VoiceConsentRecord> records = [];
    private readonly List<VoiceOperation> operations = [];
    private string? fixtureDirectory;
    internal int HttpCalls => 0;
    public bool Enabled => enabled();
    internal static DebugVoiceLabBackend FromFixtures(string directory, Func<bool> enabled, Func<CancellationToken, Task> persistConsent)
    {
        var backend = new DebugVoiceLabBackend(enabled, persistConsent);
        backend.fixtureDirectory = directory;
        return backend;
    }
    private void Seed()
    {
        if (fixtureDirectory is not { } directory) return;
        fixtureDirectory = null;
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        var record = JsonSerializer.Deserialize<VoiceConsentRecord>(File.ReadAllText(Path.Combine(directory, "consent-record.json")), options)
            ?? throw new InvalidDataException("Missing consent fixture.");
        record.Validate();
        var creatorRecord = JsonSerializer.Deserialize<VoiceConsentRecord>(File.ReadAllText(Path.Combine(directory, "consent-record-creator.json")), options)
            ?? throw new InvalidDataException("Missing creator consent fixture.");
        creatorRecord.Validate();
        records.Add(record);
        records.Add(record with { RecordId = Guid.NewGuid().ToString("D"), VoiceId = "verificationFixture", VoiceName = "Awaiting verification", Status = VoiceConsentStatus.VerificationRequired });
        records.Add(creatorRecord with { RecordId = Guid.NewGuid().ToString("D"), VoiceId = "creatorFixture", VoiceName = "Different creator key" });
        records.Add(record with { RecordId = Guid.NewGuid().ToString("D"), VoiceId = "deletedFixture", VoiceName = "Deleted fixture", Status = VoiceConsentStatus.Deleted, DeletedAt = record.CreatedAt });
        var now = DateTimeOffset.UtcNow;
        operations.Add(new(Guid.NewGuid(), VoiceOperationKind.Delete, Guid.NewGuid().ToString("D"), "fixture-delete", ElevenLabsRegion.Default,
            now, now, VoiceOperationState.Intent, "unfinishedDelete", false, null, 0, null, false, null, null));
        foreach (var creatorMismatch in new[] { false, true })
            operations.Add(new(Guid.NewGuid(), VoiceOperationKind.Create, Guid.NewGuid().ToString("D"), "fixture-create", ElevenLabsRegion.Default,
                now.AddDays(-2), now, VoiceOperationState.Dispatched, null, true, null, 1, null, false, null, null,
                RecoveryNeedsReview: !creatorMismatch, RecoveryNeedsCreatorKey: creatorMismatch));
    }
    private void Guard(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Enabled) throw new InvalidOperationException("Voice Lab is disabled.");
    }
    public Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct) { Guard(ct); Seed(); return Task.FromResult(new VoiceLabSnapshot(records.ToArray(), operations.ToArray())); }
    public Task ReconcileAsync(bool force, CancellationToken ct) { Guard(ct); return Task.CompletedTask; }
    public Task PersistProviderConsentAsync(CancellationToken ct) { Guard(ct); return persistConsent(ct); }
    public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct)
    { Guard(ct); return Task.FromResult(new VoiceLabSubscription("starter", "active", 0, 30000, null, true, 2, 10)); }
    public Task DeleteAsync(string recordId, CancellationToken ct)
    {
        Guard(ct);
        if (records.Any(record => record.RecordId == recordId && record.VoiceId == "creatorFixture")) throw new VoiceCreatorMismatchException();
        return RemoveLocalAsync(recordId, ct);
    }
    public Task RemoveLocalAsync(string recordId, CancellationToken ct)
    {
        Guard(ct);
        var index = records.FindIndex(record => record.RecordId == recordId);
        if (index >= 0) records[index] = records[index] with { Status = VoiceConsentStatus.Deleted, DeletedAt = DateTimeOffset.UtcNow };
        return Task.CompletedTask;
    }
    public Task WithdrawAsync(string recordId, CancellationToken ct)
    { Guard(ct); operations.RemoveAll(operation => operation.RecordId == recordId); return Task.CompletedTask; }
    public Task SaveAsync(VoiceConsentRecord record, CancellationToken ct) { Guard(ct); records.Add(record); return Task.CompletedTask; }
    public Task RemoveSpeakerAsync(CancellationToken ct) { Guard(ct); return Task.CompletedTask; }
}
#endif
