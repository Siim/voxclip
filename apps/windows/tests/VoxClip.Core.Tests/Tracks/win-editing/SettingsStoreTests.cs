using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class SettingsStoreTests
{
    [Fact]
    public async Task FirstLoadReadsPreferencesThatReappearAfterAReplacementNameGap()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var operations = new MissingReadTransition { CreateOnFirstDelay = "{\"schema\":\"voxclip-settings/1\",\"general.appearance\":\"dark\",\"org.example.preference\":true}" };
        var store = new SettingsStore(path, null, operations);

        var loaded = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("dark", loaded.Values["general.appearance"].GetString());
        Assert.True(loaded.Values["org.example.preference"].GetBoolean());
        Assert.Equal(2, operations.ReadAttempts);
        Assert.Equal([25], operations.Delays);
        Assert.Null(store.LastLoadError);

        loaded.Values["export.srt"] = Element("true");
        await store.SaveAsync(loaded, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        var persisted = await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("dark", persisted.Values["general.appearance"].GetString());
        Assert.True(persisted.Values["org.example.preference"].GetBoolean());
        Assert.True(persisted.Values["export.srt"].GetBoolean());
    }

    [Fact]
    public async Task FirstLaunchMissingSettingsReturnDefaultsAfterBoundedRetry()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var operations = new MissingReadTransition();
        var store = new SettingsStore(path, null, operations);

        var loaded = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("system", loaded.Values["general.appearance"].GetString());
        Assert.Equal(6, operations.ReadAttempts);
        Assert.Equal([25, 50, 100, 200, 400], operations.Delays);
        Assert.Null(store.LastLoadError);
        Assert.Empty(Directory.EnumerateFileSystemEntries(storage.Root));
    }

    [Fact]
    public async Task ExhaustedNameGapForExistingSettingsIsAnExplicitReadError()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var original = "{\"schema\":\"voxclip-settings/1\",\"general.appearance\":\"dark\"}";
        await File.WriteAllTextAsync(path, original, TestContext.Current.CancellationToken);
        var operations = new MissingReadTransition { FailEveryReadAsMissing = true };
        var store = new SettingsStore(path, null, operations);

        var error = await Assert.ThrowsAsync<VoxClipException>(() => store.LoadAsync(TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, error.Code);
        Assert.IsType<FileNotFoundException>(error.InnerException);
        Assert.Equal("Could not read settings.", store.LastLoadError);
        Assert.Equal(6, operations.ReadAttempts);
        Assert.Equal([25, 50, 100, 200, 400], operations.Delays);
        Assert.Equal(original, await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task CancelledFirstLoadDoesNotCacheDefaults()
    {
        using var storage = new TestStorage();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var path = storage.PathFor("settings.json");
        var operations = new MissingReadTransition { CancelOnFirstDelay = cancellation };
        var store = new SettingsStore(path, null, operations);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.LoadAsync(cancellation.Token));
        Assert.Equal(1, operations.ReadAttempts);
        Assert.Equal([25], operations.Delays);
        await File.WriteAllTextAsync(path, "{\"schema\":\"voxclip-settings/1\",\"general.appearance\":\"dark\"}", TestContext.Current.CancellationToken);
        Assert.Equal("dark", (await store.LoadAsync(TestContext.Current.CancellationToken)).Values["general.appearance"].GetString());
        Assert.Null(store.LastLoadError);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task SettingsReadFailuresExposeDiagnosticsWithOptionalStaticWarnings(bool unauthorized, bool reportWarnings)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        await File.WriteAllTextAsync(path, "{}", TestContext.Current.CancellationToken);
        var warnings = new List<string>();
        Action<string>? onWarning = reportWarnings ? warnings.Add : null;
        var store = new SettingsStore(path, onWarning, new FailedRead { Unauthorized = unauthorized });
        foreach (var operation in new Func<Task>[] { () => store.LoadAsync(TestContext.Current.CancellationToken),
            () => store.SaveAsync(new AppSettings("voxclip-settings/1"), TestContext.Current.CancellationToken) })
        {
            var error = await Assert.ThrowsAsync<VoxClipException>(operation);
            Assert.Equal(VoxClipErrorCode.ProjectUnreadable, error.Code);
            Assert.Equal("Could not read settings.", error.Message);
            Assert.Equal(unauthorized ? typeof(UnauthorizedAccessException) : typeof(IOException), error.InnerException!.GetType());
        }
        Assert.Equal("Could not read settings.", store.LastLoadError);
        Assert.Equal(reportWarnings ? 2 : 0, warnings.Count);
        Assert.All(warnings, warning => Assert.Equal("Could not read settings.", warning));
        Assert.Equal("{}", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task InvalidUtf8SettingsArePreservedAndRecoveredAsDefaults()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var bytes = Encoding.UTF8.GetBytes("{\"schema\":\"voxclip-settings/1\",\"general.appearance\":\"dark\"}");
        bytes[^3] = 0xFF;
        await File.WriteAllBytesAsync(path, bytes, TestContext.Current.CancellationToken);
        var warnings = new List<string>();
        var store = new SettingsStore(path, warnings.Add);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("system", settings.Values["general.appearance"].GetString());
        Assert.NotNull(store.LastLoadError);
        Assert.Equal("Damaged settings were set aside; valid preferences were recovered.", Assert.Single(warnings));
        Assert.Equal(bytes, await File.ReadAllBytesAsync(Assert.Single(Directory.GetFiles(storage.Root, "settings.json.damaged-*")), TestContext.Current.CancellationToken));
        Assert.Equal("{\n  \"schema\": \"voxclip-settings/1\"\n}\n", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task DefaultsMatchTheSchemaAndProviderCatalogWithoutCreatingFiles()
    {
        using var storage = new TestStorage();
        var settings = await new SettingsStore(storage.PathFor("settings.json")).LoadAsync(TestContext.Current.CancellationToken);
        using var schema = FixtureLoader.ReadJson("schemas/settings.schema.json");
        foreach (var property in schema.RootElement.GetProperty("properties").EnumerateObject())
            if (property.Value.TryGetProperty("default", out var expected)) Assert.True(JsonElement.DeepEquals(expected, settings.Values[property.Name]), property.Name);
        using var catalog = FixtureLoader.ReadJson("catalog/llm-providers.json");
        foreach (var connector in catalog.RootElement.GetProperty("connectors").EnumerateArray())
            if (connector.TryGetProperty("defaultModel", out var expected) && expected.ValueKind == JsonValueKind.String)
                Assert.Equal(expected.GetString(), settings.Values["llm.model." + connector.GetProperty("id").GetString()].GetString());
        Assert.Empty(Directory.EnumerateFileSystemEntries(storage.Root));
    }

    [Fact]
    public async Task DebounceIsTrailingAndSerializesAnImmutableSnapshot()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var store = new SettingsStore(path);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        settings.Values["llm.model.anthropic"] = Element("\"custom-one\"");
        settings.Values["llm.model.openai"] = Element("\"custom-two\"");
        settings.Values["org.example.future"] = Element("{\"nested\":[1,true,null,\"õ\"]}");
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        Assert.False(File.Exists(path));
        await Task.Delay(200, TestContext.Current.CancellationToken);
        settings.Values["general.appearance"] = Element("\"dark\"");
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        settings.Values["general.appearance"] = Element("\"light\"");
        await Task.Delay(200, TestContext.Current.CancellationToken);
        Assert.False(File.Exists(path));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        while (!File.Exists(path)) await Task.Delay(25, timeout.Token);
        var persisted = await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("dark", persisted.Values["general.appearance"].GetString());
        Assert.Equal("custom-one", persisted.Values["llm.model.anthropic"].GetString());
        Assert.Equal("custom-two", persisted.Values["llm.model.openai"].GetString());
        Assert.True(JsonElement.DeepEquals(settings.Values["org.example.future"], persisted.Values["org.example.future"]));
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.Empty(Directory.GetFiles(storage.Root, "*.tmp"));
    }

    [Fact]
    public async Task ReplacementsAreAlwaysWholeJsonAndFlushWritesOnlyTheLatestSnapshot()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var store = new SettingsStore(path);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        settings.Values["org.example.large"] = Element(JsonSerializer.Serialize(new string('x', 100_000)));
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        using var done = new CancellationTokenSource();
        var reader = Task.Run(async () =>
        {
            while (!done.IsCancellationRequested)
            {
                using var document = JsonDocument.Parse(await Core.Services.Project.AtomicFile.ReadAllTextAsync(path,
                    new UTF8Encoding(false, true), TestContext.Current.CancellationToken));
                Assert.Equal("voxclip-settings/1", document.RootElement.GetProperty("schema").GetString());
                await Task.Yield();
            }
        }, TestContext.Current.CancellationToken);
        try
        {
            for (var index = 0; index < 15; index++)
            {
                settings.Values["org.example.sequence"] = Element(index.ToString(System.Globalization.CultureInfo.InvariantCulture));
                await store.SaveAsync(settings, TestContext.Current.CancellationToken);
                await store.FlushAsync(TestContext.Current.CancellationToken);
            }
        }
        finally { await done.CancelAsync(); await reader; }
        using var persisted = JsonDocument.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal(14, persisted.RootElement.GetProperty("org.example.sequence").GetInt32());
        var ordered = persisted.RootElement.EnumerateObject().Where(property => property.Name != "schema").Select(property => property.Name).ToArray();
        Assert.Equal(ordered.Order(StringComparer.Ordinal), ordered);
        Assert.Empty(Directory.GetFiles(storage.Root, "*.tmp"));
    }

    [Fact]
    public async Task FailedFlushRetainsThePendingSnapshotForAnExplicitRetry()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var store = new SettingsStore(path, null, new FailedFirstWrite());
        await store.SaveAsync(new AppSettings("voxclip-settings/1"), TestContext.Current.CancellationToken);
        await Assert.ThrowsAnyAsync<IOException>(() => store.FlushAsync(TestContext.Current.CancellationToken));
        Assert.NotNull(store.LastWriteError);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.Null(store.LastWriteError);
        Assert.Equal("voxclip-settings/1", JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!["schema"]!.GetValue<string>());
        Assert.Empty(Directory.GetFiles(storage.Root, "*.tmp"));
    }

    [Fact]
    public async Task DirectoryAtSettingsPathIsAnExplicitReadError()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        Directory.CreateDirectory(path);
        var store = new SettingsStore(path);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => store.LoadAsync(TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, error.Code);
        Assert.Equal("Could not read settings.", store.LastLoadError);
    }

    [Theory]
    [InlineData("{")]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("{\"schema\":null}")]
    [InlineData("{\"schema\":\"voxclip-settings/2\"}")]
    [InlineData("{\"schema\":\"voxclip-settings/1\",\"general.appearance\":\"invalid\"}")]
    [InlineData("{\"schema\":\"voxclip-settings/1\",\"general.showLowConfidence\":1}")]
    [InlineData("{\"schema\":\"voxclip-settings/1\",\"transcription.recentLanguages\":[\"en\",\"en\"]}")]
    [InlineData("{\"schema\":\"voxclip-settings/1\",\"llm.model.openai\":\"\"}")]
    [InlineData("{\"schema\":\"voxclip-settings/1\",\"llm.cloudConsent.openai\":\"yes\"}")]
    [InlineData("{\"schema\":\"voxclip-settings/1\",\"schema\":\"voxclip-settings/1\"}")]
    public async Task CorruptSettingsAreMovedAsideAndDefaultsRemainSaveable(string json)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        await File.WriteAllTextAsync(path, json, TestContext.Current.CancellationToken);
        var store = new SettingsStore(path);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("system", settings.Values["general.appearance"].GetString());
        Assert.True(File.Exists(path));
        Assert.NotNull(store.LastLoadError);
        var quarantined = Assert.Single(Directory.GetFiles(storage.Root, "settings.json.damaged-*"));
        Assert.Equal(json, await File.ReadAllTextAsync(quarantined, TestContext.Current.CancellationToken));
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.Equal("voxclip-settings/1", (await store.LoadAsync(TestContext.Current.CancellationToken)).Schema);
        Assert.Equal(json, await File.ReadAllTextAsync(quarantined, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task InvalidOrCancelledSaveDoesNotReplaceAnEarlierPendingSnapshot()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var store = new SettingsStore(path);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        settings.Values["cache.limitGB"] = Element("3");
        await Assert.ThrowsAsync<JsonException>(() => store.SaveAsync(settings, TestContext.Current.CancellationToken));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.SaveAsync(settings, new CancellationToken(true)));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.FlushAsync(new CancellationToken(true)));
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.Equal(5, (await store.LoadAsync(TestContext.Current.CancellationToken)).Values["cache.limitGB"].GetInt32());
    }

    [Fact]
    public async Task EveryWriterOutputPassesTheRealDraft202012Schemas()
    {
        using var storage = new TestStorage();
        var settingsPath = storage.PathFor("settings.json");
        var store = new SettingsStore(settingsPath);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        settings.Values["general.appearance"] = Element("\"dark\"");
        settings.Values["llm.model.openai"] = Element("\"custom\"");
        settings.Values["general.recentProjects"] = JsonSerializer.SerializeToElement(new[] { storage.PathFor("recent.voxclip") });
        settings.Values["update.htmlURL"] = Element("\"https://github.com/voxconvo/voxclip/releases\"");
        settings.Values["cache.limitGB"] = Element("10");
        settings.Values["org.example.preference"] = Element("{\"enabled\":true}");
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        var files = new List<string> { settingsPath };
        var recoveredPath = storage.PathFor("recovered.json");
        await File.WriteAllTextAsync(recoveredPath, "{\"schema\":\"voxclip-settings/1\",\"general.appearance\":\"dark\",\"cache.limitGB\":3,\"org.example.preference\":true}", TestContext.Current.CancellationToken);
        await new SettingsStore(recoveredPath).LoadAsync(TestContext.Current.CancellationToken);
        files.Add(recoveredPath);
        foreach (var fixture in Directory.GetFiles(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects"), "*.voxclip"))
        {
            var name = Path.GetFileName(fixture);
            var path = storage.PathFor(name);
            await new Core.Services.Project.ProjectStore().SaveAsync(Core.Domain.Shared.ProjectSerialization.Deserialize(await File.ReadAllTextAsync(TestStorage.ProjectPath(name), TestContext.Current.CancellationToken)), path, TestContext.Current.CancellationToken);
            files.Add(path);
        }
        await WinCoreNative.SchemaPython.ValidateAsync(files, TestContext.Current.CancellationToken);
    }

    [Theory]
    [InlineData("voxclip-settings/1")]
    [InlineData("voxclip-settings/2")]
    [InlineData(null)]
    public async Task PerKeyRecoveryPersistsWithoutSaveAndPreservesOriginalBytes(string? schema)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var document = new JsonObject { ["general.appearance"] = "dark", ["update.autoCheck"] = false, ["cache.limitGB"] = 3,
            ["llm.model.openai"] = "custom-model", ["org.future.preference"] = new JsonObject { ["flag"] = true } };
        if (schema is not null) document["schema"] = schema;
        var bytes = System.Text.Encoding.UTF8.GetPreamble().Concat(System.Text.Encoding.UTF8.GetBytes(document.ToJsonString())).ToArray();
        await File.WriteAllBytesAsync(path, bytes, TestContext.Current.CancellationToken);
        var warnings = new List<string>();
        var store = new SettingsStore(path, warnings.Add);
        var recovered = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.NotNull(store.LastLoadError);
        Assert.Equal("Damaged settings were set aside; valid preferences were recovered.", Assert.Single(warnings));
        Assert.DoesNotContain(path, warnings[0], StringComparison.Ordinal);
        var fresh = await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken);
        foreach (var settings in new[] { recovered, fresh })
        {
            Assert.Equal("dark", settings.Values["general.appearance"].GetString());
            Assert.False(settings.Values["update.autoCheck"].GetBoolean());
            Assert.Equal(5, settings.Values["cache.limitGB"].GetInt32());
            Assert.Equal("custom-model", settings.Values["llm.model.openai"].GetString());
            Assert.True(settings.Values["org.future.preference"].GetProperty("flag").GetBoolean());
        }
        Assert.Equal(bytes, await File.ReadAllBytesAsync(Assert.Single(Directory.GetFiles(storage.Root, "settings.json.damaged-*")), TestContext.Current.CancellationToken));
        var persisted = JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!.AsObject();
        Assert.Equal(5, persisted.Count);
        Assert.False(persisted.ContainsKey("cache.limitGB"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedRecoveryWriteKeepsValidPreferencesPendingWithoutRepeatingQuarantine(bool saveAgain)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var original = "{\"schema\":\"voxclip-settings/1\",\"general.appearance\":\"dark\",\"cache.limitGB\":3,\"org.future.preference\":true}";
        await File.WriteAllTextAsync(path, original, TestContext.Current.CancellationToken);
        var warnings = new List<string>();
        var operations = new FailedFirstWrite();
        var store = new SettingsStore(path, warnings.Add, operations);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => store.LoadAsync(TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, error.Code);
        Assert.NotNull(store.LastLoadError);
        Assert.NotNull(store.LastWriteError);
        Assert.IsType<IOException>(error.InnerException);
        var backup = Assert.Single(Directory.GetFiles(storage.Root, "settings.json.damaged-*"));
        Assert.Equal(original, await File.ReadAllTextAsync(backup, TestContext.Current.CancellationToken));
        var recovered = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("dark", recovered.Values["general.appearance"].GetString());
        Assert.True(recovered.Values["org.future.preference"].GetBoolean());
        Assert.Equal(5, recovered.Values["cache.limitGB"].GetInt32());
        recovered.Values["general.appearance"] = Element("\"light\"");
        Assert.Equal("dark", (await store.LoadAsync(TestContext.Current.CancellationToken)).Values["general.appearance"].GetString());
        Assert.Equal(1, operations.Attempts);
        if (saveAgain)
        {
            var latest = await store.LoadAsync(TestContext.Current.CancellationToken);
            latest.Values["export.srt"] = Element("true");
            await store.SaveAsync(latest, TestContext.Current.CancellationToken);
        }
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.Null(store.LastWriteError);
        Assert.Equal(2, operations.Attempts);
        Assert.Single(Directory.GetFiles(storage.Root, "settings.json.damaged-*"));
        Assert.Equal(original, await File.ReadAllTextAsync(backup, TestContext.Current.CancellationToken));
        var persisted = await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal("dark", persisted.Values["general.appearance"].GetString());
        Assert.True(persisted.Values["org.future.preference"].GetBoolean());
        Assert.Equal(saveAgain, persisted.Values["export.srt"].GetBoolean());
        Assert.Collection(warnings,
            warning => Assert.Equal("Damaged settings were set aside; valid preferences were recovered.", warning),
            warning => Assert.Equal("Settings could not be saved; the latest changes remain pending.", warning));
        Assert.All(warnings, warning => Assert.DoesNotContain(path, warning, StringComparison.Ordinal));
    }

    [Fact]
    public async Task ReloadInsideDebounceAndAfterFlushReturnsLatestIndependentSnapshot()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var store = new SettingsStore(path);
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        settings.Values["general.appearance"] = Element("\"dark\"");
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        var reloaded = await store.LoadAsync(TestContext.Current.CancellationToken);
        Assert.False(File.Exists(path));
        Assert.Equal("dark", reloaded.Values["general.appearance"].GetString());
        settings.Values["general.appearance"] = Element("\"light\"");
        reloaded.Values["export.srt"] = Element("true");
        await store.SaveAsync(reloaded, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        foreach (var snapshot in new[] { await store.LoadAsync(TestContext.Current.CancellationToken), await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken) })
        {
            Assert.Equal("dark", snapshot.Values["general.appearance"].GetString());
            Assert.True(snapshot.Values["export.srt"].GetBoolean());
        }
        var saved = JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!.AsObject();
        Assert.Equal(3, saved.Count);
        Assert.DoesNotContain(saved, pair => pair.Key.StartsWith("llm.model.", StringComparison.Ordinal) || pair.Key.StartsWith("llm.baseUrl.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task SavingUnchangedDefaultsDoesNotPinAnyCatalogValues()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("settings.json");
        var store = new SettingsStore(path);
        await store.SaveAsync(await store.LoadAsync(TestContext.Current.CancellationToken), TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.Single(JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!.AsObject());
    }

    private sealed class FailedRead : Core.Services.Project.AtomicFileOperations
    {
        internal bool Unauthorized { get; init; }
        internal override Task<string> ReadAllTextAsync(string path, Encoding encoding, CancellationToken ct)
        {
            if (Unauthorized) throw new UnauthorizedAccessException(path);
            throw new IOException(path);
        }
    }

    private sealed class MissingReadTransition : AtomicFileOperations
    {
        private string? readPath;
        internal string? CreateOnFirstDelay { get; init; }
        internal CancellationTokenSource? CancelOnFirstDelay { get; init; }
        internal bool FailEveryReadAsMissing { get; init; }
        internal int ReadAttempts { get; private set; }
        internal List<int> Delays { get; } = [];

        internal override Task<string> ReadAllTextAsync(string path, Encoding encoding, CancellationToken ct)
        {
            ReadAttempts++;
            readPath = path;
            if (FailEveryReadAsMissing) return Task.FromException<string>(new FileNotFoundException("Injected replacement name gap.", path));
            return base.ReadAllTextAsync(path, encoding, ct);
        }

        internal override async Task DelayAsync(int milliseconds, CancellationToken ct)
        {
            Delays.Add(milliseconds);
            if (Delays.Count == 1 && CreateOnFirstDelay is not null)
                await File.WriteAllTextAsync(readPath!, CreateOnFirstDelay, ct);
            if (Delays.Count == 1) CancelOnFirstDelay?.Cancel();
            ct.ThrowIfCancellationRequested();
        }
    }

    private sealed class FailedFirstWrite : Core.Services.Project.AtomicFileOperations
    {
        internal int Attempts { get; private set; }
        internal override bool UseReplace => false;
        internal override void Move(string source, string destination, bool overwrite)
        {
            if (++Attempts == 1) throw new IOException("Injected write failure.");
            base.Move(source, destination, overwrite);
        }
    }

    private static JsonElement Element(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }
}
