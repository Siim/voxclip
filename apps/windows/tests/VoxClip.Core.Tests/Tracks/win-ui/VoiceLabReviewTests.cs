#if WIN_UI_TESTS
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.LLM;
using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class VoiceLabReviewTests
{
    private static string Root => Path.GetDirectoryName(SharedResources.ResolveRoot())!;
    private static string Pane => File.ReadAllText(Path.Combine(Root, "apps/windows/src/VoxClip.App/Controls/VoiceLabSettingsPane.cs"));

    [Fact]
    public void KeyInventoryUsesGateAwareGenerationOwner()
    {
        Assert.Contains("keyInventory.RefreshAsync()", Pane);
        Assert.DoesNotContain("App.Services.Keys.GetKeyAsync", Pane);
        Assert.Contains("keyInventory.Dispose()", Pane);
    }

    [Fact]
    public async Task GateClosureStopsBlockedInventoryAndReenableReloads()
    {
        var enabled = true;
        var keys = new BlockingKeys();
        using var inventory = new VoiceLabKeyInventory(keys, () => enabled, TestContext.Current.CancellationToken);
        var first = inventory.RefreshAsync();
        Assert.Single(keys.Reads);
        enabled = false;
        await inventory.RefreshAsync();
        Assert.True(keys.FirstToken.IsCancellationRequested);
        keys.Release.SetResult("synthetic-key");
        await first;
        Assert.Single(keys.Reads);
        Assert.Empty(inventory.Rows);
        enabled = true;
        await inventory.RefreshAsync();
        Assert.Equal(4, keys.Reads.Count);
        Assert.Equal(3, inventory.Rows.Count);
    }

    [Fact]
    public async Task ReenableBeforeOldReadCompletesDropsOldGeneration()
    {
        var enabled = true;
        var keys = new BlockingKeys();
        using var inventory = new VoiceLabKeyInventory(keys, () => enabled, TestContext.Current.CancellationToken);
        var first = inventory.RefreshAsync();
        enabled = false;
        await inventory.RefreshAsync();
        enabled = true;
        await inventory.RefreshAsync();
        keys.Release.SetResult("stale-key");
        await first;
        Assert.Equal(4, keys.Reads.Count);
        Assert.All(inventory.Rows, row => Assert.False(row.Saved));
    }

    private sealed class BlockingKeys : IKeyProvider
    {
        internal List<string> Reads { get; } = [];
        internal TaskCompletionSource<string?> Release { get; } = new();
        internal CancellationToken FirstToken { get; private set; }
        public Task<string?> GetKeyAsync(string account, CancellationToken ct)
        {
            Reads.Add(account);
            if (Reads.Count != 1) return Task.FromResult<string?>(null);
            FirstToken = ct;
            return Release.Task;
        }
    }
}
#endif
