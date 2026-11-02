using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabAcceptAllTests
{
    internal static JsonNode Vectors() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/accept-all-cases.json"))!;
    internal static (Project Project, VoiceLabSegment[] Segments, VoiceLabAsset[] Assets, VoiceLabVoiceReference Voice) Input(JsonNode input) => (
        ProjectSerialization.Deserialize(input["project"]!.ToJsonString()),
        input["segments"]!.AsArray().Select(item => item.Deserialize(ProjectJsonContext.Default.VoiceLabSegment)!).ToArray(),
        input["assets"]!.AsArray().Select(item => item.Deserialize(ProjectJsonContext.Default.VoiceLabAsset)!).ToArray(),
        input["voice"].Deserialize(ProjectJsonContext.Default.VoiceLabVoiceReference)!);
    [Fact]
    public void All22CorrectedAcceptanceRowsAndReviewRowsReplayExactly()
    {
        var vectors = Vectors();
        Assert.Equal(1, vectors["version"]!.GetValue<int>()); Assert.Equal(22, vectors["cases"]!.AsArray().Count);
        Assert.Equal(new[] { "cases", "inputs", "version" }, vectors.AsObject().Select(item => item.Key).Order());
        foreach (var row in vectors["cases"]!.AsArray().Select(item => item!))
        {
            var input = Input(vectors["inputs"]![row["input"]!.GetValue<string>()]!);
            var before = ProjectSerialization.Serialize(input.Project);
            var scope = row["scope"]!.GetValue<string>();
            try
            {
                var result = new VoiceLabEditCommand.AcceptAll(input.Segments, input.Assets, input.Voice).ApplyingTo(input.Project,
                    scope == "full" ? VoiceLabOutputScope.Full : VoiceLabOutputScope.Clip(scope));
                Assert.True(row["expected"]!["error"] is null, row["case"]!.GetValue<string>());
                Assert.Equal(row["expected"]!["segmentIDs"]!.AsArray().Select(id => id!.GetValue<string>()), result.VoiceLab.Segments.Select(item => item.Id));
                Assert.Equal(input.Assets.Length, result.VoiceLab.Assets!.Count);
                var bytes = ProjectSerialization.Serialize(result);
                Assert.Equal(bytes, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(bytes)));
            }
            catch (VoiceLabProjectException error)
            {
                Assert.Equal(row["expected"]!["error"]?.GetValue<string>(), ErrorName(error));
            }
            Assert.Equal(before, ProjectSerialization.Serialize(input.Project));
        }
        var review = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/accept-all-review-cases.json"))!;
        Assert.Equal("voxclip.accept-all-review.v1", review["schema"]!.GetValue<string>()); Assert.Single(review["cases"]!.AsArray());
        foreach (var row in review["cases"]!.AsArray().Select(item => item!))
        {
            var input = Input(vectors["inputs"]![row["input"]!.GetValue<string>()]!);
            var segments = row["segments"]!.AsArray().Select(item => item.Deserialize(ProjectJsonContext.Default.VoiceLabSegment)!).ToArray();
            Assert.Equal(row["expected"]!["error"]!.GetValue<string>(), ErrorName(Assert.Throws<VoiceLabProjectException>(() =>
                new VoiceLabEditCommand.AcceptAll(segments, [], input.Voice).ApplyingTo(input.Project))));
            Assert.Equal(VoiceLabProjectErrorCode.InvalidSegment, Assert.Throws<VoiceLabProjectException>(() =>
                VoiceLabProject.AcceptAll(VoiceLabProject.AddVoiceReference(input.Project, input.Voice), [], [])).Code);
        }
    }
    internal static VoiceLabWindow Window(VoiceLabSegment segment)
    {
        var recipe = segment.Candidates[segment.SelectedCandidateIndex].Recipe!;
        return new(segment.Replace.FirstWordId, segment.Replace.LastWordId, [], [], segment.Replace.Start, segment.Replace.End,
            recipe.Video.SourceStartSample, recipe.Video.SourceEndSample,
            new(recipe.Seams.In.Kind, segment.Replace.Start, recipe.Video.SourceStartSample, recipe.Seams.In.FadeSamples),
            new(recipe.Seams.Out.Kind, segment.Replace.End, recipe.Video.SourceEndSample, recipe.Seams.Out.FadeSamples));
    }
    [Fact]
    public void PrePaymentProjectionUsesTheAcceptanceRulesWithoutInventingAssets()
    {
        var vectors = Vectors();
        foreach (var row in vectors["cases"]!.AsArray().Select(item => item!).Where(row => row["expected"]!["error"] is null && row["input"]!.GetValue<string>() != "group"))
        {
            var input = Input(vectors["inputs"]![row["input"]!.GetValue<string>()]!); var name = row["scope"]!.GetValue<string>();
            var scope = name == "full" ? VoiceLabOutputScope.Full : VoiceLabOutputScope.Clip(name);
            var accepted = new VoiceLabEditCommand.AcceptAll(input.Segments, input.Assets, input.Voice).ApplyingTo(input.Project, scope);
            foreach (var segment in input.Segments)
            {
                var without = accepted with { VoiceLab = accepted.VoiceLab with { Segments = accepted.VoiceLab.Segments.Where(item => item.Id != segment.Id).ToArray() } };
                VoiceLabRenderContract.ValidatePlacement(without, scope, Window(segment));
            }
        }
        foreach (var name in new[] { "outside-clip", "crosses-clip", "cut-invalidates-seam" })
        {
            var input = Input(vectors["inputs"]![name]!);
            Assert.Throws<VoiceLabProjectException>(() => VoiceLabRenderContract.ValidatePlacement(input.Project, VoiceLabOutputScope.Clip("clip-main"), Window(input.Segments[0])));
        }
    }
    private static string ErrorName(VoiceLabProjectException error) => char.ToLowerInvariant(error.Code.ToString()[0]) + error.Code.ToString()[1..];
    [Theory]
    [InlineData("Rewrite clip 2")]
    [InlineData("Rewrite 8 words")]
    [InlineData("Rewrite full take")]
    public void OneNamedUndoRestoresTheWholeSetAndRedoIsExact(string title)
    {
        var input = Input(Vectors()["inputs"]!["disjoint"]!);
        var history = new VoiceLabEditHistory(input.Project);
        var command = new VoiceLabEditCommand.AcceptAll(input.Segments, input.Assets, input.Voice);
        Assert.Equal("Accept Voice Lab takes", command.ActionName);
        Assert.Throws<VoiceLabProjectException>(() => history.Apply(command));
        var changed = history.Apply(input.Segments, input.Assets, input.Voice, VoiceLabOutputScope.Full, title, input.Project.ModifiedAt.AddSeconds(1));
        Assert.Single(changed.UndoStack); Assert.Equal(title, changed.UndoActionName);
        Assert.Equal(ProjectSerialization.Serialize(input.Project), ProjectSerialization.Serialize(changed.Undo().Present));
        Assert.Equal(ProjectSerialization.Serialize(changed.Present), ProjectSerialization.Serialize(changed.Undo().Redo().Present));
    }
}
