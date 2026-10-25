using System.Globalization;
using System.Numerics;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Shared exact duration formatting for editing §4.4 and AI §11.3.</summary>
public static class EditingFormat
{
    /// <summary>Format a finite nonnegative binary64 value with one decimal, exact ties up.</summary>
    public static string ToFixed1(double value)
    {
        if (!double.IsFinite(value) || value < 0) throw new ArgumentOutOfRangeException(nameof(value));
        if (value >= 1e21) return value.ToString("R", CultureInfo.InvariantCulture).Replace("E+", "e+", StringComparison.Ordinal);
        var bits = BitConverter.DoubleToUInt64Bits(value);
        var exponentBits = (int)((bits >> 52) & 2047);
        var mantissa = bits & ((1UL << 52) - 1);
        var exponent = exponentBits == 0 ? -1074 : exponentBits - 1023 - 52;
        if (exponentBits != 0) mantissa |= 1UL << 52;
        BigInteger rounded;
        if (exponent >= 0) rounded = (new BigInteger(mantissa) * 10) << exponent;
        else if (-exponent > 60) rounded = BigInteger.Zero;
        else rounded = (new BigInteger(mantissa) * 10 + (BigInteger.One << (-exponent - 1))) >> -exponent;
        return (rounded / 10).ToString(CultureInfo.InvariantCulture) + "." + (rounded % 10).ToString(CultureInfo.InvariantCulture);
    }
}

internal static class EditingMath
{
    internal static double Round(double value)
    {
        var floor = Math.Floor(value);
        return value - floor >= 0.5 ? floor + 1 : floor;
    }

    internal static long ClampSample(double seconds, double rate, long total)
        => (long)Math.Min(total, Math.Max(0, Round(seconds * rate)));
}
