using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabJoinAdvisoryRecipeTests
{
    static JsonElement Document()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/join-advisory-cases.json");
        var root = document.RootElement;
        Assert.Equal("voxclip-voice-lab-join-advisory-cases/1", root.GetProperty("schema").GetString());
        Assert.Equal(16, root.GetProperty("caseCount").GetInt32());
        Assert.Equal(16, root.GetProperty("cases").GetArrayLength());
        return root.Clone();
    }

    public static IEnumerable<object[]> Cases() => Document().GetProperty("cases").EnumerateArray()
        .SelectMany(item => new[] { 3, 4 }.Select(version => new object[] { item.GetProperty("name").GetString()!, version }));

    [Theory]
    [MemberData(nameof(Cases))]
    public void SharedRecipesReadRoundTripAndPrepare(string name, int version)
    {
        var document = Document();
        var item = document.GetProperty("cases").EnumerateArray().Single(item => item.GetProperty("name").GetString() == name);
        var projectJson = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/" + document.GetProperty("baseProject").GetString()))!.AsObject();
        projectJson["schemaVersion"] = version;
        var segment = projectJson["voiceLab"]!["segments"]![0]!;
        var qa = segment["candidates"]![0]!["recipe"]!["qa"]!.AsObject();
        foreach (var property in item.GetProperty("qa").EnumerateObject())
            qa[property.Name] = JsonNode.Parse(property.Value.GetRawText());
        var summary = segment["qa"]!.AsObject();
        foreach (var key in summary.Select(property => property.Key).ToArray()) summary[key] = qa[key]?.DeepClone();
        var json = projectJson.ToJsonString();
        if (!item.GetProperty("valid").GetBoolean())
        {
            Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(json));
            return;
        }
        var project = ProjectSerialization.Deserialize(json);
        var encoded = ProjectSerialization.Serialize(project);
        var roundTrip = ProjectSerialization.Deserialize(encoded);
        Assert.Equal(encoded, ProjectSerialization.Serialize(roundTrip));
        var prepared = VoiceLabRenderContract.Prepare(roundTrip, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        prepared.Verify(roundTrip, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        var saved = JsonNode.Parse(encoded)!["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"]!["qa"]!;
        if (item.GetProperty("qa").TryGetProperty("joinAdvisory", out var advisory))
        {
            var expected = JsonNode.Parse(advisory.GetRawText())!;
            Assert.True(UtcTimestamp.TryParse(advisory.GetProperty("acceptedAt").GetString(), out var acceptedAt));
            Assert.Equal(acceptedAt, Assert.Single(prepared.SelectedSegmentRecipes).Recipe.Qa.JoinAdvisory!.AcceptedAt);
            Assert.True(JsonNode.DeepEquals(expected["seams"], saved["joinAdvisory"]!["seams"]));
            Assert.Equal(2, saved["joinAdvisory"]!.AsObject().Count);
        }
        else
            Assert.Null(saved["joinAdvisory"]);
    }
}
