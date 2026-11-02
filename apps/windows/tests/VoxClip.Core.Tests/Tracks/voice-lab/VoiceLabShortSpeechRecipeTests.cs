using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabShortSpeechRecipeTests
{
    static JsonElement Document()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/short-speech-recipe-cases.json");
        var root = document.RootElement;
        Assert.Equal("voxclip-voice-lab-short-speech-recipe-cases/1", root.GetProperty("schema").GetString());
        Assert.Equal(["baseProject", "caseCount", "cases", "schema"], root.EnumerateObject().Select(property => property.Name).Order().ToArray());
        Assert.Equal(root.GetProperty("caseCount").GetInt32(), root.GetProperty("cases").GetArrayLength());
        return root.Clone();
    }

    public static IEnumerable<object[]> Cases() => Document().GetProperty("cases").EnumerateArray()
        .SelectMany(item => new[] { 3, 4 }.Select(version => new object[] { item.GetProperty("name").GetString()!, version }));

    static JsonObject ProjectJson(JsonElement item, int version)
    {
        var project = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/" + Document().GetProperty("baseProject").GetString()))!.AsObject();
        project["schemaVersion"] = version;
        var segment = project["voiceLab"]!["segments"]![0]!;
        var qa = segment["candidates"]![0]!["recipe"]!["qa"]!.AsObject();
        foreach (var property in item.GetProperty("qa").EnumerateObject())
            qa[property.Name] = JsonNode.Parse(property.Value.GetRawText());
        segment["qa"]!["speakerScore"] = qa["speakerScore"]?.DeepClone();
        return project;
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void SharedRecipesReadRoundTripAndPrepare(string name, int version)
    {
        var item = Document().GetProperty("cases").EnumerateArray().Single(item => item.GetProperty("name").GetString() == name);
        var json = ProjectJson(item, version).ToJsonString();
        if (item.GetProperty("error").GetString() is { } error)
        {
            if (error == "ProjectUnreadable")
                Assert.Equal(VoxClipErrorCode.ProjectUnreadable, Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(json)).Code);
            else
                Assert.Equal(Enum.Parse<VoiceLabProjectErrorCode>(error), Assert.Throws<VoiceLabProjectException>(() => ProjectSerialization.Deserialize(json)).Code);
            return;
        }

        var project = ProjectSerialization.Deserialize(json);
        VoiceLabProject.Validate(project);
        var serialized = ProjectSerialization.Serialize(project);
        var roundTrip = ProjectSerialization.Deserialize(serialized);
        Assert.Equal(serialized, ProjectSerialization.Serialize(roundTrip));
        var prepared = VoiceLabRenderContract.Prepare(roundTrip, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        prepared.Verify(roundTrip, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        var recipe = Assert.Single(prepared.SelectedSegmentRecipes).Recipe;
        Assert.Equal(7000, prepared.OutputPlan.OutputSamples);
        Assert.True(prepared.Disclosure.Required);
        Assert.Equal(.7, prepared.Disclosure.OutputAiSeconds, 6);
        var savedQa = JsonNode.Parse(serialized)!["voiceLab"]!["segments"]![0]!["candidates"]![0]!["recipe"]!["qa"]!.AsObject();
        if (item.GetProperty("qa").TryGetProperty("shortSpeech", out var evidence))
        {
            Assert.True(JsonNode.DeepEquals(JsonNode.Parse(evidence.GetRawText()), savedQa["shortSpeech"]));
            if (evidence.GetProperty("mode").GetString() == "unmeasured")
            {
                Assert.Null(recipe.Qa.SpeakerScore);
                Assert.False(recipe.Qa.SpeakerPassed);
            }
        }
        else Assert.False(savedQa.ContainsKey("shortSpeech"));
    }

    static Project AcceptedUnmeasured()
    {
        var item = Document().GetProperty("cases").EnumerateArray().Single(item => item.GetProperty("name").GetString() == "unmeasured-recorded-statement");
        return ProjectSerialization.Deserialize(ProjectJson(item, 4).ToJsonString());
    }

    [Theory]
    [InlineData("mismatched-record")]
    [InlineData("stock-voice")]
    [InlineData("unknown-mode")]
    [InlineData("unknown-consent-method")]
    [InlineData("negative-frames")]
    [InlineData("empty-record")]
    [InlineData("zero-takes")]
    [InlineData("pooled-short")]
    [InlineData("pooled-single-take")]
    [InlineData("unmeasured-long")]
    public void RejectedRecipesStillEnforceEvidenceShape(string defect)
    {
        var project = AcceptedUnmeasured();
        var segment = project.VoiceLab.Segments[0];
        var candidate = segment.Candidates[1];
        var recipe = candidate.Recipe!;
        var evidence = new VoiceLabShortSpeechEvidence(VoiceLabShortSpeechMode.Unmeasured, "consent-fixture", VoiceLabConsentMethod.RecordedStatement, 16000, 1);
        evidence = defect switch
        {
            "mismatched-record" => evidence with { RecordId = "other-record" },
            "unknown-mode" => evidence with { Mode = (VoiceLabShortSpeechMode)99 },
            "unknown-consent-method" => evidence with { ConsentMethod = (VoiceLabConsentMethod)99 },
            "negative-frames" => evidence with { VoicedFrames = -1 },
            "empty-record" => evidence with { RecordId = "" },
            "zero-takes" => evidence with { TakeCount = 0 },
            "pooled-short" => evidence with { Mode = VoiceLabShortSpeechMode.Pooled, TakeCount = 2 },
            "pooled-single-take" => evidence with { Mode = VoiceLabShortSpeechMode.Pooled, VoicedFrames = 48000 },
            "unmeasured-long" => evidence with { VoicedFrames = 48000 },
            _ => evidence
        };
        recipe = recipe with { Qa = recipe.Qa with { ShortSpeech = evidence }, VoiceSource = defect == "stock-voice" ? VoiceLabVoiceSource.Stock : recipe.VoiceSource };
        var candidates = segment.Candidates.ToArray();
        candidates[1] = candidate with { Rejected = "qa-rejected", Recipe = recipe };
        project = project with { VoiceLab = project.VoiceLab with { Segments = [segment with { Candidates = candidates }] } };
        Assert.Equal(VoiceLabProjectErrorCode.InvalidSegment, Assert.Throws<VoiceLabProjectException>(() => VoiceLabProject.Validate(project)).Code);
    }

    [Theory]
    [InlineData("words", VoiceLabProjectErrorCode.QaRejected)]
    [InlineData("clipping", VoiceLabProjectErrorCode.QaRejected)]
    [InlineData("threshold-range", VoiceLabProjectErrorCode.QaRejected)]
    [InlineData("threshold-nan", VoiceLabProjectErrorCode.QaRejected)]
    [InlineData("empty-model", VoiceLabProjectErrorCode.QaRejected)]
    [InlineData("consent", VoiceLabProjectErrorCode.ConsentUnverified)]
    [InlineData("future-verification", VoiceLabProjectErrorCode.ConsentUnverified)]
    [InlineData("no-evidence-no-score", VoiceLabProjectErrorCode.QaRejected)]
    [InlineData("pooled-no-score", VoiceLabProjectErrorCode.QaRejected)]
    public void UnmeasuredDoesNotBypassOtherRenderGuards(string defect, VoiceLabProjectErrorCode expected)
    {
        var project = AcceptedUnmeasured();
        var segment = project.VoiceLab.Segments[0];
        var candidate = segment.Candidates[0];
        var recipe = candidate.Recipe!;
        var qa = recipe.Qa;
        qa = defect switch
        {
            "words" => qa with { TranscriptExact = false },
            "clipping" => qa with { PeakDbfs = 0 },
            "threshold-range" => qa with { SpeakerThreshold = 1.01 },
            "threshold-nan" => qa with { SpeakerThreshold = double.NaN },
            "empty-model" => qa with { SpeakerModel = "" },
            "no-evidence-no-score" => qa with { ShortSpeech = null },
            "pooled-no-score" => qa with { ShortSpeech = qa.ShortSpeech! with { Mode = VoiceLabShortSpeechMode.Pooled, VoicedFrames = 48000, TakeCount = 2 } },
            _ => qa
        };
        recipe = recipe with { Qa = qa };
        if (defect == "consent") recipe = recipe with { VoiceRefId = "missing-voice" };
        if (defect == "future-verification") recipe = recipe with { ConsentVerifiedAt = recipe.Provenance.CreatedAt.AddSeconds(1) };
        var candidates = segment.Candidates.ToArray();
        candidates[0] = candidate with { Recipe = recipe };
        project = project with { VoiceLab = project.VoiceLab with { Segments = [segment with { Candidates = candidates }] } };
        Assert.Equal(expected, Assert.Throws<VoiceLabProjectException>(() => VoiceLabProject.Validate(project)).Code);
    }
}
