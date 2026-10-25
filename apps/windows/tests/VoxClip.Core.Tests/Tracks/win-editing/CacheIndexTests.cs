using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class CacheIndexTests
{
    [Fact]
    public async Task CacheMissesAreSafeAndEvictionNeverTouchesOpenSourcesOrModels()
    {
        using var storage = new TestStorage();
        var root = storage.PathFor("Cache");
        var index = new CacheIndex(root);
        Assert.Empty(await index.ReadAsync(TestContext.Current.CancellationToken));
        var oldest = new string('a', 64);
        var protectedKey = new string('b', 64);
        var newest = new string('c', 64);
        var envelope = new CacheEnvelope(48000, 0.01, 100);
        await index.TouchAsync(oldest, 100, envelope, TestContext.Current.CancellationToken);
        var created = Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken)).CreatedAt;
        await index.TouchAsync(oldest, 120, null, TestContext.Current.CancellationToken);
        var updated = Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken));
        Assert.Equal(created, updated.CreatedAt);
        Assert.Equal(envelope, updated.Envelope);
        await index.TouchAsync(protectedKey, 100, null, TestContext.Current.CancellationToken);
        await index.TouchAsync(newest, 100, null, TestContext.Current.CancellationToken);
        var corrupt = Path.Combine(root, new string('d', 64));
        Directory.CreateDirectory(corrupt);
        await File.WriteAllTextAsync(Path.Combine(corrupt, "meta.json"), "not json", TestContext.Current.CancellationToken);
        var models = storage.PathFor("Models/model.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(models)!);
        await File.WriteAllTextAsync(models, "model", TestContext.Current.CancellationToken);
        Assert.Equal(3, (await index.ReadAsync(TestContext.Current.CancellationToken)).Count);
        var remainingBytes = Directory.GetFiles(Path.Combine(root, protectedKey), "*", SearchOption.AllDirectories).Concat(Directory.GetFiles(Path.Combine(root, newest), "*", SearchOption.AllDirectories)).Sum(path => new FileInfo(path).Length);
        Assert.Equal([oldest], await index.EvictAsync(remainingBytes + "not json".Length, new HashSet<string> { protectedKey }, TestContext.Current.CancellationToken));
        Assert.Equal([newest], await index.EvictAsync(0, new HashSet<string> { protectedKey }, TestContext.Current.CancellationToken));
        Assert.True(Directory.Exists(Path.Combine(root, protectedKey)));
        Assert.True(File.Exists(models));
        Assert.True(Directory.Exists(corrupt));
    }

    [Fact]
    public async Task CacheByteTotalsDoNotOverflowAndCancelledOperationsDoNotWrite()
    {
        using var storage = new TestStorage();
        var index = new CacheIndex(storage.Root);
        var first = new string('a', 64);
        var second = new string('b', 64);
        await index.TouchAsync(first, long.MaxValue, null, TestContext.Current.CancellationToken);
        await index.TouchAsync(second, long.MaxValue, null, TestContext.Current.CancellationToken);
        Assert.Equal(2, (await index.EvictAsync(0, new HashSet<string>(), TestContext.Current.CancellationToken)).Count);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => index.TouchAsync(first, 1, null, new CancellationToken(true)));
        Assert.Empty(await index.ReadAsync(TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<ArgumentException>(() => index.TouchAsync("../invalid", 1, null, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<ArgumentException>(() => index.TouchAsync(first, -1, null, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task CacheDoesNotFollowASymbolicEntryOutsideItsRoot()
    {
        if (OperatingSystem.IsWindows()) return;
        using var storage = new TestStorage();
        var external = storage.PathFor("external");
        var root = storage.PathFor("Cache");
        Directory.CreateDirectory(external);
        Directory.CreateDirectory(root);
        var key = new string('a', 64);
        Directory.CreateSymbolicLink(Path.Combine(root, key), external);
        var index = new CacheIndex(root);
        Assert.Empty(await index.ReadAsync(TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<IOException>(() => index.TouchAsync(key, 1, null, TestContext.Current.CancellationToken));
        Assert.Empty(Directory.GetFiles(external));
    }

    [Fact]
    public async Task EvictionMeasuresNewFilesInsteadOfTrustingTheTouchEstimate()
    {
        using var storage = new TestStorage();
        var index = new CacheIndex(storage.Root);
        var key = new string('a', 64);
        await index.TouchAsync(key, 0, null, TestContext.Current.CancellationToken);
        var nested = Path.Combine(storage.Root, key, "transcripts");
        Directory.CreateDirectory(nested);
        await File.WriteAllBytesAsync(Path.Combine(nested, "later.json"), new byte[4096], TestContext.Current.CancellationToken);
        Assert.Equal([key], await index.EvictAsync(2048, new HashSet<string>(), TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task OldOrphansAreEvictedOnlyOverLimitWhileFreshAndOpenEntriesAreProtected(bool corrupt)
    {
        using var storage = new TestStorage();
        var index = new CacheIndex(storage.Root);
        var old = new string('a', 64);
        var fresh = new string('b', 64);
        var open = new string('c', 64);
        foreach (var key in new[] { old, fresh, open })
        {
            var directory = Path.Combine(storage.Root, key);
            Directory.CreateDirectory(directory);
            var file = Path.Combine(directory, corrupt ? "meta.json" : "audio-16k.wav");
            await File.WriteAllTextAsync(file, "unfinished", TestContext.Current.CancellationToken);
            if (key != fresh)
            {
                File.SetLastWriteTimeUtc(file, DateTime.UtcNow.AddHours(-2));
                Directory.SetLastWriteTimeUtc(directory, DateTime.UtcNow.AddHours(-2));
            }
        }
        Assert.Empty(await index.EvictAsync(long.MaxValue, new HashSet<string> { open }, TestContext.Current.CancellationToken));
        Assert.True(Directory.Exists(Path.Combine(storage.Root, old)));
        Assert.Equal([old], await index.EvictAsync(20, new HashSet<string> { open }, TestContext.Current.CancellationToken));
        Assert.True(Directory.Exists(Path.Combine(storage.Root, fresh)));
        Assert.True(Directory.Exists(Path.Combine(storage.Root, open)));
        Assert.Equal([open], await index.EvictAsync(0, new HashSet<string>(), TestContext.Current.CancellationToken));
    }
}
