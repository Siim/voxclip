import Foundation

/// One provider's estimated spend in one month; voice-lab §3.1.
public struct VoiceLabSpendTotal: Sendable, Equatable {
    public var usd: Decimal
    /// Actions that ran without a known price.
    public var unknownCount: Int

    public init(usd: Decimal = 0, unknownCount: Int = 0) { self.usd = usd; self.unknownCount = unknownCount }
}

/// The `voxclip-voice-lab-spend/1` document: estimates of actions that ran, by local month (`YYYY-MM`) and provider.
public struct VoiceLabSpendDocument: Sendable, Equatable {
    public static let format = "voxclip-voice-lab-spend/1"

    public var months: [String: [String: VoiceLabSpendTotal]]

    public init(months: [String: [String: VoiceLabSpendTotal]] = [:]) { self.months = months }

    /// Nil when the bytes are not exactly this format; the ledger then moves the file aside. A byte-order mark and a
    /// repeated key are refused explicitly, because JSONSerialization would skip the one and keep one value of the other.
    public init?(data: Data) {
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]), String(data: data, encoding: .utf8) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !Self.repeatsKey(Array(data)),
              Set(root.keys) == ["schema", "months"], root["schema"] as? String == Self.format,
              let months = root["months"] as? [String: Any] else { return nil }
        var result: [String: [String: VoiceLabSpendTotal]] = [:]
        for (month, value) in months {
            guard Self.isMonth(month), let providers = value as? [String: Any] else { return nil }
            var totals: [String: VoiceLabSpendTotal] = [:]
            for (provider, value) in providers {
                guard Self.isProvider(provider), let entry = value as? [String: Any], Set(entry.keys) == ["usd", "unknownCount"],
                      let text = entry["usd"] as? String, let usd = VoiceLabMoney.parse(text, wholeDigits: 12, fractionDigits: 10),
                      let count = Self.count(entry["unknownCount"]) else { return nil }
                totals[provider] = VoiceLabSpendTotal(usd: usd, unknownCount: count)
            }
            result[month] = totals
        }
        self.months = result
    }

    /// The user's local calendar month of `date` in `timeZone`, on the Gregorian calendar whatever the user's calendar.
    public static func month(of date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    public func total(provider: String, month: String) -> VoiceLabSpendTotal { months[month]?[provider] ?? VoiceLabSpendTotal() }

    /// Adds one action that ran: a known amount to `usd`, an unknown one to `unknownCount`. Throws `invalidInput` for a
    /// provider id the file cannot hold, a negative amount, or a total the reader would refuse.
    public mutating func record(_ estimate: CostEstimate, month: String) throws {
        guard Self.isMonth(month), Self.isProvider(estimate.provider), !(estimate.usd?.isNaN ?? false), (estimate.usd ?? 0) >= 0 else {
            throw VoiceLabError.invalidInput
        }
        var total = self.total(provider: estimate.provider, month: month)
        if let usd = estimate.usd { total.usd += VoiceLabMoney.usd(usd) } else { total.unknownCount += 1 }
        guard total.usd < VoiceLabMoney.power(12), total.unknownCount <= Int(Int32.max) else { throw VoiceLabError.invalidInput }
        months[month, default: [:]][estimate.provider] = total
    }

    /// The canonical file: two-space indent, months and providers in ordinal order, `usd` before `unknownCount`, LF ends.
    public func encoded() -> Data {
        var lines = ["{", "  \"schema\": \"\(Self.format)\","]
        if months.isEmpty {
            lines.append("  \"months\": {}")
        } else {
            lines.append("  \"months\": {")
            let keys = months.keys.sorted()
            for (index, month) in keys.enumerated() {
                let comma = index < keys.count - 1 ? "," : ""
                let totals = months[month] ?? [:]
                let providers = totals.keys.sorted()
                if providers.isEmpty { lines.append("    \"\(month)\": {}" + comma); continue }
                lines.append("    \"\(month)\": {")
                for (position, provider) in providers.enumerated() {
                    let total = totals[provider] ?? VoiceLabSpendTotal()
                    lines += ["      \"\(provider)\": {", "        \"usd\": \"\(VoiceLabMoney.canonical(total.usd))\",",
                              "        \"unknownCount\": \(total.unknownCount)", "      }" + (position < providers.count - 1 ? "," : "")]
                }
                lines.append("    }" + comma)
            }
            lines.append("  }")
        }
        lines.append("}")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// True when an object in `bytes`, already known to be valid JSON, repeats a key. Keys compare after unescaping, so
    /// "2026-10" and its escaped spelling are the same key.
    static func repeatsKey(_ bytes: [UInt8]) -> Bool {
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        var containers: [Set<String>?] = []  // the keys seen in each open object; nil for an array
        var expectingKey = false
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "{"):
                containers.append([])
                expectingKey = true
            case UInt8(ascii: "["):
                containers.append(nil)
                expectingKey = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                containers.removeLast()
                expectingKey = false
            case UInt8(ascii: ","):
                expectingKey = containers.last.map { $0 != nil } ?? false
            case quote:
                let start = index
                index += 1
                while bytes[index] != quote { index += bytes[index] == backslash ? 2 : 1 }
                if expectingKey, var keys = containers.last ?? nil {
                    let literal = Data(bytes[start...index])
                    guard let key = try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) as? String,
                          keys.insert(key).inserted else { return true }
                    containers[containers.count - 1] = keys
                }
                expectingKey = false
            default:
                break
            }
            index += 1
        }
        return false
    }

    static func isMonth(_ key: String) -> Bool {
        key.range(of: "\\A[0-9]{4}-(?:0[1-9]|1[0-2])\\z", options: .regularExpression) != nil
    }

    static func isProvider(_ key: String) -> Bool {
        key.range(of: "\\A[a-z0-9]+(?:-[a-z0-9]+)*\\z", options: .regularExpression) != nil
    }

    /// A JSON integer from 0 to Int32.max; booleans, fractions and exponents are refused, as on Windows.
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !(number is NSDecimalNumber), CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number), let count = value as? Int, (0...Int(Int32.max)).contains(count) else { return nil }
        return count
    }
}
