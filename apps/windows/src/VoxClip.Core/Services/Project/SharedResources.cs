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
/// <summary>Whether this process runs tests: an xUnit or VSTest host (testhost, a loaded xunit assembly, a
/// <c>*.Tests</c> entry assembly), <c>dotnet test</c>, or the test platforms' environment flags. Twin of Mac
/// <c>TestProcess</c>; it also looks in Release, because the Windows suites run Release builds. A test process never
/// writes the user's log folder (<see cref="DataLocations.Logs"/>).</summary>
public static class TestProcess
{
    /// <summary>Whether this process runs tests, decided once at first use.</summary>
    public static bool IsRunning { get; } = Detect(Environment.GetEnvironmentVariables().Keys.Cast<object>().Select(key => key.ToString() ?? ""),
        Environment.ProcessPath is { } path ? Path.GetFileNameWithoutExtension(path) : "", Environment.GetCommandLineArgs(),
        AppDomain.CurrentDomain.GetAssemblies().Select(assembly => assembly.GetName().Name ?? ""),
        System.Reflection.Assembly.GetEntryAssembly()?.GetName().Name);
    /// <summary>Where a test process's logs go when no <c>VOXCLIP_DATA_DIR</c> is set: this process's own temporary folder.</summary>
    public static string Logs => Path.Combine(Path.GetTempPath(), "VoxClipTests-" + Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture), "Logs");
    private static readonly string[] EnvironmentPrefixes = ["VSTEST_", "TESTINGPLATFORM_", "XUNIT_"];
    internal static bool Detect(IEnumerable<string> environmentNames, string processName, IReadOnlyList<string> arguments,
        IEnumerable<string> assemblyNames, string? entryAssembly) =>
        processName.Contains("testhost", StringComparison.OrdinalIgnoreCase)
        || (processName.Equals("dotnet", StringComparison.OrdinalIgnoreCase) && arguments.Skip(1).Take(1).Any(argument => argument.Equals("test", StringComparison.OrdinalIgnoreCase)))
        || entryAssembly?.EndsWith(".Tests", StringComparison.OrdinalIgnoreCase) == true
        || assemblyNames.Any(name => name.StartsWith("xunit.", StringComparison.OrdinalIgnoreCase) || name.StartsWith("testhost", StringComparison.OrdinalIgnoreCase))
        || environmentNames.Any(name => EnvironmentPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)));
}
/// <summary>Data paths, separate from the Velopack installation root; architecture §2.5.</summary>
public sealed record DataLocations(string Root, string Settings, string Models, string Cache, string Autosave, string Secrets, string Logs)
{
    /// <summary>Resolve paths without creating directories or touching service data.</summary>
    public static DataLocations Resolve() => Resolve(Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR"),
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), TestProcess.IsRunning);
    /// <summary>Without <c>VOXCLIP_DATA_DIR</c>, a test process (<paramref name="testing"/>) logs to its own temporary
    /// folder, never ~/Library/Logs/VoxClip or the user's data folder.</summary>
    internal static DataLocations Resolve(string? configured, string home, bool testing)
    {
        var root = Path.GetFullPath(!string.IsNullOrWhiteSpace(configured) ? configured : OperatingSystem.IsWindows()
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VoxConvo", "VoxClip")
            : Path.Combine(home, "Library", "Application Support", "VoxClip"));
        var logs = !string.IsNullOrWhiteSpace(configured) ? Path.Combine(root, "Logs")
            : testing ? TestProcess.Logs
            : OperatingSystem.IsMacOS() ? Path.Combine(home, "Library", "Logs", "VoxClip") : Path.Combine(root, "Logs");
        return new(root, Path.Combine(root, "settings.json"), Path.Combine(root, "Models"), Path.Combine(root, "Cache"),
            Path.Combine(root, "Autosave"), Path.Combine(root, "Secrets"), logs);
    }
}
