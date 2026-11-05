using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Replays the wire cases of shared/fixtures/caption-translations/caption-translation-cases.json (ai.md §18.2), as the
/// Swift CaptionTranslationTests do: a Mac project with translated captions opens, validates and saves unchanged here, and
/// Windows refuses to render or export it with a reason until a Windows package renders translations.</summary>
public sealed class CaptionTranslationVectorTests
{
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/caption-translations/caption-translation-cases.json"))!.AsObject();

    private static JsonObject Applied(JsonNode item)
    {
        var document = JsonNode.Parse(FixtureLoader.ReadText(Cases()["baseProject"]!.GetValue<string>()))!.AsObject();
        document["captionTranslations"] = item["captionTranslations"]!.DeepClone();
        if (item["version"] is { } version) document["schemaVersion"] = version.DeepClone();
        return document;
    }

    [Fact]
    public void TheFileHasItsOwnFormat()
    {
        var cases = Cases();
        Assert.Equal("voxclip-caption-translation-cases/1", cases["schema"]!.GetValue<string>());
        Assert.Equal(4, cases["wire"]!["valid"]!.AsArray().Count);
        Assert.Equal(14, cases["wire"]!["invalid"]!.AsArray().Count);
    }

    [Fact]
    public void MacProjectsWithTranslationsOpenValidateAndSaveUnchanged()
    {
        foreach (var item in Cases()["wire"]!["valid"]!.AsArray())
        {
            var id = item!["id"]!.GetValue<string>();
            var input = Applied(item);
            var project = ProjectSerialization.Deserialize(input.ToJsonString());
            var encoded = ProjectSerialization.Serialize(project);
            Assert.Equal(encoded, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(encoded)));
            var saved = JsonNode.Parse(encoded)!.AsObject();
            Assert.True(JsonNode.DeepEquals(input["captionTranslations"], saved["captionTranslations"]), id + ": " + saved["captionTranslations"]?.ToJsonString());
        }
    }

    [Fact]
    public void InvalidListsAreRefused()
    {
        foreach (var item in Cases()["wire"]!["invalid"]!.AsArray())
            Assert.True(Record.Exception(() => ProjectSerialization.Deserialize(Applied(item!).ToJsonString())) is not null, item!["id"]!.GetValue<string>());
    }

    [Fact]
    public void WindowsRefusesToRenderTranslatedCaptionsWithAReasonAndKeepsThem()
    {
        var project = ProjectSerialization.Deserialize(Applied(Cases()["wire"]!["valid"]![0]!).ToJsonString());
        var refusal = Assert.IsType<VoxClipException>(Record.Exception(() => VoiceLabRenderContract.RequireWindowsVisualSupport(project)));
        Assert.Equal(VoxClipErrorCode.ExportFailed, refusal.Code);
        Assert.Equal(CaptionTranslations.ExportUnsupportedMessage, refusal.Message);
        Assert.Throws<VoxClipException>(() => VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight));
        Assert.Single(project.CaptionTranslations);
        VoiceLabRenderContract.RequireWindowsVisualSupport(project with { CaptionTranslations = [] });
    }
}
