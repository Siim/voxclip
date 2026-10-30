using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

internal sealed record VoiceLabTakeRunChecks(Action<VoiceConsentRecord> Validate,
    Func<VoiceConsentRecord, float[], Guid, VoiceLabDispatchBinding, long, CancellationToken, Task<OwnVoicePolicy>> Authorize,
    Func<float[], int, CancellationToken, Task<float[]>> Embedding);

public sealed class VoiceLabTakeRun
{
    private sealed record Pending(VoiceLabTakeRunQuote Quote, VoiceLabTakeInput Input, VoiceConsentRecord Record,
        VoiceLabTakePreflight Preflight, float[] Source, float[] Speech, long ModelRevision, long Revision, VoiceLabDispatchBinding Binding);
    private readonly object sync = new();
    private readonly ElevenLabsVoiceLab client;
    private readonly VoiceConsentStore store;
    private readonly VoiceLabTakeStorage storage;
    private readonly VoiceLabTakeRunChecks checks;
    private readonly VoiceLabDispatchGate inputGate;
    private readonly Func<CancellationToken, Task<bool>> inputsAreCurrent;
    private readonly Dictionary<Guid, VoiceLabTakeScratch> scratches = [];
    private readonly Dictionary<Guid, VoiceLabAsset> paidAssets = [];
    private readonly Dictionary<Guid, (VoiceLabTakeRow Row, Pending Input)> acceptedRows = [];
    private Pending? pending;
    private Guid? owner;
    private bool preparing;
    private long revision;
    private CancellationTokenSource? running;
    private VoiceLabTakeRunEnd stop = VoiceLabTakeRunEnd.Cancelled;
    internal Func<string, Task>? Suspension { get; set; }
    public VoiceLabTakeRun(ElevenLabsVoiceLab client, VoiceConsentStore store, VoiceSpeakerCheck speaker,
        VoiceLabTakeStorage storage, VoiceLabDispatchGate inputGate, Func<CancellationToken, Task<bool>> inputsAreCurrent)
        : this(client, store, storage, inputGate, inputsAreCurrent, ProductionChecks(store, speaker)) { }
    internal VoiceLabTakeRun(ElevenLabsVoiceLab client, VoiceConsentStore store, VoiceLabTakeStorage storage,
        VoiceLabDispatchGate inputGate, Func<CancellationToken, Task<bool>> inputsAreCurrent, VoiceLabTakeRunChecks checks)
    { this.client = client; this.store = store; this.storage = storage; this.inputGate = inputGate; this.inputsAreCurrent = inputsAreCurrent; this.checks = checks; }
    private static VoiceLabTakeRunChecks ProductionChecks(VoiceConsentStore store, VoiceSpeakerCheck speaker)
    {
        var guard = new VoiceUseGuard(store, speaker);
        return new(record =>
        {
            speaker.ValidateAvailability();
            if (!speaker.Supports(record.Statement.Language) || speaker.ModelId != record.Speaker.Model || speaker.Threshold != record.Speaker.Threshold)
                throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        }, (record, speech, request, binding, model, ct) => guard.AuthorizeAsync("take:" + VoiceConsentStore.Hash(System.Runtime.InteropServices.MemoryMarshal.AsBytes(speech.AsSpan()).ToArray()),
            record.RecordId, speech, request, true, ct: ct, binding: binding, modelRevision: model),
            (samples, rate, ct) => speaker.EmbeddingAsync(VoiceConsentAudio.Resample(samples, rate), ct));
    }
    public VoiceLabTakeScratch? Scratch(Guid id) { lock (sync) return scratches.GetValueOrDefault(id); }
    public VoiceLabAsset? PaidAsset(Guid id) { lock (sync) return paidAssets.GetValueOrDefault(id); }
    public async Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default)
    {
        long version;
        VoiceLabDispatchBinding binding;
        VoiceLabTakeRunQuote? retired;
        VoiceLabTakeScratch[] oldScratches;
        lock (sync)
        {
            if (preparing || owner.HasValue) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            preparing = true;
            version = ++revision;
            inputGate.Invalidate();
            binding = inputGate.Capture();
            retired = pending?.Quote;
            pending = null;
            oldScratches = scratches.Values.ToArray(); scratches.Clear(); acceptedRows.Clear();
        }
        if (retired is not null) client.DiscardTakeRun(retired);
        var quotes = new List<VoiceLabTakeQuote>();
        var id = Guid.NewGuid();
        try
        {
            await Task.WhenAll(oldScratches.Select(scratch => scratch.InvalidateAsync())).ConfigureAwait(false);
            Check(version, binding, ct);
            ct.ThrowIfCancellationRequested();
            var snapshot = input.Snapshot();
            var record = store.Load(snapshot.RecordId);
            store.ValidateUse(record);
            checks.Validate(record);
            if (snapshot.Language != record.Statement.Language) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
            if (!await inputsAreCurrent(ct).ConfigureAwait(false)) throw new VoiceLabRunInvalidatedException();
            Check(version, binding, ct);
            var preflight = VoiceLabTakeProcessing.Preflight(snapshot);
            var source = await Task.Run(() => VoiceConsentAudio.Resample(snapshot.Source, snapshot.SourceSampleRate, 24000), ct).ConfigureAwait(false);
            Check(version, binding, ct);
            var rate = snapshot.SourceSampleRate;
            var center = (snapshot.Window.StartSample + snapshot.Window.EndSample) / 2;
            var start = (int)Math.Max(0, center - 5L * rate);
            var end = Math.Min(snapshot.Source.Length, start + 10 * rate);
            var speech = VoiceConsentAudio.Resample(snapshot.Source.AsSpan(start, end - start), rate, 16000);
            var model = client.ModelRevision;
            for (var index = 0; index < 3; index++)
            {
                var options = snapshot.Options(index);
                var review = new OwnVoicePolicy(record.RecordId, record.VoiceId, true, true, true, true, true);
                var synthesis = client.PrepareSynthesis(snapshot.Text, snapshot.ModelId, VoiceLabVoiceChoice.Own(record.VoiceId, review), snapshot.Language, options, Guid.NewGuid());
                try { quotes.Add(new(index, options.Seed, synthesis, client.PrepareQa(snapshot.Language, record.RecordId, Guid.NewGuid()))); }
                catch { client.DiscardTakeRun(new(id, [new(index, options.Seed, synthesis, synthesis)])); throw; }
            }
            var quote = new VoiceLabTakeRunQuote(id, quotes);
            if (!await inputsAreCurrent(ct).ConfigureAwait(false)) throw new VoiceLabRunInvalidatedException();
            Check(version, binding, ct);
            if (client.ModelRevision != model) throw new VoiceLabRunInvalidatedException();
            lock (sync)
            {
                Check(version, binding, ct);
                pending = new(quote, snapshot, record, preflight, source, speech, model, version, binding);
            }
            return quote;
        }
        catch
        {
            if (quotes.Count > 0) client.DiscardTakeRun(new(id, quotes));
            throw;
        }
        finally { lock (sync) preparing = false; }
    }
    public async Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
    {
        Pending value;
        Guid execution;
        CancellationTokenSource cancellation;
        lock (sync)
        {
            if (!approved || preparing || owner.HasValue || pending is not { } prepared || !ReferenceEquals(quote, prepared.Quote))
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
        try
        {
            await Checkpoint("clock", value, token).ConfigureAwait(false);
            if (!client.QuotesAreFresh(quote.Actions)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            await ValidateAsync(value, token).ConfigureAwait(false);
            await Checkpoint("validation", value, token).ConfigureAwait(false);
            var approvals = client.ApproveTakeRun(quote, true);
            await Checkpoint("approval", value, token).ConfigureAwait(false);
            await Checkpoint("launch", value, token).ConfigureAwait(false);
            return await PerformAsync(value, approvals, progress ?? (_ => Task.CompletedTask), token).ConfigureAwait(false);
        }
        finally
        {
            client.DiscardTakeRun(quote);
            lock (sync)
            {
                if (owner == execution) { owner = null; running = null; }
            }
            cancellation.Dispose();
        }
    }
    private async Task<VoiceLabTakeRunResult> PerformAsync(Pending value, IReadOnlyList<VoiceLabAuthorization> approvals,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task> progress, CancellationToken ct)
    {
        var rows = new List<VoiceLabTakeRow>();
        foreach (var take in value.Quote.Takes)
        {
            VoiceLabAudioResult? generated = null;
            VoiceLabReceipt? qaReceipt = null;
            VoiceLabTakeAudio? audio = null;
            try
            {
                await ValidateAsync(value, ct).ConfigureAwait(false);
                var policy = await checks.Authorize(value.Record, value.Speech, take.Synthesis.Review.RequestId, value.Binding, value.ModelRevision, ct).ConfigureAwait(false);
                await Checkpoint("authorization", value, ct).ConfigureAwait(false);
                generated = await client.SynthesizeAsync(value.Input.Text, value.Input.ModelId, VoiceLabVoiceChoice.Own(value.Record.VoiceId, policy),
                    value.Input.Language, value.Input.Options(take.Index), approvals[take.Index * 2], ct, take.Synthesis.Review.RequestId).ConfigureAwait(false);
                if (Suspension is { } afterSynthesis) await afterSynthesis("synthesis").ConfigureAwait(false);
                var paid = await Task.Run(() => VoiceLabAssetStore.Write(generated.Pcm, generated.SampleRate, storage.ProjectId,
                    Guid.NewGuid().ToString("D"), storage.PaidRoot, DateTimeOffset.UtcNow), CancellationToken.None).ConfigureAwait(false);
                lock (sync) paidAssets[take.Synthesis.Review.RequestId] = paid;
                await ValidateAsync(value, ct).ConfigureAwait(false);
                var analysis = VoiceLabTakeProcessing.Process(generated, value.Input, value.Preflight);
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
                float[] vector;
                try
                {
                    if (audio.Trimmed.Length < audio.SampleRate * 3) throw new VoiceConsentException(VoiceConsentError.SpeakerMismatch);
                    vector = await checks.Embedding(audio.Trimmed, audio.SampleRate, ct).ConfigureAwait(false);
                }
                catch (VoiceConsentException error) when (error.Kind == VoiceConsentError.SpeakerMismatch)
                {
                    var failed = new VoiceLabTakeQaResult(0, VoiceLabLoudness.LufsJumpLu(audio.Mixed, audio.SampleRate, audio.Seams),
                        VoiceLabLoudness.SamplePeakDbfs(audio.Mixed), null, [VoiceLabTakeQaFailure.Speaker]);
                    rows.Add(new(take.Synthesis.Review.RequestId, take.Index, take.Seed, generated.Receipt, Generated: generated, Quote: take, Audio: audio, Qa: failed));
                    await progress(rows.AsReadOnly()).ConfigureAwait(false);
                    await ValidateAsync(value, ct).ConfigureAwait(false);
                    continue;
                }
                await ValidateAsync(value, ct).ConfigureAwait(false);
                var ownerVector = VoiceConsentRecord.DecodeEmbedding(value.Record.Speaker.Embedding) ?? throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
                var score = SpeakerAudio.Cosine(ownerVector, vector);
                var qaPolicy = await checks.Authorize(value.Record, value.Speech, take.Qa.Review.RequestId, value.Binding, value.ModelRevision, ct).ConfigureAwait(false);
                await Checkpoint("qaAuthorization", value, ct).ConfigureAwait(false);
                var recognized = await client.TranscribeQaAsync(audio.Mixed, audio.SampleRate, value.Input.Language, qaPolicy, approvals[take.Index * 2 + 1], ct).ConfigureAwait(false);
                qaReceipt = recognized.Receipt;
                await ValidateAsync(value, ct).ConfigureAwait(false);
                var lower = audio.PatchStart / (double)audio.SampleRate;
                var upper = audio.PatchEnd / (double)audio.SampleRate;
                var inside = recognized.Words.Where(word => (word.Start + word.End) / 2 >= lower && (word.Start + word.End) / 2 < upper).Select(word => word.Text).ToArray();
                var qa = VoiceLabTakeQuality.Evaluate(value.Input.Text, inside, audio.Mixed, audio.SampleRate, audio.Seams, score, value.Record.Speaker.Threshold);
                var rank = VoiceLabTakeQuality.Rank(audio.Fit, value.Input.Window.End - value.Input.Window.Start, qa.TranscriptMatch, VoiceLabLoudness.Flatness(audio.Trimmed, audio.SampleRate));
                var row = new VoiceLabTakeRow(take.Synthesis.Review.RequestId, take.Index, take.Seed, generated.Receipt, qaReceipt, generated, take, audio, qa, rank);
                rows.Add(row);
                lock (sync) { Check(value.Revision, value.Binding, ct); acceptedRows[row.Id] = (row, value); }
                await progress(rows.AsReadOnly()).ConfigureAwait(false);
                await ValidateAsync(value, ct).ConfigureAwait(false);
                if (row.Selectable && row.Fits) return new(rows.AsReadOnly(), VoiceLabTakeRunEnd.EarlyStop);
            }
            catch (Exception error)
            {
                if (error is VoiceLabRunInvalidatedException || ct.IsCancellationRequested) return new(rows.AsReadOnly(), End(error));
                rows.Add(new(take.Synthesis.Review.RequestId, take.Index, take.Seed, generated?.Receipt, qaReceipt, generated, take, audio, Failure: error));
                await progress(rows.AsReadOnly()).ConfigureAwait(false);
                if (Fatal(error)) return new(rows.AsReadOnly(), End(error));
                try { await ValidateAsync(value, ct).ConfigureAwait(false); }
                catch (Exception stopped) { return new(rows.AsReadOnly(), End(stopped)); }
            }
        }
        return new(rows.AsReadOnly(), VoiceLabTakeRunEnd.Completed);
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
    public Task CancelAsync() => StopAsync(VoiceLabTakeRunEnd.Cancelled);
    public Task InvalidateAsync() => StopAsync(VoiceLabTakeRunEnd.Invalidated);
    private async Task StopAsync(VoiceLabTakeRunEnd reason)
    {
        VoiceLabTakeScratch[] retired;
        VoiceLabTakeRunQuote? quote;
        CancellationTokenSource? cancellation;
        lock (sync)
        {
            stop = reason; revision++;
            inputGate.Invalidate();
            cancellation = running;
            quote = pending?.Quote; pending = null;
            retired = scratches.Values.ToArray(); scratches.Clear(); acceptedRows.Clear();
        }
        try { cancellation?.Cancel(); }
        catch (ObjectDisposedException) { }
        if (quote is not null) client.DiscardTakeRun(quote);
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
        await ValidateAsync(item.Input, ct).ConfigureAwait(false);
        var publication = scratch.Fitted.Publish(storage.ProjectId, Guid.NewGuid().ToString("D"), storage.PaidRoot, date, id.ToString("D"), item.Row.Seed, scratch.Audio.GainDb, ct);
        await ValidateAsync(item.Input, ct).ConfigureAwait(false);
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
    private static bool Fatal(Exception error) => error is VoiceConsentException or VoiceCreatorMismatchException or OperationCanceledException or VoiceLabRunInvalidatedException ||
        error is VoiceLabException { Kind: VoiceLabErrorKind.Unauthorized or VoiceLabErrorKind.PermissionMissing or VoiceLabErrorKind.MissingKey or
            VoiceLabErrorKind.QuotaExceeded or VoiceLabErrorKind.ConsentRequired or VoiceLabErrorKind.SpeakerMismatch or VoiceLabErrorKind.Cancelled };
}
