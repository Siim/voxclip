#if DEBUG
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.Services;

internal sealed class DebugVoiceCreationBackend : IVoiceCreationBackend
{
    private readonly VoiceStatementBackend inner;
    private readonly DebugVoiceLabBackend client;
    private readonly VoiceConsentStore store;
    private readonly DataLocations data;
    private readonly string fixtures;
    private readonly TimeProvider clock;
    private readonly string scenario;
    private readonly DebugVoiceEmbedder embedder = new();
    private VoiceConsentStatement? statement;
    private VoiceConsentAttestations? attestations;
    private double trainingSeconds;
    private int creates, plans, saves;
    private string? lastRecordId;
    private sealed record Draft(string RecordId, string Name, long PreparedAt);
    internal DebugVoiceCreationBackend(VoiceStatementBackend inner, DebugVoiceLabBackend client, DataLocations data, string fixtures, TimeProvider? clock = null)
    {
        this.inner = inner; this.client = client; this.data = data; this.fixtures = fixtures; this.clock = clock ?? TimeProvider.System;
        store = new(data, clock);
        var path = Path.Combine(fixtures, "creation-scenario.json");
        using var configuration = File.Exists(path) ? JsonDocument.Parse(File.ReadAllBytes(path)) : null;
        scenario = configuration?.RootElement.GetProperty("scenario").GetString() ?? "ready";
        Receipt();
    }
    public bool Enabled => inner.Enabled;
    public bool SpeakerAvailable => inner.SpeakerAvailable;
    public bool SpeakerCalibrated(string language) => inner.SpeakerCalibrated(language);
    public string? PlanMessage => inner.PlanMessage;
    public string VerificationCost => inner.VerificationCost;
    public bool CreationPending => client.HasPendingCreation;
    public VoiceConsentStatement Statement(string name, string language, DateOnly date) => inner.Statement(name, language, date);
    public Task SaveStatementAsync(string recordId, MicrophoneTake take, CancellationToken ct) => inner.SaveStatementAsync(recordId, take, ct);
    public async Task VerifyAsync(string recordId, VoiceConsentStatement accepted, VoiceConsentAttestations assertions, CancellationToken ct)
    {
        await inner.VerifyAsync(recordId, accepted, assertions, ct);
        statement = accepted; attestations = assertions;
    }
    public Task SaveTrainingAsync(MicrophoneTake take, CancellationToken ct)
    {
        trainingSeconds = 0;
        var samples = VoiceConsentAudio.Resample(take.Mono, take.Rate, 48000);
        try
        {
            trainingSeconds = VoiceTrainingAudio.ReadAloud(samples).Sum(sample => sample.Seconds);
            Directory.CreateDirectory(data.Cache);
            File.WriteAllText(Path.Combine(data.Cache, "training-result.json"), JsonSerializer.Serialize(new { seconds = trainingSeconds, maximumSeconds = 90, httpCalls = 0 }));
        }
        finally { Array.Clear(samples); }
        ct.ThrowIfCancellationRequested(); return Task.CompletedTask;
    }
    public Task<VoiceProjectAudio> AnalyzeProjectAsync(VoiceTrainingProject project, CancellationToken ct) => inner.AnalyzeProjectAsync(project, ct);
    public Task<VoiceCreationQuote> PrepareCreationAsync(string recordId, string name, VoiceProjectAudio? project, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Enabled || !SpeakerAvailable || scenario == "speaker-unavailable") throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        if (!embedder.Matches(scenario == "speaker-mismatch")) throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);
        if (statement is null || (project is null ? trainingSeconds < 60 : project.Selection.SelectedMs < 30_000) || CreationPending)
            throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
        return Task.FromResult(new VoiceCreationQuote(new(VoiceLabCostPresentationKind.Inline, ""), new Draft(recordId, name, clock.GetTimestamp()),
            project is null ? null : new(project.Name, project.Selection.SelectedMs / 1000)));
    }
    public bool QuoteIsFresh(VoiceCreationQuote quote) => quote.Ticket is Draft draft && scenario != "expired" && clock.GetElapsedTime(draft.PreparedAt) < TimeSpan.FromMinutes(5);
    public async Task<VoiceConsentRecord> CreateAsync(VoiceCreationQuote quote, CancellationToken ct)
    {
        if (!QuoteIsFresh(quote)) throw new VoiceCreationExpiredException();
        plans++; await client.DiscoverSubscriptionAsync(false, ct);
        ct.ThrowIfCancellationRequested();
        if (!Enabled || !SpeakerAvailable) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        var draft = (Draft)quote.Ticket;
        lastRecordId = draft.RecordId;
        var template = JsonSerializer.Deserialize<VoiceConsentRecord>(File.ReadAllBytes(Path.Combine(fixtures, "consent-record.json")), new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        var record = template with { RecordId = draft.RecordId, VoiceName = draft.Name + " (VoxClip)", VoiceId = "fixture" + Guid.NewGuid().ToString("N"), CreatedAt = clock.GetUtcNow(),
            Status = scenario == "verification" ? VoiceConsentStatus.VerificationRequired : VoiceConsentStatus.Active,
            Statement = template.Statement with { Text = statement!.Text, Nonce = statement.Nonce.ToArray(), AudioSha256 = VoiceConsentStore.Hash(store.Statement(draft.RecordId)) }, Attestations = attestations! };
        creates++;
        if (scenario == "uncertain")
        {
            await inner.AbandonAsync(draft.RecordId);
            client.StageCreation(record, true); Receipt();
            throw new VoiceConsentException(VoiceConsentError.CreationPending);
        }
        client.StageCreation(record, false);
        if (scenario == "save-failure") { Receipt(); throw new VoiceConsentSaveException(record); }
        store.Save(record); client.CompleteCreation(record); Receipt(); return record;
    }
    public Task SaveCreationRecordAsync(VoiceConsentRecord record, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested(); saves++; store.Save(record); client.CompleteCreation(record); Receipt(); return Task.CompletedTask;
    }
    public async Task AbandonAsync(string recordId)
    {
        await inner.AbandonAsync(recordId);
        await client.WithdrawAsync(recordId, CancellationToken.None);
        Receipt();
    }
    private void Receipt()
    {
        Directory.CreateDirectory(data.Cache);
        File.WriteAllText(Path.Combine(data.Cache, "creation-result.json"), JsonSerializer.Serialize(new { scenario, recordId = lastRecordId, createCalls = creates, planChecks = plans, saveCalls = saves, httpCalls = 0 }));
    }
    public void Dispose() => inner.Dispose();
}

internal sealed class DebugVoiceEmbedder
{
    internal bool Matches(bool mismatch)
    {
        float[] owner = [1, 0];
        float[] candidate = mismatch ? [0, 1] : [1, 0];
        return SpeakerAudio.Cosine(owner, candidate) >= .8;
    }
}
#endif
