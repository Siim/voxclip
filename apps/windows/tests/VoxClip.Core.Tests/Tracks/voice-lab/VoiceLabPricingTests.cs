using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Replays shared/fixtures/voice-lab/pricing-cases.json (Voice Lab §3.1 and §3.2, rules in pricing-cases-README.md).</summary>
[Trait("Track", "voice-lab")]
public sealed class VoiceLabPricingTests
{
    private static readonly Lazy<JsonObject> Document = new(() =>
    {
        var document = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/pricing-cases.json"))!.AsObject();
        Assert.Equal("voxclip-voice-lab-pricing-cases/1", document["schema"]!.GetValue<string>());
        return document;
    });
    private static VoiceLabPriceCatalog Catalog() => VoiceLabPrices.Load(FixtureLoader.SharedRoot);
    private static JsonObject Ledger => Document.Value["ledger"]!.AsObject();
    private static JsonObject[] Rows(JsonNode? array)
    {
        var rows = array!.AsArray().Select(row => row!.AsObject()).ToArray();
        Assert.NotEmpty(rows);
        return rows;
    }
    private static string? Text(JsonNode? node) => node?.GetValue<string>();
    private static decimal? Amount(JsonNode? node) => node is null ? null : decimal.Parse(node.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture);
    private static DateTimeOffset Instant(JsonNode? node) =>
        DateTimeOffset.Parse(node!.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
    private static TimeZoneInfo Zone(JsonNode? offset) =>
        TimeZoneInfo.CreateCustomTimeZone("fixture", TimeSpan.FromSeconds(offset!.GetValue<int>()), "fixture", "fixture");
    private static VoiceLabPricedOperation Operation(JsonNode? node) =>
        new(Text(node!["provider"])!, Text(node["operation"])!, Text(node["endpoint"]), Text(node["unit"])!);
    private static CostEstimate Spend(JsonNode row) => new(Text(row["provider"])!, "fixture", 1, "call", Amount(row["usd"]), null, "fixture");
    private static VoiceLabCostPresentationResult Presentation(JsonNode? node) =>
        new(Text(node!["kind"]) == "inline" ? VoiceLabCostPresentationKind.Inline : VoiceLabCostPresentationKind.Confirm, Text(node["text"])!);
    private static VoiceLabMonthlyCap? Cap(JsonNode? node) => node is null ? null : new(Amount(node["limit"])!.Value, Amount(node["spent"])!.Value);
    private static readonly CostEstimate Isolation = new("elevenlabs", "audioIsolation", 180, "second", 0.36m, 3000, "list-2026-10-25");

    private static void Check(CostEstimate estimate, JsonNode expected, string id)
    {
        Assert.True(estimate.Units == expected["units"]!.GetValue<double>(), id + " units");
        Assert.True(estimate.Unit == Text(expected["unit"]), id + " unit");
        Assert.True((estimate.Usd is { } usd ? VoiceLabMoney.Canonical(usd) : null) == Text(expected["usd"]), id + " usd");
        Assert.True(estimate.Credits == expected["credits"]?.GetValue<int>(), id + " credits");
        Assert.True(estimate.Basis == Text(expected["basis"]), id + " basis");
    }

    private sealed class Scratch : IDisposable
    {
        internal string Root { get; } = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "voxclip-spend-" + Guid.NewGuid().ToString("N"))).FullName;
        public void Dispose() { try { Directory.Delete(Root, true); } catch (IOException) { } }
    }

    private sealed class Discovery(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        internal Discovery(Func<HttpRequestMessage, HttpResponseMessage> respond) : this((request, _) => Task.FromResult(respond(request))) { }
        internal int Billable { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            if (request.RequestUri!.AbsolutePath is not ("/v1/models" or "/v1/user/subscription" or "/v2/voices")) Billable++;
            return respond(request, ct);
        }
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private const string Models = "[{\"model_id\":\"eleven_v3\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"}],\"model_rates\":{\"character_cost_multiplier\":0.5}}," +
        "{\"model_id\":\"new_speech_model\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"}]}," +
        "{\"model_id\":\"eleven_multilingual_sts_v2\",\"can_do_voice_conversion\":true,\"languages\":[{\"language_id\":\"en\"}],\"model_rates\":null}]";
    private const string Plan = "{\"tier\":\"starter\",\"status\":\"active\",\"character_count\":0,\"character_limit\":10000,\"can_use_instant_voice_cloning\":true,\"voice_slots_used\":0,\"voice_limit\":10}";
    private const string Voices = "{\"voices\":[{\"voice_id\":\"own123\",\"name\":\"Mine\",\"category\":\"cloned\",\"is_owner\":true,\"voice_verification\":{\"requires_verification\":false,\"is_verified\":true}}," +
        "{\"voice_id\":\"stock123\",\"name\":\"Stock\",\"category\":\"premade\"}],\"has_more\":false}";
    /// <summary>The EU provider: discovery finds <c>eleven_v3</c>, <c>eleven_multilingual_sts_v2</c>, the own voice <c>own123</c> and the stock voice
    /// <c>stock123</c>. Every other request goes to <paramref name="action"/> with its token.</summary>
    private static Discovery Provider(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) => new((request, ct) => request.RequestUri!.AbsolutePath switch
    {
        "/v1/models" => Task.FromResult(Json(Models)), "/v1/user/subscription" => Task.FromResult(Json(Plan)), "/v2/voices" => Task.FromResult(Json(Voices)),
        _ => action(request, ct)
    });
    private static async Task<ElevenLabsVoiceLab> DiscoveredLabAsync(Discovery handler, VoiceLabSpendLedger? spend, CancellationToken ct)
    {
        var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys("synthetic-test-key"), handler, ElevenLabsRegion.Eu, new CaptureLog(), prices: Catalog(), spend: spend);
        await service.DiscoverModelsAsync(ct);
        await service.DiscoverSubscriptionAsync(ct);
        await service.DiscoverVoicesAsync(ct);
        return service;
    }
    /// <summary>A timestamped TTS reply for "Hi" with <paramref name="pcm"/>.</summary>
    private static HttpResponseMessage Speech(byte[] pcm) => Json(SpeechJson(pcm));
    private static string SpeechJson(byte[] pcm) => "{\"audio_base64\":\"" + Convert.ToBase64String(pcm) +
        "\",\"alignment\":{\"characters\":[\"H\",\"i\"],\"character_start_times_seconds\":[0,0.02],\"character_end_times_seconds\":[0.02,0.04]}}";
    /// <summary>A reply body whose reads the test scripts: <c>read</c> gets the read's number from 1, the buffer and the read's token.</summary>
    private sealed class ScriptedBody(Func<int, Memory<byte>, CancellationToken, Task<int>> read) : Stream
    {
        private int reads;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => new(read(++reads, buffer, cancellationToken));
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            read(++reads, buffer.AsMemory(offset, count), cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    [Fact]
    public void CatalogIsTheFixtureInputAndLoads()
    {
        var bytes = File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, "catalog", "voice-lab.json"));
        Assert.Equal(Text(Document.Value["inputs"]!["shared/catalog/voice-lab.json"]), Convert.ToHexStringLower(SHA256.HashData(bytes)));
        var catalog = Catalog();
        Assert.Equal(18, catalog.Entries.Count);
        Assert.Equal(VoiceLabPriceFormula.Zero, catalog.Find(VoiceLabPricedOperation.ElevenLabsDeleteClone, null)?.Formula);
        Assert.Equal("2026-10-25", catalog.Find(VoiceLabPricedOperation.ElevenLabsTextToSpeech, "eleven_v3")?.Checked);
        Assert.Equal("2026-10-26", catalog.Find(VoiceLabPricedOperation.FalLipsync("fal-ai/sync-lipsync/v3"), null)?.Checked);
    }

    [Fact]
    public void CatalogDefectsAreRefused()
    {
        var original = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "catalog", "voice-lab.json")))!.AsObject();
        bool Refused(Action<JsonArray, JsonObject> change)
        {
            var root = original.DeepClone().AsObject();
            change(root["entries"]!.AsArray(), root);
            try { VoiceLabPriceCatalog.Parse(Encoding.UTF8.GetBytes(root.ToJsonString())); return false; }
            catch (VoxClipException exception) when (exception.Code == VoxClipErrorCode.SharedResourcesMissing) { return true; }
        }
        Assert.False(Refused((_, _) => { }));
        Assert.True(Refused((_, root) => root["schema"] = "voxclip-voice-lab-prices/2"));
        Assert.True(Refused((entries, _) => entries[0]!["usdParameters"] = new JsonObject { ["perHour"] = 0.22 }));
        Assert.True(Refused((entries, _) => entries[0]!["usdParameters"] = new JsonObject { ["perHour"] = "-0.22" }));
        Assert.True(Refused((entries, _) => entries[0]!["unit"] = "character"));
        Assert.True(Refused((entries, _) => entries[0]!["formula"] = "perDay"));
        Assert.True(Refused((entries, _) => entries[0]!["creditsParameters"] = new JsonObject { ["perMinute"] = "1000" }));
        Assert.True(Refused((entries, _) => entries[1]!.AsObject().Remove("source")));
        Assert.True(Refused((entries, _) => entries[1]!["note"] = "extra"));
        Assert.True(Refused((entries, _) => entries[9]!["usdParameters"] = new JsonObject { ["perCall"] = "1" }));
        // Two entries that could price one request: an exact duplicate, and a model-less entry beside model entries.
        Assert.True(Refused((entries, _) => entries.Add(entries[4]!.DeepClone())));
        Assert.True(Refused((entries, _) => { var row = entries[4]!.DeepClone().AsObject(); row.Remove("model"); entries.Add(row); }));
    }

    [Fact]
    public void EstimatesReplayEveryCase()
    {
        var catalog = Catalog();
        foreach (var row in Rows(Document.Value["estimates"]))
        {
            var id = Text(row["id"])!;
            var operation = Operation(row["operation"]);
            CostEstimate Estimate() => VoiceLabPricing.Estimate(operation, Text(row["model"]), row["units"]!.GetValue<double>(),
                row["candidates"]!.GetValue<int>(), row["characterMultiplier"]?.GetValue<double>(), catalog);
            var expected = row["expected"]!;
            if (expected["error"] is not null)
            {
                Assert.True(Assert.Throws<VoiceLabException>(Estimate).Kind == VoiceLabErrorKind.InvalidInput, id);
                continue;
            }
            var result = Estimate();
            Assert.True(result.Provider == operation.Provider && result.Operation == operation.Operation, id);
            Check(result, expected, id);
        }
    }

    [Fact]
    public void ProviderPricesReplaceTheAmountThroughTheTypedHook()
    {
        foreach (var row in Rows(Document.Value["providerPrices"]))
        {
            var id = Text(row["id"])!;
            var source = row["estimate"]!;
            var estimate = new CostEstimate(Text(source["provider"])!, Text(source["operation"])!, source["units"]!.GetValue<double>(), Text(source["unit"])!,
                Amount(source["usd"]), source["credits"]?.GetValue<int>(), Text(source["basis"])!);
            var price = row["price"]!;
            var live = new VoiceLabProviderPrice(Amount(price["usd"])!.Value, price["credits"]?.GetValue<int>(),
                Text(price["basis"]) == "provider-estimate" ? VoiceLabProviderPriceBasis.ProviderEstimate : VoiceLabProviderPriceBasis.ProviderPricingApi);
            var expected = row["expected"]!;
            if (expected["error"] is not null)
            {
                Assert.True(Assert.Throws<VoiceLabException>(() => VoiceLabPricing.Apply(live, estimate)).Kind == VoiceLabErrorKind.InvalidInput, id);
                continue;
            }
            var result = VoiceLabPricing.Apply(live, estimate);
            Assert.True(result.Provider == Text(expected["provider"]) && result.Operation == Text(expected["operation"]), id);
            Check(result, expected, id);
        }
    }

    [Fact]
    public void FormatsPresentationsAndButtonsReplay()
    {
        foreach (var row in Rows(Document.Value["formats"]))
        {
            var usd = Amount(row["usd"])!.Value;
            Assert.Equal(Text(row["text"]), VoiceLabCostPresentation.Format(usd));
            var estimate = new CostEstimate("elevenlabs", "textToSpeech", 1, "character", usd, null, "list-2026-10-25");
            Assert.Equal(Presentation(row["presentation"]), VoiceLabCostPresentation.Kind(estimate, false, "ElevenLabs"));
        }
        foreach (var row in Rows(Document.Value["presentations"]))
        {
            var estimate = new CostEstimate("fixture", "fixture", 1, "call", Amount(row["usd"]), null, "fixture");
            var kind = VoiceLabCostPresentation.Kind(estimate, row["isLipSync"]!.GetValue<bool>(), Text(row["providerName"])!, Cap(row["cap"]));
            Assert.True(Presentation(row["expected"]) == kind, row.ToJsonString());
        }
        foreach (var row in Rows(Document.Value["buttons"]))
        {
            var estimate = new CostEstimate("elevenlabs", "fixture", 1, "call", Amount(row["usd"]), null, "fixture");
            var kind = VoiceLabCostPresentation.Kind(estimate, row["isLipSync"]!.GetValue<bool>(), "ElevenLabs", Cap(row["cap"]));
            Assert.Equal(Text(row["text"]), VoiceLabCostPresentation.ButtonTitle(Text(row["action"])!, row["takes"]?.GetValue<int>(), kind));
        }
    }

    [Fact]
    public async Task ElevenLabsQuotesCarryCatalogEstimates()
    {
        using var handler = Provider((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound)));
        var ct = TestContext.Current.CancellationToken;
        using var service = await DiscoveredLabAsync(handler, null, ct);
        foreach (var row in Rows(Document.Value["quotes"]))
        {
            var id = Text(row["id"])!;
            var model = Text(row["model"]) ?? "";
            var prepared = Text(row["operation"]) switch
            {
                "textToSpeech" => service.PrepareSynthesis(Text(row["text"])!, model, VoiceLabVoiceChoice.Stock("stock123"), "en", new VoiceLabSpeechOptions(7), Guid.NewGuid()),
                "voiceChange" => service.PrepareConversion(VoiceLabTestCalls.SyntheticWav(row["wav"]!["rate"]!.GetValue<int>(), row["wav"]!["frames"]!.GetValue<int>()),
                    model, VoiceLabVoiceChoice.Stock("stock123"), "en", 7, false, Guid.NewGuid()),
                "createClone" => service.PrepareClone(VoiceLabTestCalls.CloneRequest(), new OwnVoicePolicy("record-1", null, true, true, true, true, true), Guid.NewGuid()),
                _ => service.PrepareDeletion("own123", new OwnVoicePolicy("record-1", "own123", true, true, true, true, true), Guid.NewGuid())
            };
            var estimate = prepared.Estimate.ToCostEstimate();
            var expected = row["expected"]!;
            Assert.True(estimate.Provider == Text(expected["provider"]) && estimate.Operation == Text(expected["operation"]), id);
            Check(estimate, expected, id);
        }
        // A run of takes uses the same discovered multiplier, for credits only; preparation and estimates send nothing billable.
        var run = service.Estimate(VoiceLabOperation.TextToSpeech, "eleven_v3", 60, 3);
        Assert.True(run.Usd is { } usd && VoiceLabMoney.Canonical(usd) == "0.0144" && run.Credits == 90 && run.Units == 180);
        Assert.Equal(0, handler.Billable);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("0.0099")]
    [InlineData("100.5")]
    [InlineData("\"0.5\"")]
    [InlineData("true")]
    [InlineData("null")]
    [InlineData("1e400")]
    public async Task DiscoveryRefusesAMalformedCharacterMultiplier(string value)
    {
        var models = "[{\"model_id\":\"eleven_v3\",\"can_do_text_to_speech\":true,\"model_rates\":{\"character_cost_multiplier\":" + value + "}}]";
        using var handler = new Discovery(_ => Json(models));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys("synthetic-test-key"), handler, ElevenLabsRegion.Eu, new CaptureLog(), prices: Catalog());
        await Assert.ThrowsAnyAsync<Exception>(() => service.DiscoverModelsAsync(TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task RolloversUseTheLocalCalendarMonthAtTheStart()
    {
        Assert.Equal(Text(Ledger["emptyFile"]), new VoiceLabSpendDocument().Encode());
        foreach (var row in Rows(Ledger["rollovers"]))
        {
            using var scratch = new Scratch();
            var data = new DataLocations(scratch.Root, Path.Combine(scratch.Root, "settings.json"), "", "", "", "", "");
            var ledger = new VoiceLabSpendLedger(data, Zone(row["timeZoneOffsetSeconds"]));
            Assert.Equal(Path.Combine(scratch.Root, "VoiceLab", "spend.json"), ledger.FilePath);
            foreach (var step in Rows(row["records"]))
            {
                var at = Instant(step["at"]);
                Assert.Equal(Text(step["month"]), ledger.Month(at));
                Assert.Null(await ledger.RecordAsync(Spend(step), at, TestContext.Current.CancellationToken));
            }
            Assert.Equal(Text(row["ledger"]), await File.ReadAllTextAsync(ledger.FilePath, TestContext.Current.CancellationToken));
            if (!OperatingSystem.IsWindows())
            {
                // Only VoiceLab itself is created, 0700 like the paid-asset root; the ledger and its lock are 0600.
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(Path.GetDirectoryName(ledger.FilePath)!));
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(ledger.FilePath));
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(ledger.FilePath + ".lock"));
            }
            var names = Directory.GetFiles(Path.GetDirectoryName(ledger.FilePath)!).Select(file => Path.GetFileName(file)).Order(StringComparer.Ordinal).ToArray();
            Assert.Equal(new[] { "spend.json", "spend.json.lock" }, names);
        }
    }

    [Fact]
    public async Task TwoConcurrentRecordersLoseNoUpdate()
    {
        var concurrent = Ledger["concurrent"]!;
        using var scratch = new Scratch();
        var path = Path.Combine(scratch.Root, "VoiceLab", "spend.json");
        var at = Instant(concurrent["at"]);
        var count = concurrent["recordsPerWriter"]!.GetValue<int>();
        var writers = Rows(concurrent["writers"]);
        using var barrier = new Barrier(writers.Length);
        var ct = TestContext.Current.CancellationToken;
        var runs = writers.Select(writer =>
        {
            // Separate ledger instances with separate lock handles, as the App and the CLI would have.
            var ledger = new VoiceLabSpendLedger(path, TimeZoneInfo.Utc);
            var estimate = Spend(writer);
            return Task.Run(async () =>
            {
                barrier.SignalAndWait(ct);
                var warnings = new List<VoiceLabSpendWarning>();
                for (var index = 0; index < count; index++)
                    if (await ledger.RecordAsync(estimate, at, ct) is { } warning) warnings.Add(warning);
                return warnings;
            }, ct);
        }).ToArray();
        Assert.Empty((await Task.WhenAll(runs)).SelectMany(warnings => warnings));
        Assert.Equal(Text(concurrent["ledger"]), await File.ReadAllTextAsync(path, ct));
    }

    [Fact]
    public async Task CorruptLedgersAreMovedAsideAndAFreshLedgerStarts()
    {
        var recovery = Ledger["recoveryRecord"]!;
        foreach (var row in Rows(Ledger["existing"]))
        {
            var id = Text(row["id"])!;
            using var scratch = new Scratch();
            var path = Path.Combine(scratch.Root, "spend.json");
            var bytes = Text(row["contentBase64"]) is { } encoded ? Convert.FromBase64String(encoded) : Encoding.UTF8.GetBytes(Text(row["content"])!);
            await File.WriteAllBytesAsync(path, bytes, TestContext.Current.CancellationToken);
            var warning = await new VoiceLabSpendLedger(path, TimeZoneInfo.Utc).RecordAsync(Spend(recovery), Instant(recovery["at"]), TestContext.Current.CancellationToken);
            var backups = Directory.GetFiles(scratch.Root, "spend.corrupt-*").Select(file => Path.GetFileName(file)).ToArray();
            if (row["corrupt"]!.GetValue<bool>())
            {
                var backup = Assert.Single(backups)!;
                Assert.Matches("\\Aspend\\.corrupt-[0-9]{13}\\.json\\z", backup);
                Assert.True(warning == new VoiceLabSpendWarning(VoiceLabSpendWarningKind.ReplacedCorruptLedger, backup), id);
                Assert.Equal(bytes, await File.ReadAllBytesAsync(Path.Combine(scratch.Root, backup), TestContext.Current.CancellationToken));
            }
            else Assert.True(warning is null && backups.Length == 0, id);
            Assert.True(Text(row["ledger"]) == await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken), id);
        }
    }

    [Fact]
    public async Task FreeActionsAreNeverRecorded()
    {
        var free = Ledger["freeOnly"]!;
        var ct = TestContext.Current.CancellationToken;
        using var scratch = new Scratch();
        var data = new DataLocations(scratch.Root, Path.Combine(scratch.Root, "settings.json"), "", "", "", "", "");
        var ledger = new VoiceLabSpendLedger(data, Zone(free["timeZoneOffsetSeconds"]));
        foreach (var step in Rows(free["records"])) Assert.Null(await ledger.RecordAsync(Spend(step), Instant(step["at"]), ct));
        Assert.False(Directory.Exists(Path.Combine(scratch.Root, "VoiceLab")));
        Assert.Equal(new VoiceLabSpendDocument().Encode(), (await ledger.ReadAsync(ct))!.Encode());
    }

    [Fact]
    public async Task FailuresReturnTypedWarningsAndRecordNothing()
    {
        using var scratch = new Scratch();
        var ct = TestContext.Current.CancellationToken;
        var path = Path.Combine(scratch.Root, "spend.json");
        var ledger = new VoiceLabSpendLedger(path, TimeZoneInfo.Utc, TimeSpan.FromMilliseconds(50));
        var now = DateTimeOffset.UtcNow;
        using (new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        {
            // Another holder of the lock: a writer gives up after LockTimeout, a reader after ReadTimeout, and nothing changes.
            Assert.Equal(new VoiceLabSpendWarning(VoiceLabSpendWarningKind.LockTimedOut), await ledger.RecordAsync(Isolation, now, ct));
            Assert.Null(await ledger.ReadAsync(ct));
            Assert.False(await ledger.WouldCrossAsync(0, "elevenlabs", Isolation, now, ct));
            // The token cancels only the wait for the lock, at once instead of after a long timeout.
            var patient = new VoiceLabSpendLedger(path, TimeZoneInfo.Utc, TimeSpan.FromMinutes(1));
            using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));
            var watch = Stopwatch.StartNew();
            Assert.Equal(new VoiceLabSpendWarning(VoiceLabSpendWarningKind.Cancelled), await patient.RecordAsync(Isolation, now, cancel.Token));
            Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
        }
        Assert.False(File.Exists(path));
        Assert.Equal(new VoiceLabSpendWarning(VoiceLabSpendWarningKind.InvalidEstimate), await ledger.RecordAsync(Isolation with { Provider = "Eleven Labs" }, now, ct));
        Assert.Equal(new VoiceLabSpendWarning(VoiceLabSpendWarningKind.InvalidEstimate), await ledger.RecordAsync(Isolation with { Usd = -1 }, now, ct));
        Assert.False(File.Exists(path));
        // A file where the ledger's directory belongs, and a missing data folder, which the ledger never creates.
        var blocked = Path.Combine(scratch.Root, "not-a-directory");
        await File.WriteAllBytesAsync(blocked, [], ct);
        var writeFailed = new VoiceLabSpendWarning(VoiceLabSpendWarningKind.WriteFailed);
        Assert.Equal(writeFailed, await new VoiceLabSpendLedger(Path.Combine(blocked, "spend.json")).RecordAsync(Isolation, now, ct));
        var missing = Path.Combine(scratch.Root, "missing-data");
        var orphan = new VoiceLabSpendLedger(new DataLocations(missing, Path.Combine(missing, "settings.json"), "", "", "", "", ""));
        Assert.Equal(writeFailed, await orphan.RecordAsync(Isolation, now, ct));
        Assert.False(Directory.Exists(missing));
        Assert.Null(await ledger.RecordAsync(Isolation, now, ct));
        Assert.Equal(new VoiceLabSpendTotal(0.36m, 0), await ledger.TotalAsync("elevenlabs", now, ct));
    }

    [Fact]
    public async Task ReadOnlyFoldersAndOtherIoFailuresFailAtOnce()
    {
        using var scratch = new Scratch();
        var ct = TestContext.Current.CancellationToken;
        var directory = Directory.CreateDirectory(Path.Combine(scratch.Root, "VoiceLab")).FullName;
        var lockPath = Path.Combine(directory, "spend.json.lock");
        var ledger = new VoiceLabSpendLedger(Path.Combine(directory, "spend.json"), TimeZoneInfo.Utc, TimeSpan.FromMinutes(1));
        var writeFailed = new VoiceLabSpendWarning(VoiceLabSpendWarningKind.WriteFailed);
        var watch = Stopwatch.StartNew();
        if (OperatingSystem.IsWindows())
        {
            // Windows ignores the read-only attribute on folders, so the lock file itself is read-only.
            await File.WriteAllBytesAsync(lockPath, [], ct);
            File.SetAttributes(lockPath, FileAttributes.ReadOnly);
            try { Assert.Equal(writeFailed, await ledger.RecordAsync(Isolation, DateTimeOffset.UtcNow, ct)); }
            finally { File.SetAttributes(lockPath, FileAttributes.Normal); }
        }
        else
        {
            // Without a lock file the lock cannot be created; with one, the temporary file cannot.
            var readOnly = UnixFileMode.UserRead | UnixFileMode.UserExecute;
            var writable = readOnly | UnixFileMode.UserWrite;
            File.SetUnixFileMode(directory, readOnly);
            try
            {
                Assert.Equal(writeFailed, await ledger.RecordAsync(Isolation, DateTimeOffset.UtcNow, ct));
                File.SetUnixFileMode(directory, writable);
                await File.WriteAllBytesAsync(lockPath, [], ct);
                File.SetUnixFileMode(directory, readOnly);
                Assert.Equal(writeFailed, await ledger.RecordAsync(Isolation, DateTimeOffset.UtcNow, ct));
            }
            finally { File.SetUnixFileMode(directory, writable); }
            // An I/O error that is not a held lock, here a link to itself (ELOOP), is not waited for either.
            File.Delete(lockPath);
            File.CreateSymbolicLink(lockPath, lockPath);
            Assert.Equal(writeFailed, await ledger.RecordAsync(Isolation, DateTimeOffset.UtcNow, ct));
        }
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
        Assert.False(File.Exists(ledger.FilePath));
    }

    [Fact]
    public async Task TheServiceRecordsEachAcceptedActionOnce()
    {
        using var scratch = new Scratch();
        var ct = TestContext.Current.CancellationToken;
        var ledger = new VoiceLabSpendLedger(Path.Combine(scratch.Root, "VoiceLab", "spend.json"), TimeZoneInfo.Utc);
        var pcm = new byte[4800];
        var status = HttpStatusCode.OK;
        var slow = false;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = Provider(async (request, token) =>
        {
            switch (request.RequestUri!.AbsolutePath)
            {
                case "/v1/voices/add": return Json("{\"voice_id\":\"new123\",\"requires_verification\":false}");
                case "/v1/voices/own123": return Json("{\"status\":\"ok\"}");
                case "/v1/text-to-speech/stock123/with-timestamps":
                    if (slow)
                    {
                        entered.TrySetResult();
                        await Task.Delay(Timeout.Infinite, token);
                    }
                    return status == HttpStatusCode.OK ? Speech(pcm) : new HttpResponseMessage(status) { Content = new StringContent("{\"detail\":\"busy\"}") };
                case "/v1/voice-changer/stock123":
                    return status == HttpStatusCode.OK ? new HttpResponseMessage(status) { Content = new ByteArrayContent(pcm) { Headers = { ContentType = new("audio/pcm") } } }
                        : new HttpResponseMessage(status) { Content = new StringContent("busy") };
                default: return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
        });
        using var service = await DiscoveredLabAsync(handler, ledger, ct);
        var stock = VoiceLabVoiceChoice.Stock("stock123");
        var input = VoiceLabTestCalls.SyntheticWav(24000, 24000);
        Task<VoiceLabAudioResult> Speak(CancellationToken token) =>
            service.SynthesizeAsync("Hi", "eleven_v3", stock, "en", service.Approve(service.PrepareSynthesis("Hi", "eleven_v3", stock, "en"), true), token);
        Task<VoiceLabAudioResult> Change() => service.ConvertAsync(input, "eleven_multilingual_sts_v2", stock, "en",
            service.Approve(service.PrepareConversion(input, "eleven_multilingual_sts_v2", stock, "en"), true), ct);

        // Creating and deleting a voice are accepted but free, so they touch nothing.
        var createPolicy = new OwnVoicePolicy("record-1", null, true, true, true, true, true);
        var ownPolicy = new OwnVoicePolicy("record-1", "own123", true, true, true, true, true);
        var clone = VoiceLabTestCalls.CloneRequest();
        var cloneQuote = service.PrepareClone(clone, createPolicy);
        var deleteQuote = service.PrepareDeletion("own123", ownPolicy);
        var created = await service.CreateOwnCloneAsync(clone, createPolicy, service.Approve(cloneQuote, true), ct);
        var deleted = await service.DeleteOwnCloneAsync("own123", ownPolicy, service.Approve(deleteQuote, true), ct);
        Assert.True(cloneQuote.Estimate.Usd == 0 && deleteQuote.Estimate.Usd == 0);
        Assert.Null(created.SpendWarning);
        Assert.Null(deleted.SpendWarning);
        Assert.False(Directory.Exists(Path.Combine(scratch.Root, "VoiceLab")));

        // A TTS take and a voice change are each recorded once, at the approved quote's estimate.
        var spoken = await Speak(ct);
        var changed = await Change();
        Assert.Null(spoken.SpendWarning);
        Assert.Null(changed.SpendWarning);
        var expected = service.Estimate(VoiceLabOperation.TextToSpeech, "eleven_v3", 2).Usd!.Value +
            service.Estimate(VoiceLabOperation.VoiceChange, "eleven_multilingual_sts_v2", 1).Usd!.Value;
        var recorded = (await ledger.ReadAsync(ct))!;
        var month = Assert.Single(recorded.Months);
        var total = Assert.Single(month.Value);
        Assert.Equal("elevenlabs", total.Key);
        Assert.Equal(new VoiceLabSpendTotal(expected, 0), total.Value);

        // A refusal sends nothing; a 4xx or 5xx reply and a cancellation before the reply record nothing.
        var billable = handler.Billable;
        Assert.Equal(VoiceLabErrorKind.ConsentRequired,
            Assert.Throws<VoiceLabException>(() => service.Approve(service.PrepareSynthesis("Hi", "eleven_v3", stock, "en"), false)).Kind);
        var approval = service.Approve(service.PrepareSynthesis("Hi", "eleven_v3", stock, "en"), true);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired,
            (await Assert.ThrowsAsync<VoiceLabException>(() => service.SynthesizeAsync("Ho", "eleven_v3", stock, "en", approval, ct))).Kind);
        Assert.Equal(billable, handler.Billable);
        foreach (var code in new[] { HttpStatusCode.Unauthorized, HttpStatusCode.TooManyRequests, HttpStatusCode.InternalServerError })
        {
            status = code;
            await Assert.ThrowsAsync<VoiceLabException>(() => Speak(ct));
            await Assert.ThrowsAsync<VoiceLabException>(() => Change());
        }
        status = HttpStatusCode.OK;
        using (var early = new CancellationTokenSource())
        {
            await early.CancelAsync();
            var error = await Assert.ThrowsAnyAsync<Exception>(() => Speak(early.Token));
            Assert.True(error is OperationCanceledException or VoiceLabException { Kind: VoiceLabErrorKind.Cancelled }, error.GetType().Name);
        }
        slow = true;
        using (var late = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            var pending = Speak(late.Token);
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(10), ct);
            await late.CancelAsync();
            Assert.Equal(VoiceLabErrorKind.Cancelled, (await Assert.ThrowsAsync<VoiceLabException>(() => pending)).Kind);
        }
        Assert.Equal(billable + 7, handler.Billable);
        Assert.Equal(recorded.Encode(), (await ledger.ReadAsync(ct))!.Encode());
    }

    [Fact]
    public async Task TheTwoHundredStatusLineIsRecordedOnceWhateverTheBodyDoes()
    {
        using var scratch = new Scratch();
        var ct = TestContext.Current.CancellationToken;
        var ledger = new VoiceLabSpendLedger(Path.Combine(scratch.Root, "VoiceLab", "spend.json"), TimeZoneInfo.Utc);
        var json = Encoding.UTF8.GetBytes(SpeechJson(new byte[4800]));
        // Every TTS reply is a 200 with the body this names.
        Func<HttpContent> content = () => new ByteArrayContent(json);
        using var handler = Provider((request, _) => Task.FromResult(request.RequestUri!.AbsolutePath == "/v1/text-to-speech/stock123/with-timestamps"
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = content() } : new HttpResponseMessage(HttpStatusCode.NotFound)));
        using var service = await DiscoveredLabAsync(handler, ledger, ct);
        var stock = VoiceLabVoiceChoice.Stock("stock123");
        Task<VoiceLabAudioResult> Speak(CancellationToken token) =>
            service.SynthesizeAsync("Hi", "eleven_v3", stock, "en", service.Approve(service.PrepareSynthesis("Hi", "eleven_v3", stock, "en"), true), token);
        var take = service.Estimate(VoiceLabOperation.TextToSpeech, "eleven_v3", 2).Usd!.Value;
        async Task<decimal> TotalAsync() => (await ledger.ReadAsync(ct))?.Months.Values.FirstOrDefault()?.GetValueOrDefault("elevenlabs")?.Usd ?? 0;
        static StreamContent Scripted(Func<int, Memory<byte>, CancellationToken, Task<int>> read) =>
            new(new ScriptedBody(read)) { Headers = { ContentType = new("application/json") } };
        int Chunk(Memory<byte> buffer) { json.AsMemory(0, 64).CopyTo(buffer); return 64; }

        // Cancelled after the 200 head and a first 64-byte chunk: the record started with the status line and stands.
        var firstChunk = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        content = () => Scripted(async (read, buffer, token) =>
        {
            if (read == 1) return Chunk(buffer);
            firstChunk.TrySetResult();
            await Task.Delay(Timeout.Infinite, token);
            return 0;
        });
        using (var cut = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            var pending = Speak(cut.Token);
            await firstChunk.Task.WaitAsync(TimeSpan.FromSeconds(10), ct);
            await cut.CancelAsync();
            Assert.Equal(VoiceLabErrorKind.Cancelled, (await Assert.ThrowsAsync<VoiceLabException>(() => pending)).Kind);
        }
        Assert.Equal(take, await TotalAsync());

        // The connection drops after the same chunk.
        content = () => Scripted((read, buffer, _) => read == 1 ? Task.FromResult(Chunk(buffer)) : Task.FromException<int>(new IOException("The connection was reset.")));
        Assert.Equal(VoiceLabErrorKind.Network, (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(ct))).Kind);
        Assert.Equal(take * 2, await TotalAsync());

        // A body over the 44 MiB limit, declared by Content-Length or found while reading.
        content = () => new ByteArrayContent(json) { Headers = { ContentLength = 44L * 1024 * 1024 + 1 } };
        Assert.Equal(VoiceLabErrorKind.ResponseTooLarge, (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(ct))).Kind);
        Assert.Equal(take * 3, await TotalAsync());
        content = () => Scripted((_, buffer, _) =>
        {
            buffer.Span.Clear();
            return Task.FromResult(buffer.Length);
        });
        Assert.Equal(VoiceLabErrorKind.ResponseTooLarge, (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(ct))).Kind);
        Assert.Equal(take * 4, await TotalAsync());

        // Cancelled after the last byte: the reply is kept and recorded once.
        using (var late = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            content = () => Scripted(async (read, buffer, _) =>
            {
                if (read == 1)
                {
                    json.AsMemory().CopyTo(buffer);
                    return json.Length;
                }
                await late.CancelAsync();
                return 0;
            });
            var kept = await Speak(late.Token);
            Assert.True(late.IsCancellationRequested);
            Assert.Equal(new byte[4800], kept.Pcm);
            Assert.Null(kept.SpendWarning);
        }
        Assert.Equal(take * 5, await TotalAsync());
    }

    [Fact]
    public async Task ALedgerThatCannotWriteKeepsTheResultAndCarriesTheWarning()
    {
        using var scratch = new Scratch();
        var ct = TestContext.Current.CancellationToken;
        var ledger = new VoiceLabSpendLedger(Path.Combine(scratch.Root, "VoiceLab", "spend.json"), TimeZoneInfo.Utc);
        var pcm = new byte[4800];
        using var handler = Provider((request, _) => Task.FromResult(request.RequestUri!.AbsolutePath == "/v1/text-to-speech/stock123/with-timestamps"
            ? Speech(pcm) : new HttpResponseMessage(HttpStatusCode.NotFound)));
        using var service = await DiscoveredLabAsync(handler, ledger, ct);
        var stock = VoiceLabVoiceChoice.Stock("stock123");
        var approval = service.Approve(service.PrepareSynthesis("Hi", "eleven_v3", stock, "en"), true);
        VoiceLabAudioResult spoken;
        if (OperatingSystem.IsWindows())
        {
            // Windows ignores the read-only attribute on folders, so the lock file is read-only instead.
            var lockPath = Path.Combine(Directory.CreateDirectory(Path.Combine(scratch.Root, "VoiceLab")).FullName, "spend.json.lock");
            await File.WriteAllBytesAsync(lockPath, [], ct);
            File.SetAttributes(lockPath, FileAttributes.ReadOnly);
            try { spoken = await service.SynthesizeAsync("Hi", "eleven_v3", stock, "en", approval, ct); }
            finally { File.SetAttributes(lockPath, FileAttributes.Normal); }
        }
        else
        {
            // A read-only data folder: VoiceLab cannot be created.
            var readOnly = UnixFileMode.UserRead | UnixFileMode.UserExecute;
            File.SetUnixFileMode(scratch.Root, readOnly);
            try { spoken = await service.SynthesizeAsync("Hi", "eleven_v3", stock, "en", approval, ct); }
            finally { File.SetUnixFileMode(scratch.Root, readOnly | UnixFileMode.UserWrite); }
            Assert.Empty(Directory.EnumerateFileSystemEntries(scratch.Root));
        }
        var writeFailed = new VoiceLabSpendWarning(VoiceLabSpendWarningKind.WriteFailed);
        Assert.Equal(pcm, spoken.Pcm);
        Assert.Equal(writeFailed, spoken.SpendWarning);
        Assert.Equal(writeFailed, spoken.Receipt.SpendWarning);
        Assert.False(File.Exists(ledger.FilePath));
    }

    [Fact]
    public Task ReadersRacingAWriterSeeOnlyWholeLedgers() => RaceReaderAgainstWriter();

    /// <summary>The VM test for real Windows share modes, which this Mac cannot run: .NET maps them to <c>flock</c> elsewhere.</summary>
    [Fact]
    public async Task WindowsShareModesKeepWritersApartAndReadersOutOfTheReplaceWindow()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("Real Windows share modes run on the Windows ARM64 VM; elsewhere .NET maps them to flock.");
        using var scratch = new Scratch();
        var path = Path.Combine(scratch.Root, "spend.json");
        using (new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        {
            // A second exclusive open is a sharing violation (HResult 32), the only failure the ledger waits for.
            var violation = Assert.Throws<IOException>(() => new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None));
            Assert.Equal(32, violation.HResult & 0xFFFF);
            var busy = new VoiceLabSpendLedger(path, TimeZoneInfo.Utc, TimeSpan.FromMilliseconds(50));
            Assert.Equal(new VoiceLabSpendWarning(VoiceLabSpendWarningKind.LockTimedOut), await busy.RecordAsync(Isolation, DateTimeOffset.UtcNow, TestContext.Current.CancellationToken));
        }
        await RaceReaderAgainstWriter();
    }

    /// <summary>A reader polling while a writer records 100 times never reads through <c>File.Replace</c>: every total it sees is whole and
    /// never goes backwards.</summary>
    private static async Task RaceReaderAgainstWriter()
    {
        using var scratch = new Scratch();
        var ct = TestContext.Current.CancellationToken;
        var path = Path.Combine(scratch.Root, "spend.json");
        var writer = new VoiceLabSpendLedger(path, TimeZoneInfo.Utc);
        var reader = new VoiceLabSpendLedger(path, TimeZoneInfo.Utc);
        var now = DateTimeOffset.UtcNow;
        var cent = Isolation with { Usd = 0.01m };
        var writing = Task.Run(async () =>
        {
            for (var index = 0; index < 100; index++) Assert.Null(await writer.RecordAsync(cent, now, ct));
        }, ct);
        var seen = 0m;
        while (!writing.IsCompleted)
        {
            if (await reader.TotalAsync("elevenlabs", now, ct) is { } total)
            {
                Assert.True(total.Usd >= seen, $"{total.Usd} after {seen}");
                seen = total.Usd;
            }
            await Task.Delay(1, ct);
        }
        await writing;
        Assert.Equal(new VoiceLabSpendTotal(1m, 0), await reader.TotalAsync("elevenlabs", now, ct));
    }

    [Fact]
    public async Task CapCrossingAndTheCapSentence()
    {
        var cap = Ledger["cap"]!;
        using var scratch = new Scratch();
        var ledger = new VoiceLabSpendLedger(Path.Combine(scratch.Root, "spend.json"), Zone(cap["timeZoneOffsetSeconds"]));
        foreach (var row in Rows(cap["existing"])) Assert.Null(await ledger.RecordAsync(Spend(row), Instant(row["at"]), TestContext.Current.CancellationToken));
        foreach (var row in Rows(cap["checks"]))
        {
            var crosses = await ledger.WouldCrossAsync(Amount(row["cap"])!.Value, Text(row["provider"])!, Spend(row), Instant(row["at"]), TestContext.Current.CancellationToken);
            Assert.True(crosses == row["wouldCross"]!.GetValue<bool>(), row.ToJsonString());
        }
        foreach (var row in Rows(cap["sentences"]))
            Assert.Equal(Text(row["text"]), VoiceLabCostPresentation.CapWarning(Amount(row["cap"])!.Value, Text(row["providerName"])!));
    }

    [Fact]
    public async Task MonthlyCapSettingValidatesAndRoundTrips()
    {
        foreach (var row in Rows(Document.Value["settings"]))
        {
            var key = Text(row["key"])!;
            Assert.True(SettingsValidation.KnownKey(key), key);
            var settings = new AppSettings("voxclip-settings/1");
            using (var value = JsonDocument.Parse(row["value"]?.ToJsonString() ?? "null")) settings.Values[key] = value.RootElement.Clone();
            if (row["valid"]!.GetValue<bool>()) SettingsValidation.Validate(settings);
            else Assert.Throws<JsonException>(() => SettingsValidation.Validate(settings));
        }
        var edited = new AppSettings("voxclip-settings/1");
        edited.SetVoiceLabMonthlyCap("elevenlabs", 12.50m);
        Assert.Equal("12.5", edited.Values["voiceLab.monthlyCapUsd.elevenlabs"].GetString());
        Assert.Equal(12.5m, edited.GetVoiceLabMonthlyCap("elevenlabs"));
        Assert.Null(edited.GetVoiceLabMonthlyCap("fal"));
        var decoded = JsonSerializer.Deserialize(JsonSerializer.Serialize(edited, SettingsJsonContext.Default.AppSettings), SettingsJsonContext.Default.AppSettings)!;
        Assert.Equal(12.5m, decoded.GetVoiceLabMonthlyCap("elevenlabs"));
        SettingsValidation.Validate(decoded);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => edited.SetVoiceLabMonthlyCap("elevenlabs", 12.345m)).Kind);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => edited.SetVoiceLabMonthlyCap("elevenlabs", -1m)).Kind);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => edited.SetVoiceLabMonthlyCap("Eleven Labs", 1m)).Kind);
        edited.SetVoiceLabMonthlyCap("elevenlabs", null);
        Assert.Empty(edited.Values);

        // The store keeps the key across a save and a fresh load.
        using var scratch = new Scratch();
        var path = Path.Combine(scratch.Root, "settings.json");
        var store = new SettingsStore(path);
        var loaded = await store.LoadAsync(TestContext.Current.CancellationToken);
        loaded.SetVoiceLabMonthlyCap("fal", 20m);
        await store.SaveAsync(loaded, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.Equal(20m, (await new SettingsStore(path).LoadAsync(TestContext.Current.CancellationToken)).GetVoiceLabMonthlyCap("fal"));
    }
}
