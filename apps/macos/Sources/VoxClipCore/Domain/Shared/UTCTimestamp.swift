import Foundation

/// Persisted RFC 3339 timestamps; editing §10.1 and project schema `$defs/timestamp`.
///
/// Text is always UTC `YYYY-MM-DDTHH:MM:SS.sssZ` in the proleptic Gregorian calendar, years 0001–9999. Writers round
/// to the nearest millisecond, an exact half going to the later instant. Readers accept 0–9 fractional digits and an
/// uppercase `Z` and round the same way, so a loaded date is exactly the one the next save writes. All of it is integer
/// arithmetic: Foundation's ISO 8601 styles truncate binary seconds, and its Gregorian calendar is Julian before 1582.
public enum UTCTimestamp {
    /// 0001-01-01T00:00:00.000Z and 9999-12-31T23:59:59.999Z, in milliseconds since 1970.
    public static let firstMillisecond: Int64 = -62_135_596_800_000
    public static let lastMillisecond: Int64 = 253_402_300_799_999
    /// 2001-01-01T00:00:00Z, the reference date `Date` counts from.
    static let referenceMillisecond: Int64 = 978_307_200_000
    private static let scale: [Int64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000]

    /// The canonical text, or nil when `date` rounds outside years 0001–9999.
    public static func string(from date: Date) -> String? {
        milliseconds(from: date).flatMap { string(milliseconds: $0) }
    }

    /// The canonical text for whole milliseconds since 1970, or nil outside years 0001–9999.
    public static func string(milliseconds: Int64) -> String? {
        guard (firstMillisecond...lastMillisecond).contains(milliseconds) else { return nil }
        let dayNumber = floorDivision(milliseconds, 86_400_000), time = milliseconds - dayNumber * 86_400_000
        let (year, month, day) = civil(dayNumber)
        func pad(_ value: Int64, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: width - digits.count) + digits
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(time / 3_600_000, 2)):\(pad(time / 60_000 % 60, 2)):\(pad(time / 1000 % 60, 2)).\(pad(time % 1000, 3))Z"
    }

    /// The exact binary value of `date` rounded to whole milliseconds since 1970, an exact half going to the later instant.
    public static func milliseconds(from date: Date) -> Int64? {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite, seconds.magnitude < 1e12 else { return nil }
        guard seconds.magnitude >= 0x1p-20 else { return referenceMillisecond }
        // seconds = significand · 2^-shift exactly; floor(significand · 1000 / 2^shift + 1/2), in steps that cannot overflow.
        let significand = Int64(seconds.significand * 0x1p52) * (seconds.sign == .minus ? -1 : 1)
        let shift = 52 - seconds.exponent
        return ((((significand * 1000) >> (shift - 1)) + 1) >> 1) + referenceMillisecond
    }

    /// The date for `YYYY-MM-DDTHH:MM:SS[.fraction]Z` with 0–9 fractional digits, rounded like a write; nil for any other
    /// form or outside years 0001–9999. `allowingOffset` also accepts a `±HH:MM` offset (cache metadata, architecture §8.2).
    public static func date(from text: String, allowingOffset: Bool = false) -> Date? {
        milliseconds(from: text, allowingOffset: allowingOffset).map { date(milliseconds: $0) }
    }

    public static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(milliseconds - referenceMillisecond) / 1000)
    }

    /// Whole milliseconds since 1970 for an accepted text; see `date(from:allowingOffset:)`.
    public static func milliseconds(from text: String, allowingOffset: Bool = false) -> Int64? {
        let bytes = Array(text.utf8)
        func digits(_ start: Int, _ count: Int) -> Int64? {
            guard start + count <= bytes.count else { return nil }
            var value: Int64 = 0
            for byte in bytes[start..<start + count] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int64(byte - 0x30)
            }
            return value
        }
        func at(_ index: Int, _ character: Unicode.Scalar) -> Bool { index < bytes.count && bytes[index] == UInt8(ascii: character) }
        guard let year = digits(0, 4), at(4, "-"), let month = digits(5, 2), at(7, "-"), let day = digits(8, 2), at(10, "T"),
              let hour = digits(11, 2), at(13, ":"), let minute = digits(14, 2), at(16, ":"), let second = digits(17, 2),
              year >= 1, (1...12).contains(month), day >= 1, day <= daysInMonth(year, month), hour < 24, minute < 60, second < 60 else { return nil }
        var index = 19, nanoseconds: Int64 = 0
        if at(index, ".") {
            let start = index + 1
            index = start
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            guard (1...9).contains(index - start), let fraction = digits(start, index - start) else { return nil }
            nanoseconds = fraction * scale[9 - (index - start)]
        }
        let offset: Int64
        if at(index, "Z"), index + 1 == bytes.count { offset = 0 }
        else if allowingOffset, index + 6 == bytes.count, at(index, "+") || at(index, "-"), let hours = digits(index + 1, 2), at(index + 3, ":"),
                let minutes = digits(index + 4, 2), hours < 24, minutes < 60 { offset = (hours * 60 + minutes) * 60_000 * (at(index, "-") ? -1 : 1) }
        else { return nil }
        let milliseconds = ((days(year, month, day) * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + (nanoseconds + 500_000) / 1_000_000 - offset
        return (firstMillisecond...lastMillisecond).contains(milliseconds) ? milliseconds : nil
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's `days_from_civil`).
    static func days(_ year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = floorDivision(shiftedYear, 400), yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
    }

    /// The proleptic Gregorian date of a day count since 1970-01-01 (`civil_from_days`).
    static func civil(_ days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days + 719_468
        let era = floorDivision(shifted, 146_097), dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, dayOfYear - (153 * shiftedMonth + 2) / 5 + 1)
    }

    static func daysInMonth(_ year: Int64, _ month: Int64) -> Int64 {
        if month == 2 { return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28 }
        return [4, 6, 9, 11].contains(month) ? 30 : 31
    }

    static func floorDivision(_ value: Int64, _ divisor: Int64) -> Int64 {
        value % divisor < 0 ? value / divisor - 1 : value / divisor
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// Canonical UTC timestamps; `UTCTimestamp`.
    public static var utcTimestamp: Self {
        .custom { date, encoder in
            guard let text = UTCTimestamp.string(from: date) else {
                throw EncodingError.invalidValue(date, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Timestamp outside years 0001-9999"))
            }
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// UTC timestamps with 0–9 fractional digits; `UTCTimestamp`.
    public static var utcTimestamp: Self { utcTimestamp(allowingOffset: false) }

    /// `allowingOffset` also accepts a `±HH:MM` offset, which only cache metadata may carry (architecture §8.2).
    public static func utcTimestamp(allowingOffset: Bool) -> Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            guard let date = UTCTimestamp.date(from: try container.decode(String.self), allowingOffset: allowingOffset) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected UTC RFC 3339 timestamp")
            }
            return date
        }
    }
}
