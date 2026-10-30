using System.Text.Json;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class AppSettingsTests
{
    [Theory]
    [InlineData("voiceLab.labelPosition", "\"top-right\"")]
    [InlineData("voiceLab.labelPosition", "\"top-left\"")]
    [InlineData("voiceLab.labelPosition", "\"bottom-right\"")]
    [InlineData("voiceLab.labelPosition", "\"bottom-left\"")]
    [InlineData("voiceLab.c2pa", "true")]
    [InlineData("voiceLab.c2pa", "false")]
    [InlineData("voiceLab.betaNoticeAccepted", "true")]
    [InlineData("voiceLab.betaNoticeAccepted", "false")]
    public async Task VoiceLabPreferencesRoundTrip(string key, string json)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json"); var store = new SettingsStore(path);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        settings.Set(key, Element(json));
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        var saved = await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken);
        Assert.True(JsonElement.DeepEquals(Element(json), saved.Values[key]));
    }

    [Theory]
    [InlineData("voiceLab.labelPosition", "\"unknown\"")]
    [InlineData("voiceLab.labelPosition", "null")]
    [InlineData("voiceLab.labelPosition", "true")]
    [InlineData("voiceLab.c2pa", "\"true\"")]
    [InlineData("voiceLab.c2pa", "null")]
    [InlineData("voiceLab.c2pa", "1")]
    [InlineData("voiceLab.betaNoticeAccepted", "\"false\"")]
    [InlineData("voiceLab.betaNoticeAccepted", "null")]
    [InlineData("voiceLab.betaNoticeAccepted", "0")]
    public async Task InvalidVoiceLabPreferencesAreRefused(string key, string json)
    {
        using var storage = new TestStorage(); var store = new SettingsStore(storage.PathFor("settings.json"));
        var settings = new AppSettings("voxclip-settings/1"); settings.Set(key, Element(json));
        await Assert.ThrowsAsync<JsonException>(() => store.SaveAsync(settings, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("20", true, "20")]
    [InlineData("12.50", true, "12.5")]
    [InlineData("0", true, "0")]
    [InlineData("999999999.99", true, "999999999.99")]
    [InlineData("", false, null)]
    [InlineData("-1", false, null)]
    [InlineData("1.234", false, null)]
    [InlineData("1000000000", false, null)]
    [InlineData("abc", false, null)]
    public void PublicVoiceLabCapParserUsesTheCanonicalCoreFormat(string text, bool valid, string? canonical)
    {
        Assert.Equal(valid, AppSettings.TryParseVoiceLabMonthlyCap(text, out var amount));
        if (!valid) { Assert.Equal(0m, amount); return; }
        var settings = new AppSettings("voxclip-settings/1"); settings.SetVoiceLabMonthlyCap("elevenlabs", amount);
        Assert.Equal(canonical, settings.GetString("voiceLab.monthlyCapUsd.elevenlabs"));
    }

    [Fact]
    public void HandCodedDefaultsExactlyMatchEverySchemaDefault()
    {
        using var schema = FixtureLoader.ReadJson("schemas/settings.schema.json");
        var expected = schema.RootElement.GetProperty("properties").EnumerateObject()
            .Where(property => property.Value.TryGetProperty("default", out _)).ToDictionary(property => property.Name, property => property.Value.GetProperty("default"));
        Assert.Equal(expected.Keys.Order(StringComparer.Ordinal), AppSettings.Defaults.Keys.Order(StringComparer.Ordinal));
        foreach (var pair in expected) Assert.True(JsonElement.DeepEquals(pair.Value, AppSettings.Defaults[pair.Key]), pair.Key);
        var defaults = Assert.IsAssignableFrom<IDictionary<string, JsonElement>>(AppSettings.Defaults);
        Assert.Throws<NotSupportedException>(() => defaults.Add("changed", Element("true")));
    }

    [Fact]
    public void TypedGettersUseSchemaDefaultsAndReturnNullForMissingOrWrongTypes()
    {
        var settings = new AppSettings("voxclip-settings/1");
        Assert.False(settings.GetBool("general.showLowConfidence"));
        Assert.Equal(5, settings.GetDouble("cache.limitGB"));
        Assert.Equal("system", settings.GetString("general.appearance"));
        Assert.Equal("top-right", settings.GetString("voiceLab.labelPosition"));
        Assert.True(settings.GetBool("voiceLab.c2pa"));
        Assert.False(settings.GetBool("voiceLab.betaNoticeAccepted"));
        Assert.Null(settings.GetString("export.folder"));
        foreach (var key in new[] { "missing", "export.folder" })
        {
            Assert.Null(settings.GetBool(key));
            Assert.Null(settings.GetDouble(key));
            Assert.Null(settings.GetString(key));
        }
        settings.Set("boolean", Element("true"));
        settings.Set("number", Element("1.25"));
        settings.Set("text", Element("\"value\""));
        Assert.True(settings.GetBool("boolean"));
        Assert.Equal(1.25, settings.GetDouble("number"));
        Assert.Equal("value", settings.GetString("text"));
        Assert.Null(settings.GetString("boolean"));
        Assert.Null(settings.GetBool("number"));
        Assert.Null(settings.GetDouble("text"));
        settings.Set("general.appearance", Element("false"));
        Assert.Null(settings.GetString("general.appearance"));
    }

    [Fact]
    public void SetClonesJsonAndDistinguishesNullValuesFromRemovedKeys()
    {
        var settings = new AppSettings("voxclip-settings/1");
        using (var document = JsonDocument.Parse("{\"nested\":[1,true,null]}")) settings.Set("org.example.value", document.RootElement);
        Assert.Equal(3, settings.Values["org.example.value"].GetProperty("nested").GetArrayLength());
        settings.Set("general.appearance", Element("\"dark\""));
        Assert.Equal("dark", settings.GetString("general.appearance"));
        settings.Set("general.appearance", null);
        Assert.False(settings.Values.ContainsKey("general.appearance"));
        Assert.Equal("system", settings.GetString("general.appearance"));
        settings.Set("org.example.value", null);
        Assert.False(settings.Values.ContainsKey("org.example.value"));
        settings.Set("org.example.null", Element("null"));
        Assert.Equal(JsonValueKind.Null, settings.Values["org.example.null"].ValueKind);
    }

    [Fact]
    public async Task ExplicitLocationsAndTypedRemovalsPersistWithoutPinningDefaults()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("preferences/settings.json");
        var locations = new DataLocations(storage.Root, path, storage.PathFor("Models"), storage.PathFor("Cache"),
            storage.PathFor("Autosave"), storage.PathFor("Secrets"), storage.PathFor("Logs"));
        var store = new SettingsStore(locations);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Empty(Directory.EnumerateFileSystemEntries(storage.Root));
        settings.Set("general.appearance", Element("\"dark\""));
        settings.Set("llm.model.openai", Element("\"custom\""));
        settings.Set("org.example.remove", Element("true"));
        settings.Set("org.example.keep", Element("true"));
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        settings.Set("general.appearance", null);
        settings.Set("llm.model.openai", null);
        settings.Set("org.example.remove", null);
        settings.Set("cache.limitGB", AppSettings.Defaults["cache.limitGB"]);
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        using var written = JsonDocument.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal(new[] { "cache.limitGB", "org.example.keep", "schema" }, written.RootElement.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal));
        var reloaded = await new SettingsStore(locations).LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("system", reloaded.GetString("general.appearance"));
        Assert.NotEqual("custom", reloaded.GetString("llm.model.openai"));
        Assert.Null(reloaded.GetBool("org.example.remove"));
        Assert.True(reloaded.GetBool("org.example.keep"));
    }

    [Fact]
    public async Task UnsetDefaultsReplaceSchemaDefaultsOnlyForUnsetKeysAndAreNeverWritten()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        await File.WriteAllTextAsync(path, "{\"schema\":\"voxclip-settings/1\",\"voiceLab.betaNoticeAccepted\":false}", TestContext.Current.CancellationToken);
        var overlay = new Dictionary<string, JsonElement> { ["voiceLab.enabled"] = Element("true"), ["voiceLab.betaNoticeAccepted"] = Element("true") };
        var store = new SettingsStore(path) { UnsetDefaults = overlay };
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.True(settings.GetBool("voiceLab.enabled"));
        Assert.False(settings.GetBool("voiceLab.betaNoticeAccepted"));
        settings = settings.With("general.appearance", Element("\"dark\""));
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        using (var written = JsonDocument.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken)))
            Assert.Equal(new[] { "general.appearance", "schema", "voiceLab.betaNoticeAccepted" },
                written.RootElement.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal));
        Assert.False((await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken)).GetBool("voiceLab.enabled"));
        settings = (await store.LoadAsync(TestContext.Current.CancellationToken)).With("voiceLab.enabled", Element("false"));
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.False((await new SettingsStore(path) { UnsetDefaults = overlay }.LoadAsync(TestContext.Current.CancellationToken)).GetBool("voiceLab.enabled"));
    }

    [Fact]
    public void UnsetDefaultsAcceptOnlyKnownKeysWithValidValues()
    {
        Assert.Throws<ArgumentException>(() => new SettingsStore("unused.json") { UnsetDefaults = new Dictionary<string, JsonElement> { ["org.example.flag"] = Element("true") } });
        Assert.Throws<JsonException>(() => new SettingsStore("unused.json") { UnsetDefaults = new Dictionary<string, JsonElement> { ["voiceLab.enabled"] = Element("\"yes\"") } });
        Assert.Empty(new SettingsStore("unused.json").UnsetDefaults);
    }

    [Fact]
    public async Task WithKeepsUntouchedDefaultsImplicitAndWritesAnExplicitDefaultValue()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var store = new SettingsStore(path);
        var settings = (await store.LoadAsync(TestContext.Current.CancellationToken)).With("voiceLab.c2pa", AppSettings.Defaults["voiceLab.c2pa"]);
        settings = settings.With("editing.pauseBreath", Element("\"tight\""));
        Assert.Equal("tight", settings.GetString("editing.pauseBreath"));
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        using var written = JsonDocument.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal(new[] { "editing.pauseBreath", "schema", "voiceLab.c2pa" }, written.RootElement.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal));
    }

    private static JsonElement Element(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }
}
