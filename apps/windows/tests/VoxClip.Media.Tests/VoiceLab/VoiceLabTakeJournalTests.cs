using System.Buffers.Binary;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>The paid-take journal (voice-lab §3 "Paid takes are kept") against <c>shared/fixtures/voice-lab/take-journal-cases.json</c>,
/// which the Mac journal replays too (Mac <c>VoiceLabTakeJournalTests</c>).</summary>
public sealed class VoiceLabTakeJournalTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-take-journal-" + Guid.NewGuid().ToString("N"));
    public VoiceLabTakeJournalTests() => Directory.CreateDirectory(root);
    public void Dispose() => Directory.Delete(root, true);

    private static JsonObject Document() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/take-journal-cases.json"))!.AsObject();
    private static VoiceLabTakeJournalEntry Entry(JsonNode node) =>
        VoiceLabTakeJournal.Decode(System.Text.Encoding.UTF8.GetBytes(node.ToJsonString())) ?? throw new InvalidOperationException("unparsable entry");
    private static VoiceLabTakeJournalKey Key(JsonNode node) => new(node["recordID"]!.GetValue<string>(), node["voiceID"]!.GetValue<string>(),
        node["modelID"]!.GetValue<string>(), node["language"]!.GetValue<string>(), node["requestText"]!.GetValue<string>(),
        node["previousText"]!.GetValue<string>(), node["nextText"]!.GetValue<string>(), node["pace"]!.GetValue<double>());

    /// <summary>The fixture's journal on disk: each asset by the paid-asset writer (its SHA-256 is the fixture's, so both platforms write
    /// the same canonical WAV), then every entry through the journal.</summary>
    private string Journal(JsonObject document)
    {
        var project = document["projectId"]!.GetValue<string>();
        foreach (var asset in document["assets"]!.AsArray())
        {
            var frames = asset!["frames"]!.GetValue<int>();
            var pcm = new byte[frames * 2];
            for (var index = 0; index < frames; index++) BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(index * 2), (short)asset["fill"]!.GetValue<int>());
            var written = VoiceLabAssetStore.Write(pcm, asset["sampleRate"]!.GetValue<int>(), project, asset["assetId"]!.GetValue<string>(), root, DateTimeOffset.UtcNow);
            Assert.Equal(asset["sha256"]!.GetValue<string>(), written.Sha256);
        }
        foreach (var entry in document["entries"]!.AsArray()) VoiceLabTakeJournal.Write(Entry(entry!), project, root);
        return project;
    }

    [Fact]
    public void TheSharedCasesParseRoundTripAndMatch()
    {
        var document = Document();
        Assert.Equal(new[] { "schema", "entrySchema", "projectId", "caseCount", "assets", "entries", "cases" }.Order(), document.Select(pair => pair.Key).Order());
        Assert.Equal("voxclip-take-journal-cases/1", document["schema"]!.GetValue<string>());
        Assert.Equal(VoiceLabTakeJournalEntry.CurrentSchema, document["entrySchema"]!.GetValue<string>());
        var cases = document["cases"]!.AsArray();
        Assert.Equal(35, document["caseCount"]!.GetValue<int>());
        Assert.Equal(35, cases.Count);
        var project = Journal(document);
        Assert.Equal(document["entries"]!.AsArray().Count, VoiceLabTakeJournal.List(project, root).Count);
        foreach (var item in cases)
        {
            var id = item!["id"]!.GetValue<string>();
            switch (item["kind"]!.GetValue<string>())
            {
                case "parse":
                    var decoded = VoiceLabTakeJournal.Decode(System.Text.Encoding.UTF8.GetBytes(item["entry"]!.ToJsonString()));
                    var valid = decoded is not null && Record.Exception(() => VoiceLabTakeJournal.Validate(decoded, project)) is null;
                    Assert.True(valid == item["valid"]!.GetValue<bool>(), id);
                    if (!valid) continue;
                    // The shape is pinned: the journal writes exactly the fixture's keys and values back.
                    var written = JsonNode.Parse(VoiceLabTakeJournal.Encode(decoded!))!;
                    Assert.True(JsonNode.DeepEquals(Normalized(item["entry"]!), Normalized(written)), id + ": " + written.ToJsonString());
                    break;
                case "match":
                    var claimed = item["claimed"]!.AsArray().Select(node => node!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
                    var found = VoiceLabTakeJournal.Match(Key(item["key"]!), project, root, claimed);
                    Assert.True(found?.AssetFile == item["expected"]?.GetValue<string>(), id + ": " + found?.AssetFile);
                    break;
                default: Assert.Fail("Unknown case kind in " + id); break;
            }
        }
    }

    /// <summary>Numbers compared by value (the fixture writes 1.0 where an encoder may write 1), keys in any order.</summary>
    private static JsonNode? Normalized(JsonNode? node) => node switch
    {
        JsonObject value => new JsonObject(value.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => KeyValuePair.Create(pair.Key, Normalized(pair.Value)))),
        JsonArray value => new JsonArray(value.Select(Normalized).ToArray()),
        JsonValue value when value.GetValueKind() == System.Text.Json.JsonValueKind.Number => JsonValue.Create(value.GetValue<decimal>()),
        _ => node?.DeepClone()
    };

    /// <summary>A crash mid-write leaves a <c>.partial</c> file that nothing reads, and the next write of that entry replaces it; a
    /// foreign or malformed file is ignored; recovered timing replaces the entry in place; a changed asset is never adopted.</summary>
    [Fact]
    public void EntriesSurviveACrashedWriteAndAdoptOnlyIntactAssets()
    {
        var document = Document();
        var project = Journal(document);
        var folder = Path.Combine(root, project, "takes");
        var newest = Entry(document["entries"]![1]!);
        File.WriteAllText(Path.Combine(folder, "." + newest.AssetId + ".json.partial"), "{\"schema\":");
        File.WriteAllText(Path.Combine(folder, "0f6a1c2e-9999-4a00-8000-000000000009.json"), "not json");
        File.WriteAllBytes(Path.Combine(folder, "renamed.json"), VoiceLabTakeJournal.Encode(newest));
        Assert.Equal(document["entries"]!.AsArray().Count, VoiceLabTakeJournal.List(project, root).Count);
        Assert.Equal(newest.AssetFile, VoiceLabTakeJournal.Match(newest.Key, project, root)?.AssetFile);
        VoiceLabTakeJournal.UpdateTiming(newest.AssetFile, [new("H", 0.1, 0.4)], true, project, root);
        var updated = VoiceLabTakeJournal.List(project, root).Single(entry => entry.AssetFile == newest.AssetFile);
        Assert.True(updated.Alignment!.Recovered);
        Assert.Equal(new VoiceLabTakeJournalTiming("H", 0.1, 0.4), Assert.Single(updated.Alignment.Characters));
        Assert.False(File.Exists(Path.Combine(folder, "." + newest.AssetId + ".json.partial")));
        var older = Entry(document["entries"]![0]!);
        // A word check that failed is written in place too, keeping the timing; the take is then never adopted, and the older take over
        // the same request is, until a later run's passing verdict replaces the failed one.
        VoiceLabTakeJournal.UpdateChecks(newest.AssetFile, new(VoiceLabTakeJournalOutcome.Passed, VoiceLabTakeJournalOutcome.Failed, ["transcript"]), project, root);
        var checkedEntry = VoiceLabTakeJournal.List(project, root).Single(entry => entry.AssetFile == newest.AssetFile);
        Assert.False(checkedEntry.Adoptable);
        Assert.Equal(VoiceLabTakeJournalOutcome.Failed, checkedEntry.Checks!.Words);
        Assert.Equal(["transcript"], checkedEntry.Checks.HardFailures);
        Assert.True(checkedEntry.Alignment!.Recovered);
        Assert.Equal(older.AssetFile, VoiceLabTakeJournal.Match(newest.Key, project, root)?.AssetFile);
        VoiceLabTakeJournal.UpdateChecks(newest.AssetFile, new(VoiceLabTakeJournalOutcome.Passed, VoiceLabTakeJournalOutcome.Passed, []), project, root);
        Assert.Equal(newest.AssetFile, VoiceLabTakeJournal.Match(newest.Key, project, root)?.AssetFile);
        Assert.Throws<VoiceLabException>(() => VoiceLabTakeJournal.UpdateChecks(newest.AssetFile, new(null, VoiceLabTakeJournalOutcome.Failed, [""]), project, root));
        var (result, asset) = VoiceLabTakeJournal.Adopt(older, project, root);
        Assert.Equal(older.Frames * 2, result.Pcm.Length);
        Assert.Equal("Hello", string.Concat(result.Alignment!.Select(item => item.Character)));
        Assert.Equal(Guid.ParseExact(older.RequestId, "D"), result.Receipt.ActionId);
        Assert.Equal("req_fixture_older", result.Receipt.ProviderRequestId);
        Assert.Equal(older.AssetFile, asset.File);
        Assert.Equal(older.AssetSha256, asset.Sha256);
        var path = Path.Combine(root, newest.AssetFile);
        var bytes = File.ReadAllBytes(path); bytes[^1] ^= 0xff; File.WriteAllBytes(path, bytes);
        Assert.NotEqual(newest.AssetFile, VoiceLabTakeJournal.Match(newest.Key, project, root)?.AssetFile);
        VoiceLabTakeJournal.Remove(newest.AssetId, project, root);
        Assert.DoesNotContain(VoiceLabTakeJournal.List(project, root), entry => entry.AssetFile == newest.AssetFile);
        Assert.True(File.Exists(path));
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(folder));
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(Path.Combine(folder, older.AssetId + ".json")));
        }
    }

    /// <summary>Windows has no retention pass, so the journal drops its own finished entries (Mac <c>VoiceLabAssetRetention</c> at a
    /// project's close): one whose asset the project uses, one whose asset is gone, and, after 60 days, any the project never used.
    /// Their assets stay. The entries used to stay for good, and every adoption read them all.</summary>
    [Fact]
    public void SettleDropsUsedGoneAndAgedEntriesAndKeepsTheirAssets()
    {
        var document = Document();
        var project = Journal(document);
        var entries = document["entries"]!.AsArray().Select(node => Entry(node!)).ToArray();
        var older = entries[0];
        var created = entries.Max(entry => entry.CreatedAt);
        Assert.Equal(2, VoiceLabTakeJournal.Settle(project, root, new HashSet<string>(StringComparer.Ordinal) { older.AssetFile }, created.AddDays(59)));
        var kept = VoiceLabTakeJournal.List(project, root).Select(entry => entry.AssetFile).ToHashSet(StringComparer.Ordinal);
        Assert.Equal(entries.Length - 2, kept.Count);
        Assert.DoesNotContain(older.AssetFile, kept);
        Assert.DoesNotContain(entries.Single(entry => entry.RequestText == "Missing").AssetFile, kept);
        Assert.Equal(0, VoiceLabTakeJournal.Settle(project, root, new HashSet<string>(StringComparer.Ordinal), created.AddDays(59)));
        Assert.Equal(entries.Length - 2, VoiceLabTakeJournal.Settle(project, root, new HashSet<string>(StringComparer.Ordinal), created.AddDays(61)));
        Assert.Empty(VoiceLabTakeJournal.List(project, root));
        foreach (var asset in document["assets"]!.AsArray())
            Assert.True(File.Exists(Path.Combine(root, project, asset!["assetId"]!.GetValue<string>() + ".wav")));
    }

    /// <summary>The App's settle at a project's close (<c>EditorPage.SettleTakeJournal</c>): an entry whose asset the project used goes,
    /// unused current ones stay adoptable.</summary>
    [Fact]
    public void TheProjectCloseLetsGoOfTheTakesItUsed()
    {
        var document = Document();
        var project = Journal(document);
        var entries = document["entries"]!.AsArray().Select(node => Entry(node!)).ToArray();
        var before = VoiceLabTakeJournal.List(project, root).Count;
        var used = VoiceLabTakeJournal.List(project, root).First();
        Assert.True(VoiceLabTakeJournalSettlement.Settle(project, root, [used.AssetFile]) >= 1);
        var kept = VoiceLabTakeJournal.List(project, root).Select(entry => entry.AssetFile).ToHashSet(StringComparer.Ordinal);
        Assert.DoesNotContain(used.AssetFile, kept);
        Assert.True(kept.Count >= 1 && kept.Count < before, $"{kept.Count} of {before} of {entries.Length}");
    }

    /// <summary>The launch sweep (<c>AppServices.InitializeAsync</c>) keeps the 60-day rule for a project that is never opened again or
    /// crashed before its close: every journal drops its gone and aged entries, used ones are left for the project's own open, folders
    /// with no journal are passed over, and the assets stay. Pruning used to run only at a clean close of the project.</summary>
    [Fact]
    public void TheLaunchSweepDropsGoneAndAgedEntriesOfProjectsNeverOpened()
    {
        var document = Document();
        var project = Journal(document);
        var entries = document["entries"]!.AsArray().Select(node => Entry(node!)).ToArray();
        var created = entries.Max(entry => entry.CreatedAt);
        Directory.CreateDirectory(Path.Combine(root, "no-journal-here"));
        Assert.Equal(1, VoiceLabTakeJournalSettlement.SweepStale(root, created.AddDays(59)));
        var kept = VoiceLabTakeJournal.List(project, root).Select(entry => entry.AssetFile).ToHashSet(StringComparer.Ordinal);
        Assert.Equal(entries.Length - 1, kept.Count);
        Assert.DoesNotContain(entries.Single(entry => entry.RequestText == "Missing").AssetFile, kept);
        Assert.Equal(entries.Length - 1, VoiceLabTakeJournalSettlement.SweepStale(root, created.AddDays(61)));
        Assert.Empty(VoiceLabTakeJournal.List(project, root));
        Assert.Equal(0, VoiceLabTakeJournalSettlement.SweepStale(Path.Combine(root, "absent"), created.AddDays(61)));
        foreach (var asset in document["assets"]!.AsArray())
            Assert.True(File.Exists(Path.Combine(root, project, asset!["assetId"]!.GetValue<string>() + ".wav")));
    }
}
