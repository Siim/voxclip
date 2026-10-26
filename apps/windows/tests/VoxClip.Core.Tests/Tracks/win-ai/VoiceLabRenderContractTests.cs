using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using System.Text.Json.Nodes;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class VoiceLabRenderContractTests
{
    static Project Fixture(string name = "passage-render-v3") => ProjectSerialization.Deserialize(
        File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", name + ".voxclip")));
    static void Error(VoiceLabProjectErrorCode code, Action action) => Assert.Equal(code, Assert.Throws<VoiceLabProjectException>(action).Code);
    static Project Replace(Project project, VoiceLabSegment segment) => project with { VoiceLab = project.VoiceLab with { Segments = [segment] } };

    [Fact]
    public void PassageAndFullTakePrepareAndRoundTrip()
    {
        var passage = Fixture();
        Assert.Equal(3, passage.SchemaVersion);
        Assert.Equal(ProjectSerialization.Serialize(passage), ProjectSerialization.Serialize(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(passage))));
        var prepared = VoiceLabRenderContract.Prepare(passage, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.Equal(7000, prepared.OutputPlan.OutputSamples);
        Assert.Single(prepared.SelectedSegmentRecipes);
        Assert.True(prepared.Disclosure.Required);
        Assert.False(prepared.Disclosure.Persistent);
        Assert.Equal(.7, prepared.Disclosure.OutputAiSeconds, 6);
        Assert.Equal(new VoiceLabLabelInterval(0,3.7), Assert.Single(prepared.Disclosure.Intervals));
        Assert.Equal(.15, prepared.Disclosure.FadeSeconds);
        prepared.Verify(passage, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        var stale = passage with { Captions = passage.Captions with { StyleId = "vox-highlight" } };
        Error(VoiceLabProjectErrorCode.StaleRenderContract, () => prepared.Verify(stale, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight));
        var full = VoiceLabRenderContract.Prepare(Fixture("full-take-render-v3"), VoiceLabOutputScope.Full, VoiceLabLabelPosition.BottomLeft);
        Assert.Equal(2, Assert.Single(full.SelectedSegmentRecipes).Recipe.Chunks.Count);
        Assert.True(full.Disclosure.Persistent);
        Assert.Equal(new VoiceLabLabelInterval(0,7), Assert.Single(full.Disclosure.Intervals));
    }
    [Fact]
    public void SelectionAndSourceRestore()
    {
        var original = Fixture();
        var chosen = VoiceLabProject.SelectCandidate(original, "vl-passage", 1);
        Assert.Equal(.2, chosen.VoiceLab.Segments[0].Audio.TrimStart, 6);
        Assert.Equal(-1, chosen.VoiceLab.Segments[0].Audio.GainDb);
        Assert.Equal((uint)8, chosen.VoiceLab.Segments[0].Provenance.Seed);
        Assert.Equal(.12, chosen.VoiceLab.Segments[0].Words![0].Start);
        Assert.Equal((uint)8, Assert.Single(VoiceLabRenderContract.Prepare(chosen, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft).SelectedSegmentRecipes).Recipe.Seed);
        Assert.Equal(ProjectSerialization.Serialize(original), ProjectSerialization.Serialize(VoiceLabProject.SelectCandidate(chosen, "vl-passage", 0)));
        var disabled = VoiceLabProject.SetEnabled(original, "vl-passage", false);
        Assert.Empty(VoiceLabRenderContract.Prepare(disabled, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight).SelectedSegmentRecipes);
        Assert.Equal(ProjectSerialization.Serialize(original), ProjectSerialization.Serialize(VoiceLabProject.SetEnabled(disabled, "vl-passage", true)));
        var deleted = VoiceLabProject.Delete(original, "vl-passage");
        Assert.Equal(2, deleted.VoiceLab.Assets!.Count);
        Assert.False(VoiceLabRenderContract.Prepare(deleted, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight).Disclosure.Required);
        Error(VoiceLabProjectErrorCode.NeedsVoiceLabUpgrade, () => VoiceLabRenderContract.Prepare(Fixture("passage-project"), VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight));
    }
    [Fact]
    public void InvalidPolicyAndVideoCapability()
    {
        var good = Fixture(); var segment = good.VoiceLab.Segments[0]; var first = segment.Candidates[0]; var recipe = first.Recipe!;
        Error(VoiceLabProjectErrorCode.MissingRenderPolicy, () => VoiceLabProject.Validate(Replace(good, segment with { Candidates = [first with { Recipe = null }, segment.Candidates[1]] })));
        Error(VoiceLabProjectErrorCode.MissingRenderPolicy, () => VoiceLabProject.Validate(Replace(good, segment with { Candidates = [first with { Recipe = recipe with { RoomTone = null } }, segment.Candidates[1]] })));
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabProject.Validate(Replace(good, segment with { Candidates = [first with { Recipe = recipe with { Seams = recipe.Seams with { In = recipe.Seams.In with { AssetHandleFrames = 1 } } } }, segment.Candidates[1]] })));
        Error(VoiceLabProjectErrorCode.QaRejected, () => VoiceLabProject.Validate(Replace(good, segment with { Candidates = [first with { Recipe = recipe with { Qa = recipe.Qa with { PeakDbfs = double.NaN } } }, segment.Candidates[1]] })));
        var retimed = Replace(good, segment with { Candidates = [first with { Recipe = recipe with { Video = recipe.Video with { Mode = VoiceLabVideoMode.Retimed, RetimeFactor = 1 } } }, segment.Candidates[1]] });
        VoiceLabProject.Validate(retimed);
        Error(VoiceLabProjectErrorCode.VideoModeUnsupported, () => VoiceLabRenderContract.Prepare(retimed, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight));
        var raw = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-render-v3.voxclip"));
        Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(raw.Replace("\"mode\": \"source\"", "\"mode\": \"unrecognised\"", StringComparison.Ordinal)));
    }
    [Fact]
    public void DisclosureThresholdsAndStockConversion()
    {
        var at = VoiceLabRenderContract.Prepare(Fixture("disclosure-at-30-render-v3"), VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        var above = VoiceLabRenderContract.Prepare(Fixture("disclosure-above-30-render-v3"), VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.Equal(2.1, at.Disclosure.OutputAiSeconds, 6); Assert.False(at.Disclosure.Persistent);
        Assert.Equal(2.101, above.Disclosure.OutputAiSeconds, 6); Assert.True(above.Disclosure.Persistent);
        var stock = VoiceLabRenderContract.Prepare(Fixture("voice-changer-half-render-v3"), VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.Equal(3.5, stock.Disclosure.OutputAiSeconds); Assert.True(stock.Disclosure.Persistent);
        Assert.Equal(["voiceChanger"], stock.Disclosure.Kinds);
        Assert.Equal("The voice in this video was changed with AI.", stock.Disclosure.PostText);
    }
    [Fact]
    public void ChunksAndChangedDurationSourceCapability()
    {
        var good = Fixture("full-take-render-v3"); var segment = good.VoiceLab.Segments[0]; var first = segment.Candidates[0];
        Error(VoiceLabProjectErrorCode.InvalidRange, () => VoiceLabProject.Validate(Replace(good, segment with {
            Candidates = [first with { Recipe = first.Recipe! with { Chunks = [first.Recipe!.Chunks[0]] } }, segment.Candidates[1]] })));
        var passage = Fixture(); segment = passage.VoiceLab.Segments[0]; first = segment.Candidates[0];
        var recipe = first.Recipe!;
        var audio = recipe.Audio with { TrimEnd = .85, Stretch = 1 };
        recipe = recipe with { OutDuration = .75, Audio = audio,
            Chunks = [recipe.Chunks[0] with { AssembledEndFrame = 20400 }], Video = recipe.Video with { OutputSamples = 750 } };
        passage = Replace(passage, segment with { OutDuration = .75, Audio = audio,
            Candidates = [first with { Recipe = recipe }, segment.Candidates[1]] });
        VoiceLabProject.Validate(passage);
        Error(VoiceLabProjectErrorCode.VideoModeUnsupported, () => VoiceLabRenderContract.Prepare(passage, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight));
    }
    [Fact]
    public void AcceptRejectsMalformedCandidateIndices()
    {
        var project = Fixture(); var segment = project.VoiceLab.Segments[0];
        Error(VoiceLabProjectErrorCode.InvalidCandidate, () => VoiceLabProject.Accept(project, [], segment with { Candidates = [] }));
        Error(VoiceLabProjectErrorCode.InvalidCandidate, () => VoiceLabProject.Accept(project, [], segment with { SelectedCandidateIndex = 99 }));
    }
    [Fact]
    public void SelectedScopeSeamWindows()
    {
        var touching = Fixture("touching-render-v3");
        var prepared = VoiceLabRenderContract.Prepare(touching, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.Equal(2, prepared.SelectedSegmentRecipes.Count);
        var gap = Fixture("one-sample-gap-render-v3");
        Assert.Contains(VoiceLabOutputPlanner.Build(gap, VoiceLabOutputScope.Full).Pieces,
            p => p.Kind == VoiceLabOutputPieceKind.Source && p.SourceEndSample-p.SourceStartSample == 1);
        Error(VoiceLabProjectErrorCode.OverlappingFades, () => VoiceLabRenderContract.Prepare(gap, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight));
        var clipped = Fixture("clipped-seam-render-v3");
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabRenderContract.Prepare(clipped, VoiceLabOutputScope.Clip("clip-edge"), VoiceLabLabelPosition.TopRight));
        Assert.Equal(2, VoiceLabRenderContract.Prepare(clipped, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight).SelectedSegmentRecipes.Count);
    }
    [Fact]
    public void StretchedAssetHandlesUseRawFramesAtTheAssetRate()
    {
        var original = Fixture();
        Project WithHandles(long incoming, long outgoing)
        {
            var segment = original.VoiceLab.Segments[0]; var candidate = segment.Candidates[0]; var recipe = candidate.Recipe!;
            var audio = recipe.Audio with { TrimEnd = .856, Stretch = .7/(.856-.1) };
            recipe = recipe with { Audio = audio, Chunks = [recipe.Chunks[0] with { AssembledEndFrame = 20544 }],
                Seams = recipe.Seams with { In = recipe.Seams.In with { AssetHandleFrames = incoming },
                                            Out = recipe.Seams.Out with { AssetHandleFrames = outgoing } } };
            return Replace(original, segment with { Audio = audio, Candidates = [candidate with { Recipe = recipe }, segment.Candidates[1]] });
        }
        // 10 output samples at 1 kHz require ceil(10 * 24 kHz / (1 kHz * (0.7 / 0.756))) = 260 raw frames.
        var sufficient = WithHandles(260, 260);
        VoiceLabProject.Validate(sufficient);
        Assert.Single(VoiceLabRenderContract.Prepare(sufficient, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight).SelectedSegmentRecipes);
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabProject.Validate(WithHandles(259, 260)));
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabProject.Validate(WithHandles(260, 259)));
    }
    [Fact]
    public void TouchingSynthSeamUsesOneHalfHandleFromEachAsset()
    {
        var original = Fixture("touching-render-v3");
        Project WithHandles(long outgoing, long incoming)
        {
            var first = original.VoiceLab.Segments[0]; var second = original.VoiceLab.Segments[1];
            var firstCandidate = first.Candidates[0]; var secondCandidate = second.Candidates[0];
            first = first with { Candidates = [firstCandidate with { Recipe = firstCandidate.Recipe! with {
                Seams = firstCandidate.Recipe!.Seams with { Out = firstCandidate.Recipe!.Seams.Out with { AssetHandleFrames = outgoing } } } }, first.Candidates[1]] };
            second = second with { Candidates = [secondCandidate with { Recipe = secondCandidate.Recipe! with {
                Seams = secondCandidate.Recipe!.Seams with { In = secondCandidate.Recipe!.Seams.In with { AssetHandleFrames = incoming } } } }, second.Candidates[1]] };
            return original with { VoiceLab = original.VoiceLab with { Segments = [first, second] } };
        }
        // Each side of the one 20-sample seam supplies 10 output samples: 240 frames at 24 kHz.
        var sufficient = WithHandles(240, 240);
        VoiceLabProject.Validate(sufficient);
        var prepared = VoiceLabRenderContract.Prepare(sufficient, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.Equal(2, prepared.SelectedSegmentRecipes.Count);
        Assert.Equal(20, prepared.SelectedSegmentRecipes[0].Recipe.Seams.Out.FadeSamples);
        Assert.Equal(20, prepared.SelectedSegmentRecipes[1].Recipe.Seams.In.FadeSamples);
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabProject.Validate(WithHandles(239, 240)));
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabProject.Validate(WithHandles(240, 239)));
    }
    [Fact]
    public void HalfUpAndRequestBinding()
    {
        using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "render-cases.json")));
        var vector = document.RootElement.GetProperty("sample-grid-half-up");
        Assert.Equal(vector.GetProperty("samples").GetInt64(), VoxClip.Core.Domain.Editing.EditingMath.Round(vector.GetProperty("seconds").GetDouble()*vector.GetProperty("rate").GetDouble()));
        var project = Fixture(); var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Error(VoiceLabProjectErrorCode.StaleRenderContract, () => prepared.Verify(project, VoiceLabOutputScope.Clip("clip-main"), VoiceLabLabelPosition.TopRight));
        Error(VoiceLabProjectErrorCode.StaleRenderContract, () => prepared.Verify(VoiceLabProject.SelectCandidate(project, "vl-passage", 1), VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight));
    }
    [Fact]
    public void PreparedCollectionsAreDetachedAndReadOnly()
    {
        var project = Fixture();
        var segment = project.VoiceLab.Segments[0]; var recipe = segment.Candidates[0].Recipe!;
        var chunks = recipe.Chunks.ToArray(); var words = recipe.Words!.ToArray();
        project = Replace(project, segment with { Candidates = [segment.Candidates[0] with { Recipe = recipe with { Chunks = chunks, Words = words } }, segment.Candidates[1]] });
        var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        var savedChunk = prepared.SelectedSegmentRecipes[0].Recipe.Chunks[0];
        chunks[0] = chunks[0] with { RequestId = "changed" };
        words[0] = words[0] with { Text = "changed" };
        Assert.Equal(savedChunk, prepared.SelectedSegmentRecipes[0].Recipe.Chunks[0]);
        Assert.NotEqual("changed", prepared.SelectedSegmentRecipes[0].Recipe.Words![0].Text);
        Assert.Throws<NotSupportedException>(() => ((IList<VoiceLabChunk>)prepared.SelectedSegmentRecipes[0].Recipe.Chunks)[0] = chunks[0]);
        Assert.Throws<NotSupportedException>(() => ((IList<VoiceLabWord>)prepared.SelectedSegmentRecipes[0].Recipe.Words!).Clear());
        Assert.Throws<NotSupportedException>(() => ((IList<VoiceLabSelectedRecipe>)prepared.SelectedSegmentRecipes).Clear());
        Assert.Throws<NotSupportedException>(() => ((IList<VoiceLabOutputPiece>)prepared.OutputPlan.Pieces).Clear());
        Assert.Throws<NotSupportedException>(() => ((IList<VoiceLabLabelInterval>)prepared.Disclosure.Intervals).Clear());
        Assert.Throws<NotSupportedException>(() => ((IList<string>)prepared.Disclosure.Kinds).Clear());
        Error(VoiceLabProjectErrorCode.StaleRenderContract, () => prepared.Verify(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight));
    }
    [Fact]
    public void InvalidEnumsRejectJsonAndPublicValues()
    {
        var raw = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "voice-changer-half-render-v3.voxclip"));
        foreach (var (field, value) in new[] { ("voiceSource", "stock"), ("status", "deleted"), ("mode", "source"),
                     ("kind", "gap"), ("scope", "passage") })
        {
            var original = $"\"{field}\": \"{value}\"";
            Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(raw.Replace(original, $"\"{field}\": 99", StringComparison.Ordinal)));
        }
        var project = Fixture("voice-changer-half-render-v3"); var segment = project.VoiceLab.Segments[0]; var first = segment.Candidates[0];
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabProject.Validate(Replace(project, segment with { Scope = (VoiceLabSegmentScope)99 })));
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabProject.Validate(Replace(project, segment with { Candidates = [first with { Recipe = first.Recipe! with { VoiceSource = (VoiceLabVoiceSource)99 } }, segment.Candidates[1]] })));
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabProject.Validate(Replace(project, segment with { Candidates = [first with { Recipe = first.Recipe! with { Video = first.Recipe!.Video with { Mode = (VoiceLabVideoMode)99 } } }, segment.Candidates[1]] })));
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabProject.Validate(Replace(project, segment with { Candidates = [first with { Recipe = first.Recipe! with { Seams = first.Recipe!.Seams with { Out = first.Recipe!.Seams.Out with { Kind = (VoiceLabSeamKind)99 } } } }, segment.Candidates[1]] })));
        Error(VoiceLabProjectErrorCode.ConsentUnverified, () => VoiceLabProject.Validate(project with { VoiceLab = project.VoiceLab with { Voices = project.VoiceLab.Voices!.Select(v => v with { Status = (VoiceLabVoiceStatus)99 }).ToArray() } }));
    }
    [Fact]
    public void InvalidPublicLabelPositionRejectsBeforePreparation()
    {
        var project = Fixture();
        Error(VoiceLabProjectErrorCode.InvalidSegment, () => VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, (VoiceLabLabelPosition)99));
    }
    [Fact]
    public void MalformedV3WireShapesAreProjectUnreadable()
    {
        var raw = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-render-v3.voxclip"));
        var changes = new (string Name, Action<JsonNode> Apply)[]
        {
            ("schemaVersion numeric string", root => root["schemaVersion"] = "3"),
            ("voiceLab", root => root["voiceLab"] = 42),
            ("missing voiceLab", root => root.AsObject().Remove("voiceLab")),
            ("cleanAudio", root => root["voiceLab"]!["cleanAudio"] = 42),
            ("missing cleanAudio", root => root["voiceLab"]!.AsObject().Remove("cleanAudio")),
            ("voices array", root => root["voiceLab"]!["voices"] = 42),
            ("voice object", root => root["voiceLab"]!["voices"]![0] = 42),
            ("segments array", root => root["voiceLab"]!["segments"] = 42),
            ("segment object", root => root["voiceLab"]!["segments"]![0] = 42),
            ("candidates array", root => root["voiceLab"]!["segments"]![0]!["candidates"] = 42),
            ("candidate object", root => root["voiceLab"]!["segments"]![0]!["candidates"]![0] = 42),
            ("recipe object", root => root["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"] = 42),
            ("qa object", root => root["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"]!["qa"] = 42),
            ("video object", root => root["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"]!["video"] = 42),
            ("seams object", root => root["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"]!["seams"] = 42),
            ("incoming seam object", root => root["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"]!["seams"]!["in"] = 42),
            ("outgoing seam object", root => root["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"]!["seams"]!["out"] = 42),
            ("numeric enum string", root => root["voiceLab"]!["segments"]![0]!["kind"] = "99"),
            ("unknown enum string", root => root["voiceLab"]!["segments"]![0]!["kind"] = "unknown")
        };
        foreach (var (name, apply) in changes)
        {
            var document = JsonNode.Parse(raw)!;
            apply(document);
            var error = Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(document.ToJsonString()));
            Assert.True(error.Code == VoxClipErrorCode.ProjectUnreadable, $"{name}: {error.Code}");
        }
    }
    [Fact]
    public void ExcludedScopeAndInvalidV3References()
    {
        var project = Fixture();
        var sourceOnly = project with { Edits = project.Edits with { Clips = [project.Edits.Clips[0] with { StartWordId = "w1", EndWordId = "w2" }] } };
        var prepared = VoiceLabRenderContract.Prepare(sourceOnly, VoiceLabOutputScope.Clip("clip-main"), VoiceLabLabelPosition.TopRight);
        Assert.Empty(prepared.SelectedSegmentRecipes); Assert.False(prepared.Disclosure.Required);
        Error(VoiceLabProjectErrorCode.UnsafePath, () => VoiceLabProject.Validate(project with { VoiceLab = project.VoiceLab with { Assets = [project.VoiceLab.Assets![0] with { File = "../outside.wav" }, project.VoiceLab.Assets[1]] } }));
        Error(VoiceLabProjectErrorCode.DanglingAsset, () => VoiceLabProject.Validate(Replace(project, project.VoiceLab.Segments[0] with { Audio = project.VoiceLab.Segments[0].Audio with { AssetId = "missing" } })));
        var raw = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-render-v3.voxclip"));
        Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(raw.Replace("\"schemaVersion\": 3", "\"schemaVersion\": 4", StringComparison.Ordinal)));
        Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(raw.Replace("\"assetId\": null,\n      \"mix\": null", "\"mix\": null", StringComparison.Ordinal)));
        foreach (var missing in new[] { "seams", "video", "qa", "consentVerifiedAt" })
        {
            var node = System.Text.Json.Nodes.JsonNode.Parse(raw)!;
            node["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"]!.AsObject().Remove(missing);
            Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(node.ToJsonString()));
        }
        using var extension = System.Text.Json.JsonDocument.Parse("{\"value\":7}");
        var extended = project with { Extensions = new Dictionary<string, System.Text.Json.JsonElement> { ["example.keep"] = extension.RootElement.Clone() } };
        Assert.Equal(7, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(extended)).Extensions!["example.keep"].GetProperty("value").GetInt32());
    }
}
