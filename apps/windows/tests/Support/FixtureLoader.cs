using System.Text.Json;
namespace VoxClip.Tests.Support;

/// <summary>Repository-only fixture resolver; architecture §2.4. Honors VOXCLIP_SHARED_DIR, otherwise walks executable ancestors.</summary>
public static class FixtureLoader
{
    /// <summary>Locate shared fixtures without copying them to an app source or output directory.</summary>
    public static string SharedRoot
    {
        get
        {
            var configured = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR");
            if (!string.IsNullOrWhiteSpace(configured))
            {
                if (!Directory.Exists(Path.Combine(configured, "fixtures"))) throw new DirectoryNotFoundException("VOXCLIP_SHARED_DIR has no fixtures directory.");
                return Path.GetFullPath(configured);
            }
            for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            {
                var candidate = Path.Combine(directory.FullName, "shared");
                if (Directory.Exists(Path.Combine(directory.FullName, "apps")) && Directory.Exists(Path.Combine(candidate, "fixtures"))) return candidate;
            }
            throw new DirectoryNotFoundException("Set VOXCLIP_SHARED_DIR to the repository shared directory.");
        }
    }
    /// <summary>Read a JSON fixture under the shared root. Caller disposes the document.</summary>
    public static JsonDocument ReadJson(string relativePath) => JsonDocument.Parse(File.ReadAllText(Path.Combine(SharedRoot, relativePath)));
    /// <summary>Read a UTF8 fixture under the shared root.</summary>
    public static string ReadText(string relativePath) => File.ReadAllText(Path.Combine(SharedRoot, relativePath));
}
