using System.Globalization;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Where a paid action shows its cost before it runs; Voice Lab §3.1.</summary>
public enum VoiceLabCostPresentationKind
{
    /// <summary>The formatted amount on the action's button; one click runs it. Empty for a free action.</summary>
    Inline,
    /// <summary>A confirmation sentence with [Continue] and [Cancel].</summary>
    Confirm
}

/// <summary>The presentation and its text: the button amount or the confirmation sentence.</summary>
public sealed record VoiceLabCostPresentationResult(VoiceLabCostPresentationKind Kind, string Text);

/// <summary>A provider's monthly soft cap with its known spend so far this month; Voice Lab §3.1. Unknown amounts never count.</summary>
/// <param name="Limit">Settings → Voice Lab → "Warn me above $__ a month per provider".</param>
/// <param name="Spent">The ledger's known <c>usd</c> for the provider in the action's month.</param>
public sealed record VoiceLabMonthlyCap(decimal Limit, decimal Spent)
{
    /// <summary>True when a known amount takes the month from at most the limit to above it. Reaching the limit exactly, or
    /// starting above it, does not cross.</summary>
    public bool IsCrossedBy(CostEstimate estimate)
    {
        ArgumentNullException.ThrowIfNull(estimate);
        return estimate.Usd is { } usd && Spent <= Limit && Spent + usd > Limit;
    }
}

/// <summary>How a paid Voice Lab action shows its cost before it runs; Voice Lab §3.1. The copy is design.md's, in English.</summary>
public static class VoiceLabCostPresentation
{
    /// <summary>Inline only below this, compared before any rounding.</summary>
    public const decimal InlineLimit = 0.5m;
    private const decimal Cent = 0.01m;

    /// <summary>Inline when the amount is known, below $0.50, the action is not lip sync and it does not cross <paramref name="cap"/>;
    /// a confirmation otherwise, with the cap sentence appended when it crosses. A free action (exactly $0) is inline with no amount,
    /// except that lip sync always confirms. <paramref name="providerName"/> is the display name, such as "ElevenLabs", "fal.ai" or
    /// "sync.so".</summary>
    public static VoiceLabCostPresentationResult Kind(CostEstimate estimate, bool isLipSync, string providerName, VoiceLabMonthlyCap? cap = null)
    {
        ArgumentNullException.ThrowIfNull(estimate);
        if (estimate.Usd is not { } usd) return new(VoiceLabCostPresentationKind.Confirm, UnknownPrice(providerName));
        if (usd == 0 && !isLipSync) return new(VoiceLabCostPresentationKind.Inline, "");
        var crossing = cap?.IsCrossedBy(estimate) == true;
        if (usd < InlineLimit && !isLipSync && !crossing) return new(VoiceLabCostPresentationKind.Inline, Format(usd));
        var sentence = "This will cost " + (usd < Cent ? "less than $0.01" : "about " + Amount(usd)) + " on your " + providerName + " account.";
        return new(VoiceLabCostPresentationKind.Confirm, crossing ? sentence + " " + CapWarning(cap!.Limit, providerName) : sentence);
    }

    /// <summary>An LLM send (<c>voiceRewrite</c>, <c>patchRewrite</c>) by who pays for it; Voice Lab §3.1 as amended by the user's
    /// decision of 2026-10-31. A CLI signed in on a plan, Ollama and LM Studio (on this PC or another host) and Apple on-device cost
    /// nothing extra: inline with no amount, so the send starts at once. An API-key connector, a CLI signed in with an API key, and a
    /// CLI whose sign-in is unknown confirm every send with the unknown-price sentence. An LLM send never has a known price (§3.1),
    /// so the estimate is not an input. <paramref name="signIn"/> is read only for the two CLI connectors.
    /// <paramref name="providerName"/> names whose pricing to check, such as "Anthropic" or "OpenAI".</summary>
    public static VoiceLabCostPresentationResult KindForLlmSend(ConnectorId connector, CliSignIn? signIn, string providerName)
    {
        var free = connector is ConnectorId.Ollama or ConnectorId.LmStudio or ConnectorId.AppleFoundation ||
            (connector is ConnectorId.ClaudeCode or ConnectorId.Codex && signIn == CliSignIn.Plan);
        return free ? new(VoiceLabCostPresentationKind.Inline, "") : new(VoiceLabCostPresentationKind.Confirm, UnknownPrice(providerName));
    }

    /// <summary>The confirmation for an action whose price VoxClip can't know.</summary>
    private static string UnknownPrice(string providerName) => "VoxClip can't tell what this costs. Check " + providerName + "'s pricing.";

    /// <summary>"&lt; $0.01" below a cent. Otherwise two significant digits, rounded half away from zero but never finer than a cent,
    /// with two decimals below $10 and none from $10: "≈ $0.36", "≈ $1.20", "≈ $12", "≈ $1,000".</summary>
    public static string Format(decimal usd) => usd < Cent ? Amount(usd) : "≈ " + Amount(usd);

    /// <summary>"Clean audio · ≈ $0.36", "Re-voice · 3 takes · ≈ $0.02". A free action or a confirmation carries no amount.</summary>
    public static string ButtonTitle(string action, int? takes, VoiceLabCostPresentationResult kind)
    {
        ArgumentNullException.ThrowIfNull(kind);
        var parts = new List<string> { action };
        if (takes is { } count) parts.Add(count == 1 ? "1 take" : count.ToString(CultureInfo.InvariantCulture) + " takes");
        if (kind.Kind == VoiceLabCostPresentationKind.Inline && kind.Text.Length > 0) parts.Add(kind.Text);
        return string.Join(" · ", parts);
    }

    /// <summary>The sentence a confirmation adds when the action would cross the provider's monthly cap.</summary>
    public static string CapWarning(decimal cap, string providerName) =>
        "This takes you past your $" + CapText(cap) + " limit for " + providerName + " this month.";

    /// <summary>The amount without the approximation sign: "$0.36", "$12", "$1,000" or "&lt; $0.01".</summary>
    internal static string Amount(decimal usd)
    {
        if (usd < Cent) return "< $0.01";
        var exponent = 0;
        while (usd >= VoiceLabMoney.Power(exponent + 1)) exponent++;
        while (usd < VoiceLabMoney.Power(exponent)) exponent--;
        var quantum = VoiceLabMoney.Power(Math.Max(exponent - 1, -2));
        var rounded = Math.Round(usd / quantum, 0, MidpointRounding.AwayFromZero) * quantum;
        return "$" + (rounded >= 10 ? VoiceLabMoney.Grouped(rounded) : Cents(rounded));
    }

    /// <summary>A whole cap shows no decimals; any other cap shows two.</summary>
    internal static string CapText(decimal cap) =>
        cap == decimal.Floor(cap) ? VoiceLabMoney.Grouped(cap) : Cents(Math.Round(cap, 2, MidpointRounding.AwayFromZero));

    /// <summary>A non-negative multiple of $0.01 with exactly two decimals.</summary>
    private static string Cents(decimal value)
    {
        var whole = decimal.Floor(value);
        var fraction = (int)((value - whole) * 100);
        return VoiceLabMoney.Grouped(whole) + "." + fraction.ToString("00", CultureInfo.InvariantCulture);
    }
}
