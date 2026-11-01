import Foundation
import Observation
import VoxClipCore

/// A read-only view of the local-month estimate ledger, never a provider bill or a daily total.
@MainActor @Observable final class MonthlySpend {
    private(set) var total: VoiceLabSpendTotal?
    private(set) var month: String?
    private var revision = 0
    func refresh(ledger: VoiceLabSpendLedger, now: Date = Date()) async {
        revision += 1
        let ticket = revision
        let value = await ledger.total(provider: "elevenlabs", at: now)
        guard ticket == revision else { return }
        total = value; month = ledger.month(of: now)
    }
    var text: String {
        guard let total else { return "ElevenLabs · spend unavailable this month" }
        let dollars = NSDecimalNumber(decimal: total.usd).doubleValue
        let amount = String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), dollars)
        let unknown = total.unknownCount > 0 ? " + \(total.unknownCount) unpriced" : ""
        return "ElevenLabs · \(amount)\(unknown) this month"
    }
}

extension AppModel {
    var monthlySpendLine: String? { bool("voiceLab.enabled") ? monthlySpend.text : nil }
    func refreshMonthlySpend(now: Date = Date()) async {
        guard bool("voiceLab.enabled") else { return }
        await monthlySpend.refresh(ledger: VoiceLabSpendLedger(locations: locations), now: now)
    }
}
