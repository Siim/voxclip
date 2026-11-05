using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>Replays shared/fixtures/clip-controls/clip-controls-wire-cases.json, as the Swift ClipControlsProjectWireTests do.</summary>
public sealed class ClipControlsProjectWireTests
{
    private static JsonObject Fixture() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-project.voxclip"))!.AsObject();
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-wire-cases.json"))!.AsObject();

    private static JsonObject Applied(JsonNode item)
    {
        var document = Fixture();
        foreach (var patch in item["patches"]!.AsArray())
        {
            var parts = patch!["path"]!.GetValue<string>().Split('/', StringSplitOptions.RemoveEmptyEntries);
            JsonNode target = document;
            foreach (var part in parts[..^1]) target = target is JsonArray array ? array[int.Parse(part)]! : target[part]!;
            if (target is JsonArray values) values[int.Parse(parts[^1])] = patch["value"]?.DeepClone();
            else if (patch["remove"]?.GetValue<bool>() == true) target.AsObject().Remove(parts[^1]);
            else target[parts[^1]] = patch["value"]?.DeepClone();
        }
        return document;
    }

    [Fact]
    public void FormatIsItsOwnFile() => Assert.Equal("voxclip-clip-controls-wire-cases/1", Cases()["format"]!.GetValue<string>());

    [Fact]
    public void MacProjectsWithClipControlsOpenValidateAndSaveUnchanged()
    {
        var valid = Cases()["valid"]!.AsArray();
        Assert.Equal(13, valid.Count);
        foreach (var item in valid)
        {
            var id = item!["id"]!.GetValue<string>();
            var input = Applied(item);
            var project = ProjectSerialization.Deserialize(input.ToJsonString());
            Assert.Equal(4, project.SchemaVersion);
            var encoded = ProjectSerialization.Serialize(project);
            Assert.Equal(encoded, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(encoded)));
            var saved = JsonNode.Parse(encoded)!.AsObject();
            if (input["clipControls"] is null) Assert.False(saved.ContainsKey("clipControls"), id);
            else Assert.True(JsonNode.DeepEquals(input["clipControls"], saved["clipControls"]), id + ": " + saved["clipControls"]?.ToJsonString());
        }
    }

    [Fact]
    public void InvalidCorpusIsRejected()
    {
        var invalid = Cases()["invalid"]!.AsArray();
        Assert.Equal(38, invalid.Count);
        foreach (var item in invalid)
        {
            var exception = Record.Exception(() => ProjectSerialization.Deserialize(Applied(item!).ToJsonString()));
            Assert.True(exception is not null, item!["id"]!.GetValue<string>());
            if (item["tooNew"]?.GetValue<bool>() == true)
                Assert.Equal(VoxClipErrorCode.ProjectTooNew, Assert.IsType<VoxClipException>(exception).Code);
        }
    }

    [Fact]
    public void WindowsRendersClipControlsForTheirClipOnlyAndKeepsTheProject()
    {
        var project = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        var controls = Assert.Single(project.ClipControls);
        Assert.Equal(new ProjectClipControls("clip-main", 1.25, ClipShape.Portrait, ClipLook.Muted, -3.5, 0.5, 1, false, true, 90), controls);
        // The refusal is gone: the clip render carries its controls; the full video renders without them (design §6.9).
        VoiceLabRenderContract.RequireWindowsVisualSupport(project);
        Assert.Equal(controls, ClipRenderInput.Resolve(project, "clip-main", "/data", "/shared")?.Controls);
        Assert.Null(ClipControlsRendering.Controls(project, null));
        Assert.Equal(ProjectSerialization.Serialize(project), ProjectSerialization.Serialize(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project))));
        // Back at the defaults the entry is removed and nothing changes the render.
        var reset = ClipControlsProject.Setting(new ProjectClipControls("clip-main", 1, null, ClipLook.Original, 0, 0, 0, false, false, 0), project);
        Assert.Empty(reset.ClipControls);
        Assert.Null(ClipControlsRendering.Controls(reset, "clip-main"));
    }

    [Fact]
    public void RemovingAClipDropsItsControlsAndALegacyProjectPromotesOnItsFirst()
    {
        var project = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        Assert.Empty(ClipControlsProject.Pruned(project.ClipControls, []));
        var legacy = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/interview-take.voxclip"));
        Assert.Equal(1, legacy.SchemaVersion);
        Assert.False(JsonNode.Parse(ProjectSerialization.Serialize(legacy))!.AsObject().ContainsKey("clipControls"));
        var words = legacy.Transcript!.Words;
        var clipped = legacy with { Edits = legacy.Edits with { Clips = [new ClipRange("clip-a", words[0].Id, words[^1].Id, null, ClipOrigin.Manual, null, null, true)] } };
        var speed = new ProjectClipControls("clip-a", 1.1, null, ClipLook.Original, 0, 0, 0, false, false, 0);
        var promoted = ClipControlsProject.Setting(speed, clipped);
        Assert.Equal(4, promoted.SchemaVersion);
        Assert.Equal(speed, Assert.Single(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(promoted)).ClipControls));
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Serialize(clipped with { ClipControls = [speed] }));
        Assert.Throws<VoxClipException>(() => ClipControlsProject.Setting(speed with { ClipId = "missing" }, clipped));
    }
}
