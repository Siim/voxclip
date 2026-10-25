using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class EditingProjectTests
{
    public static IEnumerable<TheoryDataRow<string>> Projects() => ProjectStoreTests.Projects();

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
