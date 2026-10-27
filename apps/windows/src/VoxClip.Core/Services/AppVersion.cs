using System.Reflection;
using System.Text.RegularExpressions;

namespace VoxClip.Core.Services;

/// <summary>Runtime display and schema-valid project writer versions; release §1.</summary>
public static class AppVersion
{
    /// <summary>Entry assembly informational version without build metadata, or unknown when blank.</summary>
    public static string Current => Resolve(Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion);

    internal static string Resolve(string? value)
    {
        var version = value?.Split('+')[0];
        return string.IsNullOrWhiteSpace(version) ? "unknown" : version;
    }

    internal static string ResolveProjectWriter(string? value)
        => value is not null && Regex.IsMatch(value, @"\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-beta\.(?:0|[1-9][0-9]*))?\z",
            RegexOptions.CultureInvariant | RegexOptions.NonBacktracking) ? value : "0.0.0";
}
