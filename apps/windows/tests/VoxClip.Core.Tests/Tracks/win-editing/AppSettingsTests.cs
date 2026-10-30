using System.Text.Json;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class AppSettingsTests
{
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

    private static JsonElement Element(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }
}
