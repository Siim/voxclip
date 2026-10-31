#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The app keeps its cache under the size limit (architecture §8.2), as the Mac's CacheEvictionAppTests: the launch
/// pass, a pass after each import that spares the new project, a lower limit enforced at once, editors in three windows holding
/// and moving their leases, and opening a project marking its entry used. Headless, in temp folders, with an injected launch
/// delay and clock.</summary>
public sealed class CacheUpkeepTests
{
    private static readonly DateTimeOffset Start = new(2026, 10, 31, 9, 0, 0, TimeSpan.Zero);
    private static string Key(char letter) => new(letter, 64);
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task StartingSchedulesTheLaunchPassThirtySecondsLater()
    {
        using var folder = new Folder();
        var requested = new TaskCompletionSource<TimeSpan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var never = new TaskCompletionSource();
        var scheduler = new CacheEvictionScheduler(new CacheIndex(folder.Root), () => 0,
            delay: (span, ct) => { requested.TrySetResult(span); return never.Task.WaitAsync(ct); });
        var upkeep = new CacheUpkeep(scheduler, () => new AppSettings("voxclip-settings/1"));
        Assert.False(scheduler.LaunchScheduled);
        upkeep.Started();
        Assert.True(scheduler.LaunchScheduled);
        Assert.Equal(TimeSpan.FromSeconds(30), await requested.Task.WaitAsync(Ct));
        Assert.Equal(0, scheduler.CompletedRuns);
    }

    [Fact]
    public async Task AnImportRunsAPassThatSparesTheNewProject()
    {
        using var folder = new Folder();
        var clock = new Clock(Start);
        var index = new CacheIndex(folder.Root, clock);
        var (old, imported) = (Key('a'), Key('b'));
        await SeedAsync(index, old);
        clock.Advance(TimeSpan.FromMinutes(1));
        await SeedAsync(index, imported);
        var scheduler = new CacheEvictionScheduler(index, () => 0);
        var upkeep = new CacheUpkeep(scheduler, () => new AppSettings("voxclip-settings/1"));
        // The new project's editor holds its lease before the import asks for a pass.
        using var editor = new OpenProjectCacheLease(index);
        editor.Hold(imported);
        await editor.Touches;
        upkeep.Imported();
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(1, scheduler.CompletedRuns);
        Assert.False(Directory.Exists(Path.Combine(folder.Root, old)));
        Assert.True(File.Exists(Path.Combine(folder.Root, imported, "audio-16k.wav")));
    }

    [Fact]
    public async Task LoweringTheLimitEvictsAtOnceAndRaisingItDoesNot()
    {
        using var folder = new Folder();
        var settings = new AppSettings("voxclip-settings/1");
        var launch = new TaskCompletionSource();
        var scheduler = new CacheEvictionScheduler(new CacheIndex(folder.Root), () => CacheUpkeep.LimitBytes(settings),
            delay: (_, ct) => launch.Task.WaitAsync(ct));
        var upkeep = new CacheUpkeep(scheduler, () => settings);
        upkeep.Started();
        Assert.Equal(5_000_000_000L, CacheUpkeep.LimitBytes(settings));
        settings = settings.With(CacheUpkeep.LimitKey, JsonSerializer.SerializeToElement(20));
        upkeep.SettingChanged(CacheUpkeep.LimitKey);
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(0, scheduler.CompletedRuns);
        settings = settings.With(CacheUpkeep.LimitKey, JsonSerializer.SerializeToElement(2));
        upkeep.SettingChanged("general.appearance");
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(0, scheduler.CompletedRuns);
        upkeep.SettingChanged(CacheUpkeep.LimitKey);
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(1, scheduler.CompletedRuns);
        Assert.Equal(2_000_000_000L, CacheUpkeep.LimitBytes(settings));
        upkeep.SettingChanged(CacheUpkeep.LimitKey);
        await scheduler.WaitUntilIdleAsync();
        Assert.Equal(1, scheduler.CompletedRuns);
    }

    [Fact]
    public async Task EditorsInThreeWindowsLeaseTheirKeysAndARelinkMovesTheLease()
    {
        using var folder = new Folder();
        var clock = new Clock(Start);
        var index = new CacheIndex(folder.Root, clock);
        var (shared, other, relinked) = (Key('a'), Key('b'), Key('c'));
        foreach (var key in new[] { shared, other, relinked }) await SeedAsync(index, key);
        // Two projects of one source in two windows, and a third window with another source.
        var first = new OpenProjectCacheLease(index);
        var second = new OpenProjectCacheLease(index);
        using var third = new OpenProjectCacheLease(index);
        first.Hold(shared);
        second.Hold(shared);
        third.Hold(other);
        Assert.Equal([shared, other], index.Keys.LeasedKeys.Order(StringComparer.Ordinal));
        first.Dispose();
        Assert.True(index.Keys.IsLeased(shared));
        // The third window relinks its video to another file: the lease moves with it. Holding the same key again changes nothing.
        third.Hold(relinked);
        third.Hold(relinked);
        Assert.Equal(relinked, third.Key);
        Assert.False(index.Keys.IsLeased(other));
        // Marking an entry used leases it for a moment; let the editors' marks finish first.
        await Task.WhenAll(first.Touches, second.Touches, third.Touches);
        await new CacheEvictionScheduler(index, () => 0).ClearEverythingAsync();
        Assert.True(Directory.Exists(Path.Combine(folder.Root, shared)));
        Assert.True(Directory.Exists(Path.Combine(folder.Root, relinked)));
        Assert.False(Directory.Exists(Path.Combine(folder.Root, other)));
        second.Dispose();
        second.Dispose();
        Assert.Equal(relinked, Assert.Single(index.Keys.LeasedKeys));
    }

