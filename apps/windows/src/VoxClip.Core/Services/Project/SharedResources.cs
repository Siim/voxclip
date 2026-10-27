using VoxClip.Core.Domain.Shared;
namespace VoxClip.Core.Services.Project;

/// <summary>Single shared-resource lookup; architecture §2.4. No fixtures are copied into app output.</summary>
public static class SharedResources
{
    /// <summary>Resolve the environment override, installed directory, then repo walk-up.</summary>
    public static string ResolveRoot(string? executableDirectory = null)
    {
        var configured = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR");
        if (!string.IsNullOrWhiteSpace(configured)) return Require(configured);
        var start = executableDirectory ?? AppContext.BaseDirectory;
        var installed = Path.Combine(start, "shared");
        if (Valid(installed)) return Path.GetFullPath(installed);
        for (var directory = new DirectoryInfo(start); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "shared");
            if (Directory.Exists(Path.Combine(directory.FullName, "apps")) && Valid(candidate)) return candidate;
        }
        throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
    }
    private static string Require(string root)
    {
        if (!Valid(root)) throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VOXCLIP_SHARED_DIR does not contain caption-styles and data/share-text.json.");
        return Path.GetFullPath(root);
    }
    private static bool Valid(string root) => Directory.Exists(Path.Combine(root, "caption-styles")) && File.Exists(Path.Combine(root, "data", "share-text.json"));
}
/// <summary>Data paths, separate from the Velopack installation root; architecture §2.5.</summary>
public sealed record DataLocations(string Root, string Settings, string Models, string Cache, string Autosave, string Secrets, string Logs)
{
    /// <summary>Resolve paths without creating directories or touching service data.</summary>
    public static DataLocations Resolve()
    {
        var configured = Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR");
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var root = Path.GetFullPath(!string.IsNullOrWhiteSpace(configured) ? configured : OperatingSystem.IsWindows()
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VoxConvo", "VoxClip")
            : Path.Combine(home, "Library", "Application Support", "VoxClip"));
        var logs = string.IsNullOrWhiteSpace(configured) && OperatingSystem.IsMacOS() ? Path.Combine(home, "Library", "Logs", "VoxClip") : Path.Combine(root, "Logs");
        return new(root, Path.Combine(root, "settings.json"), Path.Combine(root, "Models"), Path.Combine(root, "Cache"),
            Path.Combine(root, "Autosave"), Path.Combine(root, "Secrets"), logs);
    }
}
