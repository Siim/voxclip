#if DEBUG
using System.Reflection;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed class DebugRewriteTakeRunner : IVoiceLabTakeRunner, IDisposable
{
    private readonly JsonDocument fixtures;
    private readonly TimeProvider clock;
    private VoiceLabTakeRunQuote? pending;
    private VoiceLabTakeInput? input;
    private readonly DebugRewriteTakeAssets? assets;
    internal string State { get; set; } = "ready";
    internal decimal? Price { get; set; } = 0.02m;
    internal decimal Spend { get; set; }
    internal Exception? PreparationError { get; set; }
    internal Func<CancellationToken, Task>? BeforeTransport { get; set; }
    internal Func<CancellationToken, Task>? BeforePrepare { get; set; }
    internal int Preparations { get; private set; }
    internal int PaidRequests { get; private set; }
    internal int HttpCalls => 0;
    internal IReadOnlyList<VoiceLabTakeInput> PreparedInputs => inputs;
    private readonly List<VoiceLabTakeInput> inputs = [];
    internal DebugRewriteTakeRunner(string file, TimeProvider? clock = null, VoiceLabTakeStorage? storage = null)
    {
        fixtures = JsonDocument.Parse(File.ReadAllBytes(file));
        if (fixtures.RootElement.GetProperty("schema").GetString() != "voxclip-take-run-cases/1" ||
            fixtures.RootElement.GetProperty("run").GetProperty("candidates").GetInt32() != 3)
            throw new InvalidDataException("The take-run fixture schema is not supported.");
        this.clock = clock ?? TimeProvider.System;
        if (storage is not null) assets = new(storage);
    }
    internal Task<RewriteGenerationChoices> DiscoverAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(new RewriteGenerationChoices(State == "no-voice" ? [] : [new("fixture-voice", "My voice · consent Oct 12")],
            [new("eleven_multilingual_v2", "Multilingual v2", ["en"], true, false, 5000, 1)]));
    }
    public async Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput value, CancellationToken ct = default)
    {
        Preparations++;
        if (BeforePrepare is { } pause) await pause(ct);
        ct.ThrowIfCancellationRequested();
        if (PreparationError is { } error) throw error;
        input = value.Snapshot(); inputs.Add(input);
        var expiry = clock.GetUtcNow().AddSeconds(fixtures.RootElement.GetProperty("run").GetProperty("approvalSeconds").GetInt32());
        var actionIndex = 0;
        VoiceLabPreparedAction Action(VoiceLabOperation operation)
        {
            var requestId = Guid.NewGuid();
            var estimate = new VoiceLabEstimate("elevenlabs", operation, 1, "fixture", actionIndex++ == 0 ? Price : 0m, null, "fixture");
            var review = new VoiceLabReview(operation, requestId, "elevenlabs", ElevenLabsRegion.Default, "fixture", value.ModelId,
                value.RecordId, null, null, value.RecordId);
            return (VoiceLabPreparedAction)typeof(VoiceLabPreparedAction).GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single(constructor => constructor.GetParameters().Length == 5)
                .Invoke([Guid.NewGuid(), "fixture", expiry, estimate, review]);
        }
        return pending = new(Guid.NewGuid(), Enumerable.Range(0, 3).Select(index => new VoiceLabTakeQuote(index, unchecked(value.Seed + (uint)index),
            Action(VoiceLabOperation.TextToSpeech), Action(VoiceLabOperation.SpeechToText))).ToArray());
    }
    public Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default) =>
        approved ? ExecuteWithDispatchAsync(quote, new(_ => Task.CompletedTask, action => action()), progress, ct)
            : Task.FromException<VoiceLabTakeRunResult>(new VoiceLabException(VoiceLabErrorKind.ConsentRequired));
    public async Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
    {
        if (!IsQuoteFresh(quote)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        if (BeforeTransport is { } pause) await pause(ct);
        await dispatch.AuthorizeAsync(ct);
        await dispatch.Start(() => { PaidRequests++; return Task.FromResult(true); }, ct);
        if (assets is not null) await assets.InvalidateAsync();
        if (progress is not null) await progress([]);
        if (State == "provider-error") return new([new(Guid.NewGuid(), 0, quote.Takes[0].Seed, Failure: new VoiceLabException(VoiceLabErrorKind.Unauthorized))], VoiceLabTakeRunEnd.Fatal);
        if (State == "generating") await new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously).Task.WaitAsync(ct);
        List<VoiceLabTakeRow> rows = [];
        foreach (var take in quote.Takes)
        {
            ct.ThrowIfCancellationRequested();
            var fixture = fixtures.RootElement.GetProperty("qa").EnumerateArray().First(row => row.GetProperty("id").GetString() ==
                (State == "none-passed" || State == "mixed" && take.Index == 0 ? "short-mismatch" : "short-exact"));
            var failures = fixture.GetProperty("failures").GetArrayLength() == 0 ? Array.Empty<VoiceLabTakeQaFailure>() : [VoiceLabTakeQaFailure.Transcript];
            var window = input!.Window;
            var plan = new VoiceLabFitPlan([], new(0, 0), new(0, 0), 0, 24_000, window.Start, window.End,
                window.StartSample, window.EndSample, 24_000, [new(input.Text, 0.1, 0.8, Synthetic: true)]);
            var qa = new VoiceLabTakeQaResult(1, 0, -10, fixture.GetProperty("speaker").GetDouble(), failures);
            var audio = new VoiceLabTakeAudio(24_000, [], [], 0, 0, [], 0, null, State == "length-changed"
                ? new VoiceLabFitResult.ChangedDuration(plan, 1.2, 0.2) : new VoiceLabFitResult.Exact(plan));
            var score = fixtures.RootElement.GetProperty("ranking")[0].GetProperty("score").GetDouble();
            if (State == "ranked") score = take.Index == 1 ? 1 : 0.5;
            rows.Add(assets is null ? new(Guid.NewGuid(), take.Index, take.Seed, Audio: audio, Qa: qa, Score: score) :
                await assets.RowAsync(input, take, qa, score, State == "length-changed", ct));
            if (progress is not null) await progress(rows.ToArray());
            if (qa.Passed && State is not ("length-changed" or "three-ready" or "mixed" or "ranked" or "cancelled" or "fatal"))
                return new(rows.ToArray(), VoiceLabTakeRunEnd.EarlyStop);
        }
        return new(rows.ToArray(), State switch { "cancelled" => VoiceLabTakeRunEnd.Cancelled, "fatal" => VoiceLabTakeRunEnd.Fatal, _ => VoiceLabTakeRunEnd.Completed });
    }
    public Task DiscardPendingAsync() { pending = null; return Task.CompletedTask; }
    public void InvalidatePreparation() => pending = null;
    public async Task InvalidateAsync() { await DiscardPendingAsync(); if (assets is not null) await assets.InvalidateAsync(); }
    internal VoiceLabTakeScratch? Scratch(Guid id) => assets?.Scratch(id);
    internal Task RejectAsync(Guid id) => assets?.RejectAsync(id) ?? Task.CompletedTask;
    internal Task<(VoiceLabPublishedTake, VoiceConsentRecord)> PublishAsync(Guid id, DateTimeOffset date, CancellationToken ct) =>
        assets?.PublishAsync(id, date, ct) ?? Task.FromException<(VoiceLabPublishedTake, VoiceConsentRecord)>(new VoiceLabException(VoiceLabErrorKind.InvalidAudio));
    public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => ReferenceEquals(pending, quote) && clock.GetUtcNow() < quote.ExpiresAt;
    public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => Task.FromResult(cap is null ? null : cap with { Spent = Spend });
    public Task<decimal?> ReadMonthlySpendAsync(VoiceLabMonthlyCap? fallback, CancellationToken ct = default) => Task.FromResult<decimal?>(Spend);
    public void Dispose() => fixtures.Dispose();
}
#endif
