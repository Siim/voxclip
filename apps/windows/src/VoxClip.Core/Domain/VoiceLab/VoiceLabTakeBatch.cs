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
    public static void Validate(IReadOnlyList<VoiceLabTakeInput> inputs)
    {
        if (inputs.Count is < 1 or > MaximumWindows) throw Invalid();
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
        if (end is VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop)
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
