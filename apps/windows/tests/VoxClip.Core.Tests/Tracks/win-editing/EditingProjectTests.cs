using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class EditingProjectTests
{
    public static IEnumerable<TheoryDataRow<string>> Projects() => ProjectStoreTests.Projects();

    [Fact]
    public void AgentThreadPromotesOnlyOnUse()
    {
        var legacy = ProjectSerialization.Serialize(ContextDemoProject.UpgradeToV4(TestStorage.ProjectFixture()));
        Assert.Equal(legacy, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(legacy)));
        var document = JsonNode.Parse(legacy)!;
        document["schemaVersion"] = 8;
        document["agentThread"] = new JsonObject { ["id"] = "th-test", ["mode"] = "propose", ["turns"] = new JsonArray() };
        var wire = document.ToJsonString();
        var roundTrip = ProjectSerialization.Serialize(ProjectSerialization.Deserialize(wire));
        Assert.Equal(roundTrip, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(roundTrip)));
        Assert.Equal(VoxClipErrorCode.ProjectTooNew,
            Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(wire, 7)).Code);
        var spoken = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "recordings", "two-recordings.voxclip")));
        var v7 = ProjectSerialization.Serialize(spoken);
        Assert.Equal(7, ProjectSerialization.Deserialize(v7).SchemaVersion);
        Assert.Equal(v7, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(v7)));
        var v8 = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(spoken with { AgentThread = new("th-companions", AgentMode.Propose, []) }));
        Assert.Equal(8, v8.SchemaVersion);
        Assert.Equal(spoken.Media.SpokenSources!.Select(source => source.SourceKey), v8.Media.SpokenSources!.Select(source => source.SourceKey));
    }

    [Fact]
    public async Task ProjectOpenStopsRunningTurnsWithoutReplayingPendingEdits()
    {
        var project = ProjectSerialization.Deserialize(AgentFixture());
        var running = Assert.Single(project.AgentThread!.Turns) with { Id = "t2", State = AgentTurnState.Running, Changes = [] };
        project = project with { AgentThread = project.AgentThread with { Turns = [.. project.AgentThread.Turns, running] } };
        var wire = ProjectSerialization.Serialize(project);
        Assert.Equal(wire, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(wire)));
        using var storage = new TestStorage();
        var path = storage.PathFor("agent-thread.voxclip");
        await File.WriteAllTextAsync(path, wire, TestContext.Current.CancellationToken);
        var loaded = (await new ProjectStore().LoadAsync(path, TestContext.Current.CancellationToken)).Project;
        Assert.Equal([AgentTurnState.Pending, AgentTurnState.Stopped], loaded.AgentThread!.Turns.Select(turn => turn.State));
        Assert.Equal(AgentChangeState.Applied, Assert.Single(loaded.AgentThread.Turns[0].Changes).State);
        Assert.Equal(project.Captions.StyleId, loaded.Captions.StyleId);
    }

    [Fact]
    public void StrictAgentWireRejectsUnknownKeysAndVersionMismatch()
    {
        var original = JsonNode.Parse(AgentFixture())!;
        var invalid = original.DeepClone();
        invalid["schemaVersion"] = 6;
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(invalid.ToJsonString())).Code);
        invalid = original.DeepClone();
        invalid["agentThread"] = null;
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(invalid.ToJsonString())).Code);
        var patch = original["agentThread"]!["turns"]![0]!["changes"]![0]!["patch"]![0]!;
        patch["unknown"] = true;
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(original.ToJsonString())).Code);
    }

    private static string AgentFixture() => File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "agent-chat", "pending-turn.voxclip"));

    [Fact]
    public void SpokenSourcesRequireV7AndV6ReaderRefusesThem()
    {
        var original = ContextDemoProject.UpgradeToV4(TestStorage.ProjectFixture());
        var document = JsonNode.Parse(ProjectSerialization.Serialize(original))!;
        document["schemaVersion"] = 6;
        var legacy = ProjectSerialization.Deserialize(document.ToJsonString());
        Assert.Equal(6, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(legacy)).SchemaVersion);
        var media = document["media"]!;
        var companion = (JsonObject)media["source"]!.DeepClone();
        var key = new string('b', 64);
        companion["contentKey"] = key;
        companion.Remove("recordingHash");
        media["additionalSources"] = new JsonArray(companion);
        media["spokenSources"] = new JsonArray(new JsonObject { ["sourceKey"] = key, ["offsetSeconds"] = 10_000,
            ["wordIdPrefix"] = "r2.", ["transcript"] = document["transcript"]!.DeepClone() });
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(document.ToJsonString()));
        document["schemaVersion"] = 7;
        Assert.Equal(VoxClipErrorCode.ProjectTooNew,
            Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(document.ToJsonString(), 6)).Code);
        var spoken = ProjectSerialization.Deserialize(document.ToJsonString());
        Assert.True(JsonNode.DeepEquals(media, JsonNode.Parse(ProjectSerialization.Serialize(spoken))!["media"]));
    }

    [Fact]
    public void StoryPartsRoundTripInPlayOrder()
    {
        var baseProject = ProjectSerialization.Deserialize(File.ReadAllText(TestStorage.ProjectPath("interview-take.voxclip")));
        var document = JsonNode.Parse(ProjectSerialization.Serialize(ContextDemoProject.UpgradeToV4(baseProject)))!;
        document["schemaVersion"] = 4;
        var legacy = ProjectSerialization.Deserialize(document.ToJsonString());
        Assert.Equal(4, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(legacy)).SchemaVersion);
        document["schemaVersion"] = 5;
        document["edits"]!["clips"] = JsonNode.Parse("""
            [{"id":"story","startWordId":"w1","endWordId":"w4","title":null,"origin":"manual","aiResultId":null,
              "aiClipIndex":null,"selected":true,"kind":"story","parts":[
                {"id":"closing","startWordId":"w4","endWordId":"w4"},{"id":"opening","startWordId":"w1","endWordId":"w2"}]}]
            """);
        var story = ProjectSerialization.Deserialize(document.ToJsonString());
        Assert.Single(story.Edits.Clips);
        var roundTrip = JsonNode.Parse(ProjectSerialization.Serialize(story))!;
        Assert.Equal(5, roundTrip["schemaVersion"]!.GetValue<int>());
        Assert.True(JsonNode.DeepEquals(document["edits"]!["clips"], roundTrip["edits"]!["clips"]));
    }

    [Fact]
    public void PartCommandsKeepCutsAndWriteOnlyNecessaryVersions()
    {
        var project = ContextDemoProject.UpgradeToV4(ProjectSerialization.Deserialize(File.ReadAllText(TestStorage.ProjectPath("interview-take.voxclip"))));
        ClipPart opening = new("opening", "w1", "w2");
        ClipPart closing = new("closing", "w4", "w4", new("face", 1, 0.3, 0.5));
        project = EditingEngine.ApplyEditing(project, new EditOperation.AddClip(new("story", "w1", "w4", null, ClipOrigin.Manual, null, null, true, Parts: [closing, opening])));
        Assert.Equal(5, project.SchemaVersion);
        Assert.Equal(new[] { closing, opening }, Assert.Single(project.Edits.Clips).PlayParts);
        project = EditingEngine.ApplyEditing(project, new EditOperation.SetWordCuts(["w2"], true));
        Assert.Same(project, EditingEngine.ApplyEditing(project, new EditOperation.UpdateClip("story", 0, 1)));
        project = EditingEngine.ApplyEditing(project, new EditOperation.MakeClipOfPart("story", "opening"));
        Assert.Equal("w2", Assert.Single(project.Edits.Clips[^1].PlayParts).EndWordId);
        project = EditingEngine.ApplyEditing(project, new EditOperation.SetClipParts("story", [opening]));
        Assert.Equal(4, project.SchemaVersion);
        Assert.Equal(new[] { "w2", "w6" }, project.Edits.CutWordIds);
    }

    [Theory]
    [MemberData(nameof(Projects))]
    public void SharedProjectsRoundTripThePersistedEditSubset(string name)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(TestStorage.ProjectPath(name)));
        var state = Assert.IsType<EditState>(EditingEngine.FromProject(project));
        Assert.Same(project.Transcript, state.Transcript);
        Assert.Equal(project.Edits.CutWordIds, state.Transcript.Words.Where(word => state.CutWordIds.Contains(word.Id)).Select(word => word.Id));
        Assert.Equal(project.Edits.CutPauseIds, state.Pauses.Where(pause => state.CutPauseIds.Contains(pause.Id)).Select(pause => pause.Id));
        var result = EditingEngine.ApplyToProject(project, state);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(ProjectSerialization.Serialize(project)), JsonNode.Parse(ProjectSerialization.Serialize(result))));
        var restored = Assert.IsType<EditState>(EditingEngine.FromProject(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(result))));
        Assert.Equal(state.Pauses, restored.Pauses);
        Assert.Equal(state.Clips, restored.Clips);
        using var json = JsonDocument.Parse(ProjectSerialization.Serialize(result));
        Assert.Equal(new[] { "activeClipId", "clips", "corrections", "cutPauseIds", "cutWordIds", "pauseKeepSeconds", "pauseThresholdSeconds" },
            json.RootElement.GetProperty("edits").EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal));
    }

    [Fact]
    public void ProjectsWithoutTranscriptsHaveNoEditingState()
        => Assert.Null(EditingEngine.FromProject(TestStorage.ProjectFixture() with { Transcript = null }));

    [Theory]
    [MemberData(nameof(Projects))]
    public void RemovingClipsDropsOnlyTheirShareCaptionsAndPreservesOtherSections(string name)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(TestStorage.ProjectPath(name)));
        var clip = new ClipRange("bridge-clip", project.Transcript!.Words[0].Id, project.Transcript.Words[^1].Id, null, ClipOrigin.Manual, null, null, true);
        project = project with { Edits = project.Edits with { Clips = project.Edits.Clips.Append(clip).ToArray() },
            Share = new(new Dictionary<string, string> { ["full"] = "full caption", [clip.Id] = "clip caption" }) };
        var state = EditingEngine.FromProject(project)!;
        var result = EditingEngine.ApplyToProject(project, EditingEngine.Reduce(state, new EditOperation.RemoveClip(clip.Id)));
        Assert.DoesNotContain(result.Edits.Clips, existing => existing.Id == clip.Id);
        Assert.Equal("full caption", Assert.Single(result.Share.Captions).Value);
        Assert.Same(project.Ai, result.Ai);
        Assert.Same(project.Media, result.Media);
        Assert.Same(project.Transcript, result.Transcript);
        Assert.Same(project.Captions, result.Captions);
        Assert.Same(project.Export, result.Export);
        Assert.Same(project.VoiceLab, result.VoiceLab);
        Assert.Same(project.Extensions, result.Extensions);
    }

    [Fact]
    public void BridgeUsesTheSameStaleReferenceCleanupAsTheProjectStore()
    {
        var project = TestStorage.ProjectFixture();
        project = project with { Edits = project.Edits with { CutWordIds = ["missing"], CutPauseIds = ["missing"],
            Corrections = new Dictionary<string, string> { ["missing"] = "text" },
            Clips = [project.Edits.Clips[0] with { StartWordId = "missing" }], ActiveClipId = "missing" } };
        var state = EditingEngine.FromProject(project)!;
        Assert.Empty(state.CutWordIds);
        Assert.Empty(state.CutPauseIds);
        Assert.Empty(state.Corrections);
        Assert.Empty(state.Clips);
        Assert.Null(state.ActiveClipId);
        var result = EditingEngine.ApplyToProject(project, state);
        Assert.DoesNotContain(result.Share.Captions.Keys, key => key != "full");
    }

    [Fact]
    public void ApplyingTranscriptReplacementClearsDependentAiAndShareData()
    {
        var project = TestStorage.ProjectFixture();
        var state = EditingEngine.FromProject(project)!;
        var replacement = state.Transcript with { Refined = false };
        state = EditingEngine.Reduce(state, new EditOperation.ReplaceTranscript(replacement));
        var result = EditingEngine.ApplyToProject(project, state);
        Assert.Same(replacement, result.Transcript);
        Assert.Equal(1, result.Edits.PauseThresholdSeconds);
        Assert.Empty(result.Edits.Clips);
        Assert.Empty(result.Edits.Corrections);
        Assert.Empty(result.Ai.Results);
        Assert.Empty(result.Share.Captions);
        Assert.Same(project.Media, result.Media);
        Assert.Same(project.Captions, result.Captions);
    }
}
