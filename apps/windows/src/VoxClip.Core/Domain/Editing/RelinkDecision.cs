namespace VoxClip.Core.Domain.Editing;

/// <summary>The pure editing §10.3 source-replacement decision.</summary>
public enum RelinkDecision
{
    /// <summary>Identical size and content key; no confirmation required.</summary>
    Match,
    /// <summary>A different file needs explicit permission.</summary>
    NeedsConfirmation,
    /// <summary>A confirmed different file has a compatible planning duration.</summary>
    Different,
    /// <summary>The planning duration is incompatible.</summary>
    Refused
}

/// <summary>Shared, media-free relink policy, editing §10.3.</summary>
public static class Relinking
{
    /// <summary>Compare source identity, then require confirmation and the inclusive 50 ms grid bound.</summary>
    public static RelinkDecision Decide(long storedSize, string storedKey, double storedDuration,
        long size, string key, double duration, bool confirmedDifferent)
    {
        if (size == storedSize && string.Equals(key, storedKey, StringComparison.Ordinal)) return RelinkDecision.Match;
        if (!confirmedDifferent) return RelinkDecision.NeedsConfirmation;
        return double.IsFinite(duration) && double.IsFinite(storedDuration)
            && Math.Abs(EditingMath.Round(duration * 1000) - EditingMath.Round(storedDuration * 1000)) <= 50
            ? RelinkDecision.Different : RelinkDecision.Refused;
    }
}
