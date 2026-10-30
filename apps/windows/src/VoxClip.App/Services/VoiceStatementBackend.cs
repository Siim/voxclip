using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.Services;

internal sealed class VoiceStatementBackend : IVoiceCreationBackend
{
    private readonly DataLocations data;
    private readonly Func<bool> enabled;
    private readonly Func<string?> plan;
    private readonly Func<bool> speakerAvailable;
    private readonly Func<CancellationToken, Task> consent;
    private readonly VoiceConsentStore store;
    private readonly VoiceConsentText text;
    private readonly Dictionary<string, string[]> words;
    private readonly VoiceLabPriceCatalog prices;
    private readonly ElevenLabsVoiceLab client;
    private readonly ElevenLabsTranscriber transcriber;
    private readonly VoiceEnrollment enrollment;
    private readonly TimeProvider clock;
    private readonly Func<VoiceConsentStatement, TranscriptionRequest, CancellationToken, Task<RawTranscript>>? transcribe;
    private VoiceConsentStatement? verifying;
    private double seconds;
    private IReadOnlyList<VoiceTrainingSample> training = [];

    internal VoiceStatementBackend(DataLocations data, IKeyProvider keys, ILog log, ElevenLabsRegion region,
        Func<bool> enabled, Func<string?> plan, Func<CancellationToken, Task> consent, TimeProvider? clock = null,
        Func<bool>? speakerAvailable = null,
        Func<VoiceConsentStatement, TranscriptionRequest, CancellationToken, Task<RawTranscript>>? transcribe = null)
    {
        this.data = data; this.enabled = enabled; this.plan = plan; this.consent = consent;
        this.clock = clock ?? TimeProvider.System;
        this.speakerAvailable = speakerAvailable ?? (() => VoiceSpeakerCheck.Unavailable.Available);
        this.transcribe = transcribe;
        var shared = SharedResources.ResolveRoot();
        text = JsonSerializer.Deserialize<VoiceConsentText>(File.ReadAllBytes(Path.Combine(shared, "voice-lab", "statements.json")), new JsonSerializerOptions(JsonSerializerDefaults.Web))
            ?? throw new VoiceConsentException(VoiceConsentError.InvalidWords);
        words = new[] { "en", "et" }.ToDictionary(language => language,
            language => File.ReadAllText(Path.Combine(shared, "voice-lab", "nonce-words-" + language + ".txt")).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        prices = VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(shared, "catalog", "voice-lab.json")));
        store = new(data, clock);
        client = new(keys, region, log);
        transcriber = new(keys, region, logger: log);
        enrollment = new(store, client, ScribeAsync, clock: clock);
    }

    public bool Enabled => enabled();
    public bool SpeakerAvailable => speakerAvailable();
    public string? PlanMessage => plan();
    public string VerificationCost => VoiceLabCostPresentation.Kind(VoiceLabPricing.Estimate(
        VoiceLabPricedOperation.ElevenLabsSpeechToText, "scribe_v2", seconds, 1, null, prices), false, "ElevenLabs").Text;
    private void Require(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Enabled || !SpeakerAvailable || PlanMessage is not null) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
    }
    public VoiceConsentStatement Statement(string name, string language, DateOnly date) => text.Statement(name, language, date, words[language]);
    public Task SaveStatementAsync(string recordId, MicrophoneTake take, CancellationToken ct)
    {
        Require(ct);
        if (take.Rate is < 8000 or > 192000 || take.Mono.LongLength < 5L * take.Rate || take.Mono.LongLength > 30L * take.Rate)
            throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
        var samples = VoiceConsentAudio.Resample(take.Mono, take.Rate, 48000);
        try
        {
            Require(ct);
            var wav = VoiceTrainingAudio.Wav(samples);
            try { store.SaveStatement(wav, recordId); seconds = samples.Length / 48000.0; }
            finally { Array.Clear(wav); }
            Require(ct);
        }
        finally { Array.Clear(samples); }
        return Task.CompletedTask;
    }
    public async Task VerifyAsync(string recordId, VoiceConsentStatement statement, VoiceConsentAttestations attestations, CancellationToken ct)
    {
        Require(ct);
        if (statement.Language != "en") throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        if (!attestations.Complete) throw new VoiceConsentException(VoiceConsentError.AttestationsRequired);
        await consent(ct).ConfigureAwait(false);
        Require(ct);
        var wav = store.Statement(recordId);
        verifying = statement;
        try { await enrollment.VerifyAsync(recordId, statement, wav, attestations, true, Enabled, ct).ConfigureAwait(false); Require(ct); }
        finally { verifying = null; Array.Clear(wav); }
    }
    private async Task<RawTranscript> ScribeAsync(byte[] wav, string language, CancellationToken ct)
    {
        var directory = Path.Combine(data.Cache, "voice-consent", Guid.NewGuid().ToString("D"));
        try
        {
            Require(ct);
            var pcm = VoiceConsentAudio.Pcm16k(wav);
            byte[] converted;
            try { converted = VoiceTrainingAudio.Wav(pcm, 16000); }
            finally { Array.Clear(pcm); }
            var path = Path.Combine(directory, "verify.wav");
            var frames = VoiceConsentAudio.ValidateWav(converted).Frames;
            try
            {
                if (OperatingSystem.IsWindows()) Directory.CreateDirectory(directory);
                else Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                await File.WriteAllBytesAsync(path, converted, ct).ConfigureAwait(false);
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            finally { Array.Clear(converted); }
            var request = new TranscriptionRequest(new(TranscriptEngine.Elevenlabs, "scribe_v2", new LanguageChoice.Forced(language), new(Diarize: false)),
                new(path, frames, seconds, 0, 0), "voice-consent-" + Guid.NewGuid().ToString("N"));
            Require(ct);
            return transcribe is { } selected ? await selected(verifying!, request, ct).ConfigureAwait(false)
                : await transcriber.TranscribeAsync(request, new Progress<TranscriptionProgress>(), ct).ConfigureAwait(false);
        }
        finally
        {
            Array.Clear(wav);
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }
    public Task AbandonAsync(string recordId)
    {
        enrollment.Cancel(recordId);
        seconds = 0; training = [];
        return Task.CompletedTask;
    }
    public bool CreationPending => store.Operations().Any(operation => operation.BlocksCreation(clock.GetUtcNow()));
    public Task SaveTrainingAsync(MicrophoneTake take, CancellationToken ct)
    {
        Require(ct); training = [];
        var samples = VoiceConsentAudio.Resample(take.Mono, take.Rate, 48000);
        try { training = VoiceTrainingAudio.ReadAloud(samples); Require(ct); }
        finally { Array.Clear(samples); }
        return Task.CompletedTask;
    }
    public async Task<VoiceCreationQuote> PrepareCreationAsync(string recordId, string name, CancellationToken ct)
    {
        Require(ct);
        var quote = await enrollment.PrepareAsync(recordId, name, training, Enabled, ct).ConfigureAwait(false);
        return new(VoiceLabCostPresentation.Kind(quote.Estimate.ToCostEstimate(), false, "ElevenLabs"), quote);
    }
    public bool QuoteIsFresh(VoiceCreationQuote quote) => quote.Ticket is VoiceLabPreparedAction action && client.QuotesAreFresh([action]);
    public async Task<VoiceConsentRecord> CreateAsync(VoiceCreationQuote quote, CancellationToken ct)
    {
        Require(ct);
        if (!QuoteIsFresh(quote)) throw new VoiceCreationExpiredException();
        var subscription = await client.DiscoverSubscriptionAsync(ct).ConfigureAwait(false);
        Require(ct);
        if (!subscription.CanClone) throw new VoiceLabException(VoiceLabErrorKind.PlanUnavailable);
        if (subscription.VoiceSlotsUsed >= subscription.VoiceLimit) throw new VoiceLabException(VoiceLabErrorKind.NoVoiceSlots);
        if (!QuoteIsFresh(quote)) throw new VoiceCreationExpiredException();
        return await enrollment.CreateAsync((VoiceLabPreparedAction)quote.Ticket, true, Enabled, typeof(VoiceStatementBackend).Assembly.GetName().Version?.ToString() ?? "unknown", ct).ConfigureAwait(false);
    }
    public async Task SaveCreationRecordAsync(VoiceConsentRecord record, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested(); store.Save(record);
        var reconciler = new VoiceOperationReconciler(store, _ => client, clock);
        foreach (var operation in store.Operations().Where(operation => operation.RecordId == record.RecordId && !operation.Finished))
            await reconciler.ReconcileAsync(operation.Id, true, ct).ConfigureAwait(false);
    }
    public void Dispose() { training = []; client.Dispose(); transcriber.Dispose(); }
}

internal sealed class VoiceStatementCapture(VoiceMicrophoneRecorder recorder) : IVoiceStatementCapture
{
    public Task StartAsync(CancellationToken ct) => recorder.StartAsync(30, ct);
    public Task StartTrainingAsync(CancellationToken ct) => recorder.StartAsync(90, ct);
    public Task Completion => recorder.Completion;
    public MicrophoneSnapshot Snapshot => recorder.Snapshot();
    public MicrophoneTake Stop() => recorder.Stop();
    public void Discard() => recorder.Discard();
    public ValueTask DisposeAsync() => recorder.DisposeAsync();
}
