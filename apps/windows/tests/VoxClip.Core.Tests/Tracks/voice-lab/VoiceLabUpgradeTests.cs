using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Tests.Tracks.WinCoreNative;
using VoxClip.Core.Tests.Tracks.WinEditing;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabUpgradeTests
{
    static Project Load(string folder, string name) => ProjectSerialization.Deserialize(
        File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", folder, name)));
    static void Error(VoiceLabProjectErrorCode code, Action action) => Assert.Equal(code, Assert.Throws<VoiceLabProjectException>(action).Code);
    static JsonObject Json(Project project) => JsonNode.Parse(ProjectSerialization.Serialize(project))!.AsObject();
    static Project ExtendedV1()
    {
        using var extension = JsonDocument.Parse("{\"nested\":[7,true],\"text\":\"õäöü\"}");
        return Load("projects", "interview-take.voxclip") with
        {
            Extensions = new Dictionary<string, JsonElement>(StringComparer.Ordinal) { ["org.example.fork"] = extension.RootElement.Clone() }
        };
    }
    static Project SegmentFreeV2()
    {
        var v2 = Load("voice-lab", "passage-project.voxclip");
        return v2 with { VoiceLab = v2.VoiceLab with { Segments = [], Assets = [v2.VoiceLab.Assets![0]] } };
    }
    /// <summary>The shared voice-lab source with an empty v1 Voice Lab layer.</summary>
    static Project VoiceLabV1() => Load("voice-lab", "passage-render-v3.voxclip") with { SchemaVersion = 1, VoiceLab = new VoiceLabPlaceholder([]) };
    static (VoiceLabSegment Segment, IReadOnlyList<VoiceLabAsset> Assets) Take(string name)
    {
        var source = Load("voice-lab", name + ".voxclip");
        return (source.VoiceLab.Segments[0], source.VoiceLab.Assets!);
    }
    static VoiceLabVoiceReference Voice(string id = "voice-fixture", string provider = "elevenlabs", string voiceId = "fixture-voice",
        string consent = "consent-fixture", string name = "Fixture voice", VoiceLabVoiceStatus status = VoiceLabVoiceStatus.Active)
        => new(id, provider, voiceId, consent, name, status);
    static JsonObject UpgradeCases() => JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "upgrade-cases.json")))!.AsObject();
    /// <summary>Sorted-key JSON whose numbers are binary64 values, the comparison form in upgrade-README.md.</summary>
    static string Canonical(JsonNode? node) => Sorted(node)?.ToJsonString() ?? "null";
    static JsonNode? Sorted(JsonNode? node) => node switch
    {
        JsonObject value => new JsonObject(value.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => KeyValuePair.Create(pair.Key, Sorted(pair.Value)))),
        JsonArray value => new JsonArray(value.Select(Sorted).ToArray()),
        JsonValue value when value.GetValueKind() == JsonValueKind.Number => JsonValue.Create(value.GetValue<double>()),
        _ => node?.DeepClone(),
    };
    static string Name(VoiceLabProjectException error) => char.ToLowerInvariant(error.Code.ToString()[0]) + error.Code.ToString()[1..];
    /// <summary>Replays one shared case and returns the saved project JSON, or the name of the error its last step threw.
    /// A case without steps returns the error that loading its input threw.</summary>
    static (string? Json, string? Error) Replay(JsonObject cases, JsonNode item)
    {
        var steps = item["steps"]!.AsArray();
        Project project;
        try { project = ProjectSerialization.Deserialize(cases["projects"]![item["input"]!.GetValue<string>()]!.ToJsonString()); }
        catch (VoiceLabProjectException error)
        {
            Assert.True(steps.Count == 0, item["id"] + " refused its input");
            return (null, Name(error));
        }
        for (var index = 0; index < steps.Count; index++)
        {
            var step = steps[index]!;
            try
            {
                project = step["op"]!.GetValue<string>() switch
                {
                    "upgradeToV3" => VoiceLabProject.UpgradeToV3(project),
                    "addVoiceReference" => VoiceLabProject.AddVoiceReference(project, step["voice"].Deserialize(ProjectJsonContext.Default.VoiceLabVoiceReference)!),
                    "markVoiceDeleted" => VoiceLabProject.MarkVoiceDeleted(project, step["id"]!.GetValue<string>()),
                    "accept" => AcceptTake(project, cases["takes"]![step["take"]!.GetValue<string>()]!),
                    var op => throw new InvalidDataException("Unknown upgrade step " + op),
                };
            }
            catch (VoiceLabProjectException error)
            {
                Assert.True(index == steps.Count - 1, item["id"] + " refused before its last step");
                return (null, Name(error));
            }
        }
        return (ProjectSerialization.Serialize(project), null);
    }
    static Project AcceptTake(Project project, JsonNode take) => VoiceLabProject.Accept(project,
        take["assets"]!.AsArray().Select(asset => asset.Deserialize(ProjectJsonContext.Default.VoiceLabAsset)!).ToArray(),
        take["segment"].Deserialize(ProjectJsonContext.Default.VoiceLabSegment)!);
    /// <summary>A copy of <paramref name="project"/> with <paramref name="edit"/> applied to the <c>video</c> object of every candidate recipe.</summary>
    static JsonNode WithRecipeVideos(JsonNode project, Action<JsonObject> edit)
    {
        var copy = project.DeepClone();
        foreach (var segment in copy["voiceLab"]!["segments"]!.AsArray())
            foreach (var candidate in segment!["candidates"]!.AsArray())
                if (candidate!["recipe"] is JsonObject recipe) edit(recipe["video"]!.AsObject());
        return copy;
    }
    static async Task<Project> SaveAndReload(Project project)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("take.voxclip");
        var store = new ProjectStore();
        await store.SaveAsync(project, path, TestContext.Current.CancellationToken);
        return (await store.LoadAsync(path, TestContext.Current.CancellationToken)).Project;
    }

    [Fact]
    public async Task V1UpgradeKeepsTheDocumentThroughSaveAndReload()
    {
        var original = ExtendedV1();
        var upgraded = VoiceLabProject.UpgradeToV3(original);
        Assert.Equal(1, original.SchemaVersion);
        Assert.Null(original.VoiceLab.Assets);
        Assert.Equal(3, upgraded.SchemaVersion);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("{\"segments\":[],\"assets\":[],\"cleanAudio\":{\"mode\":\"off\",\"assetId\":null,\"mix\":null},\"voices\":[],\"videoAssets\":[]}"),
            Json(upgraded)["voiceLab"]));
        var rest = Json(upgraded);
        rest["schemaVersion"] = 1;
        rest["voiceLab"] = Json(original)["voiceLab"]!.DeepClone();
        Assert.True(JsonNode.DeepEquals(Json(original), rest));
        var reopened = await SaveAndReload(upgraded);
        var saved = Json(reopened);
        var source = Json(original);
        Assert.Equal(3, reopened.SchemaVersion);
        Assert.True(JsonNode.DeepEquals(Json(upgraded)["voiceLab"], saved["voiceLab"]));
        foreach (var key in new[] { "id", "title", "createdAt", "transcript", "edits", "captions", "export", "share", "ai", "extensions" })
            Assert.True(JsonNode.DeepEquals(source[key], saved[key]), key);
        VoiceLabProject.Validate(reopened);
    }

    [Fact]
    public void SegmentFreeV2KeepsAssetsAndV3IsUnchanged()
    {
        var v2 = SegmentFreeV2();
        var upgraded = VoiceLabProject.UpgradeToV3(v2);
        Assert.Equal(3, upgraded.SchemaVersion);
        Assert.Equal(2, v2.SchemaVersion);
        Assert.Equal(v2.VoiceLab.Assets!, upgraded.VoiceLab.Assets!);
        Assert.Empty(upgraded.VoiceLab.Segments);
        Assert.Equal(new VoiceLabCleanAudio(VoiceLabCleanAudioMode.Off, null, null), upgraded.VoiceLab.CleanAudio);
        Assert.Empty(upgraded.VoiceLab.Voices!);
        Assert.Empty(upgraded.VoiceLab.VideoAssets!);
        Assert.Same(v2.Transcript, upgraded.Transcript);
        Assert.Same(v2.Edits, upgraded.Edits);
        Assert.Equal(v2.Media, upgraded.Media);
        var v3 = Load("voice-lab", "passage-render-v3.voxclip");
        Assert.Same(v3, VoiceLabProject.UpgradeToV3(v3));
    }

    [Fact]
    public void LegacySegmentsAndInvalidInputsAreNotPromoted()
    {
        var legacy = Load("voice-lab", "passage-project.voxclip");
        Error(VoiceLabProjectErrorCode.LegacySegmentsNeedReview, () => VoiceLabProject.UpgradeToV3(legacy));
        Error(VoiceLabProjectErrorCode.LegacySegmentsNeedReview, () => VoiceLabProject.UpgradeToV3(VoiceLabProject.SetEnabled(legacy, "vl-passage", false)));
        Assert.Equal(2, legacy.SchemaVersion);
        Assert.Single(legacy.VoiceLab.Segments);
        var v1 = ExtendedV1();
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabProject.UpgradeToV3(v1 with { VoiceLab = v1.VoiceLab with { Assets = [] } }));
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabProject.UpgradeToV3(v1 with { SchemaVersion = 4 }));
    }

    [Fact]
    public async Task LoadingAndSavingNeverUpgrade()
    {
        var reopenedV1 = await SaveAndReload(ExtendedV1());
        Assert.Equal(1, reopenedV1.SchemaVersion);
        Assert.Null(reopenedV1.VoiceLab.Assets);
        Assert.Null(reopenedV1.VoiceLab.Voices);
        Assert.Contains("org.example.fork", reopenedV1.Extensions!);
        var reopenedV2 = await SaveAndReload(SegmentFreeV2());
        Assert.Equal(2, reopenedV2.SchemaVersion);
        Assert.Single(reopenedV2.VoiceLab.Assets!);
        Assert.Null(reopenedV2.VoiceLab.CleanAudio);
    }

    [Fact]
    public void AcceptUpgradesV1AndSegmentFreeV2AndNeverWritesV2()
    {
        var (changer, changerAssets) = Take("voice-changer-half-render-v3");
        var v1 = VoiceLabV1();
        var accepted = VoiceLabProject.Accept(v1, changerAssets, changer);
        Assert.Equal(1, v1.SchemaVersion);
        Assert.Equal(3, accepted.SchemaVersion);
        Assert.Same(changer, Assert.Single(accepted.VoiceLab.Segments));
        Assert.Equal(changerAssets, accepted.VoiceLab.Assets!);
        Assert.Equal(new VoiceLabCleanAudio(VoiceLabCleanAudioMode.Off, null, null), accepted.VoiceLab.CleanAudio);
        Assert.Empty(accepted.VoiceLab.Voices!);
        Assert.Empty(accepted.VoiceLab.VideoAssets!);
        Assert.Single(VoiceLabRenderContract.Prepare(accepted, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight).SelectedSegmentRecipes);
        var v2 = Load("voice-lab", "passage-project.voxclip");
        Error(VoiceLabProjectErrorCode.LegacySegmentsNeedReview, () => VoiceLabProject.Accept(v2, changerAssets, changer));
        var emptyV2 = v2 with { VoiceLab = v2.VoiceLab with { Segments = [], Assets = [] } };
        Assert.Equal(ProjectSerialization.Serialize(accepted), ProjectSerialization.Serialize(VoiceLabProject.Accept(emptyV2, changerAssets, changer)));
        // An upgraded v1 has no voice reference yet, so an own-voice take still needs active consent.
        var (own, ownAssets) = Take("passage-render-v3");
        Error(VoiceLabProjectErrorCode.ConsentUnverified, () => VoiceLabProject.Accept(v1, ownAssets, own));
    }

    /// <summary>JSON cannot hold a non-finite number, so accept refuses one in any stored recipe instead of failing later in Serialize.</summary>
    [Fact]
    public void AcceptRefusesNonFiniteNumbersInRejectedRecipes()
    {
        var (changer, assets) = Take("voice-changer-half-render-v3");
        var v1 = VoiceLabV1();
        var alternative = changer.Candidates[1] with { Rejected = "Rejected in review" };
        var segment = changer with { Candidates = [changer.Candidates[0], alternative] };
        Assert.NotEmpty(ProjectSerialization.Serialize(VoiceLabProject.Accept(v1, assets, segment)));
        var recipe = alternative.Recipe!;
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabProject.Accept(v1, assets, segment with { Candidates = [changer.Candidates[0],
            alternative with { Recipe = recipe with { Qa = recipe.Qa with { PeakDbfs = double.NegativeInfinity } } }] }));
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabProject.Accept(v1, assets, segment with { Candidates = [changer.Candidates[0],
            alternative with { Recipe = recipe with { Video = recipe.Video with { RetimeFactor = double.NaN } } }] }));
    }

    [Fact]
    public void AddVoiceReferenceNeedsV3AndAUniqueActiveProviderVoice()
    {
        var v1 = VoiceLabV1();
        Error(VoiceLabProjectErrorCode.RequiresVersion3, () => VoiceLabProject.AddVoiceReference(v1, Voice()));
        Error(VoiceLabProjectErrorCode.RequiresVersion3, () => VoiceLabProject.AddVoiceReference(SegmentFreeV2(), Voice()));
        var empty = VoiceLabProject.UpgradeToV3(v1);
        var added = VoiceLabProject.AddVoiceReference(empty, Voice(name: " \tFixture voice\n"));
        Assert.Equal(Voice(), Assert.Single(added.VoiceLab.Voices!));
        Assert.Empty(empty.VoiceLab.Voices!);
        Assert.Same(empty.VoiceLab.Segments, added.VoiceLab.Segments);
        Assert.Same(empty.VoiceLab.Assets, added.VoiceLab.Assets);
        // Each row breaks one rule; "voice-two"/"other-voice" alone is valid, and a duplicate id or active voice ID is not.
        VoiceLabVoiceReference[] invalid =
        [
            Voice("../voice", voiceId: "other-voice"), Voice("", voiceId: "other-voice"),
            Voice(new string('v', 65), voiceId: "other-voice"), Voice(voiceId: "other-voice"),
            Voice("voice-two", voiceId: "other-voice", consent: ""), Voice("voice-two", voiceId: "other-voice", consent: "consent record"),
            Voice("voice-two", provider: "ElevenLabs", voiceId: "other-voice"), Voice("voice-two", provider: "stock", voiceId: "other-voice"),
            Voice("voice-two", voiceId: "../voices"), Voice("voice-two", voiceId: "voice/other"), Voice("voice-two", voiceId: "voice\n"),
            Voice("voice-two", voiceId: ""), Voice("voice-two", voiceId: new string('a', 129)),
            Voice("voice-two", voiceId: "other-voice", status: VoiceLabVoiceStatus.Deleted), Voice("voice-two", voiceId: "other-voice", name: " \n "),
            Voice("voice-two"),
        ];
        foreach (var reference in invalid)
            Error(VoiceLabProjectErrorCode.InvalidVoice, () => VoiceLabProject.AddVoiceReference(added, reference));
        // Names count Unicode scalars, not UTF-16 units or grapheme clusters.
        var astral = VoiceLabProject.AddVoiceReference(added, Voice("voice-two", voiceId: "other-voice", name: string.Concat(Enumerable.Repeat("\U0001D11E", 60))));
        Assert.Equal(120, astral.VoiceLab.Voices![^1].DisplayName.Length);
        Error(VoiceLabProjectErrorCode.InvalidVoice, () => VoiceLabProject.AddVoiceReference(added,
            Voice("voice-two", voiceId: "other-voice", name: string.Concat(Enumerable.Repeat("õ", 31)))));
        Assert.Equal(2, VoiceLabProject.AddVoiceReference(added, Voice("voice-two", voiceId: new string('a', 128))).VoiceLab.Voices!.Count);
    }

    [Fact]
    public void DeletedVoiceKeepsAcceptedTakesRenderableAndRefusesNewOwnVoiceTakes()
    {
        var fixture = Load("voice-lab", "passage-render-v3.voxclip");
        var active = fixture with { VoiceLab = fixture.VoiceLab with { Voices = [fixture.VoiceLab.Voices![0] with { Status = VoiceLabVoiceStatus.Active }] } };
        var deleted = VoiceLabProject.MarkVoiceDeleted(active, "voice-fixture");
        Assert.Equal(VoiceLabVoiceStatus.Deleted, Assert.Single(deleted.VoiceLab.Voices!).Status);
        Assert.Equal(VoiceLabVoiceStatus.Active, active.VoiceLab.Voices![0].Status);
        Assert.Same(active.VoiceLab.Segments, deleted.VoiceLab.Segments);
        Assert.Same(active.VoiceLab.Assets, deleted.VoiceLab.Assets);
        Assert.Equal(ProjectSerialization.Serialize(fixture), ProjectSerialization.Serialize(deleted));
        // Rendering uses the stored consent evidence, not the reference's current status (§10.5).
        Assert.Single(VoiceLabRenderContract.Prepare(deleted, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight).SelectedSegmentRecipes);
        Assert.Same(deleted, VoiceLabProject.MarkVoiceDeleted(deleted, "voice-fixture"));
        Error(VoiceLabProjectErrorCode.MissingVoice, () => VoiceLabProject.MarkVoiceDeleted(deleted, "voice-missing"));
        Error(VoiceLabProjectErrorCode.RequiresVersion3, () => VoiceLabProject.MarkVoiceDeleted(VoiceLabV1(), "voice-fixture"));
        // Without the earlier take, the same own-voice take is a new accept: refused once deleted, allowed while active.
        var (own, ownAssets) = Take("passage-render-v3");
        var cleared = VoiceLabProject.Delete(deleted, "vl-passage");
        cleared = cleared with { VoiceLab = cleared.VoiceLab with { Assets = [] } };
        Error(VoiceLabProjectErrorCode.ConsentUnverified, () => VoiceLabProject.Accept(cleared, ownAssets, own));
        var reactivated = cleared with { VoiceLab = cleared.VoiceLab with { Voices = active.VoiceLab.Voices } };
        Assert.Equal(ProjectSerialization.Serialize(active), ProjectSerialization.Serialize(VoiceLabProject.Accept(reactivated, ownAssets, own)));
    }

    /// <summary>Accept checks consent for every unrejected own-voice candidate; selecting one after deletion relies on its stored evidence (§10.5).</summary>
    [Fact]
    public void OwnVoiceAlternativeNeedsActiveConsentOnlyWhenAccepted()
    {
        var cases = UpgradeCases();
        var take = cases["takes"]!["changer-own-alternative"]!;
        var active = ProjectSerialization.Deserialize(cases["projects"]!["voice-lab-v3-active-voice"]!.ToJsonString());
        Error(VoiceLabProjectErrorCode.ConsentUnverified, () => AcceptTake(VoiceLabProject.MarkVoiceDeleted(active, "voice-fixture"), take));
        var deleted = VoiceLabProject.MarkVoiceDeleted(AcceptTake(active, take), "voice-fixture");
        var selected = Assert.Single(VoiceLabProject.SelectCandidate(deleted, take["segment"]!["id"]!.GetValue<string>(), 1).VoiceLab.Segments);
        Assert.Equal(1, selected.SelectedCandidateIndex);
        Assert.Equal("fixture-voice", selected.Provenance.VoiceId);
    }

    /// <summary>Transitions are values without I/O or undo registration (§10.3), so App undo restores an earlier value it holds.</summary>
    [Fact]
    public void RestoredTransitionValuesKeepByteIdenticalJson()
    {
        var original = VoiceLabV1();
        var (own, ownAssets) = Take("passage-render-v3");
        var history = new Stack<(Project Project, string Json)>();
        history.Push((original, ProjectSerialization.Serialize(original)));
        void Apply(Func<Project, Project> transition)
        {
            var next = transition(history.Peek().Project);
            history.Push((next, ProjectSerialization.Serialize(next)));
        }
        Apply(VoiceLabProject.UpgradeToV3);
        Apply(project => VoiceLabProject.AddVoiceReference(project, Voice()));
        Apply(project => VoiceLabProject.Accept(project, ownAssets, own));
        Apply(project => VoiceLabProject.MarkVoiceDeleted(project, "voice-fixture"));
        Assert.Equal(5, history.Count);
        Assert.Equal(ProjectSerialization.Serialize(Load("voice-lab", "passage-render-v3.voxclip")), history.Peek().Json);
        while (history.TryPop(out var entry))
            Assert.Equal(entry.Json, ProjectSerialization.Serialize(entry.Project));
        var snapshot = ProjectSerialization.Serialize(original);
        Assert.Equal(snapshot, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(snapshot)));
    }

    [Fact]
    public void SharedUpgradeCasesReplay()
    {
        var cases = UpgradeCases();
        Assert.Equal("voxclip-voice-lab-upgrade-cases/1", cases["schema"]!.GetValue<string>());
        Assert.NotEmpty(cases["cases"]!.AsArray());
        foreach (var node in cases["cases"]!.AsArray())
        {
            var item = node!;
            var id = item["id"]!.GetValue<string>();
            var (json, error) = Replay(cases, item);
            // Expected projects keep their source fixtures' whole seconds, which a save writes in canonical form (editing §10.1).
            var expected = item["error"] is { } refusal ? refusal.GetValue<string>()
                : Canonical(TimestampWireRuleTests.CanonicalTimestamps(cases["projects"]![item["expected"]!.GetValue<string>()]));
            var actual = json is null ? error : Canonical(JsonNode.Parse(json));
            Assert.Equal(id + ": " + expected, id + ": " + actual);
            if (json is not null) ProjectSerialization.Deserialize(json);
        }
    }

    /// <summary>The Mac suite proves its encoder writes these <c>videoRecipes</c> exactly; every mode must read back here.</summary>
    [Fact]
    public void MacEncodedVideoRecipesDecodeInEveryMode()
    {
        var recipes = UpgradeCases()["videoRecipes"]!.AsObject();
        var modes = new List<VoiceLabVideoMode>();
        foreach (var (mode, node) in recipes)
        {
            var recipe = node.Deserialize(ProjectJsonContext.Default.VoiceLabVideoRecipe)!;
            modes.Add(recipe.Mode);
            Assert.Equal(mode, node!["mode"]!.GetValue<string>());
            Assert.Equal(Canonical(node), Canonical(JsonSerializer.SerializeToNode(recipe, ProjectJsonContext.Default.VoiceLabVideoRecipe)));
        }
        Assert.Equal(Enum.GetValues<VoiceLabVideoMode>(), modes.Order());
    }

    /// <summary>Every video key is required, explicit null included (architecture §2.1 rule 8), as on Mac and in the schema.
    /// Development builds before 2026-10-26 left out the null keys, so such files are unreadable.</summary>
    [Fact]
    public async Task RecipeVideoMissingAKeyIsUnreadable()
    {
        var cases = UpgradeCases();
        var project = cases["projects"]!["passage-render-v3"]!;
        string[] keys = [.. cases["videoRecipes"]!["source"]!.AsObject().Select(pair => pair.Key).Order(StringComparer.Ordinal)];
        Assert.Equal(15, keys.Length);
        // The store refuses the file the earlier Mac encoder wrote, which left out every null key.
        var older = WithRecipeVideos(project, video => { foreach (var key in video.Where(pair => pair.Value is null).Select(pair => pair.Key).ToArray()) video.Remove(key); });
        using var storage = new TestStorage();
        var path = storage.PathFor("take.voxclip");
        var store = new ProjectStore();
        await File.WriteAllTextAsync(path, project.ToJsonString(), TestContext.Current.CancellationToken);
        Assert.Equal(3, (await store.LoadAsync(path, TestContext.Current.CancellationToken)).Project.SchemaVersion);
        await File.WriteAllTextAsync(path, older.ToJsonString(), TestContext.Current.CancellationToken);
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable,
            (await Assert.ThrowsAsync<VoxClipException>(() => store.LoadAsync(path, TestContext.Current.CancellationToken))).Code);
        // The store's raw validator and the serializer each require every single key.
        foreach (var partial in keys.Select(key => WithRecipeVideos(project, video => video.Remove(key))).Prepend(older))
        {
            var json = partial.ToJsonString();
            Assert.False(JsonNode.DeepEquals(project, partial));
            Assert.Throws<JsonException>(() => ProjectValidation.Validate(json));
            Assert.Equal(VoxClipErrorCode.ProjectUnreadable, Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(json)).Code);
        }
    }

    [Fact]
    public async Task UpgradedFilesMatchTheProjectSchema()
    {
        using var storage = new TestStorage();
        var store = new ProjectStore();
        var files = new List<string>();
        foreach (var (name, project) in new[] { ("v1-extension", ExtendedV1()), ("v2-asset", SegmentFreeV2()) })
        {
            var path = storage.PathFor(name + ".voxclip");
            await store.SaveAsync(VoiceLabProject.UpgradeToV3(project), path, TestContext.Current.CancellationToken);
            files.Add(path);
        }
        var cases = UpgradeCases();
        foreach (var node in cases["cases"]!.AsArray())
        {
            var item = node!;
            if (Replay(cases, item).Json is not { } json) continue;
            var path = storage.PathFor("case-" + item["id"]!.GetValue<string>() + ".voxclip");
            await File.WriteAllTextAsync(path, json, TestContext.Current.CancellationToken);
            files.Add(path);
        }
        await SchemaPython.ValidateAsync(files, TestContext.Current.CancellationToken);
    }
}
