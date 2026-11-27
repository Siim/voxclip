using System.Text.Json;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCoreNative;

public sealed class HarnessProposalTests
{
    [Fact]
    public void ALocalCompanionAndStoryMapToTheSharedOperations()
    {
        using var input = FixtureLoader.ReadJson("fixtures/recordings/harness-cases.json");
        var vector = input.RootElement;
        var expected = vector.GetProperty("expected");
        var original = ProjectSerialization.Deserialize(FixtureLoader.ReadText($"fixtures/recordings/{vector.GetProperty("project").GetString()}"));
        var transcript = Assert.Single(original.Media.SpokenSources!).Transcript;
        original = original with
        {
            Media = original.Media with { SpokenSources = null }, SchemaVersion = 6,
            Edits = original.Edits with { Clips = [], ActiveClipId = null }
        };
        var timeline = HarnessTimeline.Read(vector.GetProperty("timeline"));
        var cloud = new HarnessProposal(timeline, original);
        Assert.Equal(expected.GetProperty("cloudRefusal").GetString(), Assert.Throws<HarnessException>(() =>
            cloud.Review(original, FixtureLoader.SharedRoot, recordingTranscript: transcript)).Message);

        original = original with { Transcript = original.Transcript! with { Engine = original.Transcript.Engine with { Id = TranscriptEngine.Whispercpp } } };
        transcript = transcript with { Engine = transcript.Engine with { Id = TranscriptEngine.Whispercpp } };
        var proposal = new HarnessProposal(timeline, original);
        var result = proposal.Review(original, FixtureLoader.SharedRoot, recordingTranscript: transcript);
        var clip = Assert.Single(result.Project.Edits.Clips);
        Assert.Equal(Values("operationIds"), result.Operations.Select(operation => operation.Id));
        Assert.Equal(Values("partIds"), clip.PlayParts.Select(part => part.Id));
        Assert.Equal(Values("startWordIds"), clip.PlayParts.Select(part => part.StartWordId));
        Assert.Equal(Values("endWordIds"), clip.PlayParts.Select(part => part.EndWordId));
        Assert.Equal(transcript, Assert.Single(result.Project.Media.SpokenSources!).Transcript);
        Assert.Empty(result.Pending);
        Assert.Null(original.Media.SpokenSources);
        Assert.Empty(original.Edits.Clips);

        IEnumerable<string?> Values(string field) => expected.GetProperty(field).EnumerateArray().Select(item => item.GetString());
    }

    [Fact]
    public void AStoryKeepsPartsInPlayOrderWithoutRenderingARewrite()
    {
        using var input = FixtureLoader.ReadJson("fixtures/clips-mode/harness-proposal-cases.json");
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip"));
        var proposal = new HarnessProposal(HarnessTimeline.Read(input.RootElement.GetProperty("story")), project);

        var result = proposal.Review(project, FixtureLoader.SharedRoot);
        var candidate = result.Project;

        var story = Assert.Single(candidate.Edits.Clips, clip => clip.Title == "Result first");
        Assert.Equal(StoryClipKind.Story, story.Kind);
        Assert.Equal(new[] { project.Transcript!.Words[14].Id, project.Transcript.Words[9].Id },
            story.PlayParts.Select(part => part.StartWordId));
        Assert.Equal(project.VoiceLab.Segments.ToArray(), candidate.VoiceLab.Segments.ToArray());
        Assert.Empty(candidate.VoiceLab.Assets ?? []);
        Assert.IsType<ClipAutopilotAction.Rewrite>(Assert.Single(result.Pending).Action);
    }

    [Fact]
    public void HarnessAndAutopilotProduceTheSameOperations()
    {
        using var input = FixtureLoader.ReadJson("fixtures/clips-mode/harness-proposal-cases.json");
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip"));
        var staged = new HarnessProposal(HarnessTimeline.Read(input.RootElement.GetProperty("equivalentPlan")), project);
        var plan = new ClipAutopilotPlan
        {
            StartWord = 9, EndWord = 16, Title = "A faster edit", Hook = "Edit faster",
            Cuts = [new(11, 11, ClipAutopilotCutKind.Other, "Remove the aside.")],
            CaptionChoice = new("vox-bold", new("DM Sans", 700), ClipAutopilotCaptionCase.Upper, 4),
            ClipLookChoice = new(ClipLook.Warm, "Warm the footage."), SpeedChoice = new(1.1, "Keep the pacing brisk."),
            PostText = "A simpler way to make an edit.", Score = 90, Verdict = ClipAutopilotVerdict.Post,
        };
        var mapped = ClipAutopilotMapping.Operations(plan, "clip-2f1c", project, ClipAutopilotFonts.Load(FixtureLoader.SharedRoot));
        var proposed = staged.Review(project, FixtureLoader.SharedRoot).Operations;
        Assert.Equal(mapped.Select(Signature), proposed.Select(Signature));

        static string Signature(ClipAutopilotOperation operation) =>
            $"{operation.Id}:{operation.Decision}:{operation.Reason}:{JsonSerializer.Serialize(operation.Action, operation.Action.GetType())}";
    }

