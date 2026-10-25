using System.Numerics;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Pure numeric-version ordering from architecture §13.1; missing components are zero and prereleases sort lower.</summary>
public static class VersionComparison
{
    /// <summary>Compares versions without integer overflow; accepts a leading v and ignores build metadata.</summary>
    public static int CompareVersions(string left, string right)
    {
        var first = Parse(left);
        var second = Parse(right);
        for (var index = 0; index < Math.Max(first.Parts.Length, second.Parts.Length); index++)
        {
            var comparison = (index < first.Parts.Length ? first.Parts[index] : BigInteger.Zero)
                .CompareTo(index < second.Parts.Length ? second.Parts[index] : BigInteger.Zero);
            if (comparison != 0) return comparison;
        }
        return first.Prerelease == second.Prerelease ? 0 : first.Prerelease ? -1 : 1;
    }

    private static (BigInteger[] Parts, bool Prerelease) Parse(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        var numeric = value.Trim().TrimStart('v').Split('+')[0];
        var suffix = numeric.IndexOf('-');
        var parts = (suffix < 0 ? numeric : numeric[..suffix]).Split('.');
        if (parts.Any(part => part.Length == 0 || part.Any(character => character < '0' || character > '9')))
            throw new FormatException("Version components must be nonnegative decimal integers.");
        return (parts.Select(part => BigInteger.Parse(part, System.Globalization.CultureInfo.InvariantCulture)).ToArray(), suffix >= 0);
    }
}
