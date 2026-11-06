using System.Collections.Frozen;
using VoxClip.Core.Services.LLM;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Every source-ordered window's bounded takes prepared for one approval of exactly their union (§8.6).</summary>
public sealed class VoiceLabTakeBatch
{
    public sealed record Window(VoiceLabTakeInput Input, VoiceLabTakeRunQuote Quote)
    {
        public IReadOnlyList<Guid> RequestIds => Quote.Actions.Select(action => action.Review.RequestId).ToArray();
    }
    public const string ProviderName = "ElevenLabs";
    public const int MaximumWindows = 32 / (2 * VoiceLabPricing.MaximumCandidates);
    /// <summary>The most phrases one Rewrite run prices and voices: a run of more than <see cref="MaximumWindows"/> is priced and
    /// approved once, then voiced part by part (<see cref="VoiceLabTakeRunParts"/>, Mac <c>ClipTakePlan.maximumPhrases</c>).</summary>
    public const int MaximumRunPhrases = 100;
    public Guid Id { get; }
    public IReadOnlyList<Window> Windows { get; }
    public CostEstimate Estimate { get; }
    public int TakeCount => Windows.Sum(window => window.Quote.Takes.Count);
    public VoiceLabTakeBatch(IReadOnlyList<Window> windows, Guid? id = null)
    {
        Validate(windows.Select(window => window.Input).ToArray());
        HashSet<Guid> runs = [], quotes = [], requests = [];
        foreach (var window in windows)
        {
            if (window.Quote.Takes.Count is < 1 or > 3 || !runs.Add(window.Quote.Id)) throw Invalid();
            foreach (var quote in window.Quote.Actions)
                if (!quotes.Add(quote.Token) || !requests.Add(quote.Review.RequestId)) throw Invalid();
        }
        Id = id ?? Guid.NewGuid();
        Windows = Array.AsReadOnly(windows.Select(window => window with { Input = window.Input.Snapshot() }).ToArray());
        Estimate = VoiceLabTakeRunQuote.Total(Windows.SelectMany(window => window.Quote.Actions).Select(action => action.Estimate.ToCostEstimate()), TakeCount);
    }
    public static void Validate(IReadOnlyList<VoiceLabTakeInput> inputs) => Validate(inputs, MaximumWindows);
    /// <summary>The batch rules across a whole run of parts: one voice, language, model and source, in source order.</summary>
    public static void ValidateRun(IReadOnlyList<VoiceLabTakeInput> inputs) => Validate(inputs, MaximumRunPhrases);
    private static void Validate(IReadOnlyList<VoiceLabTakeInput> inputs, int maximum)
    {
        if (inputs.Count < 1 || inputs.Count > maximum) throw Invalid();
        var first = inputs[0];
        for (int index = 0; index < inputs.Count; index++)
        {
            var input = inputs[index];
            if (input.RecordId != first.RecordId || input.Language != first.Language || input.ModelId != first.ModelId || input.ContentKey != first.ContentKey ||
                index > 0 && inputs[index - 1].Window.EndSample >= input.Window.StartSample) throw Invalid();
        }
    }
    public VoiceLabCostPresentationResult Kind(VoiceLabMonthlyCap? cap = null) => VoiceLabCostPresentation.Kind(Estimate, false, ProviderName, cap);
    public CostEstimate EstimateOf(IReadOnlySet<Guid> requestIds)
    {
        var takes = Windows.SelectMany(window => window.Quote.Takes).ToArray();
        var quotes = takes.SelectMany(take => new[] { take.Synthesis, take.Qa }).Where(action => requestIds.Contains(action.Review.RequestId));
        int touched = takes.Count(take => requestIds.Contains(take.Synthesis.Review.RequestId) || requestIds.Contains(take.Qa.Review.RequestId));
        return VoiceLabTakeRunQuote.Total(quotes.Select(action => action.Estimate.ToCostEstimate()), touched);
    }
    static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
}
/// <summary>One approval of a whole Rewrite run (Mac <c>ClipTakePlan</c> parts): its windows in consecutive batches of at most
/// <see cref="VoiceLabTakeBatch.MaximumWindows"/>, priced together. A later part is quoted again just before it runs and runs under
/// this approval only when every window's inputs and estimate equal the priced ones (<see cref="SamePrice"/>); otherwise the run
/// stops with "price changed" and sends nothing more.</summary>
public sealed class VoiceLabTakeRunParts
{
    public IReadOnlyList<VoiceLabTakeBatch> Parts { get; }
    public IReadOnlyList<VoiceLabTakeBatch.Window> Windows { get; }
    public CostEstimate Estimate { get; }
    public int TakeCount => Parts.Sum(part => part.TakeCount);
    public VoiceLabTakeRunParts(IReadOnlyList<VoiceLabTakeBatch.Window> windows)
    {
        VoiceLabTakeBatch.ValidateRun(windows.Select(window => window.Input).ToArray());
        Parts = Array.AsReadOnly(windows.Chunk(VoiceLabTakeBatch.MaximumWindows).Select(part => new VoiceLabTakeBatch(part)).ToArray());
        Windows = Array.AsReadOnly(Parts.SelectMany(part => part.Windows).ToArray());
        if (Windows.SelectMany(window => window.Quote.Actions).Select(action => action.Token).Distinct().Count() != Windows.Sum(window => window.Quote.Actions.Count))
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        Estimate = VoiceLabTakeRunQuote.Total(Windows.SelectMany(window => window.Quote.Actions).Select(action => action.Estimate.ToCostEstimate()), TakeCount);
    }
    public VoiceLabCostPresentationResult Kind(VoiceLabMonthlyCap? cap = null) =>
        VoiceLabCostPresentation.Kind(Estimate, false, VoiceLabTakeBatch.ProviderName, cap);
    /// <summary>A window quoted again just before its part runs: the same inputs, by value, and the same estimate and takes.</summary>
    public static bool SamePrice(VoiceLabTakeBatch.Window priced, VoiceLabTakeBatch.Window requoted)
    {
        VoiceLabTakeInput a = priced.Input, b = requoted.Input;
        return a.Text == b.Text && a.ModelId == b.ModelId && a.RecordId == b.RecordId && a.Language == b.Language && a.Seed == b.Seed &&
            a.ContentKey == b.ContentKey && a.SourceSampleRate == b.SourceSampleRate && Nullable.Equals(a.IncomingSilence, b.IncomingSilence) &&
            Nullable.Equals(a.OutgoingSilence, b.OutgoingSilence) && a.CleanAudioOn == b.CleanAudioOn && a.ProviderConsent == b.ProviderConsent &&
            Nullable.Equals(a.Pace, b.Pace) && a.HardJoinSmoothing == b.HardJoinSmoothing && a.AudioTags.SequenceEqual(b.AudioTags) &&
            a.CutWordIds.SetEquals(b.CutWordIds) && a.Items.SequenceEqual(b.Items) && SameWindow(a.Window, b.Window) &&
            priced.Quote.Takes.Count == requoted.Quote.Takes.Count && priced.Quote.Estimate == requoted.Quote.Estimate;
    }
    private static bool SameWindow(VoiceLabWindow a, VoiceLabWindow b) =>
        a.FirstWordId == b.FirstWordId && a.LastWordId == b.LastWordId && a.StartSample == b.StartSample && a.EndSample == b.EndSample &&
        a.LeftSeam == b.LeftSeam && a.RightSeam == b.RightSeam && a.LeftBridgeWordIds.SequenceEqual(b.LeftBridgeWordIds) &&
        a.RightBridgeWordIds.SequenceEqual(b.RightBridgeWordIds);
}
/// <summary>Window-by-window progress. Only provider-accepted requests count as sent; every unsent quote is discarded.</summary>
public sealed class VoiceLabTakeBatchProgress(VoiceLabTakeBatch batch)
{
    public VoiceLabTakeBatch Batch { get; } = batch;
    public int? Window { get; private set; } = 0;
    readonly HashSet<Guid> sent = [], discarded = [];
    public IReadOnlySet<Guid> Sent => sent.ToFrozenSet();
    public IReadOnlySet<Guid> Discarded => discarded.ToFrozenSet();
    public void Finish(int window, IReadOnlySet<Guid> requestIds, VoiceLabTakeRunEnd end)
    {
        if (Window != window) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var own = Batch.Windows[window];
        if (!requestIds.IsSubsetOf(own.RequestIds) || own.Quote.Takes.Any(take => requestIds.Contains(take.Qa.Review.RequestId) && !requestIds.Contains(take.Synthesis.Review.RequestId)))
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        sent.UnionWith(requestIds); discarded.UnionWith(own.RequestIds.Except(requestIds));
        // A window the guard settled sent nothing; the batch goes on to the next one (ADR-R40).
        if (end is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop or VoiceLabTakeRunEnd.Blocked)
            Window = window + 1 < Batch.Windows.Count ? window + 1 : null;
        else
        {
            discarded.UnionWith(Batch.Windows.Skip(window + 1).SelectMany(later => later.RequestIds));
            Window = null;
        }
    }
    public void Finish(int window, VoiceLabTakeRunResult result) => Finish(window, result.Rows.SelectMany(row => row.AcceptedRequestIds).ToHashSet(), result.End);
    public CostEstimate SentEstimate => Batch.EstimateOf(sent);
    public CostEstimate RemainingEstimate => Batch.EstimateOf(Batch.Windows.SelectMany(window => window.RequestIds).Except(sent).Except(discarded).ToHashSet());
    public CostEstimate? RemainingEstimateFrom(Guid requestId)
    {
        var order = Batch.Windows.SelectMany(window => window.RequestIds).ToArray();
        int position = Array.IndexOf(order, requestId);
        return position < 0 || sent.Contains(requestId) || discarded.Contains(requestId) ? null : Batch.EstimateOf(order.Skip(position).Except(sent).Except(discarded).ToHashSet());
    }
}
