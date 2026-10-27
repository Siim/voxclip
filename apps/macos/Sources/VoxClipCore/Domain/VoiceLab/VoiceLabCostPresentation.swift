import Foundation

/// A provider's monthly soft cap with its known spend so far this month; voice-lab §3.1. Unknown amounts never count.
public struct VoiceLabMonthlyCap: Sendable, Equatable {
    /// Settings → Voice Lab → "Warn me above $__ a month per provider".
    public var limit: Decimal
    /// The ledger's known `usd` for the provider in the action's month.
    public var spent: Decimal

    public init(limit: Decimal, spent: Decimal) { self.limit = limit; self.spent = spent }

    /// True when a known amount takes the month from at most the limit to above it. Reaching the limit exactly, or
    /// starting above it, does not cross.
    public func isCrossed(by estimate: CostEstimate) -> Bool {
        guard let usd = estimate.usd else { return false }
        return spent <= limit && spent + usd > limit
    }
}

/// How a paid Voice Lab action shows its cost before it runs; voice-lab §3.1. The copy is design.md's, in English.
public enum VoiceLabCostPresentation {
    public enum Kind: Sendable, Equatable {
        /// The formatted amount for the action's button; one click runs it. Empty for a free action.
        case inline(String)
        /// The confirmation sentence, shown with [Continue] and [Cancel].
        case confirm(String)
    }

    /// Inline only below this, compared before any rounding.
    public static let inlineLimit = Decimal(5) / 10
    private static let cent = VoiceLabMoney.power(-2)

    /// Inline when the amount is known, below $0.50, the action is not lip sync and it does not cross `cap`; a
    /// confirmation otherwise, with the cap sentence appended when it crosses. A free action (exactly $0) is inline with
    /// no amount, except that lip sync always confirms. `providerName` is the display name, such as "ElevenLabs", "fal.ai"
    /// or "sync.so".
    public static func kind(_ estimate: CostEstimate, isLipSync: Bool, providerName: String, cap: VoiceLabMonthlyCap? = nil) -> Kind {
        guard let usd = estimate.usd else { return .confirm("VoxClip can't tell what this costs. Check \(providerName)'s pricing.") }
        if usd == 0 && !isLipSync { return .inline("") }
        let crossing = cap?.isCrossed(by: estimate) ?? false
        if usd < inlineLimit && !isLipSync && !crossing { return .inline(format(usd)) }
        let cost = usd < cent ? "less than $0.01" : "about " + amount(usd)
        let sentence = "This will cost \(cost) on your \(providerName) account."
        guard crossing, let cap else { return .confirm(sentence) }
        return .confirm(sentence + " " + capWarning(cap: cap.limit, providerName: providerName))
    }

    /// "< $0.01" below a cent. Otherwise two significant digits, rounded half away from zero but never finer than a
    /// cent, with two decimals below $10 and none from $10: "≈ $0.36", "≈ $1.20", "≈ $12", "≈ $1,000".
    public static func format(_ usd: Decimal) -> String {
        usd < cent ? amount(usd) : "≈ " + amount(usd)
    }

    /// "Clean audio · ≈ $0.36", "Re-voice · 3 takes · ≈ $0.02". A free action or a confirmation carries no amount.
    public static func buttonTitle(_ action: String, takes: Int? = nil, kind: Kind) -> String {
        var parts = [action]
        if let takes { parts.append(takes == 1 ? "1 take" : "\(takes) takes") }
        if case .inline(let text) = kind, !text.isEmpty { parts.append(text) }
        return parts.joined(separator: " · ")
    }

    /// The sentence a confirmation adds when the action would cross the provider's monthly cap.
    public static func capWarning(cap: Decimal, providerName: String) -> String {
        "This takes you past your $\(capText(cap)) limit for \(providerName) this month."
    }

    /// The amount without the approximation sign: "$0.36", "$12", "$1,000" or "< $0.01".
    static func amount(_ usd: Decimal) -> String {
        guard usd >= cent else { return "< $0.01" }
        var exponent = 0
        while usd >= VoiceLabMoney.power(exponent + 1) { exponent += 1 }
        while usd < VoiceLabMoney.power(exponent) { exponent -= 1 }
        let quantum = VoiceLabMoney.power(max(exponent - 1, -2))
        let rounded = VoiceLabMoney.rounded(usd / quantum, scale: 0, .plain) * quantum
        return "$" + (rounded >= 10 ? VoiceLabMoney.grouped(rounded) : cents(rounded))
    }

    /// A whole cap shows no decimals; any other cap shows two.
    static func capText(_ cap: Decimal) -> String {
        cap == VoiceLabMoney.rounded(cap, scale: 0, .down) ? VoiceLabMoney.grouped(cap) : cents(VoiceLabMoney.rounded(cap, scale: 2, .plain))
    }

    /// A non-negative multiple of $0.01 with exactly two decimals.
    private static func cents(_ value: Decimal) -> String {
        let whole = VoiceLabMoney.rounded(value, scale: 0, .down)
        let fraction = NSDecimalNumber(decimal: (value - whole) * 100).intValue
        return VoiceLabMoney.grouped(whole) + (fraction < 10 ? ".0" : ".") + String(fraction)
    }
}
