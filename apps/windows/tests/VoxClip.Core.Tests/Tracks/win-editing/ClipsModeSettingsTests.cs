using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>Claude mode's settings (design.md §6.6), replayed from the vectors the Mac Core reads too
/// (shared/fixtures/clips-mode/clips-mode-settings-cases.json).</summary>
public sealed class ClipsModeSettingsTests
{
    private static JsonDocument Cases() => JsonDocument.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "clips-mode", "clips-mode-settings-cases.json")));

    private static AppSettings Settings(JsonElement document) => new("voxclip-settings/1")
    {
        Values = document.EnumerateObject().Where(property => property.Name != "schema").ToDictionary(property => property.Name, property => property.Value.Clone(), StringComparer.Ordinal)
    };

    [Fact]
    public async Task EveryValidCaseLoadsReadsBackAndSavesUnchanged()
    {
        using var cases = Cases();
        var root = cases.RootElement;
        Assert.Equal("voxclip-clips-mode-settings-cases/1", root.GetProperty("schema").GetString());
        Assert.Equal(root.GetProperty("valid").GetArrayLength() + root.GetProperty("invalid").GetArrayLength(), root.GetProperty("caseCount").GetInt32());
        foreach (var item in root.GetProperty("valid").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString();
            var expect = item.GetProperty("expect");
            using var storage = new TestStorage();
            var path = storage.PathFor("settings.json");
            await File.WriteAllTextAsync(path, item.GetProperty("settings").GetRawText(), TestContext.Current.CancellationToken);
            var store = new SettingsStore(path);
            var loaded = await store.LoadAsync(TestContext.Current.CancellationToken);
            var read = loaded.GetClipsAutopilot();
            Assert.True(read == new ClipsAutopilotSettings(expect.GetProperty("mode").ValueKind == JsonValueKind.Null ? null : expect.GetProperty("mode").GetString(),
                expect.GetProperty("count").GetInt32(), expect.GetProperty("capUSD").GetInt32()), name);
            // Round trip: written back as the creator chose, then read again.
            await store.SaveAsync(loaded.WithClipsAutopilot(read), TestContext.Current.CancellationToken);
            await store.FlushAsync(TestContext.Current.CancellationToken);
            var reloaded = await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken);
            Assert.True(reloaded.GetClipsAutopilot() == read, name);
            using var written = JsonDocument.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
            Assert.Equal(read.Mode is not null, written.RootElement.TryGetProperty(ClipsMode.Key, out _));
            Assert.Equal(read.Count, written.RootElement.GetProperty(ClipsMode.CountKey).GetInt32());
            Assert.Equal(read.CapUsd, written.RootElement.GetProperty(ClipsMode.CapKey).GetInt32());
        }
    }

    [Fact]
    public void EveryInvalidCaseIsRefused()
    {
        using var cases = Cases();
        foreach (var item in cases.RootElement.GetProperty("invalid").EnumerateArray())
        {
            var settings = Settings(item.GetProperty("settings"));
            Assert.ThrowsAny<JsonException>(() => SettingsValidation.Validate(settings));
        }
    }

    [Fact]
    public void KeysAreKnownAndSettingRefusesOtherValues()
    {
        Assert.True(SettingsValidation.KnownKey(ClipsMode.Key));
        Assert.True(SettingsValidation.KnownKey(ClipsMode.CountKey));
        Assert.True(SettingsValidation.KnownKey(ClipsMode.CapKey));
        Assert.False(AppSettings.Defaults.ContainsKey(ClipsMode.Key));
        var settings = new AppSettings("voxclip-settings/1").WithClipsAutopilot(new ClipsAutopilotSettings(ClipsMode.Claude, 5, 0));
        SettingsValidation.Validate(settings);
        Assert.Equal(new ClipsAutopilotSettings(ClipsMode.Claude, 5, 0), settings.GetClipsAutopilot());
        Assert.Equal("✦ Claude does it all · top 5 · ≤$0", settings.GetClipsAutopilot().Summary);
        Assert.Throws<VoxClipException>(() => settings.WithClipsAutopilot(new ClipsAutopilotSettings(ClipsMode.Claude, 4, 2)));
        Assert.Throws<VoxClipException>(() => settings.WithClipsAutopilot(new ClipsAutopilotSettings("auto", 3, 2)));
        Assert.Throws<VoxClipException>(() => settings.WithClipsAutopilot(new ClipsAutopilotSettings(ClipsMode.Pick, 3, 3)));
        Assert.Null(settings.WithClipsAutopilot(new ClipsAutopilotSettings(null, 3, 2)).GetClipsAutopilot().Mode);
    }
}