    [Fact]
    public async Task OpeningAProjectMarksItsEntryUsed()
    {
        using var folder = new Folder();
        var clock = new Clock(Start);
        var index = new CacheIndex(folder.Root, clock);
        var (opened, newer) = (Key('a'), Key('b'));
        await SeedAsync(index, opened);
        clock.Advance(TimeSpan.FromMinutes(1));
        await SeedAsync(index, newer);
        clock.Advance(TimeSpan.FromMinutes(1));
        using (var editor = new OpenProjectCacheLease(index))
        {
            editor.Hold(opened);
            await editor.Touches;
        }
        Assert.Equal(clock.GetUtcNow(), Assert.Single(await index.ReadAsync(Ct), entry => entry.ContentKey == opened).LastAccessAt);
        // One entry has to go: the one opened least recently.
        var limit = Directory.EnumerateFiles(Path.Combine(folder.Root, opened)).Sum(path => new FileInfo(path).Length) + 10;
        Assert.Equal([newer], await index.EvictAsync(limit, new HashSet<string>(), Ct));
        Assert.True(Directory.Exists(Path.Combine(folder.Root, opened)));
    }

    [Fact]
    public void SettingsOfferClearCacheAndClearEverythingWithTheMacCopy()
    {
        var repository = Path.GetDirectoryName(SharedResources.ResolveRoot())!;
        var settings = File.ReadAllText(Path.Combine(repository, "apps/windows/src/VoxClip.App/SettingsWindow.xaml.cs"));
        var mac = File.ReadAllText(Path.Combine(repository, "apps/macos/Sources/VoxClip/SettingsView.swift"));
        Assert.Equal("Clear cache", CacheUpkeep.ClearCacheLabel);
        Assert.Equal("Clear everything", CacheUpkeep.ClearEverythingLabel);
        Assert.Equal("Cache size limit", CacheUpkeep.LimitLabel);
        Assert.Equal(new[] { 2, 5, 10, 20 }, CacheUpkeep.LimitChoices);
        Assert.Contains("Picker(\"" + CacheUpkeep.LimitLabel + "\"", mac);
        Assert.Contains("Button(\"" + CacheUpkeep.ClearCacheLabel + "\")", mac);
        Assert.Contains("\"" + CacheUpkeep.ClearedCache + "\"", mac);
        Assert.Contains("Ui.Choice(CacheUpkeep.LimitLabel", settings);
        Assert.Contains("Ui.Button(CacheUpkeep.ClearCacheLabel, () => ClearCache(false))", settings);
        Assert.Contains("Ui.Button(CacheUpkeep.ClearEverythingLabel, () => ClearCache(true))", settings);
        Assert.Contains("upkeep.ClearEverythingAsync() : await upkeep.ClearCacheAsync()", settings);
    }

    /// <summary>Every holder on Windows leases its key, the app schedules its passes, and editors hold, move and release their
    /// project's lease (architecture §8.2). These run only in the WinUI app, so the source is checked here.</summary>
    [Fact]
    public void EveryCacheHolderInTheAppTakesItsLease()
    {
        var app = Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App");
        string Source(string path) => File.ReadAllText(Path.Combine(app, path));
        var services = Source("Services/AppServices.cs");
        Assert.Contains("CacheUpkeep.Started();", services);
        Assert.Contains("CacheUpkeep.SettingChanged(key);", services);
        Assert.Contains("await CacheKeys.LeaseAsync(request.ContentKey, ct);", services);
        Assert.Contains("App.Services.CacheUpkeep.Imported();", Source("MainWindow.xaml.cs"));
        var editor = Source("Pages/EditorPage.xaml.cs");
        Assert.Contains("cacheLease.Hold(project.Media.Source.ContentKey);", editor);
        Assert.Contains("cacheLease?.Hold(ViewModel.Project.Media.Source.ContentKey);", editor);
        Assert.Contains("cacheLease?.Dispose();", editor);
        Assert.Contains("App.Services.CacheKeys.LeaseAsync(source.ContentKey, lifetime.Token);", Source("Controls/TranscriptionDialog.cs"));
        Assert.Contains("CacheKeyRegistry.Shared(cacheRoot).LeaseAsync(contentKey, ct)", Source("Services/Thumbnails.cs"));
        Assert.Contains("index.Keys.LeaseAsync(contentKey, ct)", Source("Services/Waveform.cs"));
    }

    private static async Task SeedAsync(CacheIndex index, string key)
    {
        var directory = Directory.CreateDirectory(index.EntryDirectory(key)).FullName;
        await File.WriteAllBytesAsync(Path.Combine(directory, "audio-16k.wav"), new byte[1_000], Ct);
        await index.TouchAsync(key, 1_000, null, Ct);
    }

    private sealed class Folder : IDisposable
    {
        private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("voxclip-cache-upkeep-");
        internal string Root => directory.FullName;
        public void Dispose() => directory.Delete(true);
    }

    private sealed class Clock(DateTimeOffset start) : TimeProvider
    {
        private readonly object sync = new();
        private DateTimeOffset now = start;
        public override DateTimeOffset GetUtcNow() { lock (sync) return now; }
        internal void Advance(TimeSpan span) { lock (sync) now += span; }
    }
}
#endif
