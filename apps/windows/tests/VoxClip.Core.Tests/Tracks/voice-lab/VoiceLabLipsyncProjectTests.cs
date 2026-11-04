using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>A Mac lip-synced Rewrite project (voice-lab.md §8.9) on Windows, replayed from the independent generator's
/// lipsync-project-cases.json and lipsync-render-v3.voxclip: one <c>cut_off</c> segment over the source video and one
/// <c>remap</c> segment over a cut. Windows opens, validates and saves it unchanged, and refuses to render only while a
/// selected candidate is lip-synced. The macOS Core replays the same files.</summary>
public sealed class VoiceLabLipsyncProjectTests
{
    static readonly Lazy<JsonNode> Cases = new(() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/lipsync-project-cases.json"))!);
    static string Source => FixtureLoader.ReadText("fixtures/voice-lab/" + Cases.Value["project"]!.GetValue<string>());
    static IEnumerable<JsonNode> Rows(string key) => Cases.Value[key]!.AsArray().Select(row => row!);
    static string Wire(VoiceLabProjectErrorCode code) => JsonNamingPolicy.CamelCase.ConvertName(code.ToString());

    [Fact]
    public void SharedCasesHaveTheirSchemaAndCount()
    {
        var root = Cases.Value.AsObject();
        Assert.Equal(new[] { "schema", "caseCount", "project", "segments", "renders", "invalid" }, root.Select(pair => pair.Key));
        Assert.Equal("voxclip-lipsync-project/1", root["schema"]!.GetValue<string>());
        Assert.Equal(12, root["caseCount"]!.GetValue<int>());
        Assert.Equal(12, Rows("segments").Count() + Rows("renders").Count() + Rows("invalid").Count());
    }

    [Fact]
    public void MacLipSyncedRecipesOpenValidateAndSaveUnchanged()
    {
        var project = ProjectSerialization.Deserialize(Source);
        VoiceLabProject.Validate(project);
        VoiceLabRenderValidation.Validate(project);
        foreach (var row in Rows("segments"))
        {
            var id = row["id"]!.GetValue<string>();
            var segment = project.VoiceLab.Segments.Single(item => item.Id == id);
            var video = segment.Candidates[row["candidate"]!.GetValue<int>()].Recipe!.Video;
            Assert.Equal(VoiceLabVideoMode.Lipsync, video.Mode);
            Assert.Equal(row["syncMode"]!.GetValue<string>(), video.SyncMode);
            Assert.Equal(row["assetId"]!.GetValue<string>(), video.AssetId);
            Assert.Equal(row["windowStartSample"]!.GetValue<long>(), video.WindowStartSample);
            Assert.Equal(row["windowEndSample"]!.GetValue<long>(), video.WindowEndSample);
            Assert.Equal(row["outputSamples"]!.GetValue<long>(), video.OutputSamples);
            // The video the lip sync was made over keeps its own fields, and is the segment's plain candidate.
            var lipsyncBase = VoiceLabLipsync.Base(video);
            Assert.Equal(row["baseMode"]!.GetValue<string>(), JsonNamingPolicy.CamelCase.ConvertName(lipsyncBase.Mode.ToString()));
            var plain = segment.Candidates[row["plainCandidate"]!.GetValue<int>()].Recipe!.Video;
            Assert.Equal(plain.Mode, lipsyncBase.Mode);
            Assert.Equal(plain with { Cuts = null }, lipsyncBase with { Cuts = null });
            Assert.Equal(plain.Cuts ?? [], lipsyncBase.Cuts ?? []);
        }
        // Saving keeps every field, the lip-sync, cut and crop fields included, and a second save writes the same bytes.
        var saved = ProjectSerialization.Serialize(project);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(Source), JsonNode.Parse(saved)), "a save changed the Mac project");
        Assert.Equal(saved, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(saved)));
    }

    [Fact]
    public void RenderingRefusesOnlyWhileASelectedCandidateIsLipSynced()
    {
        foreach (var row in Rows("renders"))
        {
            var id = row["id"]!.GetValue<string>();
            var project = ProjectSerialization.Deserialize(Source);
            foreach (var (segment, index) in row["selected"]!.AsObject())
                project = VoiceLabProject.SelectCandidate(project, segment, index!.GetValue<int>());
            var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
            var refusal = Record.Exception(() => VoiceLabRenderInput.Capture(project, prepared, "not-opened"));
            var expected = row["windows"]?.GetValue<string>();
            if (expected is null) Assert.True(refusal is null, $"{id}: {refusal}");
            else Assert.True(refusal is VoiceLabProjectException failure && Wire(failure.Code) == expected, $"{id}: {refusal}");
        }
    }

    [Fact]
    public void InvalidLipSyncedRecipesAreRefusedWithTheMacError()
    {
        foreach (var row in Rows("invalid"))
        {
            var id = row["id"]!.GetValue<string>();
            var document = JsonNode.Parse(Source)!;
            var segment = document["voiceLab"]!["segments"]!.AsArray().Single(item => item!["id"]!.GetValue<string>() == row["segment"]!.GetValue<string>())!;
            var video = segment["candidates"]![0]!["recipe"]!["video"]!.AsObject();
            foreach (var (key, value) in row["set"]!.AsObject()) video[key] = value?.DeepClone();
            var refusal = Record.Exception(() =>
            {
                var project = ProjectSerialization.Deserialize(document.ToJsonString());
                VoiceLabProject.Validate(project);
                VoiceLabRenderValidation.Validate(project);
            });
            Assert.True(refusal is VoiceLabProjectException failure && Wire(failure.Code) == row["error"]!.GetValue<string>(), $"{id}: {refusal}");
        }
    }
}
