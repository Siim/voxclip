using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Replays shared/fixtures/clip-style/caption-look-cases.json (design §6.6), as the Swift CaptionLookTests do: a Mac
/// project whose clips carry their own caption looks opens, validates and saves unchanged here, and each clip resolves to the
/// same captions.</summary>
public sealed class CaptionLookVectorTests
{
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-style/caption-look-cases.json"))!.AsObject();
    private static JsonObject Base() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-project.voxclip"))!.AsObject();

    private static JsonObject Style(JsonObject picks) => new()
    {
        ["preset"] = "auto", ["captions"] = "auto", ["music"] = "auto", ["maxLengthSec"] = 60,
        ["shapes"] = new JsonArray("16:9", "9:16"), ["rewording"] = "fix-only", ["captionPicks"] = picks,
    };

    [Fact]
    public void TheFileHasItsOwnSchema()
    {
        var cases = Cases();
        Assert.Equal("voxclip-caption-look-cases/1", cases["schema"]!.GetValue<string>());
        Assert.Equal(6, cases["wire"]!["valid"]!.AsArray().Count);
        Assert.Equal(7, cases["wire"]!["invalid"]!.AsArray().Count);
        Assert.Equal(6, cases["resolve"]!.AsArray().Count);
    }

    [Fact]
    public void MacPicksOpenValidateAndSaveUnchanged()
    {
        foreach (var item in Cases()["wire"]!["valid"]!.AsArray())
        {
            var id = item!["id"]!.GetValue<string>();
            var document = Base();
            document["clipStyle"] = Style(new JsonObject { ["clip-1"] = item["pick"]!.DeepClone() });
            var project = ProjectSerialization.Deserialize(document.ToJsonString());
            var encoded = ProjectSerialization.Serialize(project);
            Assert.Equal(encoded, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(encoded)));
            var saved = JsonNode.Parse(encoded)!["clipStyle"]!["captionPicks"]!["clip-1"];
            Assert.True(JsonNode.DeepEquals(item["pick"], saved), id + ": " + saved?.ToJsonString());
            Assert.True(project.ClipStyle!.SameAs(ProjectSerialization.Deserialize(encoded).ClipStyle), id);
        }
    }

    [Fact]
    public void InvalidPicksAreRefused()
    {
        foreach (var item in Cases()["wire"]!["invalid"]!.AsArray())
        {
            var document = Base();
            document["clipStyle"] = Style(new JsonObject { ["clip-1"] = item!["pick"]!.DeepClone() });
            Assert.True(Record.Exception(() => ProjectSerialization.Deserialize(document.ToJsonString())) is not null, item["id"]!.GetValue<string>());
        }
    }

    [Fact]
    public void EachClipResolvesToItsOwnLookOrTheProjectCaptions()
    {
        foreach (var item in Cases()["resolve"]!.AsArray())
        {
            var document = Base();
            document["captions"]!["styleId"] = item!["captions"]!["styleId"]!.DeepClone();
            document["captions"]!["overrides"] = item["captions"]!["overrides"]!.DeepClone();
            if (item["clipStyle"] is { } style) document["clipStyle"] = style.DeepClone();
            var project = ProjectSerialization.Deserialize(document.ToJsonString());
            foreach (var (clip, expected) in item["expected"]!.AsObject())
            {
                var captions = project.CaptionsFor(clip.Length == 0 ? null : clip);
                var label = item["id"]!.GetValue<string>() + " " + clip;
                Assert.True(expected!["styleId"]!.GetValue<string>() == captions.StyleId, label + ": " + captions.StyleId);
                Assert.True(JsonNode.DeepEquals(expected["overrides"], JsonNode.Parse(captions.Overrides.GetRawText())), label);
                Assert.Equal(project.Captions.Position, captions.Position);
            }
        }
    }

    [Fact]
    public void ClaudeNeverReplacesTheCreatorsPick()
    {
        var own = new ClipCaptionPick("glow", "") { By = "user" };
        var style = new ClipStyle("auto", "auto", "auto", 60, ["16:9"], "fix-only", new Dictionary<string, ClipCaptionPick> { ["mine"] = own });
        var recorded = style.Recording(new Dictionary<string, ClipCaptionPick> { ["mine"] = new("marker", "Later."), ["new"] = new("minimal", "New.") });
        Assert.Equal(own, recorded.CaptionPicks["mine"]);
        Assert.Equal("minimal", recorded.CaptionPicks["new"].StyleId);
        Assert.Equal("glow", style.FixingCaptions("marker").CaptionStyleFor("mine"));
    }
}
