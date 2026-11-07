using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Replays shared/fixtures/voice-lab/whole-clip-revoice-wire-cases.json (ADR-R46), as the Swift WholeClipRevoiceWireReplayTests
/// do: a project holding <c>voiceLab.wholeClipRevoices</c> opens, validates, renders its disclosure and saves byte for byte; every
/// broken record is refused. Mac <c>WholeClipPriceAndRecordTests</c>' record cases.</summary>
public sealed class WholeClipRevoiceWireTests
{
    private const string ProjectPath = "fixtures/voice-lab/whole-clip-revoice-project.voxclip";
    private static JsonObject Fixture() => JsonNode.Parse(FixtureLoader.ReadText(ProjectPath))!.AsObject();
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/whole-clip-revoice-wire-cases.json"))!.AsObject();

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
    public void FormatIsItsOwnFile()
    {
        var cases = Cases();
        Assert.Equal("voxclip-whole-clip-revoice-wire/1", cases["format"]!.GetValue<string>());
        Assert.Equal(["format", "project", "clipId", "valid", "invalid"], cases.Select(pair => pair.Key));
    }

    [Fact]
    public void MacProjectsWithAWholeClipRevoiceOpenRenderTheirDisclosureAndSaveByteForByte()
    {
        var cases = Cases();
        var clipId = cases["clipId"]!.GetValue<string>();
        var valid = cases["valid"]!.AsArray();
        Assert.Equal(14, valid.Count);
        foreach (var item in valid)
        {
            var id = item!["id"]!.GetValue<string>();
            var input = Applied(item);
            var project = ProjectSerialization.Deserialize(input.ToJsonString());
            var encoded = ProjectSerialization.Serialize(project);
            Assert.Equal(encoded, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(encoded)));
            var saved = JsonNode.Parse(encoded)!.AsObject()["voiceLab"]!.AsObject();
            var records = input["voiceLab"]!["wholeClipRevoices"];
            if (records is null) Assert.False(saved.ContainsKey("wholeClipRevoices"), id);
            else
            {
                Assert.True(JsonNode.DeepEquals(records, saved["wholeClipRevoices"]), id + ": " + saved["wholeClipRevoices"]?.ToJsonString());
                foreach (var record in saved["wholeClipRevoices"]!.AsArray())
                    Assert.Equal(["id", "clipId", "segmentIds", "script", "consentRecordId", "videoRetime", "lipsyncModel", "usd", "match", "createdAt"],
                        record!.AsObject().Select(pair => pair.Key));
            }
            Assert.True(item["revoiced"]!.GetValue<bool>() == WholeClipRevoice.IsRevoiced(clipId, project), id);
            Assert.False(WholeClipRevoice.IsRevoiced("clip-other", project), id);
            var disclosure = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight).Disclosure;
            Assert.True(disclosure.Required, id);
            Assert.Equal(item["kinds"]!.AsArray().Select(kind => kind!.GetValue<string>()), disclosure.Kinds);
            Assert.Equal(item["postText"]!.GetValue<string>(), disclosure.PostText);
            Assert.Equal(item["chip"]!.GetValue<string>(), WholeClipRevoice.ChipText(disclosure.Kinds));
        }
    }

    [Fact]
    public void InvalidCorpusIsRejected()
    {
        var invalid = Cases()["invalid"]!.AsArray();
        Assert.Equal(43, invalid.Count);
        foreach (var item in invalid)
        {
            var exception = Record.Exception(() => ProjectSerialization.Deserialize(Applied(item!).ToJsonString()));
            Assert.True(exception is not null, item!["id"]!.GetValue<string>());
            if (item["tooNew"]?.GetValue<bool>() == true)
                Assert.Equal(VoxClipErrorCode.ProjectTooNew, Assert.IsType<VoxClipException>(exception).Code);
        }
    }

    private static WholeClipRevoiceRecord Revoice(params string[] segments) => new("wholeclip-1", "clip-main",
        segments.Length == 0 ? ["vl-passage", "vl-thanks"] : segments, "Thanks for watching.", "consent-1", 0.987,
        WholeClipLipsync.Lipsync2.RawValue(), 1.58, new(0.81, 0.54, null), DateTimeOffset.FromUnixTimeSeconds(1_793_000_000));

    private static Project Base() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/lipsync-render-v3.voxclip"));
    private static Project With(params WholeClipRevoiceRecord[] records) => Base() with { VoiceLab = Base().VoiceLab with { WholeClipRevoices = records } };

    [Fact]
    public void ARecordSavesAndReopensAndNoneLeavesTheKeyOut()
    {
        var project = With(Revoice());
        VoiceLabProject.Validate(project);
        var saved = ProjectSerialization.Serialize(project);
        var reopened = ProjectSerialization.Deserialize(saved);
        Assert.Equal(Revoice(), Assert.Single(reopened.VoiceLab.WholeClipRevoices!));
        Assert.Equal(saved, ProjectSerialization.Serialize(reopened));
        Assert.True(WholeClipRevoice.IsRevoiced("clip-main", reopened));
        Assert.False(WholeClipRevoice.IsRevoiced("clip-main", Base()));
        Assert.Equal("wholeclip-1", WholeClipRevoice.RecordHolding("vl-thanks", reopened)?.Id);
        Assert.Null(WholeClipRevoice.RecordHolding("vl-thanks", Base()));
        Assert.DoesNotContain("wholeClipRevoices", ProjectSerialization.Serialize(Base()), StringComparison.Ordinal);
    }

    [Fact]
    public void ARecordThatBreaksItsRulesIsRefusedBeforeItIsSaved()
    {
        bool Refused(Func<WholeClipRevoiceRecord, Project> change)
        {
            var project = change(Revoice());
            return Record.Exception(() => VoiceLabProject.Validate(project)) is not null &&
                Record.Exception(() => ProjectSerialization.Serialize(project)) is not null;
        }
        Assert.True(Refused(record => With(record with { SegmentIds = ["missing"] })));
        Assert.True(Refused(record => With(record with { SegmentIds = [] })));
        Assert.True(Refused(record => With(record with { SegmentIds = ["vl-passage", "vl-passage"] })));
        Assert.True(Refused(record => With(record with { ClipId = "no-clip" })));
        Assert.True(Refused(record => With(record with { LipsyncModel = "fal-ai/latentsync" })));
        Assert.True(Refused(record => With(record with { VideoRetime = 1.09 })));
        Assert.True(Refused(record => With(record with { VideoRetime = double.NaN })));
        Assert.True(Refused(record => With(record with { Usd = -1 })));
        Assert.True(Refused(record => With(record with { Match = new(1.5, null, null) })));
        Assert.True(Refused(record => With(record with { Script = new string('a', 20_001) })));
        Assert.True(Refused(_ => With()));
        Assert.True(Refused(record => With(record, record with { Id = "wholeclip-2", SegmentIds = ["vl-thanks"] })));
        Assert.True(Refused(record => With(record) with { SchemaVersion = 2 }));
        var recorded = With(Revoice("vl-thanks"));
        Assert.True(Refused(_ => recorded with { VoiceLab = recorded.VoiceLab with {
            Segments = recorded.VoiceLab.Segments.Select(segment => segment.Id == "vl-thanks" ? segment with { Kind = VoiceLabSegmentKind.VoiceChanger } : segment).ToArray() } }));
        Assert.False(Refused(record => With(record)));
    }

    [Fact]
    public void TheChipSaysWhatTheExportHolds()
    {
        Assert.Equal("Voice and lip movement generated with AI", WholeClipRevoice.ChipText(["lipsync", "revoice", "tts"]));
        Assert.Equal("Lip movement generated with AI", WholeClipRevoice.ChipText(["lipsync", "tts"]));
        Assert.Equal("AI MODIFIED", WholeClipRevoice.ChipText(["tts"]));
        Assert.Equal("revoice", WholeClipRevoice.DisclosureKind);
    }
}
