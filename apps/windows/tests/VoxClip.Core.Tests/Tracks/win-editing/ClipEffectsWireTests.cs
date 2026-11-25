using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>Replays shared/fixtures/clip-effects/effects-wire-cases.json, as the Swift ClipEffectsWireTests do.</summary>
public sealed class ClipEffectsWireTests
{
    private static JsonObject Fixture() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-effects/effects-project.voxclip"))!.AsObject();
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-effects/effects-wire-cases.json"))!.AsObject();

    private static JsonObject Applied(JsonNode item)
    {
        var document = Fixture();
        foreach (var patch in item["patches"]!.AsArray())
        {
            var parts = patch!["path"]!.GetValue<string>().Split('/', StringSplitOptions.RemoveEmptyEntries);
            JsonNode target = document;
            foreach (var part in parts[..^1]) target = target is JsonArray array ? array[int.Parse(part)]! : target[part]!;
            if (target is JsonArray values)
            {
                if (patch["remove"]?.GetValue<bool>() == true) values.RemoveAt(int.Parse(parts[^1]));
                else values[int.Parse(parts[^1])] = patch["value"]?.DeepClone();
            }
            else if (patch["remove"]?.GetValue<bool>() == true) target.AsObject().Remove(parts[^1]);
            else target[parts[^1]] = patch["value"]?.DeepClone();
        }
        return document;
    }

    [Fact]
    public void FormatIsItsOwnFile() => Assert.Equal("voxclip-clip-effects-wire-cases/1", Cases()["format"]!.GetValue<string>());

    [Fact]
    public void CompanionRecordingsRoundTripAndBadPlacementsAreRejected()
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-effects/footage-project-cases.json"))!;
        var document = Fixture();
        var media = document["media"]!;
        media["source"]!["recordingHash"] = vectors["recordingHash"]!.DeepClone();
        media["additionalSources"] = new JsonArray(vectors["companion"]!.DeepClone());
        media["footage"] = vectors["valid"]!.DeepClone();
        var project = ProjectSerialization.Deserialize(document.ToJsonString());
        Assert.True(JsonNode.DeepEquals(media, JsonNode.Parse(ProjectSerialization.Serialize(project))!["media"]));
        foreach (var invalid in vectors["invalid"]!.AsArray())
        {
            var placements = media["footage"]!.AsArray();
            placements.Add(invalid!.DeepClone());
            Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(document.ToJsonString()));
            placements.RemoveAt(placements.Count - 1);
        }
        media["additionalSources"]!.AsArray().Add(vectors["companion"]!.DeepClone());
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(document.ToJsonString()));
        media["additionalSources"]!.AsArray().RemoveAt(1);
        var edited = media["footage"]!.AsArray();
        foreach (var placement in vectors["v6Valid"]!.AsArray()) edited.Add(placement!.DeepClone());
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(document.ToJsonString()));
        document["schemaVersion"] = 6;
        var editedProject = ProjectSerialization.Deserialize(document.ToJsonString());
        Assert.True(JsonNode.DeepEquals(media, JsonNode.Parse(ProjectSerialization.Serialize(editedProject))!["media"]));
        var firstEdit = project with { Media = project.Media with {
            Footage = project.Media.Footage!.Select(placement => placement with { FadeInSeconds = 0 }).ToArray()
        } };
        Assert.Equal(6, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(firstEdit)).SchemaVersion);
        foreach (var invalid in vectors["v6Invalid"]!.AsArray())
        {
            edited.Add(invalid!.DeepClone());
            Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(document.ToJsonString()));
            edited.RemoveAt(edited.Count - 1);
        }
    }

    [Fact]
    public void MacProjectsWithEffectsOpenValidateAndSaveUnchanged()
    {
        foreach (var item in Cases()["valid"]!.AsArray())
        {
            var id = item!["id"]!.GetValue<string>();
            var input = Applied(item);
            var project = ProjectSerialization.Deserialize(input.ToJsonString());
            Assert.Equal(input["schemaVersion"]!.GetValue<int>(), project.SchemaVersion);
            var encoded = ProjectSerialization.Serialize(project);
            Assert.Equal(encoded, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(encoded)));
            var saved = JsonNode.Parse(encoded)!.AsObject();
            if (input["clipEffects"] is null) Assert.False(saved.ContainsKey("clipEffects"), id);
            else Assert.True(JsonNode.DeepEquals(input["clipEffects"], saved["clipEffects"]), id);
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
    public void WindowsRendersEffectsInTheirScopeAndKeepsTheProject()
    {
        var project = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.Equal(15, project.ClipEffects.Count);
        var typed = project.ClipEffects.Select(ClipEffect.Parse).ToArray();
        Assert.Equal(project.ClipEffects.Select(effect => effect.GetProperty("id").GetString()), typed.Select(effect => effect.Id));
        // Censor kinds render everywhere; the others only in their own clip, or the full video for a null clip (ai.md §18.5).
        foreach (var clip in new string?[] { null }.Concat(project.Edits.Clips.Select(clip => clip.Id)))
        {
            var expected = typed.Where(effect => effect.IsCensor || effect.ClipId == clip).Select(effect => effect.Id);
            Assert.Equal(expected, ClipEffects.Rendered(project, clip).Select(effect => effect.Id));
        }
    }

    [Fact]
    public void RemovingAClipDropsItsEffectsAndKeepsFullVideoEffects()
    {
        var project = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        Assert.Equal(["fx-pixelate-1", "fx-mute-1"], ClipEffects.Pruned(project.ClipEffects, []).Select(effect => effect.GetProperty("id").GetString()));
        Assert.Equal(["fx-pixelate-1"], ClipEffects.Pruned(project.ClipEffects, [], ["w1"]).Select(effect => effect.GetProperty("id").GetString()));
        var legacy = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/interview-take.voxclip"));
        Assert.Equal(1, legacy.SchemaVersion);
        Assert.False(JsonNode.Parse(ProjectSerialization.Serialize(legacy))!.AsObject().ContainsKey("clipEffects"));
        var word = legacy.Transcript!.Words[0];
        using var bleep = JsonDocument.Parse(JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["id"] = "fx-bleep-1", ["clipId"] = null, ["kind"] = "bleep", ["start"] = word.Start, ["end"] = word.End, ["wordIds"] = new[] { word.Id }
        }));
        var promoted = ClipEffects.Adding([bleep.RootElement], legacy);
        Assert.Equal(4, promoted.SchemaVersion);
        Assert.Single(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(promoted)).ClipEffects);
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Serialize(legacy with { ClipEffects = [bleep.RootElement.Clone()] }));
    }
}
