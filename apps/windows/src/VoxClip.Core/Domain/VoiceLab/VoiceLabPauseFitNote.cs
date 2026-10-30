using System.Globalization;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The invariant, printf-style pause adjustment note shared by both apps.</summary>
public static class VoiceLabPauseFitNote
{
    /// <summary>Chooses the sign before rounding; negative zero displays a plus.</summary>
    public static string Format(double seconds)
    {
        var magnitude = double.IsNaN(seconds) ? "nan" : double.IsInfinity(seconds) ? "inf" : Math.Abs(seconds).ToString("F1", CultureInfo.InvariantCulture);
        return "pauses " + (seconds >= 0 ? "+" : "−") + magnitude + " s";
    }
}
