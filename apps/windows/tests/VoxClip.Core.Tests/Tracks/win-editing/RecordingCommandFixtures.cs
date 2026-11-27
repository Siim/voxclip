using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class RecordingCommandFixtures
{
    [Fact]
    public void StartsFromTheWholeRecordingExceptRestarts()
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/command-cases.json"))!;
        var original = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/recordings/" + vectors["project"]!.GetValue<string>()));
        var started = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.StartFromRecording(original.Media.Source.ContentKey), original));
        var clip = Assert.Single(started.Project.Edits.Clips);
        Assert.Equal("Start from recording", started.UndoName);
        Assert.Equal(clip.Id, started.Project.Edits.ActiveClipId);
        Assert.Equal("I started Superscribe as a dictation tool.", clip.Title);
        Assert.Equal(new[] { "w1", "w18" }, clip.PlayParts.Select(part => part.StartWordId));
        Assert.Equal(new[] { "w13", "w27" }, clip.PlayParts.Select(part => part.EndWordId));
        Assert.Equal("w14", Assert.Single(started.Details!.LeftOut).StartWordId);
    }

    [Fact]
    public void ReplaysTheReferenceStoryAndRestoresTheOriginalParts()
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/command-cases.json"))!;
        var original = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/recordings/" + Text(vectors, "project")));
        var keyA = Text(vectors, "recordingA");
        var keyB = Text(vectors, "recordingB");
        var matches = TakeMatch.Build(ProjectClock.Build(original));
        var punchline = Assert.Single(matches.Solo, run => run.Key == keyA);
        var opening = matches.Beats[0];
        var started = Apply(new RecordingEdit.StartFromRecording(keyB), original, "Start from recording");
        var initial = Assert.Single(started.Project.Edits.Clips);
        AssertRanges(vectors["started"]!, initial);
        Assert.Null(RecordingEdits.Placement(initial.Id, punchline with { AfterBeatId = "absent" }, started.Project));

        var swapped = Apply(new RecordingEdit.UseLineVersion(initial.Id, opening.Id, keyA), started.Project, "Use version");
        AssertRanges(vectors["swapped"]!, Assert.Single(swapped.Project.Edits.Clips));
        var back = Apply(new RecordingEdit.UseLineVersion(initial.Id, opening.Id, keyB), swapped.Project, "Use version");
        Assert.Equal(initial.PlayParts.ToArray(), Assert.Single(back.Project.Edits.Clips).PlayParts.ToArray());
        var placement = RecordingEdits.Placement(initial.Id, punchline, swapped.Project);
        Assert.Equal(Text(vectors, "placement"), placement);
        var inserted = Apply(new RecordingEdit.InsertLine(initial.Id, keyA, punchline.StartWordId, punchline.EndWordId, placement), swapped.Project, "Add part");
        var final = vectors["final"]!;
        AssertRanges(final["ranges"]!, Assert.Single(inserted.Project.Edits.Clips));
        var clock = ProjectClock.Build(inserted.Project);
        var plan = EditingEngine.BuildPlan(EditingEngine.FromProject(inserted.Project)!, original.Media.Source.DurationSeconds, clock.SampleRate);
        Assert.Equal(final["kept"]!.AsArray().Select(pair => new MediaInterval(pair![0]!.GetValue<long>(), pair[1]!.GetValue<long>())), plan.Kept);
        Assert.Equal(final["outputSamples"]!.GetValue<long>(), plan.OutputSamples);
        Assert.Equal(final["partSeams"]!.AsArray().Select(value => value!.GetValue<long>()), plan.PartSeams);

        var leftOut = Assert.Single(started.Details!.LeftOut);
        Assert.Equal(new[] { leftOut.StartWordId, leftOut.EndWordId }, vectors["leftOut"]!.AsArray().Select(value => value!.GetValue<string>()));
        var restored = Apply(new RecordingEdit.InsertLine(initial.Id, keyB, leftOut.StartWordId, leftOut.EndWordId,
            initial.PlayParts[0].EndWordId), started.Project, "Add part");
        var single = Assert.Single(restored.Project.Edits.Clips);
        AssertRanges(vectors["putBack"]!, single);
        Assert.Equal(initial.PlayParts[0].Id, Assert.Single(single.PlayParts).Id);
        Assert.Equal(2, restored.Details!.Joins.Count);
    }

    private static string Text(JsonNode node, string field) => node[field]!.GetValue<string>();

    private static void AssertRanges(JsonNode expected, ClipRange clip) => Assert.Equal(
        expected.AsArray().Select(row => (row![0]!.GetValue<string>(), row[1]!.GetValue<string>())),
        clip.PlayParts.Select(part => (part.StartWordId, part.EndWordId)));

    private static RecordingEditResult.Applied Apply(RecordingEdit edit, Project project, string name)
    {
        var result = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(edit, project));
        Assert.Equal(name, result.UndoName);
        Assert.Equal(ProjectSerialization.Serialize(result.Project), ProjectSerialization.Serialize(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(result.Project))));
        return result;
    }
}
