using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Replays shared/fixtures/caption-translations/caption-translation-cases.json (ai.md §18.2), as the Swift
/// CaptionTranslationTests do: a Mac project with translated captions opens, validates and saves unchanged here; each spread case
/// gives the Mac's words, times and ids; translating and undoing match the Mac's edits; and Windows renders them.</summary>
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

    private static CaptionWord[] Words(JsonNode? value) => value!.AsArray()
        .Select(word => new CaptionWord(word!["id"]!.GetValue<string>(), word["text"]!.GetValue<string>(), word["start"]!.GetValue<double>(), word["end"]!.GetValue<double>()))
        .ToArray();

    [Fact]
    public void ATranslationsWordsSpreadOverTheShownWordsTheClipsOwnFirstAndBleepsStayMasked()
    {
        var spread = Cases()["spread"]!.AsArray();
        Assert.Equal(9, spread.Count);
        foreach (var item in spread)
        {
            var id = item!["id"]!.GetValue<string>();
            var document = Applied(new JsonObject { ["captionTranslations"] = item["translations"]!.DeepClone() });
            var project = ProjectSerialization.Deserialize(document.ToJsonString());
            var bleeped = item["bleeped"]!.AsArray().Select(word => word!.GetValue<string>()).ToArray();
            IReadOnlyList<ClipEffect> effects = bleeped.Length == 0 ? [] : [new ClipEffect("fx-bleep-1", null, "bleep", 0, 3) { WordIds = bleeped }];
            var shown = CaptionTranslations.Applying(Words(item["words"]), project, item["clipId"]?.GetValue<string>(), effects);
            Assert.True(Words(item["expected"]).SequenceEqual(shown), id + ": " + string.Join(" ", shown.Select(word => $"{word.Id}:{word.Text}@{word.Start}-{word.End}")));
            Assert.Equal(shown.Count, shown.Select(word => word.Id).Distinct(StringComparer.Ordinal).Count());
        }
    }

    [Fact]
    public void TranslatingStoresTheWordsCaptionsAndUndoingPutsBackTheBasesOwn()
    {
        var legacy = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/interview-take.voxclip"));
        Assert.True(legacy.SchemaVersion < 4);
        var first = CaptionTranslations.Translating(1, 3, null, "ES", "  hola mundo ", legacy);
        var words = first.Transcript!.Words;
        Assert.Equal(4, first.SchemaVersion);
        Assert.Equal([new CaptionTranslation("tr-1", null, words[1].Id, words[3].Id, "es", "hola mundo")], first.CaptionTranslations);
        var second = CaptionTranslations.Translating(3, 5, null, "de", "hallo", first);
        Assert.Equal(["tr-1"], second.CaptionTranslations.Select(entry => entry.Id));
        Assert.Equal("de", second.CaptionTranslations[0].Language);
        Assert.Equal(first.CaptionTranslations, CaptionTranslations.Untranslating(3, 5, null, first, second).CaptionTranslations);
        Assert.Empty(CaptionTranslations.Untranslating(1, 3, null, null, first).CaptionTranslations);
        Assert.Throws<VoxClipException>(() => CaptionTranslations.Translating(1, 3, null, "Spanish", "hola", legacy));
        // The shown words: masked, then translated, in a clip's own scope before the Full Take's.
        var effects = new[] { new ClipEffect("fx-bleep-1", null, "bleep", 0, 60) { WordIds = [words[2].Id] } };
        var captions = words.Take(5).Select(word => new CaptionWord(word.Id, word.Text, word.Start, word.End)).ToArray();
        var shown = CaptionTranslations.Shown(captions, first, null, effects);
        Assert.Equal([captions[0].Text, "hola", "×××××", captions[4].Text], shown.Select(word => word.Text));
        Assert.Equal(captions, CaptionTranslations.Shown(captions, legacy, null, []));
    }

    [Fact]
    public void WindowsRendersTranslatedCaptionsInsteadOfRefusing()
    {
        var project = ProjectSerialization.Deserialize(Applied(Cases()["wire"]!["valid"]![0]!).ToJsonString());
        Assert.NotEmpty(project.CaptionTranslations);
        VoiceLabRenderContract.RequireWindowsVisualSupport(project);
        VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
    }
}
