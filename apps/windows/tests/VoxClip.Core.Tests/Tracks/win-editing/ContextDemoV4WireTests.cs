using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class ContextDemoV4WireTests
{
    private static JsonObject Fixture() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/context-demo/v4-project.voxclip"))!.AsObject();
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/context-demo/wire-cases.json"))!.AsObject();

    private static string Apply(JsonNode item)
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
        return document.ToJsonString();
    }

    [Fact]
    public void SharedValidCorpusRoundTripsWithoutChangingVersion()
    {
        foreach (var item in Cases()["valid"]!.AsArray())
        {
            var project = ProjectSerialization.Deserialize(Apply(item!));
            Assert.Equal(4, project.SchemaVersion);
            var encoded = ProjectSerialization.Serialize(project);
            var saved = ProjectSerialization.Deserialize(encoded);
            Assert.Equal(encoded, ProjectSerialization.Serialize(saved));
            var raw = JsonNode.Parse(encoded)!.AsObject();
            if (project.ContextDemo is null) Assert.False(raw.ContainsKey("contextDemo"), item!["id"]!.GetValue<string>());
            if (project.MotionCues.Count == 0) Assert.False(raw.ContainsKey("motionCues"), item!["id"]!.GetValue<string>());
        }
    }

    [Fact]
    public void StrictSharedInvalidCorpusRejectsBeforeNormalization()
    {
        foreach (var item in Cases()["invalid"]!.AsArray())
        {
            var exception = Record.Exception(() => ProjectSerialization.Deserialize(Apply(item!)));
            Assert.True(exception is not null, item!["id"]!.GetValue<string>());
            if (item["tooNew"]?.GetValue<bool>() == true)
                Assert.Equal(VoxClipErrorCode.ProjectTooNew, Assert.IsType<VoxClipException>(exception).Code);
        }
    }

    [Fact]
    public void RealLegacyDocumentsPreserveVersionAndAbsentFieldShapes()
    {
        foreach (var item in Cases()["legacy"]!.AsArray())
        {
            var input = FixtureLoader.ReadText(item!["path"]!.GetValue<string>());
            var original = ProjectSerialization.Deserialize(input);
            var encoded = ProjectSerialization.Serialize(original);
            var saved = ProjectSerialization.Deserialize(encoded);
            var before = JsonNode.Parse(input)!.AsObject();
            var after = JsonNode.Parse(encoded)!.AsObject();
            Assert.Equal(item["version"]!.GetValue<int>(), saved.SchemaVersion);
            Assert.Null(saved.ContextDemo);
            Assert.Empty(saved.MotionCues);
            Assert.False(after.ContainsKey("contextDemo"));
            Assert.False(after.ContainsKey("motionCues"));
            Assert.Equal(before.Select(property => property.Key).Order(), after.Select(property => property.Key).Order());
            Assert.Equal(before["voiceLab"]!.AsObject().Select(property => property.Key).Order(),
                after["voiceLab"]!.AsObject().Select(property => property.Key).Order());
            Assert.Equal(original.Media, saved.Media);
            Assert.Equal(encoded, ProjectSerialization.Serialize(saved));
        }
    }

    [Fact]
    public void Version4KeepsFullV3VoiceSemanticsAndNeverDowngrades()
    {
        var original = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var upgraded = original with { SchemaVersion = 4 };
        var saved = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(upgraded));
        var before = JsonNode.Parse(ProjectSerialization.Serialize(original))!;
        var after = JsonNode.Parse(ProjectSerialization.Serialize(saved))!;
        Assert.True(JsonNode.DeepEquals(before["voiceLab"], after["voiceLab"]));
        Assert.Equal(4, VoiceLabProject.UpgradeToV3(saved).SchemaVersion);
        Assert.Equal(4, ContextDemoProject.UpgradeToV4(saved).SchemaVersion);
        var invalid = saved with { VoiceLab = saved.VoiceLab with { CleanAudio = null } };
        Assert.NotNull(Record.Exception(() => ProjectSerialization.Serialize(invalid)));
    }

    [Fact]
    public void OnlyFeatureMutationPromotesLegacyAndRemovingFeatureDoesNotDowngrade()
    {
        var original = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        var legacy = original with { SchemaVersion = 1, ContextDemo = null, MotionCues = [], VoiceLab = new([]) };
        Assert.Equal(1, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(legacy)).SchemaVersion);
        var changed = ContextDemoProject.SettingMotionCues(original.MotionCues, legacy);
        Assert.Equal(4, changed.SchemaVersion);
        Assert.NotNull(changed.VoiceLab.CleanAudio);
        Assert.Equal(1, legacy.SchemaVersion);
        Assert.Empty(legacy.MotionCues);
        Assert.Equal(original.MotionCues.Count, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(changed)).MotionCues.Count);
        var removed = ContextDemoProject.SettingMotionCues([], changed);
        Assert.Equal(4, removed.SchemaVersion);
        Assert.Empty(removed.MotionCues);
        Assert.NotNull(Record.Exception(() => ProjectSerialization.Serialize(changed with { SchemaVersion = 3 })));
        var badBinding = original with { Media = new(original.Media.Source with { ContentKey = new string('c', 64) }) };
        Assert.NotNull(Record.Exception(() => ProjectSerialization.Serialize(badBinding)));
    }

    [Fact]
    public void LegacyPaidSegmentsRequireReviewInsteadOfLosingTheirPolicy()
    {
        var legacy = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-project.voxclip"));
        var before = ProjectSerialization.Serialize(legacy);
        var current = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        var error = Assert.Throws<VoiceLabProjectException>(() => ContextDemoProject.SettingMotionCues(current.MotionCues, legacy));
        Assert.Equal(VoiceLabProjectErrorCode.LegacySegmentsNeedReview, error.Code);
        Assert.Equal(2, legacy.SchemaVersion);
        Assert.Equal(before, ProjectSerialization.Serialize(legacy));
    }

    [Fact]
    public void ExplicitSidecarCodecDoesNotAttachAnotherSource()
    {
        var original = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        var document = Assert.IsType<ContextDemoDocument>(original.ContextDemo);
        var encoded = ContextDemoCodec.Encode(document);
        Assert.Equal(encoded, ContextDemoCodec.Encode(ContextDemoCodec.Decode(encoded)));
        var legacy = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/interview-take.voxclip"));
        Assert.Null(legacy.ContextDemo);
        Assert.Equal(1, legacy.SchemaVersion);
    }
}
