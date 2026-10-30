#if WIN_UI_TESTS
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.LLM;
using VoxClip.App.ViewModels;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class VoiceLabReviewTests
{
    private static string Root => Path.GetDirectoryName(SharedResources.ResolveRoot())!;
    private static string Pane => File.ReadAllText(Path.Combine(Root, "apps/windows/src/VoxClip.App/Controls/VoiceLabSettingsPane.cs"));

    [Fact]
    public void R3ContractKeepsMachineLocalCommandsOutsideRepository()
    {
        var contracts = File.ReadAllText(Path.Combine(Root, "apps/windows/CONTRACTS.md"));
        var entry = contracts.Split("### 2026-10-30 — sol-win-voicelab-ui round 3", StringSplitOptions.None)[1].Split("\n### ", StringSplitOptions.None)[0];
        Assert.DoesNotContain("/tmp/", entry);
        Assert.Contains("native UIA/Narrator", entry);
    }

    [Fact]
    public void VoiceActionsUseDisambiguatedNamesAndDistinctAutomationIds()
    {
        Assert.Contains("VoiceLabActionNames.ForRecord", Pane);
        Assert.Contains("VoiceLabActionNames.ForOperation", Pane);
        Assert.Contains("\"delete-voice-\" + record.RecordId", Pane);
        Assert.Contains("\"remove-local-voice-\" + record.RecordId", Pane);
    }

    [Theory]
    [InlineData(2)]
    [InlineData(3)]
    public void SameNameVoiceActionsAreUniqueIncludingSameDay(int count)
    {
        var seed = JsonSerializer.Deserialize<VoiceConsentRecord>(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures/voice-lab/consent-record.json")), new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        var records = Enumerable.Range(1, count).Select(index => seed with { RecordId = Guid.NewGuid().ToString("D"), VoiceName = "My voice", VoiceId = "synthetic-00000" + index, CreatedAt = new DateTimeOffset(2026, 10, 30, index, 0, 0, TimeSpan.Zero) }).ToArray();
        foreach (var action in new[] { "Delete voice", "Remove from VoxClip only" })
        {
            var names = records.Select(record => VoiceLabActionNames.ForRecord(action, record, records)).ToArray();
            Assert.Equal(count, names.Distinct().Count());
            Assert.All(names, name => Assert.StartsWith(action + " My voice, created 30 October 2026, voice ID ending 00000", name));
        }
        var otherDay = records[0] with { CreatedAt = records[0].CreatedAt.AddDays(-1) };
        Assert.Equal("Delete voice My voice, created 29 October 2026", VoiceLabActionNames.ForRecord("Delete voice", otherDay, [otherDay, records[1]]));
        var operations = records.Select(record => new VoiceOperation(Guid.NewGuid(), VoiceOperationKind.Create, record.RecordId, "nonce", ElevenLabsRegion.Default, record.CreatedAt, record.CreatedAt, VoiceOperationState.Intent, null, true, null, 0, null, false, null, null)).ToArray();
        foreach (var action in new[] { "Retry voice creation", "Remove unfinished voice" })
        {
            var named = operations.Select(operation => VoiceLabActionNames.ForOperation(action, operation, operations, records)).ToArray();
            Assert.Equal(count, named.Distinct().Count());
            var recordless = operations.Select(operation => VoiceLabActionNames.ForOperation(action, operation, operations, [])).ToArray();
            Assert.Equal(count, recordless.Distinct().Count());
            Assert.EndsWith(", attempt " + count, recordless[^1]);
        }
    }

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
