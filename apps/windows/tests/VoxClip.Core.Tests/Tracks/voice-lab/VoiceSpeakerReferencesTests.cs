using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Learned voice references (voice-lab.md §6.9, ADR-R41; Mac <c>VoiceSpeakerReferencesTests</c>): the shared vectors in
/// shared/fixtures/voice-lab/voice-references-cases.json, the record's validation of them, and the store's learning, forgetting and
/// tombstone. A reference never changes what a run was approved for.</summary>
public sealed class VoiceSpeakerReferencesTests
{
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);

    private static VoiceConsentSpeaker Speaker(JsonElement element) => element.Deserialize<VoiceConsentSpeaker>(Web)!;
    private static float[] Vector(JsonElement element) => VoiceConsentRecord.DecodeEmbedding(element.GetString()!)!;

    [Fact]
    public void ReplaysEveryVoiceReferenceVector()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/voice-references-cases.json");
        var root = document.RootElement;
        Assert.Equal("voxclip-voice-references/1", root.GetProperty("schema").GetString());
        Assert.Equal(VoiceSpeakerReferences.Bound, root.GetProperty("constants").GetProperty("bound").GetInt32());
        var cases = root.GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(root.GetProperty("caseCount").GetInt32(), cases.Length);
        HashSet<string> kinds = [];
        foreach (var item in cases)
        {
            var kind = item.GetProperty("kind").GetString()!;
            var name = item.GetProperty("name").GetString()!;
            var expected = item.GetProperty("expected");
            var speaker = Speaker(item.GetProperty("speaker"));
            kinds.Add(kind);
            switch (kind)
            {
                case "usable":
                    Assert.True(expected.GetProperty("contentKeys").EnumerateArray().Select(key => key.GetString()).SequenceEqual(
                        VoiceSpeakerReferences.Usable(speaker).Select(reference => reference.ContentKey)), name);
                    Assert.True(expected.GetProperty("learnedCount").GetInt32() == VoiceSpeakerReferences.LearnedCount(speaker), name);
                    break;
                case "match":
                {
                    var match = VoiceSpeakerReferences.Match(Vector(item.GetProperty("candidate")), speaker);
                    if (expected.ValueKind == JsonValueKind.Null) { Assert.True(match is null, name); break; }
                    Assert.True(match is not null, name);
                    Assert.True(expected.GetProperty("kind").GetString() == (match.ViaReference ? "reference" : "statement"), name);
                    Assert.True(expected.GetProperty("contentKey").GetString() == match.ContentKey, name);
                    // Pure binary64 arithmetic in a fixed order: the score is the generator's to the bit.
                    Assert.True(expected.GetProperty("score").GetDouble() == match.Score, name);
                    break;
                }
                case "learning":
                {
                    var at = DateTimeOffset.Parse(item.GetProperty("at").GetString()!, System.Globalization.CultureInfo.InvariantCulture);
                    VoiceConsentSpeaker? learned = null;
                    VoiceReferenceRefusal? refusal = null;
                    try { learned = VoiceSpeakerReferences.Learning(Vector(item.GetProperty("embedding")), item.GetProperty("contentKey").GetString()!, item.GetProperty("model").GetString()!, at, speaker); }
                    catch (VoiceReferenceRefusedException error) { refusal = error.Reason; }
                    if (expected.TryGetProperty("refusal", out var pinned))
                    {
                        Assert.True(JsonNamingPolicy.CamelCase.ConvertName(refusal?.ToString() ?? "") == pinned.GetString(), name);
                        break;
                    }
                    Assert.True(learned?.References is not null, name);
                    Assert.True(expected.GetProperty("contentKeys").EnumerateArray().Select(key => key.GetString()).SequenceEqual(learned.References.Select(reference => reference.ContentKey)), name);
                    Assert.True(expected.GetProperty("statementScores").EnumerateArray().Select(score => score.GetDouble()).SequenceEqual(learned.References.Select(reference => reference.StatementScore)), name);
                    var added = learned.References.Single(reference => reference.ContentKey == item.GetProperty("contentKey").GetString());
                    Assert.True(item.GetProperty("at").GetString() == added.AddedAt, name);
                    Assert.True(expected.GetProperty("learnedScore").GetDouble() == added.StatementScore, name);
                    // The speaker block is otherwise unchanged, and validates.
                    Assert.True(learned with { References = null } == speaker with { References = null }, name);
                    VoiceSpeakerReferences.Validate(learned);
                    break;
                }
                default:
                    Assert.Fail($"unknown kind {kind} in {name}");
                    break;
            }
        }
        Assert.Equal(["learning", "match", "usable"], kinds.Order(StringComparer.Ordinal));
    }

    private static readonly float[] Owner = [1, 0, 0, 0];
    private static VoiceConsentReference Reference(string key, float[]? vector = null, string model = "fixture-model", string added = "2026-11-05T12:00:00Z", double score = .6) =>
        new(VoiceConsentRecord.EncodeEmbedding(vector ?? [.6f, .8f, 0, 0]), key, added, score, model);

    private static VoiceConsentRecord Fixture() =>
        JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"), VoiceConsentJson.Default.VoiceConsentRecord)! with
        {
            Speaker = new("fixture-model", .45, VoiceConsentRecord.EncodeEmbedding(Owner))
        };

    [Fact]
    public void TheRecordValidatesItsReferences()
    {
        var record = Fixture();
        record.Validate();
        Assert.Null(record.Speaker.References);
        // The field is absent until the first is learned: the record's bytes don't change.
        Assert.DoesNotContain("references", JsonSerializer.Serialize(record, VoiceConsentJson.Default.VoiceConsentRecord));
        (record with { Speaker = record.Speaker with { References = [Reference("project-a"), Reference("project-b", model: "other-model", vector: [1, 0, 0, 0, 0, 0])] } }).Validate();
        foreach (var references in new VoiceConsentReference[][]
        {
            [],
            [Reference("project-a"), Reference("project-a")],
            [.. Enumerable.Range(0, VoiceSpeakerReferences.Bound + 1).Select(index => Reference($"project-{index}"))],
            [Reference("")], [Reference("a b")], [Reference("é")], [Reference(new string('a', 129))],
            [Reference("project-a", model: "")],
            [Reference("project-a", added: "yesterday")], [Reference("project-a", added: "2026-11-05T12:00:00.5Z")],
            [Reference("project-a", score: double.NaN)], [Reference("project-a", score: 1.1)],
            [Reference("project-a", vector: [2, 0, 0, 0])],
            [Reference("project-a", vector: [1, 0, 0, 0, 0, 0])],
        })
            Assert.Equal(VoiceConsentError.InvalidRecord, Assert.Throws<VoiceConsentException>(() => (record with { Speaker = record.Speaker with { References = references } }).Validate()).Kind);
        // A deleted record holds none.
        var deleted = record with { Status = VoiceConsentStatus.Deleted, DeletedAt = record.CreatedAt };
        deleted.Validate();
        Assert.Throws<VoiceConsentException>(() => (deleted with { Speaker = deleted.Speaker with { References = [Reference("project-a")] } }).Validate());
        // What a run was approved for leaves the references out.
        var learned = record with { Speaker = record.Speaker with { References = [Reference("project-a")] } };
        Assert.Null(learned.WithoutReferences.Speaker.References);
        Assert.Same(record, record.WithoutReferences);
    }

    [Fact]
    public void ReferencesNeverChainAndNeverTrustTheirStoredScore()
    {
        var speaker = new VoiceConsentSpeaker("fixture-model", .45, VoiceConsentRecord.EncodeEmbedding(Owner),
        [
            Reference("near"),
            // Says it passed, but doesn't against the owner now: never used, so speech like it is not the owner.
            Reference("far", [.316f, 0, .949f, 0], score: .9),
        ]);
        Assert.Equal(["near"], VoiceSpeakerReferences.Usable(speaker).Select(reference => reference.ContentKey));
        Assert.Null(VoiceSpeakerReferences.Match([.316f, 0, .949f, 0], speaker));
        Assert.Equal("near", VoiceSpeakerReferences.Match([.24f, .94f, .24f, 0], speaker)!.ContentKey);
        Assert.Equal(1, VoiceSpeakerReferences.LearnedCount(speaker));
        // A reference is learned only against the owner's own embedding, never another reference.
        Assert.Equal(VoiceReferenceRefusal.NotTheOwner,
            Assert.Throws<VoiceReferenceRefusedException>(() => VoiceSpeakerReferences.Learning([.24f, .94f, .24f, 0], "next", "fixture-model", DateTimeOffset.UnixEpoch, speaker)).Reason);
        Assert.Throws<VoiceLabException>(() => VoiceSpeakerReferences.Learning([.6f, .8f, 0, 0], "not a key", "fixture-model", DateTimeOffset.UnixEpoch, speaker));
        Assert.Equal("2026-11-06T09:30:00Z", VoiceConsentRecord.Timestamp(new DateTimeOffset(2026, 11, 6, 11, 30, 0, TimeSpan.FromHours(2))));
    }

    private sealed class Storage : IDisposable
    {
        internal readonly string Root = Path.Combine(Path.GetTempPath(), "voxclip-reference-tests-" + Guid.NewGuid().ToString("N"));
        internal DataLocations Locations => new(Root, Path.Combine(Root, "settings.json"), Path.Combine(Root, "Models"), Path.Combine(Root, "Cache"),
            Path.Combine(Root, "Autosave"), Path.Combine(Root, "Secrets"), Path.Combine(Root, "Logs"));
        internal Storage() => Directory.CreateDirectory(Root);
        public void Dispose() => Directory.Delete(Root, true);
    }

    private static VoiceConsentRecord Saved(VoiceConsentStore store)
    {
        var wav = VoiceLabTestCalls.SyntheticWav(16000, 16000 * 6, 2000);
        var id = Guid.NewGuid().ToString("D");
        store.SaveStatement(wav, id);
        var record = Fixture();
        record = record with { RecordId = id, VoiceId = "active-voice", Statement = record.Statement! with { AudioSha256 = VoiceConsentStore.Hash(wav) } };
        store.Save(record);
        return record;
    }

    /// <summary>Mac <c>referencesReachTheNewVoiceOnlyWhenTheyPassItsOwnEmbedding</c> (ADR-R44 step 6): a rebuilt or per-video voice keeps the
    /// old voice's references only by learning each again against its own embedding, one hop; one that fails it is dropped, the old voice is
    /// untouched, and a voice that isn't active learns nothing.</summary>
    [Fact]
    public void CarriedReferencesReachTheNewVoiceOnlyWhenTheyPassItsOwnEmbedding()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var old = Saved(store);
        store.LearnReference(old.RecordId, [.6f, .8f, 0, 0], "project-near", "fixture-model");
        store.LearnReference(old.RecordId, [.6f, -.8f, 0, 0], "project-other-side", "fixture-model");
        var before = store.Load(old.RecordId);
        Assert.Equal(2, VoiceSpeakerReferences.LearnedCount(before.Speaker));
        var rebuilt = Saved(store);
        store.Save(store.Load(rebuilt.RecordId) with { Speaker = new("fixture-model", .45, VoiceConsentRecord.EncodeEmbedding([.8f, .6f, 0, 0])) });
        Assert.Equal(1, store.CarryReferences(old.RecordId, rebuilt.RecordId, new DateTimeOffset(2026, 11, 6, 12, 0, 0, TimeSpan.Zero)));
        var carried = Assert.Single(store.Load(rebuilt.RecordId).Speaker.References!);
        Assert.Equal("project-near", carried.ContentKey);
        Assert.Equal(.96, carried.StatementScore, 5);
        Assert.Equal("2026-11-06T12:00:00Z", carried.AddedAt);
        Assert.Equal(before, store.Load(old.RecordId), RecordComparer);
        // Again: nothing better to learn, so nothing is written.
        Assert.Equal(1, store.CarryReferences(old.RecordId, rebuilt.RecordId));
        var withdrawn = Saved(store);
        store.Save(store.Load(withdrawn.RecordId) with { Status = VoiceConsentStatus.Deleted, DeletedAt = withdrawn.CreatedAt, Speaker = withdrawn.Speaker });
        Assert.Equal(VoiceConsentError.Inactive, Assert.Throws<VoiceConsentException>(() => store.CarryReferences(old.RecordId, withdrawn.RecordId)).Kind);
    }

    [Fact]
    public void TheStoreLearnsAndForgetsWithoutChangingWhatARunWasApprovedFor()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Saved(store);
        var at = new DateTimeOffset(2026, 11, 6, 9, 30, 0, TimeSpan.Zero);
        var learned = store.LearnReference(record.RecordId, [3, 4, 0, 0], "project-a", "fixture-model", at);
        Assert.Equal(learned, store.Load(record.RecordId), RecordComparer);
        Assert.Equal("project-a", Assert.Single(store.Load(record.RecordId).Speaker.References!).ContentKey);
        Assert.Equal("2026-11-06T09:30:00Z", store.Load(record.RecordId).Speaker.References![0].AddedAt);
        // A run approved before the reference was learned still validates, and one approved after still does once it is forgotten.
        store.ValidateUse(record);
        store.ValidateUse(learned);
        Assert.Equal(VoiceReferenceRefusal.NotBetter,
            Assert.Throws<VoiceReferenceRefusedException>(() => store.LearnReference(record.RecordId, [3, 4, 0, 0], "project-a", "fixture-model", at)).Reason);
        Assert.Equal(VoiceReferenceRefusal.OtherModel,
            Assert.Throws<VoiceReferenceRefusedException>(() => store.LearnReference(record.RecordId, [3, 4, 0, 0], "project-b", "other-model", at)).Reason);
        var forgotten = store.ForgetReferences(record.RecordId);
        Assert.Null(forgotten.Speaker.References);
        Assert.Null(store.Load(record.RecordId).Speaker.References);
        store.ValidateUse(learned);
        Assert.Null(store.ForgetReferences(record.RecordId).Speaker.References);
        // Anything else about the record still stops a run.
        store.Save(store.Load(record.RecordId) with { VoiceName = "Another name" });
        Assert.Throws<VoiceConsentException>(() => store.ValidateUse(learned));
    }

    [Fact]
    public async Task TheTombstoneDropsTheReferencesAndAnInactiveVoiceLearnsNothing()
    {
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Saved(store);
        store.LearnReference(record.RecordId, [3, 4, 0, 0], "project-a", "fixture-model");
        store.BeginLocalRemoval(record.RecordId, true, DateTimeOffset.UnixEpoch);
        // A voice being removed learns nothing.
        Assert.Equal(VoiceConsentError.Inactive,
            Assert.Throws<VoiceConsentException>(() => store.LearnReference(record.RecordId, [3, 3, 0, 0], "project-b", "fixture-model")).Kind);
        await new VoiceOperationReconciler(store, _ => throw new InvalidOperationException("No remote call allowed")).ReconcileAsync(ct: TestContext.Current.CancellationToken);
        var deleted = store.Load(record.RecordId);
        Assert.Equal(VoiceConsentStatus.Deleted, deleted.Status);
        Assert.Null(deleted.Speaker.References);
        Assert.Equal(VoiceConsentError.Inactive,
            Assert.Throws<VoiceConsentException>(() => store.LearnReference(record.RecordId, [3, 4, 0, 0], "project-a", "fixture-model")).Kind);
    }

    [Fact]
    public async Task TheGuardScreensNothingWhileTheWindowsSpeakerCheckIsOff()
    {
        // Inert behind VoiceSpeakerCheck.WindowsNativeParityVerified (false): every phrase is unchecked, nothing is learned.
        using var storage = new Storage();
        var store = new VoiceConsentStore(storage.Locations);
        var record = Saved(store);
        var verdicts = await new VoiceUseGuard(store).ScreenAsync("project-a", record.RecordId, [new float[16_000], []], TestContext.Current.CancellationToken);
        Assert.Equal([VoiceGuardVerdict.Unchecked, VoiceGuardVerdict.Unchecked], verdicts);
        Assert.Null(store.Load(record.RecordId).Speaker.References);
        Assert.Equal(VoiceGuardVerdict.Unchecked, Assert.Single(await new VoiceUseGuard(store).ScreenAsync("not a key", record.RecordId, [new float[16_000]], TestContext.Current.CancellationToken)));
    }

    private static readonly IEqualityComparer<VoiceConsentRecord> RecordComparer = EqualityComparer<VoiceConsentRecord>.Create(
        (left, right) => JsonSerializer.Serialize(left, VoiceConsentJson.Default.VoiceConsentRecord) == JsonSerializer.Serialize(right, VoiceConsentJson.Default.VoiceConsentRecord));
}
