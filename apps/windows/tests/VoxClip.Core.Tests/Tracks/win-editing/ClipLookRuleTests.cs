using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>Replays shared/fixtures/looks/look-cases.json (looks spec §8.3 and §9.6), as the Swift ClipLookRuleTests do.</summary>
public sealed class ClipLookRuleTests
{
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/looks/look-cases.json"))!.AsObject();

    private static ProjectClipControls Controls(JsonNode node) =>
        JsonSerializer.Deserialize(node.ToJsonString(), ProjectJsonContext.Default.ProjectClipControls)!;

    [Fact]
    public void AClipsColorStateMatchesItsLookAppliedOrEdited()
    {
        var looks = ClipLookLibraryTests.Library();
        var corpus = Cases();
        Assert.Equal("voxclip-look-cases/1", corpus["format"]!.GetValue<string>());
        var cases = corpus["match"]!.AsArray();
        Assert.Equal(18, cases.Count);
        foreach (var item in cases)
        {
            var id = item!["id"]!.GetValue<string>();
            var controls = Controls(item["controls"]!);
            var match = looks.Match(controls);
            Assert.True(match?.Look.Id == item["look"]?.GetValue<string>(), id);
            Assert.True((match is null ? null : match.Edited ? "edited" : "applied") == item["state"]?.GetValue<string>(), id);
            Assert.True(looks.Name(controls) == item["name"]!.GetValue<string>(), id);
        }
    }

    [Fact]
    public void SettingALookWritesItsExpandedValuesAsOneChange()
    {
        var looks = ClipLookLibraryTests.Library();
        var baseline = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-project.voxclip")) with { ClipControls = [] };
        var cases = Cases()["setLookPreset"]!.AsArray();
        Assert.Equal(14, cases.Count);
        foreach (var item in cases)
        {
            var id = item!["id"]!.GetValue<string>();
            var project = item["before"] is { } before ? ClipControlsProject.Setting(Controls(before), baseline) : baseline;
            ClipColorFix? fix = item["fix"] is { } given
                ? new(given["exposure"]!.GetValue<int>(), given["temperature"]!.GetValue<int>(), given["tint"]!.GetValue<int>()) : null;
            Project Run() => ClipControlsProject.SettingLookPreset(item["look"]!.GetValue<string>(), item["amount"]!.GetValue<int>(), fix,
                "clip-main", project, looks);
            if (item["refused"]?.GetValue<bool>() == true)
            {
                Assert.Throws<VoxClipException>(Run);
                continue;
            }
            var result = Run();
            var expected = item["after"] is { } after ? Controls(after) : null;
            Assert.True(expected == result.ClipControls.FirstOrDefault(entry => entry.ClipId == "clip-main"), id);
            Assert.True(item["schemaVersion"]!.GetValue<int>() == result.SchemaVersion, id + ": " + result.SchemaVersion);
            var saved = JsonNode.Parse(ProjectSerialization.Serialize(result))!["clipControls"]?[0];
            Assert.True(JsonNode.DeepEquals(item["after"], saved), id + ": " + saved?.ToJsonString());
        }
    }
}