    [Theory]
    [InlineData("titleCard")]
    [InlineData("kineticCaption")]
    [InlineData("logoSting")]
    [InlineData("counter")]
    public void SharedMotionTemplatesMaterializeAsLocalClipEffects(string name)
    {
        using var fixtures = FixtureLoader.ReadJson("fixtures/clip-effects/motion-template-cases.json");
        var effect = fixtures.RootElement.EnumerateArray().Single(item => item.GetProperty("template").GetProperty("name").GetString() == name);
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip"));
        var timeline = JsonSerializer.SerializeToElement(new { clipId = "clip-2f1c", reason = "Make a showreel.", effects = new[] { effect } });
        var proposal = new HarnessProposal(HarnessTimeline.Read(timeline), project);

        var applied = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(proposal.Applying(project, FixtureLoader.SharedRoot)));

        var template = Assert.Single(applied.ClipEffects);
        Assert.Equal("clip-2f1c", template.GetProperty("clipId").GetString());
        Assert.True(JsonElement.DeepEquals(effect.GetProperty("template"), template.GetProperty("template")));
        Assert.Empty(applied.Music);
        Assert.Empty(project.ClipEffects);
    }

    [Fact]
    public async Task ProposedEditsMaterializeAsAValidProjectWithoutApplyingTheMusicBrief()
    {
        using var input = JsonDocument.Parse("""
            {
              "clipId": "clip-2f1c", "reason": "Open with the main point.", "title": "A faster edit", "captionStyle": "vox-bold",
              "cuts": [{"kind": "other", "startWord": 11, "endWord": 11, "reason": "Keep the point short."}],
              "effects": [
                {"kind": "motionTitle", "startWord": 9, "endWord": 9, "text": "A faster edit", "reason": "Name the topic."},
                {"kind": "punchIn", "startWord": 14, "endWord": 15, "scale": 1.1, "reason": "Emphasize the takeaway."}
              ],
              "generateMusic": "A quiet instrumental bed"
            }
            """);
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip"));
        var proposal = new HarnessProposal(HarnessTimeline.Read(input.RootElement), project);
        var candidate = proposal.Applying(project with { Edits = project.Edits with { ActiveClipId = "clip-9a0b" } }, FixtureLoader.SharedRoot);

        Assert.Equal("A faster edit", candidate.Edits.Clips[0].Title);
        Assert.Contains(project.Transcript!.Words[11].Id, candidate.Edits.CutWordIds);
        Assert.Equal("vox-bold", candidate.CaptionsFor("clip-2f1c").StyleId);
        Assert.Equal("title", Assert.Single(candidate.ClipEffects).GetProperty("kind").GetString());
        Assert.Equal("clip-2f1c", Assert.Single(candidate.MotionCues).ClipID);
        Assert.Equal(project.Music.ToArray(), candidate.Music.ToArray());
        Assert.Equal("clip-9a0b", candidate.Edits.ActiveClipId);

        var edited = project with { Edits = project.Edits with { CutWordIds = candidate.Edits.CutWordIds } };
        Assert.Throws<HarnessException>(() => proposal.Applying(edited, FixtureLoader.SharedRoot));

        var candidateFile = Path.Combine(Path.GetTempPath(), $"harness-candidate-{Guid.NewGuid():N}.voxclip");
        try
        {
            var ct = TestContext.Current.CancellationToken;
            await File.WriteAllTextAsync(candidateFile, ProjectSerialization.Serialize(candidate), ct);
            await SchemaPython.ValidateAsync([candidateFile], ct);
        }
        finally { File.Delete(candidateFile); }
    }
}
