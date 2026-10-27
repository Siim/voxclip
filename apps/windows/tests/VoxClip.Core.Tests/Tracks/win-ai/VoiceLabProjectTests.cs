using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using VoxClip.Core.Tests.Tracks.WinEditing;
using VoxClip.Core.Tests.Tracks.WinCoreNative;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class VoiceLabProjectTests
{
    private static Project Fixture(string name = "passage-project") => ProjectSerialization.Deserialize(
        File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", name + ".voxclip")));
    private static JsonElement Expected()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "plan-cases.json")));
        return document.RootElement.Clone();
    }
    private static void Error(VoiceLabProjectErrorCode code, Action action) => Assert.Equal(code, Assert.Throws<VoiceLabProjectException>(action).Code);

    [Fact]
    public void VersionedRoundTripAndFutureRejection()
    {
        var v1 = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "interview-take.voxclip")));
        Assert.Equal(1, v1.SchemaVersion);
        Assert.Null(v1.VoiceLab.Assets);
        Assert.Equal(1, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(v1)).SchemaVersion);
        var v2 = Fixture();
        Assert.Equal(2, v2.SchemaVersion);
        var json = ProjectSerialization.Serialize(v2);
        Assert.Equal(json, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(json)));
        Assert.Equal(VoxClipErrorCode.ProjectTooNew, Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(json.Replace("\"schemaVersion\": 2", "\"schemaVersion\": 4", StringComparison.Ordinal))).Code);
        using var extension = JsonDocument.Parse("{\"nested\":[7]}");
        var updated = v2 with { Extensions = new Dictionary<string, JsonElement> { ["example.keep"] = extension.RootElement.Clone() } };
        Assert.Equal(7, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(updated)).Extensions!["example.keep"].GetProperty("nested")[0].GetInt32());
    }

    [Fact]
    public void InvalidReferencesRangesAndWordsAreTyped()
    {
        var good = Fixture();
        var raw = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-project.voxclip"));
        Error(VoiceLabProjectErrorCode.UnsafePath, () => ProjectSerialization.Deserialize(raw.Replace(
            good.Id + "/asset-one.wav", good.Id + "/asset-one:stream.wav", StringComparison.Ordinal)));
        Error(VoiceLabProjectErrorCode.UnsafePath, () => VoiceLabProject.Validate(good with { Id = "../outside" }));
        var assets = good.VoiceLab.Assets!.ToArray();
        assets[0] = assets[0] with { File = "../outside.wav" };
        Error(VoiceLabProjectErrorCode.UnsafePath, () => ProjectSerialization.Serialize(good with { VoiceLab = good.VoiceLab with { Assets = assets } }));
        foreach (var filename in new[] { "asset-one:stream.wav", "asset-one..wav", "asset-one .wav", "con.wav" })
        {
            assets = good.VoiceLab.Assets!.ToArray(); assets[0] = assets[0] with { File = good.Id + "/" + filename };
            Error(VoiceLabProjectErrorCode.UnsafePath, () => ProjectSerialization.Serialize(good with { VoiceLab = good.VoiceLab with { Assets = assets } }));
        }
        assets = good.VoiceLab.Assets!.ToArray(); assets[0] = assets[0] with { Id = "con", File = good.Id + "/con.wav" };
        Error(VoiceLabProjectErrorCode.UnsafePath, () => ProjectSerialization.Serialize(good with { VoiceLab = good.VoiceLab with { Assets = assets } }));
        var segment = good.VoiceLab.Segments[0];
        Error(VoiceLabProjectErrorCode.DanglingAsset, () => VoiceLabProject.Validate(good with { VoiceLab = good.VoiceLab with {
            Segments = [segment with { Audio = segment.Audio with { AssetId = "missing" } }] } }));
        Error(VoiceLabProjectErrorCode.InvalidRange, () => VoiceLabProject.Validate(good with { VoiceLab = good.VoiceLab with {
            Segments = [segment with { Replace = segment.Replace with { End = double.PositiveInfinity } }] } }));
        Error(VoiceLabProjectErrorCode.InvalidRange, () => VoiceLabProject.Validate(good with { VoiceLab = good.VoiceLab with {
            Segments = [segment with { Replace = segment.Replace with { End = 2.5 } }] } }));
        var words = segment.Words!.ToArray(); words[1] = words[1] with { Start = 0.1 };
        Error(VoiceLabProjectErrorCode.InvalidWords, () => VoiceLabProject.Validate(good with { VoiceLab = good.VoiceLab with {
            Segments = [segment with { Words = words }] } }));
        words = segment.Words!.ToArray(); words[0] = words[0] with { End = 0.0001 };
        Error(VoiceLabProjectErrorCode.InvalidWords, () => VoiceLabProject.Validate(good with { VoiceLab = good.VoiceLab with {
            Segments = [segment with { Words = words }] } }));
        Error(VoiceLabProjectErrorCode.InvalidCandidate, () => VoiceLabProject.Validate(good with { VoiceLab = good.VoiceLab with {
            Segments = [segment with { SelectedCandidateIndex = 99 }] } }));
        var sourceWords = good.Transcript!.Words.ToArray(); sourceWords[1] = sourceWords[1] with { Id = sourceWords[0].Id };
        Error(VoiceLabProjectErrorCode.InvalidRange, () => VoiceLabProject.Validate(good with { Transcript = good.Transcript with { Words = sourceWords } }));
        sourceWords = good.Transcript.Words.ToArray(); sourceWords[1] = sourceWords[1] with { Id = "../word" };
        Error(VoiceLabProjectErrorCode.InvalidRange, () => VoiceLabProject.Validate(good with { Transcript = good.Transcript with { Words = sourceWords } }));
        Error(VoiceLabProjectErrorCode.OverlappingReplacement, () => VoiceLabProject.Validate(good with { VoiceLab = good.VoiceLab with {
            Segments = [segment, segment with { Id = "vl-overlap" }] } }));
    }

    [Fact]
    public void PassageFullTakeAndClipUseCanonicalPieces()
    {
        var expected = Expected();
        var project = Fixture();
        var plan = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full);
        var passage = expected.GetProperty("passage");
        Assert.Equal(passage.GetProperty("outputSamples").GetInt64(), plan.OutputSamples);
        var rows = passage.GetProperty("pieces").EnumerateArray().ToArray();
        Assert.Equal(rows.Length, plan.Pieces.Count);
        for (var i = 0; i < rows.Length; i++)
        {
            var row = rows[i].EnumerateArray().ToArray(); var piece = plan.Pieces[i];
            Assert.Equal(row[0].GetString(), piece.Kind == VoiceLabOutputPieceKind.Synth ? "synth" : "source");
            Assert.Equal(row[1].GetInt64(), piece.SourceStartSample); Assert.Equal(row[2].GetInt64(), piece.SourceEndSample);
            Assert.Equal(row[3].GetInt64(), piece.OutputStartSample); Assert.Equal(row[4].GetInt64(), piece.OutputEndSample);
        }
        foreach (var mapping in passage.GetProperty("mapping").EnumerateArray())
        {
            var pair = mapping.EnumerateArray().ToArray();
            Assert.Equal(pair[1].GetDouble(), plan.MapTime(pair[0].GetDouble()), 6);
            Assert.Equal(pair[0].GetDouble(), plan.SourceTime(pair[1].GetDouble()), 6);
        }
        foreach (var expectedCaption in passage.GetProperty("captions").EnumerateArray())
        {
            var fields = expectedCaption.EnumerateArray().ToArray();
            var caption = Assert.Single(plan.Captions, item => item.Id == fields[0].GetString());
            Assert.Equal(fields[1].GetDouble(), caption.Start, 6); Assert.Equal(fields[2].GetDouble(), caption.End, 6);
        }
        Error(VoiceLabProjectErrorCode.UnsupportedRendering, plan.RequireLegacyRendering);
        var full = VoiceLabOutputPlanner.Build(Fixture("full-take-project"), VoiceLabOutputScope.Full);
        Assert.Equal(expected.GetProperty("full").GetProperty("outputSamples").GetInt64(), full.OutputSamples);
        Assert.Single(full.Pieces);
        foreach (var mapping in expected.GetProperty("full").GetProperty("mapping").EnumerateArray())
        {
            var pair = mapping.EnumerateArray().ToArray();
            Assert.Equal(pair[1].GetDouble(), full.MapTime(pair[0].GetDouble()), 6);
        }
        var clip = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Clip("clip-main"));
        Assert.Equal(expected.GetProperty("clip").GetProperty("outputSamples").GetInt64(), clip.OutputSamples);
        Assert.Equal(1.05, clip.SourceTime(0), 6);
        Assert.Equal(7, clip.SourceTime(clip.Duration), 6);
    }

    [Fact]
    public void TransitionsRestoreSourceAndKeepAssets()
    {
        var original = Fixture();
        var disabled = VoiceLabProject.SetEnabled(original, "vl-passage", false);
        var disabledPlan = VoiceLabOutputPlanner.Build(disabled, VoiceLabOutputScope.Full);
        Assert.Equal(7000, disabledPlan.OutputSamples);
        Assert.False(disabledPlan.RequiresSyntheticRendering);
        disabledPlan.RequireLegacyRendering(); VoiceLabProject.RequireLegacyRendering(disabled);
        Assert.Equal(ProjectSerialization.Serialize(original), ProjectSerialization.Serialize(VoiceLabProject.SetEnabled(disabled, "vl-passage", true)));
        var selected = VoiceLabProject.SelectCandidate(original, "vl-passage", 1);
        Assert.Equal("asset-two", selected.VoiceLab.Segments[0].Audio.AssetId);
        Assert.Equal("asset-one", original.VoiceLab.Segments[0].Audio.AssetId);
        var deleted = VoiceLabProject.Delete(original, "vl-passage");
        Assert.Equal(2, deleted.VoiceLab.Assets!.Count);
        Assert.Equal(7000, VoiceLabOutputPlanner.Build(deleted, VoiceLabOutputScope.Full).OutputSamples);
        Assert.Same(original.Transcript, deleted.Transcript);
        Assert.Same(original.Edits, deleted.Edits);
        var v1 = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "interview-take.voxclip")));
        // Accept upgrades v1 to v3 first, so a recipe-less v2 segment can no longer create a v2 project.
        Error(VoiceLabProjectErrorCode.MissingRenderPolicy, () => VoiceLabProject.Accept(v1, original.VoiceLab.Assets!, original.VoiceLab.Segments[0]));
        Assert.Equal(1, v1.SchemaVersion);
        Error(VoiceLabProjectErrorCode.LegacySegmentsNeedReview, () => VoiceLabProject.Accept(original, [], original.VoiceLab.Segments[0] with { Id = "vl-second" }));
    }

    [Fact]
    public void SeamCutsAndVoiceChangerCaptions()
    {
        var original = Fixture();
        var edited = original with { Edits = original.Edits with { CutWordIds = ["w4", "w6"] } };
        var plan = VoiceLabOutputPlanner.Build(edited, VoiceLabOutputScope.Full);
        Assert.Equal(7050, plan.OutputSamples);
        Assert.Contains(plan.Pieces, piece => piece.Kind == VoiceLabOutputPieceKind.Synth && piece.SourceStartSample == 2500 && piece.SourceEndSample == 3200);
        var disabled = VoiceLabProject.SetEnabled(edited, "vl-passage", false);
        Assert.True(VoiceLabOutputPlanner.Build(disabled, VoiceLabOutputScope.Full).OutputSamples < 7000);
        var segment = original.VoiceLab.Segments[0];
        var changer = original with { VoiceLab = original.VoiceLab with { Segments = [segment with {
            Kind = VoiceLabSegmentKind.VoiceChanger, Text = null, Words = null }] } };
        var converted = VoiceLabOutputPlanner.Build(changer, VoiceLabOutputScope.Full);
        var sourceWord = Assert.Single(converted.Captions, word => word.Id == "w4");
        Assert.Equal("we", sourceWord.Text);
        Assert.Equal(2.5 + 0.1 / 0.7, sourceWord.Start, 6);
        var clipped = original.Edits.Clips.Select(clip => clip with { EndWordId = "w5" }).ToArray();
        var badClip = original with { Edits = original.Edits with { Clips = clipped } };
        Error(VoiceLabProjectErrorCode.InvalidScope, () => VoiceLabOutputPlanner.Build(badClip, VoiceLabOutputScope.Clip("clip-main")));
    }

    [Fact]
    public async Task StoreSaveAndReopenRetainsEnabledReplacement()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("voice-lab.voxclip");
        var original = Fixture();
        var store = new ProjectStore();
        await store.SaveAsync(original, path, TestContext.Current.CancellationToken);
        var reopened = await store.LoadAsync(path, TestContext.Current.CancellationToken);
        Assert.Equal(2, reopened.Project.SchemaVersion);
        Assert.Equal(original.VoiceLab.Segments[0].Id, reopened.Project.VoiceLab.Segments[0].Id);
        Assert.True(reopened.Project.VoiceLab.Segments[0].Enabled);
        Assert.Equal(7300, VoiceLabOutputPlanner.Build(reopened.Project, VoiceLabOutputScope.Full).OutputSamples);
    }

    [Fact]
    public void AssetNamingAcceptsOnlySafeStoreNames()
    {
        const string project = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11";
        (string AssetId, string Suffix)[] accepted = [("asset-one", "wav"), ("take_2", "flac"), ("0", "wav"), ("console", "wav"), ("con-take", "wav"),
            ("com0", "wav"), ("com10", "flac"), ("lpt0", "wav"), (new string('a', 64), "wav")];
        foreach (var (assetId, suffix) in accepted)
            Assert.Equal($"{project}/{assetId}.{suffix}", VoiceLabAssetNaming.File(project, assetId, suffix));
        var reserved = new[] { "con", "prn", "aux", "nul" }.Concat(Enumerable.Range(1, 9).SelectMany(n => new[] { $"com{n}", $"lpt{n}" }));
        string[] unsafeAssets = [.. reserved, "Asset-one", "ASSET", "asset:stream", "asset.", "asset ", "asset..", "../asset", "..", "asset/../x",
            "a\\b", "/etc/passwd", "file:///tmp/a", "https://example.com/a", "", "-asset", "_asset", "asset.wav", "ässet", new string('a', 65)];
        foreach (var assetId in unsafeAssets)
            Error(VoiceLabProjectErrorCode.InvalidAsset, () => VoiceLabAssetNaming.File(project, assetId, "wav"));
        foreach (var projectId in new[] { project.ToUpperInvariant(), "../" + project, project + "/..", "/tmp/" + project, "C:\\" + project, "file:///" + project, "", "not-a-uuid" })
            Error(VoiceLabProjectErrorCode.InvalidAsset, () => VoiceLabAssetNaming.File(projectId, "asset-one", "wav"));
        foreach (var suffix in new[] { "WAV", "mp3", "mp4", ".wav", "wav ", "", "wav/x" })
            Error(VoiceLabProjectErrorCode.InvalidAsset, () => VoiceLabAssetNaming.File(project, "asset-one", suffix));
        // §10.5 video assets use the same rule with a fixed .mp4 extension; the public name stays audio-only.
        Assert.Equal(project + "/lipsync-take.mp4", VoiceLabAssetNaming.SafeVideoFile(project, "lipsync-take"));
        Assert.All(unsafeAssets, assetId => Assert.Null(VoiceLabAssetNaming.SafeVideoFile(project, assetId)));
        // Validation applies the same rule to stored files and keeps reporting UnsafePath.
        var good = Fixture();
        Project WithFile(string file)
        {
            var assets = good.VoiceLab.Assets!.ToArray();
            assets[0] = assets[0] with { File = file };
            return good with { VoiceLab = good.VoiceLab with { Assets = assets } };
        }
        VoiceLabProject.Validate(WithFile(project + "/asset-one.flac"));
        foreach (var file in new[] { project + "/asset-one.WAV", project + "/asset-two.wav", project + "\\asset-one.wav", "/" + project + "/asset-one.wav",
            project + "/asset-one.wav.wav", project + "/asset-one", "file:///" + project + "/asset-one.wav" })
            Error(VoiceLabProjectErrorCode.UnsafePath, () => VoiceLabProject.Validate(WithFile(file)));
    }

    [Fact]
    public Task SharedVersionTwoFilesMatchJsonSchema()
        => SchemaPython.ValidateAsync(new[] { "passage-project.voxclip", "full-take-project.voxclip" }
            .Select(name => Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", name)), TestContext.Current.CancellationToken);
}
