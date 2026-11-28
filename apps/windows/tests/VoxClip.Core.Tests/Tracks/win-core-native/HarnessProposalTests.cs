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
    public void ConfirmedLocalAndCloudTranscriptsStaySeparate()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/recordings/two-recordings.voxclip"));
        var key = project.Media.Source.ContentKey;
        var cloud = project.Transcript!;
        var local = cloud with { Engine = cloud.Engine with { Id = TranscriptEngine.Whispercpp } };
        var cache = Directory.CreateTempSubdirectory("voxclip-recording-cache-");
        try
        {
            RecordingTranscriptCache.Write(key, cache.FullName, cloud);
            Assert.Equal(TranscriptEngine.Elevenlabs, RecordingTranscriptCache.Read(key, cache.FullName)?.Engine.Id);
            Assert.Null(HarnessRecording.CachedTranscript(key, cache.FullName));
            var directory = Path.Combine(cache.FullName, key, "transcripts");
            var legacy = Path.Combine(directory, "confirmed-win-v1.json");
            var legacyBytes = JsonSerializer.Serialize(cloud);
            File.WriteAllText(legacy, legacyBytes);
            File.Delete(Path.Combine(directory, "confirmed-cloud-v1.json"));
            Assert.Equal(TranscriptEngine.Elevenlabs, RecordingTranscriptCache.Read(key, cache.FullName)?.Engine.Id);
            HarnessRecording.CacheTranscript(key, cache.FullName, local);
            RecordingTranscriptCache.Write(key, cache.FullName, cloud);
            Assert.Equal(TranscriptEngine.Whispercpp, HarnessRecording.CachedTranscript(key, cache.FullName)?.Engine.Id);
            Assert.Equal(TranscriptEngine.Whispercpp, RecordingTranscriptCache.Read(key, cache.FullName)?.Engine.Id);
            Assert.Equal(legacyBytes, File.ReadAllText(legacy));
            File.WriteAllText(Path.Combine(directory, "confirmed-local-v1.json"), "{}");
            Assert.Null(HarnessRecording.CachedTranscript(key, cache.FullName));
            Assert.Equal(TranscriptEngine.Elevenlabs, RecordingTranscriptCache.Read(key, cache.FullName)?.Engine.Id);
        }
        finally { cache.Delete(recursive: true); }
    }

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
        var proposal = new HarnessProposal(timeline.PinRecordingTranscript(transcript), original);
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
        Assert.Equal("The recording transcript changed. Ask for a new timeline proposal.", Assert.Throws<HarnessException>(() =>
            proposal.Review(original, FixtureLoader.SharedRoot, recordingTranscript: transcript with { Language = "et" })).Message);

        IEnumerable<string?> Values(string field) => expected.GetProperty(field).EnumerateArray().Select(item => item.GetString());
    }

    /// <summary>Looks spec §8.5: a timeline's look is any look of shared/looks/clip-looks.json at its amount, checked against the file; one
    /// VoxClip doesn't have refuses the proposal with the reason. Twin of the Mac <c>aTimelinesLookIsALooksFileIDAtItsAmount</c>.</summary>
    [Fact]
    public void ATimelinesLookIsALooksFileIdAtItsAmount()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip"));
        HarnessProposal Proposal(string look)
        {
            using var wire = JsonDocument.Parse("{\"clipId\":\"clip-2f1c\",\"reason\":\"Warmer.\",\"look\":" + look + "}");
            return new HarnessProposal(HarnessTimeline.Read(wire.RootElement), project);
        }
        var kept = Proposal("""{"id":"warmPrint","amount":70,"reason":"A memory"}""").Review(project, FixtureLoader.SharedRoot).Project;
        var controls = Assert.IsType<ProjectClipControls>(ClipControlsProject.Controls("clip-2f1c", kept));
        Assert.Equal(("warmPrint", 70), (controls.ColorGrade?.Preset, controls.ColorGrade?.Amount ?? 0));
        Assert.Equal("warmPrint", ClipLookLibrary.Load(FixtureLoader.SharedRoot).Match(controls)?.Look.Id);
        var classic = Proposal("""{"id":"warm"}""").Review(project, FixtureLoader.SharedRoot).Project;
        Assert.Equal(ClipLook.Warm, ClipControlsProject.Controls("clip-2f1c", classic)?.Look);
        Assert.Null(ClipControlsProject.Controls("clip-2f1c", classic)?.ColorGrade);
        Assert.Equal("Choose one of VoxClip's looks.",
            Assert.IsAssignableFrom<HarnessException>(Record.Exception(() => Proposal("""{"id":"neonDream"}""").Review(project, FixtureLoader.SharedRoot))).Message);
        foreach (var bad in new[] { """{"id":"warm print"}""", """{"id":"warm","amount":120}""", """{"id":"warm","fix":true}""" })
            Assert.IsAssignableFrom<HarnessException>(Record.Exception(() => Proposal(bad)));
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
