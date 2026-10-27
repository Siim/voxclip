using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Pure header numbers and copy; cost is absent without an injected catalog or voice hunks.</summary>
public sealed record VoiceLabDiffSummaryResult(int CutCount, int RevoicedPhrases, double EstimateSeconds, CostEstimate? CostEstimate, string Copy);

/// <summary>The re-voice diff header, Voice Lab §8.2.</summary>
public static class VoiceLabDiffSummary
{
    /// <summary>Take one meter and optional complete patch text per merged voice hunk, in order. Missing text makes cost
    /// absent; there is no hunk-token fallback. Complete text includes window bridges. Bill Unicode scalars.</summary>
    public static VoiceLabDiffSummaryResult Make(VoiceLabWordDiffResult diff, IReadOnlyList<VoiceLabFitMeterResult> meters,
        VoiceLabPriceCatalog? catalog = null, string? model = null, int candidates = 1, double? characterMultiplier = null,
        IReadOnlyList<string?>? patchTexts = null)
    {
        var voice = diff.Hunks.Where(hunk => hunk.Kind == VoiceLabDiffHunkKind.Voice).ToArray();
        if (meters.Count != voice.Length || patchTexts is not null && patchTexts.Count != voice.Length)
            throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        int cuts = diff.Hunks.Where(hunk => hunk.Kind == VoiceLabDiffHunkKind.Cut).SelectMany(hunk => hunk.SourceWordIds).Distinct().Count();
        double seconds = 0;
        foreach (var meter in meters)
        {
            if (!double.IsFinite(meter.EstimateSeconds) || meter.EstimateSeconds < 0) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
            seconds += meter.EstimateSeconds;
        }
        if (!double.IsFinite(seconds)) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        CostEstimate? cost = null;
        if (catalog is not null && voice.Length > 0 && patchTexts is not null && patchTexts.All(text => text is not null))
        {
            int characters = patchTexts.Sum(text => text!.EnumerateRunes().Count());
            double units = characters;
            cost = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsTextToSpeech, model, units, candidates, characterMultiplier, catalog);
        }
        string cutCopy = cuts == 1 ? "1 cut" : cuts + " cuts";
        string phraseCopy = voice.Length == 1 ? "1 re-voiced phrase" : voice.Length + " re-voiced phrases";
        string copy = cutCopy + " · " + phraseCopy + " (" + EditingFormat.ToFixed1(seconds) + " s of AI voice)";
        if (cost?.Usd is decimal usd) copy += " · " + VoiceLabCostPresentation.Format(usd);
        return new(cuts, voice.Length, seconds, cost, copy);
    }
}
