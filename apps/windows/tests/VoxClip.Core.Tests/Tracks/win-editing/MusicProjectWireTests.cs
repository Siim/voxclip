using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>Replays shared/fixtures/music/music-wire-cases.json, as the Swift MusicProjectWireTests do.</summary>
public sealed class MusicProjectWireTests
{
    private static JsonObject Fixture() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/music/music-project.voxclip"))!.AsObject();
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/music/music-wire-cases.json"))!.AsObject();

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
    public void FormatIsItsOwnFile() => Assert.Equal("voxclip-music-wire-cases/1", Cases()["format"]!.GetValue<string>());

    [Fact]
    public void MacProjectsWithMusicOpenValidateAndSaveUnchanged()
    {
        foreach (var item in Cases()["valid"]!.AsArray())
        {
            var id = item!["id"]!.GetValue<string>();
            var input = Applied(item);
            var project = ProjectSerialization.Deserialize(input.ToJsonString());
            Assert.Equal(4, project.SchemaVersion);
            var encoded = ProjectSerialization.Serialize(project);
            Assert.Equal(encoded, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(encoded)));
            var saved = JsonNode.Parse(encoded)!.AsObject();
            if (input["music"] is null) Assert.False(saved.ContainsKey("music"), id);
            else Assert.True(JsonNode.DeepEquals(input["music"], saved["music"]), id);
        }
    }

    [Fact]
    public void InvalidCorpusIsRejected()
    {
        foreach (var item in Cases()["invalid"]!.AsArray())
        {
            var exception = Record.Exception(() => ProjectSerialization.Deserialize(Applied(item!).ToJsonString()));
            Assert.True(exception is not null, item!["id"]!.GetValue<string>());
            if (item["tooNew"]?.GetValue<bool>() == true)
                Assert.Equal(VoxClipErrorCode.ProjectTooNew, Assert.IsType<VoxClipException>(exception).Code);
        }
    }

    [Fact]
    public void WindowsRendersMusicForItsScopeAndKeepsTheProject()
    {
        var project = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Clip("clip-main"), VoiceLabLabelPosition.TopRight);
        var data = Path.Combine(Path.GetTempPath(), "voxclip-music-scope");
        // The clip plays its own track, the full video the full-video track; each from <data>/Music/<projectId>/.
        var clip = ClipRenderInput.Resolve(project, "clip-main", data, FixtureLoader.SharedRoot)!.Music!;
        var full = ClipRenderInput.Resolve(project, null, data, FixtureLoader.SharedRoot)!.Music!;
        Assert.Equal(("music-main", "music-full"), (clip.Entry.Id, full.Entry.Id));
        Assert.Equal(Path.Combine(data, "Music", project.Id, Path.GetFileName(clip.Entry.Asset.File)), clip.AssetPath);
        Assert.Null(ClipRenderInput.Resolve(project, "clip-main", data, FixtureLoader.SharedRoot)!.ForEditedAudio);
        var without = MusicProject.Setting(null, null, MusicProject.Setting(null, "clip-main", project));
        Assert.Empty(without.Music);
        Assert.Null(ClipRenderInput.Resolve(without, null, data, FixtureLoader.SharedRoot)?.Music);
    }

    [Fact]
    public void RemovingAClipDropsItsTrackAndKeepsTheFullVideoTrack()
    {
        var project = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        Assert.Equal(["music-main", "music-full"], project.Music.Select(entry => entry.Id));
        Assert.Equal(["music-full"], MusicProject.Pruned(project.Music, []).Select(entry => entry.Id));
        var legacy = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/interview-take.voxclip"));
        Assert.Equal(1, legacy.SchemaVersion);
        Assert.False(JsonNode.Parse(ProjectSerialization.Serialize(legacy))!.AsObject().ContainsKey("music"));
        var track = project.Music[1] with { Asset = project.Music[1].Asset with { File = legacy.Id + "/music-generated-1.mp3" } };
        var promoted = MusicProject.Setting(track, null, legacy);
        Assert.Equal(4, promoted.SchemaVersion);
        Assert.Equal(track, Assert.Single(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(promoted)).Music));
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Serialize(legacy with { Music = [track] }));
    }
}
