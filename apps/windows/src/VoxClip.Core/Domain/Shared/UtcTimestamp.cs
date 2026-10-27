using System.Globalization;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Persisted RFC 3339 timestamps; editing §10.1 and project schema <c>$defs/timestamp</c>. Text is always UTC
/// <c>yyyy-MM-ddTHH:mm:ss.fffZ</c> in the proleptic Gregorian calendar, years 0001–9999. Writers round to the nearest
/// millisecond, an exact half going to the later instant. Readers accept 0–9 fractional digits and an uppercase Z and round
/// the same way, so a loaded value is exactly the one the next save writes. All of it is integer tick arithmetic.</summary>
public static class UtcTimestamp
{
    private const long TicksPerMillisecond = TimeSpan.TicksPerMillisecond;
    /// <summary>9999-12-31T23:59:59.999Z, the last millisecond that can be written.</summary>
    private const long LastMillisecond = 3_155_378_975_999_990_000;

    /// <summary>The canonical text for <paramref name="value"/>.</summary>
    /// <exception cref="ArgumentOutOfRangeException">The value rounds past 9999-12-31T23:59:59.999Z.</exception>
    public static string Format(DateTimeOffset value)
    {
        var ticks = Round(value.UtcTicks);
        if (ticks > LastMillisecond) throw new ArgumentOutOfRangeException(nameof(value), "The timestamp rounds past 9999-12-31T23:59:59.999Z.");
        return new DateTime(ticks, DateTimeKind.Utc).ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'", CultureInfo.InvariantCulture);
    }

    /// <summary>Parses <c>yyyy-MM-ddTHH:mm:ss[.fraction]Z</c> with 0–9 fractional digits, rounded like a write. Any other
    /// form (an offset, a lowercase letter, a missing field) and values outside years 0001–9999 are refused.</summary>
    public static bool TryParse(string? text, out DateTimeOffset value)
    {
        value = default;
        if (text is not { Length: >= 20 } || text[4] != '-' || text[7] != '-' || text[10] != 'T' || text[13] != ':' || text[16] != ':'
            || !Digits(text, 0, 4, out var year) || !Digits(text, 5, 2, out var month) || !Digits(text, 8, 2, out var day)
            || !Digits(text, 11, 2, out var hour) || !Digits(text, 14, 2, out var minute) || !Digits(text, 17, 2, out var second)
            || year < 1 || month is < 1 or > 12 || day < 1 || day > DateTime.DaysInMonth(year, month) || hour > 23 || minute > 59 || second > 59) return false;
        var index = 19;
        long fraction = 0;
        if (text[index] == '.')
        {
            var start = ++index;
            while (index < text.Length && char.IsAsciiDigit(text[index])) index++;
            if (index - start is < 1 or > 9) return false;
            // Seven digits are whole ticks. The eighth and ninth are below a tick and cannot change the rounded millisecond.
            for (var digit = start; digit < start + 7; digit++) fraction = fraction * 10 + (digit < index ? text[digit] - '0' : 0);
        }
        if (index != text.Length - 1 || text[index] != 'Z') return false;
        var ticks = Round(new DateTime(year, month, day, hour, minute, second, DateTimeKind.Utc).Ticks + fraction);
        if (ticks > LastMillisecond) return false;
        value = new DateTimeOffset(ticks, TimeSpan.Zero);
        return true;
    }

    /// <summary>Rounds <paramref name="value"/> as a write does. False when it rounds past 9999-12-31T23:59:59.999Z, so a
    /// reader that accepts other forms can refuse a value that could never be written back.</summary>
    internal static bool TryRound(DateTimeOffset value, out DateTimeOffset rounded)
    {
        var ticks = Round(value.UtcTicks);
        rounded = ticks > LastMillisecond ? default : new DateTimeOffset(ticks, TimeSpan.Zero);
        return ticks <= LastMillisecond;
    }

    private static long Round(long ticks) => (ticks + TicksPerMillisecond / 2) / TicksPerMillisecond * TicksPerMillisecond;

    private static bool Digits(string text, int start, int count, out int value)
    {
        value = 0;
        for (var index = start; index < start + count; index++)
        {
            if (!char.IsAsciiDigit(text[index])) return false;
            value = value * 10 + text[index] - '0';
        }
        return true;
    }
}
