using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

[CollectionDefinition("WinEditingEnvironment", DisableParallelization = true)]
public sealed class EditingEnvironmentCollection;

[Collection("WinEditingEnvironment")]
public sealed class EnvironmentLocationTests
{
    [Fact]
    public async Task RelativeProjectPathResolvesMediaFromTheCurrentDirectory()
    {
        using var storage = new TestStorage();
        var store = new ProjectStore();
        var relative = storage.PathFor(Path.Combine("media", "source.bin"));
        Directory.CreateDirectory(Path.GetDirectoryName(relative)!);
        await File.WriteAllBytesAsync(relative, [1, 2, 3], TestContext.Current.CancellationToken);
        var source = TestStorage.ProjectFixture().Media.Source with { AbsolutePath = storage.PathFor("moved.bin"), RelativePath = "media/source.bin", SizeBytes = 3,
            ContentKey = await store.ComputeContentKeyAsync(relative, null, TestContext.Current.CancellationToken) };
        var original = Environment.CurrentDirectory;
        try
        {
            Environment.CurrentDirectory = storage.Root;
            var expected = Path.GetFullPath(Path.Combine("media", "source.bin"));
            Assert.Equal(expected, await store.ResolveMediaAsync(source, "talk.voxclip", TestContext.Current.CancellationToken));
            Assert.Equal(expected, await store.ResolveMediaAsync(source, Path.Combine(".", "talk.voxclip"), TestContext.Current.CancellationToken));
        }
        finally
        {
            Environment.CurrentDirectory = original;
        }
    }

    [Fact]
    public async Task DataOverrideIsResolvedWithoutIoAndUsedByTheDefaultSettingsStore()
    {
        using var storage = new TestStorage();
        var original = Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR");
        var root = storage.PathFor("isolated-data");
        try
        {
            Environment.SetEnvironmentVariable("VOXCLIP_DATA_DIR", root);
            var paths = DataLocations.Resolve();
            Assert.Equal(root, paths.Root);
            Assert.Equal(Path.Combine(root, "Models"), paths.Models);
            Assert.Equal(Path.Combine(root, "Cache"), paths.Cache);
            Assert.Equal(Path.Combine(root, "Autosave"), paths.Autosave);
            Assert.Equal(Path.Combine(root, "Secrets"), paths.Secrets);
            Assert.Equal(Path.Combine(root, "Logs"), paths.Logs);
            Assert.False(Directory.Exists(root));
            var store = new SettingsStore();
            var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
            Assert.False(Directory.Exists(root));
            await store.SaveAsync(settings, TestContext.Current.CancellationToken);
            await store.FlushAsync(TestContext.Current.CancellationToken);
            Assert.True(File.Exists(paths.Settings));
            Assert.Empty(Directory.GetDirectories(root));
        }
        finally { Environment.SetEnvironmentVariable("VOXCLIP_DATA_DIR", original); }
    }

    [Fact]
    public void ATestProcessNeverLogsIntoTheUsersLogFolder()
    {
        // About 21,800 lines of a user's ~/Library/Logs/VoxClip/voxclip.log came from these suites run on a Mac without
        // VOXCLIP_DATA_DIR. This process is a test process, so its logs go to its own temporary folder.
        Assert.True(TestProcess.IsRunning);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var logs = DataLocations.Resolve(null, home, TestProcess.IsRunning).Logs;
        Assert.Equal(TestProcess.Logs, logs);
        Assert.False(Inside(logs, Path.Combine(home, "Library", "Logs")));
        Assert.False(Inside(logs, Path.Combine(home, "Library", "Application Support", "VoxClip")));
        Assert.False(Inside(logs, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VoxConvo")));
        Assert.True(Inside(logs, Path.GetTempPath()));
        // The app itself keeps its log folder, and an explicit data folder still wins for tests.
        var app = DataLocations.Resolve(null, home, testing: false).Logs;
        Assert.Equal(OperatingSystem.IsMacOS() ? Path.Combine(home, "Library", "Logs", "VoxClip")
            : Path.Combine(DataLocations.Resolve(null, home, testing: false).Root, "Logs"), app);
        var isolated = Path.Combine(Path.GetTempPath(), "voxclip-isolated-data");
        Assert.Equal(Path.Combine(isolated, "Logs"), DataLocations.Resolve(isolated, home, testing: true).Logs);
    }

    [Fact]
    public void TheTestProcessCheckKnowsTestHostsAndNeverTheApp()
    {
        string[] app = ["VoxClip", "VoxClip.Core", "VoxClip.Media", "System.Runtime"];
        Assert.False(TestProcess.Detect(["PATH", "HOME", "VOXCLIP_DATA_DIR"], "VoxClip", ["/Applications/VoxClip"], app, "VoxClip"));
        Assert.False(TestProcess.Detect([], "voxclip-cli", ["voxclip-cli", "test"], app, "voxclip-cli"));
        Assert.True(TestProcess.Detect([], "testhost", ["testhost.dll"], app, "testhost"));
        Assert.True(TestProcess.Detect([], "dotnet", ["dotnet", "test", "--project", "tests/VoxClip.Core.Tests"], app, null));
        Assert.True(TestProcess.Detect([], "VoxClip.Media.Tests", [], app, "VoxClip.Media.Tests"));
        Assert.True(TestProcess.Detect([], "dotnet", ["dotnet", "exec", "runner.dll"], [.. app, "xunit.v3.core"], "runner"));
        Assert.True(TestProcess.Detect(["TESTINGPLATFORM_EXECUTIONID"], "runner", [], app, "runner"));
        Assert.True(TestProcess.Detect(["VSTEST_HOST_DEBUG"], "runner", [], app, "runner"));
    }

    private static bool Inside(string path, string folder)
    {
        var relative = Path.GetRelativePath(Path.GetFullPath(folder), Path.GetFullPath(path));
        return relative == "." || (!relative.StartsWith("..", StringComparison.Ordinal) && !Path.IsPathRooted(relative));
    }

    [Fact]
    public void SharedOverrideWinsAndInvalidOverridesFailRatherThanSilentlyFallingBack()
    {
        using var storage = new TestStorage();
        var original = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR");
        try
        {
            Directory.CreateDirectory(storage.PathFor("caption-styles"));
            Environment.SetEnvironmentVariable("VOXCLIP_SHARED_DIR", storage.Root);
            // A root without the share-text rules fails at launch too (publishing §2.1).
            Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, Assert.Throws<VoxClipException>(() => SharedResources.ResolveRoot()).Code);
            Directory.CreateDirectory(storage.PathFor("data"));
            File.WriteAllText(storage.PathFor(Path.Combine("data", "share-text.json")), "{}");
            Assert.Equal(storage.Root, SharedResources.ResolveRoot());
            Environment.SetEnvironmentVariable("VOXCLIP_SHARED_DIR", storage.PathFor("missing"));
            var error = Assert.Throws<VoxClipException>(() => SharedResources.ResolveRoot());
            Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, error.Code);
        }
        finally { Environment.SetEnvironmentVariable("VOXCLIP_SHARED_DIR", original); }
    }
}
