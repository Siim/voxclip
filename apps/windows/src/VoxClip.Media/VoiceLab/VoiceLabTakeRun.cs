using System.Collections.Frozen;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

/// <summary>The run's consent and speaker checks. <see cref="Voiced"/> gives a generated take's voiced speech at 16 kHz;
/// <see cref="Embedding"/> embeds voiced speech of at least one calibrated window (a long take's own, or a pooled group's).
/// <see cref="Screen"/> is the guard's free verdict on every phrase before any price (<see cref="VoiceUseGuard.ScreenAsync"/>); null leaves
/// every phrase unchecked.</summary>
internal sealed record VoiceLabTakeRunChecks(Action<VoiceConsentRecord> Validate,
    Func<VoiceConsentRecord, float[], VoiceLabPreparedAction, VoiceLabDispatchBinding, long, CancellationToken, Task<OwnVoicePolicy>> Authorize,
    Func<float[], int, CancellationToken, Task<float[]>> Voiced, Func<float[], CancellationToken, Task<float[]>> Embedding,
    Func<string, string, IReadOnlyList<float[]>, CancellationToken, Task<IReadOnlyList<VoiceGuardVerdict>>>? Screen = null);

public sealed class VoiceLabTakeRun : IVoiceLabTakeRunner
{
    private sealed record Pending(VoiceLabTakeRunQuote Quote, VoiceLabTakeInput Input, VoiceConsentRecord Record,
        VoiceLabTakePreflight Preflight, VoiceLabSourceExcerpt Source, float[] Speech, long ModelRevision, long Revision, VoiceLabDispatchBinding Binding,
        VoiceLabDispatchBinding AcceptanceBinding, IReadOnlyList<VoiceLabAuthorization>? ApprovedAhead = null)
    {
        /// <summary>The journal entry take 0 adopts (<see cref="VoiceLabTakeQuote.AdoptedAsset"/>), claimed for this run since prepare.</summary>
        public VoiceLabTakeJournalEntry? Adopted { get; init; }
    }
    private readonly object sync = new();
    private readonly ElevenLabsVoiceLab client;
    private readonly VoiceConsentStore store;
    private readonly VoiceLabTakeStorage storage;
    private readonly VoiceLabTakeRunChecks checks;
    private readonly VoiceLabDispatchGate inputGate;
    private readonly VoiceLabDispatchGate preparationGate = new();
    private readonly Func<CancellationToken, Task<bool>> inputsAreCurrent;
    private readonly Dictionary<Guid, VoiceLabTakeScratch> scratches = [];
    private readonly Dictionary<Guid, VoiceLabAsset> paidAssets = [];
    private readonly Dictionary<Guid, (VoiceLabTakeRow Row, Pending Input)> acceptedRows = [];
    /// <summary>The journal assets (voice-lab §3 "Paid takes are kept") this run made or adopted, which it never adopts again, and
    /// this run's claim on them and on the one its prepared set reserves (<see cref="VoiceLabTakeJournalClaims"/>).</summary>
    private readonly HashSet<string> journalAssets = new(StringComparer.Ordinal);
    private readonly Guid claimOwner = Guid.NewGuid();
    /// <summary>Set once this run dropped its project's finished journal entries (<see cref="VoiceLabTakeJournal.Settle"/>).</summary>
    private bool journalSettled;
    private Pending? pending;
    private Guid? owner;
    private bool preparing;
    private long revision;
    private CancellationTokenSource? running;
    private VoiceLabTakeRunEnd stop = VoiceLabTakeRunEnd.Cancelled;
    internal Func<string, Task>? Suspension { get; set; }
    /// <summary>Automatic fixes (voice-lab.md §8.2.2): a new run keeps the earlier takes' checked audio beside its own, so a
    /// paid take is never replaced. Off, each run starts from no takes, as before.</summary>
    public bool KeepsEarlierTakes { get; set; }
    /// <summary>ADR-R37: the Rewrite plan's generated speech and mismatches, shared by every phrase's run.</summary>
    public VoiceLabVoiceCheckSession VoiceChecks { get; set; } = new();
    /// <summary>The approved batch's pool, which the caller finishes after the batch's last phrase; null, each run pools and
    /// checks its own short takes at its end, borrowing earlier speech of <see cref="PhraseId"/> first.</summary>
    public VoiceLabShortTakePool? ShortTakePool { get; set; }
    public int? PhraseId { get; set; }
    /// <summary>The free on-device fallback of timing recovery (voice-lab §8.5); null leaves only the take's Scribe word check.</summary>
    public VoiceLabLocalTiming? LocalTiming { get; set; }
    /// <summary>Reports the durable paid take before timing recovery or word checks start.</summary>
    public Func<Guid, string, decimal?, Task>? PaidAudioSaved { get; set; }
    public VoiceLabTakeRun(ElevenLabsVoiceLab client, VoiceConsentStore store, VoiceSpeakerCheck speaker,
        VoiceLabTakeStorage storage, VoiceLabDispatchGate inputGate, Func<CancellationToken, Task<bool>> inputsAreCurrent)
        : this(client, store, storage, inputGate, inputsAreCurrent, ProductionChecks(store, speaker)) { }
    internal VoiceLabTakeRun(ElevenLabsVoiceLab client, VoiceConsentStore store, VoiceLabTakeStorage storage,
        VoiceLabDispatchGate inputGate, Func<CancellationToken, Task<bool>> inputsAreCurrent, VoiceLabTakeRunChecks checks)
    { this.client = client; this.store = store; this.storage = storage; this.inputGate = inputGate; this.inputsAreCurrent = inputsAreCurrent; this.checks = checks; }
    ~VoiceLabTakeRun() => VoiceLabTakeJournalClaims.ReleaseAll(claimOwner);
    private static VoiceLabTakeRunChecks ProductionChecks(VoiceConsentStore store, VoiceSpeakerCheck speaker)
    {
        var guard = new VoiceUseGuard(store, speaker);
        return new(record =>
        {
            speaker.ValidateAvailability();
            if (!speaker.Supports(record.Language) || speaker.ModelId != record.Speaker.Model || speaker.Threshold != record.Speaker.Threshold)
                throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        }, (record, speech, quote, binding, model, ct) => guard.AuthorizeAsync("take:" + VoiceConsentStore.Hash(System.Runtime.InteropServices.MemoryMarshal.AsBytes(speech.AsSpan()).ToArray()),
            record.RecordId, speech, quote, true, ct: ct, binding: binding, modelRevision: model),
            (samples, rate, ct) => speaker.GeneratedVoicedAsync(samples, rate, ct), (voiced, ct) => speaker.VoicedEmbeddingAsync(voiced, ct),
            (contentKey, recordId, speech, ct) => guard.ScreenAsync(contentKey, recordId, speech, ct));
    }
    /// <summary>The guard's free verdict on each of these phrases before any price (voice-lab.md §6.9, ADR-R41; Mac <c>screenGuard</c>), on
    /// the same speech the run's own guard reads at dispatch (<see cref="GuardSpeech"/>). Phrases that pass against the record's own
    /// embedding teach this project's reference first. Nothing is sent anywhere. Phrases of different voices or videos, or a phrase whose
    /// speech can't be read, are unchecked.</summary>
    public async Task<IReadOnlyList<VoiceGuardVerdict>> ScreenGuardAsync(IReadOnlyList<VoiceLabTakeInput> inputs, CancellationToken ct = default)
    {
        var none = inputs.Select(_ => VoiceGuardVerdict.Unchecked).ToArray();
        if (inputs.Count == 0 || checks.Screen is not { } screen ||
            inputs.Any(input => input.RecordId != inputs[0].RecordId || input.ContentKey != inputs[0].ContentKey)) return none;
        var speech = new float[inputs.Count][];
        for (var index = 0; index < inputs.Count; index++)
        {
            ct.ThrowIfCancellationRequested();
            try { speech[index] = GuardSpeech(inputs[index].Snapshot()); }
            catch (Exception error) when (error is VoiceLabException or VoiceConsentException or ArgumentException) { speech[index] = []; }
        }
        var verdicts = await screen(inputs[0].ContentKey, inputs[0].RecordId, speech, ct).ConfigureAwait(false);
        return verdicts.Count == inputs.Count ? verdicts : none;
    }
    internal Guid? PreparedSetId { get { lock (sync) return pending?.Quote.Id; } }
    public VoiceLabTakeScratch? Scratch(Guid id) { lock (sync) return scratches.GetValueOrDefault(id); }
    public VoiceLabAsset? PaidAsset(Guid id) { lock (sync) return paidAssets.GetValueOrDefault(id); }
    public async Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default)
    {
        long version;
        VoiceLabDispatchBinding binding;
        VoiceLabDispatchBinding acceptanceBinding;
        VoiceLabTakeRunQuote? retired;
        VoiceLabTakeJournalEntry? retiredAdoption;
        lock (sync)
        {
            if (preparing || owner.HasValue) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            preparing = true;
            version = revision;
            acceptanceBinding = inputGate.Capture();
            binding = preparationGate.Capture(acceptanceBinding);
            retired = pending?.Quote; retiredAdoption = pending?.Adopted;
            pending = null;
        }
        ReleaseUnused(retiredAdoption);
        if (retired is not null) client.DiscardTakeRun(retired);
        var quotes = new List<VoiceLabTakeQuote>();
        var id = Guid.NewGuid();
        VoiceLabTakeJournalEntry? adopted = null;
        try
        {
            Check(version, binding, ct);
            ct.ThrowIfCancellationRequested();
            var snapshot = input.Snapshot();
            var record = store.Load(snapshot.RecordId);
            store.ValidateUse(record);
            checks.Validate(record);
            if (snapshot.Language != record.Language) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            if (!await inputsAreCurrent(ct).ConfigureAwait(false)) throw new VoiceLabRunInvalidatedException();
            Check(version, binding, ct);
            var preflight = VoiceLabTakeProcessing.Preflight(snapshot);
            // Each region is resampled on the whole track's 24 kHz grid, where staging reads it.
            var source = await Task.Run(() => VoiceLabSourceAudio.Resample(snapshot.Source, snapshot.SourceSampleRate, VoiceLabSourceAudio.TakeAssetRate), ct).ConfigureAwait(false);
            Check(version, binding, ct);
            var speech = GuardSpeech(snapshot);
            var model = client.ModelRevision;
            // A paid take over the same words, voice and model is adopted for free as the set's one take (voice-lab §3 "Paid
            // takes are kept"). Its synthesis is approved with the set, as the provider pairs each take's requests, and never sent.
            adopted = await ReserveAdoptionAsync(snapshot, record, ct).ConfigureAwait(false);
            for (var index = 0; index < (adopted is null ? 3 : 1); index++)
            {
                var options = snapshot.Options(index);
                var review = new OwnVoicePolicy(record.RecordId, record.VoiceId, true, true, record.ConsentMethod == VoiceConsentMethod.RecordedStatement, true, true)
                    { ConsentMethod = record.ConsentMethod };
                var synthesis = client.PrepareSynthesis(snapshot.RequestText, snapshot.ModelId, VoiceLabVoiceChoice.Own(record.VoiceId, review), snapshot.Language, options, Guid.NewGuid());
                try { quotes.Add(new(index, options.Seed, synthesis, client.PrepareQa(snapshot.Language, record.RecordId, Guid.NewGuid(), snapshot.HasRequestTags)) { AdoptedAsset = adopted?.AssetFile }); }
                catch { client.DiscardTakeRun(new(id, [new(index, options.Seed, synthesis, synthesis)])); throw; }
            }
            var quote = new VoiceLabTakeRunQuote(id, quotes);
            if (!await inputsAreCurrent(ct).ConfigureAwait(false)) throw new VoiceLabRunInvalidatedException();
            Check(version, binding, ct);
            if (client.ModelRevision != model) throw new VoiceLabRunInvalidatedException();
            lock (sync)
            {
                Check(version, binding, ct);
                pending = new(quote, snapshot, record, preflight, source, speech, model, version, binding, acceptanceBinding) { Adopted = adopted };
            }
            return quote;
        }
        catch
        {
            if (quotes.Count > 0) client.DiscardTakeRun(new(id, quotes));
            ReleaseUnused(adopted);
            throw;
        }
        finally { lock (sync) preparing = false; }
    }
    /// <summary>The newest journal entry over <paramref name="input"/>'s words, voice, model and context that no live run holds and
    /// this run never made or adopted, claimed for this run; null when there is none.</summary>
    private async Task<VoiceLabTakeJournalEntry?> ReserveAdoptionAsync(VoiceLabTakeInput input, VoiceConsentRecord record, CancellationToken ct)
    {
        var key = VoiceLabTakeJournalKey.Of(input, record.VoiceId);
        HashSet<string> excluded;
        lock (sync) excluded = new(journalAssets, StringComparer.Ordinal);
        excluded.UnionWith(VoiceLabTakeJournalClaims.Claimed(storage.PaidRoot, claimOwner));
        bool settle;
        lock (sync) { settle = !journalSettled; journalSettled = true; }
        // Windows has no retention pass: the entries this project is done with (aged out, or their asset gone) go before the first
        // adoption. Dropping the entries of assets the project uses is the project close's (Settle with its references).
        if (settle) await Task.Run(() => VoiceLabTakeJournal.Settle(storage.ProjectId, storage.PaidRoot, FrozenSet<string>.Empty, DateTimeOffset.UtcNow), ct).ConfigureAwait(false);
        // Another run may claim the same entry meanwhile: the next newest is tried, a few times at most.
        for (var attempt = 0; attempt < 4; attempt++)
        {
            var skip = excluded.ToFrozenSet(StringComparer.Ordinal);
            var found = await Task.Run(() => VoiceLabTakeJournal.Match(key, storage.ProjectId, storage.PaidRoot, skip,
                forSelectedVoice: !input.ChecksGeneratedSpeaker, createdAfter: input.RecoverTakesAfter), ct).ConfigureAwait(false);
            if (found is null) return null;
            if (VoiceLabTakeJournalClaims.Claim(VoiceLabTakeJournalClaims.Key(found.AssetFile, storage.PaidRoot), claimOwner)) return found;
            excluded.Add(found.AssetFile);
        }
        return null;
    }
    /// <summary>Lets another run adopt <paramref name="entry"/> again when this run reserved it and never used it.</summary>
    private void ReleaseUnused(VoiceLabTakeJournalEntry? entry)
    {
        if (entry is null) return;
        lock (sync) if (journalAssets.Contains(entry.AssetFile) || pending?.Adopted?.AssetFile == entry.AssetFile) return;
        VoiceLabTakeJournalClaims.Release(VoiceLabTakeJournalClaims.Key(entry.AssetFile, storage.PaidRoot), claimOwner);
    }
    /// <summary>Pins exactly this window's prepared set for a batch approval, without sending anything.</summary>
    public Task ApproveAsync(VoiceLabTakeRunQuote quote)
    {
        lock (sync)
        {
            if (preparing || owner.HasValue || pending is not { } value || !ReferenceEquals(value.Quote, quote) || value.ApprovedAhead is not null)
                throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            pending = value with { ApprovedAhead = client.ApproveTakeRun(quote, true) };
        }
        return Task.CompletedTask;
    }
    public Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
    {
        if (!approved) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        return ExecuteWithDispatchAsync(quote, new((_, _) => Task.CompletedTask, action => action()), progress, ct);
    }
    public async Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
    {
        Pending value;
        Guid execution;
        CancellationTokenSource cancellation;
        lock (sync)
        {
            if (preparing || owner.HasValue || pending is not { } prepared || !ReferenceEquals(quote, prepared.Quote))
                throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            value = prepared;
            pending = null;
            execution = Guid.NewGuid();
            owner = execution;
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(ct);
            running = cancellation;
            stop = VoiceLabTakeRunEnd.Cancelled;
        }
        var token = cancellation.Token;
        var transportStarted = false;
        var retainQuote = false;
        Task launchCleanup = Task.CompletedTask;
        async Task RetireAsync(VoiceLabTakeScratch[] retired)
        {
            await Task.WhenAll(retired.Select(scratch => scratch.InvalidateAsync())).ConfigureAwait(false);
            if (progress is not null) await progress(Array.Empty<VoiceLabTakeRow>()).ConfigureAwait(false);
        }
        dispatch = dispatch.WithStart(action =>
        {
            lock (sync)
            {
                Check(value.Revision, value.Binding, token);
                if (!transportStarted && value.ApprovedAhead is null && !client.QuotesAreFresh(quote.Actions)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
                action();
                if (!transportStarted)
                {
                    transportStarted = true;
                    value = value with { Revision = ++revision };
                    if (!KeepsEarlierTakes)
                    {
                        // Earlier sets' takes go; never this set's own: an adopted take's first dispatch is its word check,
                        // after its audio is staged.
                        var own = quote.Takes.Select(take => take.Synthesis.Review.RequestId).ToHashSet();
                        var retired = scratches.Where(pair => !own.Contains(pair.Key)).ToArray();
                        foreach (var (key, _) in retired) scratches.Remove(key);
                        foreach (var key in acceptedRows.Keys.Where(key => !own.Contains(key)).ToArray()) acceptedRows.Remove(key);
                        launchCleanup = RetireAsync(retired.Select(pair => pair.Value).ToArray());
                    }
                }
            }
        });
        try
        {
            await Checkpoint("clock", value, token).ConfigureAwait(false);
            if (value.ApprovedAhead is null && !client.QuotesAreFresh(quote.Actions)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            await ValidateAsync(value, token).ConfigureAwait(false);
            await Checkpoint("validation", value, token).ConfigureAwait(false);
            await dispatch.AuthorizeAsync(quote.Takes[0].Synthesis.Review.RequestId, token).ConfigureAwait(false);
            var approvals = value.ApprovedAhead?.Select(approval => approval.ForDispatch(dispatch)).ToArray()
                ?? client.ApproveTakeRun(quote, dispatch);
            await Checkpoint("approval", value, token).ConfigureAwait(false);
            await Checkpoint("launch", value, token).ConfigureAwait(false);
            var shared = ShortTakePool;
            var pool = value.Input.ChecksGeneratedSpeaker ? shared ?? new VoiceLabShortTakePool(VoiceChecks, PhraseId) : null;
            var report = progress ?? (_ => Task.CompletedTask);
            var result = await PerformAsync(() => value, approvals, report, () => transportStarted, () => launchCleanup, pool, token).ConfigureAwait(false);
            if (shared is not null || pool is null) return result;
            // A run of its own checks its short takes at its end, Stop included, over the completed ones.
            var checkedRows = await pool.FinishAsync().ConfigureAwait(false);
            if (checkedRows.Count == 0) return result;
            ApplyVoiceChecks(checkedRows);
            var rows = result.Rows.Select(row => checkedRows.GetValueOrDefault(row.Id) ?? row).ToArray();
            await report(Array.AsReadOnly(rows)).ConfigureAwait(false);
            return new(Array.AsReadOnly(rows), result.End) { Failure = result.Failure };
        }
        catch (VoiceLabConfirmationRequiredException) { retainQuote = !transportStarted; throw; }
        finally
        {
            try { await launchCleanup.ConfigureAwait(false); }
            finally
            {
                if (!retainQuote) client.DiscardTakeRun(quote);
                else client.ReleaseTakeRun(quote);
                lock (sync)
                {
                    if (retainQuote && revision == value.Revision && client.QuotesAreFresh(quote.Actions)) pending = value with { ApprovedAhead = null };
                    if (owner == execution) { owner = null; running = null; }
                }
                ReleaseUnused(value.Adopted);
                cancellation.Dispose();
            }
        }
    }
    /// <summary>ADR-R37: the pooled check's verdicts replace this run's waiting takes, so acceptance publishes the checked row.</summary>
    public void ApplyVoiceChecks(IReadOnlyDictionary<Guid, VoiceLabTakeRow> checkedRows)
    {
        lock (sync)
            foreach (var id in acceptedRows.Keys.Where(checkedRows.ContainsKey).ToArray())
                acceptedRows[id] = (checkedRows[id], acceptedRows[id].Input);
    }
    /// <summary>The voice check before a verdict is used: current inputs and model, the speaker model and the consent record.
    /// Unlike <see cref="ValidateAsync"/> it survives Stop, which drains the pooled check over completed takes.</summary>
    private async Task ValidateVoiceAsync(Pending value, CancellationToken ct)
    {
        if (!await inputsAreCurrent(ct).ConfigureAwait(false) || client.ModelRevision != value.ModelRevision) throw new VoiceLabRunInvalidatedException();
        checks.Validate(value.Record);
        store.ValidateUse(value.Record);
    }
    private async Task<VoiceLabTakeRunResult> PerformAsync(Func<Pending> current, IReadOnlyList<VoiceLabAuthorization> approvals,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task> progress, Func<bool> hasStarted, Func<Task> launchCleanup, VoiceLabShortTakePool? pool, CancellationToken ct)
    {
        var rows = new List<VoiceLabTakeRow>();
        foreach (var take in current().Quote.Takes)
        {
            var value = current();
            VoiceLabAudioResult? generated = null;
            VoiceLabReceipt? qaReceipt = null;
            VoiceLabTakeAudio? audio = null;
            var synthesisAccepted = new VoiceLabRequestAcceptance();
            var qaAccepted = new VoiceLabRequestAcceptance();
            // An adopted take's synthesis is approved and never sent: the row counts it, at no charge, so the set's progress adds up.
            IReadOnlySet<Guid> adoptedRequest = take.AdoptedAsset is null ? System.Collections.Frozen.FrozenSet<Guid>.Empty
                : new[] { take.Synthesis.Review.RequestId }.ToFrozenSet();
            // The take's one approved Scribe request (its word check), on the given samples. An adopted take's first dispatch is
            // this one, which moves the run's revision on, so the run's state is read again after it.
            async Task<VoiceLabQaTranscript> WordCheckAsync(float[] samples, int rate)
            {
                await ValidateAsync(value, ct).ConfigureAwait(false);
                var qaPolicy = await checks.Authorize(value.Record, value.Speech, take.Qa, value.Binding, value.ModelRevision, ct).ConfigureAwait(false);
                await Checkpoint("qaAuthorization", value, ct).ConfigureAwait(false);
                var transcript = await client.TranscribeQaAsync(samples, rate, value.Input.Language, qaPolicy, approvals[take.Index * 2 + 1], ct, qaAccepted, value.Input.HasRequestTags).ConfigureAwait(false);
                await launchCleanup().ConfigureAwait(false);
                value = current();
                return transcript;
            }
            try
            {
                await ValidateAsync(value, ct).ConfigureAwait(false);
                // An adopted take passes the same consent, record and speaker guard as a paid one before its audio is used.
                var policy = await checks.Authorize(value.Record, value.Speech, take.Synthesis, value.Binding, value.ModelRevision, ct).ConfigureAwait(false);
                await Checkpoint("authorization", value, ct).ConfigureAwait(false);
                VoiceLabAsset paid;
                if (take.AdoptedAsset is { } adoptedAsset)
                {
                    if (value.Adopted is not { } entry || entry.AssetFile != adoptedAsset) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
                    (generated, paid) = await AdoptAsync(entry, take.Synthesis.Review.RequestId).ConfigureAwait(false);
                }
                else
                {
                    try
                    {
                        generated = await client.SynthesizeAsync(value.Input.RequestText, value.Input.ModelId, VoiceLabVoiceChoice.Own(value.Record.VoiceId, policy),
                            value.Input.Language, value.Input.Options(take.Index), approvals[take.Index * 2], ct, take.Synthesis.Review.RequestId, synthesisAccepted).ConfigureAwait(false);
                    }
                    catch (VoiceLabException error) when (error.Kind is VoiceLabErrorKind.InvalidAlignment or VoiceLabErrorKind.MalformedResponse &&
                        synthesisAccepted.UnalignedAudio is not null)
                    {
                        // The paid PCM decoded but its timing or segment metadata did not validate: recover its timing below.
                        generated = synthesisAccepted.UnalignedAudio;
                    }
                    await launchCleanup().ConfigureAwait(false);
                    value = current();
                    if (Suspension is { } afterSynthesis) await afterSynthesis("synthesis").ConfigureAwait(false);
                    paid = await PreservePaidAudioAsync(generated, take.Synthesis.Review.RequestId, value, take).ConfigureAwait(false);
                }
                await ValidateAsync(value, ct).ConfigureAwait(false);
                // §8.5 timing recovery: a take whose provider timing does not map to its words is retimed from its own word
                // check (the approved Scribe request, used once) or, failing that, on device. No new paid request.
                IReadOnlyList<VoiceLabWord>? heard = null;
                VoiceLabTakeAnalysis analysis;
                try
                {
                    if (generated.Alignment is null) throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
                    analysis = VoiceLabTakeProcessing.Process(generated, value.Input, value.Preflight, matchTone: true);
                }
                catch (Exception error) when (IsTimingFailure(error))
                {
                    var samples = Samples(generated);
                    var recovered = await WordCheckAsync(samples, 24000).ConfigureAwait(false);
                    qaReceipt = recovered.Receipt;
                    heard = recovered.Words;
                    IReadOnlyList<VoiceLabCharacterTiming> timing;
                    try { timing = await RecoverTimingAsync(recovered.Words, samples, value.Input, ct).ConfigureAwait(false); }
                    catch (VoiceLabException) when (!ct.IsCancellationRequested)
                    {
                        // What the take says can't be lined up with the text: its audio fails this way every time.
                        await JournalChecksAsync(VoiceLabTakeJournalChecks.TimingUnrecovered, paid).ConfigureAwait(false);
                        throw;
                    }
                    generated = generated with { Alignment = timing };
                    // The journal keeps the recovered timing, so adopting this take later needs no recovery.
                    await JournalTimingAsync(timing, paid).ConfigureAwait(false);
                    analysis = VoiceLabTakeProcessing.Process(generated, value.Input, value.Preflight, matchTone: true);
                }
                var snapshot = await VoiceLabAssets.PreparePaidAsync(paid, storage.ProjectId, storage.PaidRoot, storage.ScratchRoot, ct).ConfigureAwait(false);
                VoiceLabTakeScratch? staged = null;
                try
                {
                    Check(value.Revision, value.Binding, ct);
                    var fitted = VoiceLabSilenceFit.Prepare(snapshot, paid, analysis.Fit, value.Input.Window, value.Input.SourceSampleRate, ct);
                    staged = VoiceLabTakeRenderer.Stage(fitted, analysis, value.Input, value.Source, storage.ScratchRoot, ct);
                    lock (sync)
                    {
                        Check(value.Revision, value.Binding, ct);
                        scratches.Add(take.Synthesis.Review.RequestId, staged);
                    }
                }
                catch
                {
                    if (staged is not null) await staged.InvalidateAsync().ConfigureAwait(false);
                    else await snapshot.InvalidateAsync().ConfigureAwait(false);
                    throw;
                }
                audio = staged.Audio;
                // ADR-R37: a take with three seconds of voiced speech keeps its own speaker check; a shorter one is checked for
                // words and acoustics now and waits for its run's pooled voice check.
                float[] voiced = [];
                double? score = null;
                if (pool is not null)
                {
                    float[]? vector = null;
                    try
                    {
                        voiced = await checks.Voiced(audio.Trimmed, audio.SampleRate, ct).ConfigureAwait(false);
                        if (voiced.Length >= SpeakerAudio.WindowSize) vector = await checks.Embedding(voiced, ct).ConfigureAwait(false);
                    }
                    catch (VoiceConsentException error) when (error.Kind == VoiceConsentError.SpeakerMismatch)
                    {
                        // Rejected by generated-speaker extraction: the paid Scribe request is skipped.
                        var failed = new VoiceLabTakeQaResult(null, VoiceLabLoudness.LufsJumpLu(audio.Mixed, audio.SampleRate, audio.Seams),
                            VoiceLabLoudness.SamplePeakDbfs(audio.Mixed), null, [VoiceLabTakeQaFailure.Speaker]);
                        pool.Measured(take.Synthesis.Review.RequestId, [], value.Record, PhraseId, passed: false);
                        await JournalChecksAsync(VoiceLabTakeJournalChecks.SpeakerFailed, paid).ConfigureAwait(false);
                        rows.Add(new(take.Synthesis.Review.RequestId, take.Index, take.Seed, generated.Receipt, Generated: generated, Quote: take, Audio: audio, Qa: failed)
                            { AdoptedAsset = take.AdoptedAsset, Accepted = adoptedRequest });
                        await progress(rows.AsReadOnly()).ConfigureAwait(false);
                        await ValidateAsync(value, ct).ConfigureAwait(false);
                        continue;
                    }
                    if (vector is not null)
                    {
                        var ownerVector = VoiceConsentRecord.DecodeEmbedding(value.Record.Speaker.Embedding) ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
                        score = SpeakerAudio.Cosine(ownerVector, vector);
                        pool.Measured(take.Synthesis.Review.RequestId, voiced, value.Record, PhraseId, score >= value.Record.Speaker.Threshold);
                    }
                }
                await ValidateAsync(value, ct).ConfigureAwait(false);
                string[] inside;
                // The recovered take's word check already ran on its own audio: every word it heard is the take's.
                if (heard is not null) inside = heard.Select(word => word.Text).ToArray();
                else
                {
                    var recognized = await WordCheckAsync(audio.Mixed, audio.SampleRate).ConfigureAwait(false);
                    qaReceipt = recognized.Receipt;
                    await ValidateAsync(value, ct).ConfigureAwait(false);
                    var lower = audio.PatchStart / (double)audio.SampleRate;
                    var upper = audio.PatchEnd / (double)audio.SampleRate;
                    inside = recognized.Words.Where(word => (word.Start + word.End) / 2 >= lower && (word.Start + word.End) / 2 < upper).Select(word => word.Text).ToArray();
                }
                var qa = VoiceLabTakeQuality.Evaluate(value.Input.Text, inside, audio.Mixed, audio.SampleRate, audio.Seams, score, value.Record.Speaker.Threshold,
                    audio.Seams.Select(seam => seam == audio.PatchStart).ToArray(), audio.SeamExcesses, value.Input.HasRequestTags,
                    VoiceLabTakeQuality.ReplacementWords(value.Input.Text, value.Input.Items, value.Input.Window))
                    with { OutputSpeakerCheckSkipped = !value.Input.ChecksGeneratedSpeaker };
                // Keep hard failures with the asset so adoption can apply the next run's policy.
                await JournalChecksAsync(VoiceLabTakeJournalChecks.Of(qa, value.Record.Speaker.Threshold), paid).ConfigureAwait(false);
                var rank = VoiceLabTakeQuality.Rank(audio.Fit, value.Input.Window.End - value.Input.Window.Start,
                    qa.TranscriptMatch ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput), VoiceLabLoudness.Flatness(audio.Trimmed, audio.SampleRate));
                var row = new VoiceLabTakeRow(take.Synthesis.Review.RequestId, take.Index, take.Seed, generated.Receipt, qaReceipt, generated, take, audio, qa, rank)
                    { VoiceCheck = qa.OutputSpeakerCheckSkipped ? VoiceLabTakeVoiceCheck.SelectedVoice :
                        score is null ? VoiceLabTakeVoiceCheck.Waiting : VoiceLabTakeVoiceCheck.PerTake, AdoptedAsset = take.AdoptedAsset, Accepted = adoptedRequest };
                rows.Add(row);
                lock (sync) { Check(value.Revision, value.Binding, ct); acceptedRows[row.Id] = (row, value); }
                if (pool is not null && score is null)
                {
                    var checkedValue = value;
                    pool.Append(new(row, voiced, PhraseId, value.Record, token => ValidateVoiceAsync(checkedValue, token), checks.Embedding));
                }
                await progress(rows.AsReadOnly()).ConfigureAwait(false);
                await ValidateAsync(value, ct).ConfigureAwait(false);
                // A short take whose words and acoustics pass ends the run too: its voice is the pool's to check, not more takes'.
                if (row.AutomaticallySelectable && row.Fits || row.PassesBeforeVoiceCheck) return new(rows.AsReadOnly(), VoiceLabTakeRunEnd.EarlyStop);
            }
            catch (VoiceLabConfirmationRequiredException) { throw; }
            catch (Exception error)
            {
                if (!hasStarted())
                {
                    // The guard judged this window before anything was sent: no retry changes its verdict, and a batch's other
                    // windows go on (voice-lab.md §6.9, ADR-R40; Mac guardSettles).
                    if (GuardSettles(error)) return new(rows.AsReadOnly(), VoiceLabTakeRunEnd.Blocked) { Failure = error };
                    if (error is VoiceConsentException or VoiceLabRunInvalidatedException) return new(rows.AsReadOnly(), End(error)) { Failure = error };
                    throw;
                }
                if (generated is null && synthesisAccepted.UnalignedAudio is { } decoded)
                {
                    // Preserve paid PCM independently of cancellation; failed metadata never enters QA or publication.
                    generated = decoded;
                    try { await PreservePaidAudioAsync(decoded, take.Synthesis.Review.RequestId, value, take).ConfigureAwait(false); }
                    catch (VoiceLabAssetStoreException) { /* Keep the original provider validation failure. */ }
                }
                value = current();
                HashSet<Guid> accepted = [];
                if (synthesisAccepted.Accepted) accepted.Add(take.Synthesis.Review.RequestId);
                if (qaAccepted.Accepted) accepted.Add(take.Qa.Review.RequestId);
                if (generated is not null) accepted.UnionWith(adoptedRequest);
                rows.Add(new(take.Synthesis.Review.RequestId, take.Index, take.Seed, generated?.Receipt, qaReceipt, generated, take, audio, Failure: error)
                    { Accepted = System.Collections.Frozen.FrozenSet.ToFrozenSet(accepted), AdoptedAsset = take.AdoptedAsset });
                await progress(rows.AsReadOnly()).ConfigureAwait(false);
                if (Fatal(error) || ct.IsCancellationRequested) return new(rows.AsReadOnly(), End(error));
                try { await ValidateAsync(value, ct).ConfigureAwait(false); }
                catch (Exception stopped) { return new(rows.AsReadOnly(), End(stopped)); }
            }
        }
        return new(rows.AsReadOnly(), VoiceLabTakeRunEnd.Completed);
    }
    /// <summary>Word timing for a take whose provider timing did not map to its words (voice-lab §8.5 "Timing recovery"; Mac
    /// <c>recoverTiming</c>): what its own word check heard, mapped to the typed words; then the on-device transcriber. The
    /// word check's words are then the take's word check, so its Scribe request is never sent twice.</summary>
    private async Task<IReadOnlyList<VoiceLabCharacterTiming>> RecoverTimingAsync(IReadOnlyList<VoiceLabWord> heard, float[] samples,
        VoiceLabTakeInput input, CancellationToken ct)
    {
        try
        {
            var timing = VoiceLabProviderTiming.Recovered(heard, input.RequestText);
            client.Note("voicelab speech timing recovered source=word_check words=" + heard.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));
            return timing;
        }
        catch (VoiceLabTimingFailure failure)
        {
            if (LocalTiming is not { } local)
            {
                client.Note("voicelab speech timing unrecovered " + failure.LogFields + " local=unavailable");
                throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
            }
            try
            {
                var words = await local(samples, 24000, input.Language, ct).ConfigureAwait(false);
                var timing = VoiceLabProviderTiming.Recovered(words, input.RequestText);
                client.Note("voicelab speech timing recovered source=on_device words=" + words.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));
                return timing;
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                client.Note("voicelab speech timing unrecovered " + failure.LogFields + " local=failed");
                throw new VoiceLabException(VoiceLabErrorKind.InvalidAlignment);
            }
        }
    }
    private static float[] Samples(VoiceLabAudioResult result)
    {
        if (result.SampleRate != 24000 || result.Pcm.Length == 0 || result.Pcm.Length % 2 != 0) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
        var samples = new float[result.Pcm.Length / 2];
        for (var index = 0; index < samples.Length; index++)
            samples[index] = System.Buffers.Binary.BinaryPrimitives.ReadInt16LittleEndian(result.Pcm.AsSpan(index * 2)) / 32768f;
        return samples;
    }
    private static bool IsTimingFailure(Exception error) => error is VoiceLabException { Kind: VoiceLabErrorKind.InvalidAlignment } ||
        error is VoiceLabGeometryException { Code: VoiceLabGeometryErrorCode.AlignmentMismatch or VoiceLabGeometryErrorCode.AlignmentUnavailable or VoiceLabGeometryErrorCode.InvalidWordTiming };
    /// <summary>Stores the paid PCM as the provider returned it, then its journal entry (voice-lab §3 "Paid takes are kept"), both
    /// flushed before any check that can fail, so neither a later failure nor a relaunch loses the take. A journal that can't be
    /// written leaves the take usable in this run and is logged.</summary>
    private async Task<VoiceLabAsset> PreservePaidAudioAsync(VoiceLabAudioResult result, Guid requestId, Pending value, VoiceLabTakeQuote take)
    {
        var key = VoiceLabTakeJournalKey.Of(value.Input, value.Record.VoiceId, take.Index);
        var seed = value.Input.Options(take.Index).Seed;
        var estimate = take.Synthesis.Estimate.Usd;
        var (paid, journaled) = await Task.Run(() =>
        {
            var asset = VoiceLabAssetStore.Write(result.Pcm, result.SampleRate, storage.ProjectId, Guid.NewGuid().ToString("D"), storage.PaidRoot, DateTimeOffset.UtcNow);
            try
            {
                VoiceLabTakeJournal.Write(VoiceLabTakeJournal.Create(asset, result, key, seed, estimate), storage.ProjectId, storage.PaidRoot);
                return (asset, true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException or VoiceLabAssetStoreException) { return (asset, false); }
        }, CancellationToken.None).ConfigureAwait(false);
        lock (sync) { paidAssets[requestId] = paid; journalAssets.Add(paid.File); }
        VoiceLabTakeJournalClaims.Claim(VoiceLabTakeJournalClaims.Key(paid.File, storage.PaidRoot), claimOwner);
        if (!journaled) client.Note("voicelab take journal unwritten");
        else if (PaidAudioSaved is { } saved)
        {
            try { await saved(result.Receipt.ActionId, value.Record.RecordId, estimate).ConfigureAwait(false); }
            catch (Exception error) when (error is not OutOfMemoryException) { client.Note("voicelab rewrite checkpoint unwritten"); }
        }
        return paid;
    }
    /// <summary>The journaled take's stored PCM as the take's audio, claimed by this run for good: no synthesis, nothing charged.</summary>
    private async Task<(VoiceLabAudioResult Result, VoiceLabAsset Asset)> AdoptAsync(VoiceLabTakeJournalEntry entry, Guid requestId)
    {
        lock (sync) journalAssets.Add(entry.AssetFile);
        var adopted = await Task.Run(() => VoiceLabTakeJournal.Adopt(entry, storage.ProjectId, storage.PaidRoot), CancellationToken.None).ConfigureAwait(false);
        lock (sync) paidAssets[requestId] = adopted.Asset;
        client.Note("voicelab take adopted timing=" + (entry.Alignment is null ? "none" : entry.Alignment.Recovered ? "recovered" : "provider"));
        return adopted;
    }
    private async Task JournalTimingAsync(IReadOnlyList<VoiceLabCharacterTiming> timing, VoiceLabAsset paid)
    {
        var updated = await Task.Run(() =>
        {
            try { VoiceLabTakeJournal.UpdateTiming(paid.File, timing, true, storage.ProjectId, storage.PaidRoot); return true; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException or VoiceLabAssetStoreException) { return false; }
        }, CancellationToken.None).ConfigureAwait(false);
        if (!updated) client.Note("voicelab take journal timing unwritten");
    }
    /// <summary>How the take did in its checks, in its journal entry (<see cref="VoiceLabTakeJournalChecks"/>), so a take whose audio
    /// fails them is never adopted by a later run. A pooled voice check's verdict is the group's and is not written.</summary>
    private async Task JournalChecksAsync(VoiceLabTakeJournalChecks checks, VoiceLabAsset paid)
    {
        var updated = await Task.Run(() =>
        {
            try { VoiceLabTakeJournal.UpdateChecks(paid.File, checks, storage.ProjectId, storage.PaidRoot); return true; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceLabException or VoiceLabAssetStoreException) { return false; }
        }, CancellationToken.None).ConfigureAwait(false);
        if (!updated) client.Note("voicelab take journal checks unwritten");
    }
    private async Task ValidateAsync(Pending value, CancellationToken ct)
    {
        Check(value.Revision, value.Binding, ct);
        var current = await inputsAreCurrent(ct).ConfigureAwait(false);
        await Checkpoint("inputs", value, ct).ConfigureAwait(false);
        if (!current || client.ModelRevision != value.ModelRevision) throw new VoiceLabRunInvalidatedException();
        await Checkpoint("model", value, ct).ConfigureAwait(false);
        checks.Validate(value.Record);
        await Checkpoint("speaker", value, ct).ConfigureAwait(false);
        store.ValidateUse(value.Record);
        await Checkpoint("consent", value, ct).ConfigureAwait(false);
        await Checkpoint("record", value, ct).ConfigureAwait(false);
    }
    private async Task Checkpoint(string name, Pending value, CancellationToken ct)
    {
        if (Suspension is { } hook) await hook(name).ConfigureAwait(false);
        Check(value.Revision, value.Binding, ct);
    }
    private void Check(long expected, VoiceLabDispatchBinding binding, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        lock (sync) if (revision != expected) throw new VoiceLabRunInvalidatedException();
        binding.Validate();
    }
    public Task DiscardPendingAsync()
    {
        VoiceLabTakeRunQuote? quote;
        VoiceLabTakeJournalEntry? reserved;
        lock (sync)
        {
            if (preparing || owner.HasValue) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            quote = pending?.Quote; reserved = pending?.Adopted; pending = null;
        }
        if (quote is not null) client.DiscardTakeRun(quote);
        ReleaseUnused(reserved);
        return Task.CompletedTask;
    }
    public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => client.QuotesAreFresh(quote.Actions);
    public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => client.RefreshMonthlyCapAsync(cap, ct);
    public Task<decimal?> ReadMonthlySpendAsync(VoiceLabMonthlyCap? fallback, CancellationToken ct = default) => client.ReadMonthlySpendAsync(ct);
    public void InvalidatePreparation()
    {
        VoiceLabTakeRunQuote? quote;
        VoiceLabTakeJournalEntry? reserved;
        lock (sync)
        {
            preparationGate.Invalidate();
            quote = pending?.Quote; reserved = pending?.Adopted; pending = null;
        }
        if (quote is not null) client.DiscardTakeRun(quote);
        ReleaseUnused(reserved);
    }
    public Task CancelAsync() => CancelAsync(false);
    public Task CancelAsync(bool keepingTakes) => StopAsync(VoiceLabTakeRunEnd.Cancelled, keepingTakes);
    /// <summary>Also lets other runs adopt the takes this run made or adopted: its plan is gone.</summary>
    public Task InvalidateAsync() => StopAsync(VoiceLabTakeRunEnd.Invalidated);
    private async Task StopAsync(VoiceLabTakeRunEnd reason, bool keepingTakes = false)
    {
        VoiceLabTakeScratch[] retired;
        VoiceLabTakeRunQuote? quote;
        VoiceLabTakeJournalEntry? reserved;
        CancellationTokenSource? cancellation;
        lock (sync)
        {
            stop = reason; revision++;
            if (!keepingTakes) inputGate.Invalidate();
            cancellation = running;
            quote = pending?.Quote; reserved = pending?.Adopted; pending = null;
            if (reason == VoiceLabTakeRunEnd.Invalidated) journalAssets.Clear();
            if (keepingTakes)
            {
                retired = [];
                foreach (var key in acceptedRows.Keys.ToArray())
                {
                    var row = acceptedRows[key];
                    acceptedRows[key] = (row.Row, row.Input with { Revision = revision });
                }
            }
            else { retired = scratches.Values.ToArray(); scratches.Clear(); acceptedRows.Clear(); }
        }
        try { cancellation?.Cancel(); }
        catch (ObjectDisposedException) { }
        if (quote is not null) client.DiscardTakeRun(quote);
        if (reason == VoiceLabTakeRunEnd.Invalidated) VoiceLabTakeJournalClaims.ReleaseAll(claimOwner);
        else ReleaseUnused(reserved);
        await Task.WhenAll(retired.Select(scratch => scratch.InvalidateAsync())).ConfigureAwait(false);
    }
    public async Task RejectAsync(Guid id)
    {
        VoiceLabTakeScratch? scratch;
        lock (sync) { scratches.Remove(id, out scratch); acceptedRows.Remove(id); }
        if (scratch is not null) await scratch.InvalidateAsync().ConfigureAwait(false);
    }
    public async Task<(VoiceLabFittedPublication Publication, VoiceConsentRecord Consent)> PublishForAcceptanceAsync(Guid id, DateTimeOffset date, CancellationToken ct = default)
    {
        VoiceLabTakeScratch scratch;
        (VoiceLabTakeRow Row, Pending Input) item;
        lock (sync)
        {
            if (!acceptedRows.TryGetValue(id, out item) || !item.Row.Selectable || !scratches.TryGetValue(id, out scratch!) || !scratch.IsValid)
                throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        }
        var acceptance = item.Input with { Binding = item.Input.AcceptanceBinding };
        await ValidateAsync(acceptance, ct).ConfigureAwait(false);
        // The chunk names the request that paid for the audio: the take's own, or an adopted take's earlier one.
        var request = item.Row.Receipt?.ActionId ?? id;
        var publication = scratch.Fitted.Publish(storage.ProjectId, Guid.NewGuid().ToString("D"), storage.PaidRoot, date, request.ToString("D"), item.Row.Seed, scratch.Audio.GainDb, scratch.Audio.TiltDbPerOctave, ct);
        await ValidateAsync(acceptance, ct).ConfigureAwait(false);
        if (!scratch.IsValid || item.Row.Receipt?.VoiceId != item.Input.Record.VoiceId) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        return (publication, item.Input.Record);
    }
    private VoiceLabTakeRunEnd End(Exception error)
    {
        lock (sync)
        {
            if (error is OperationCanceledException || error is VoiceLabException { Kind: VoiceLabErrorKind.Cancelled }) return stop;
            return error is VoiceLabRunInvalidatedException ? VoiceLabTakeRunEnd.Invalidated : VoiceLabTakeRunEnd.Fatal;
        }
    }
    /// <summary>The use-time guard's own refusals, which the same speech always repeats: not the voice owner, or too little of the patch
    /// speaker's speech to check.</summary>
    internal static bool GuardSettles(Exception error) =>
        error is VoiceConsentException { Kind: VoiceConsentError.VoiceOwnerMismatch or VoiceConsentError.SpeakerMismatch };
    private static bool Fatal(Exception error) => error is VoiceConsentException or VoiceCreatorMismatchException or OperationCanceledException or VoiceLabRunInvalidatedException ||
        error is VoiceLabException { Kind: VoiceLabErrorKind.Unauthorized or VoiceLabErrorKind.PermissionMissing or VoiceLabErrorKind.MissingKey or
            VoiceLabErrorKind.QuotaExceeded or VoiceLabErrorKind.ConsentRequired or VoiceLabErrorKind.SpeakerMismatch or VoiceLabErrorKind.Cancelled };

    /// <summary>The use-time guard's speech for this patch (voice-lab §6.9, ADR-R40; Mac <c>guardSpeech</c>), at 16 kHz: the transcript
    /// words' own audio nearest the patch (<see cref="VoiceLabGuardSpeech"/>), joined, up to 10 s, from the original source. A transcript
    /// with no timed words leaves only the patch's own 10 s of source, centred on it.</summary>
    internal static float[] GuardSpeech(VoiceLabTakeInput input)
    {
        var rate = input.SourceSampleRate;
        // The same selection an accepted take's baseline reads (VoiceAnchorBaseline), with its 10 s fallback around the window.
        var selection = VoiceLabGuardSpeech.ForTake(input.Items, input.Window.Start, input.Window.End, input.Window.StartSample, input.Window.EndSample,
            rate, input.Source.TotalFrames);
        var speech = selection.Samples(input.Source) ?? throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return VoiceConsentAudio.Resample(speech, rate, 16000);
    }
}
