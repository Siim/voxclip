using System.Text.Json.Nodes;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
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
        var (vectors, original) = Load();
        var keyA = Text(vectors, "recordingA");
        var keyB = Text(vectors, "recordingB");
        var matches = TakeMatch.Build(ProjectClock.Build(original));
        var punchline = Assert.Single(matches.Solo, run => run.Key == keyA);
        var opening = matches.Beats[0];
        var started = Apply(new RecordingEdit.StartFromRecording(keyB), original, "Start from recording");
        var initial = Assert.Single(started.Project.Edits.Clips);
        AssertRanges(vectors["started"]!, initial);
        var partial = started.Project with { Edits = started.Project.Edits with
            { Clips = [initial with { Parts = null, Kind = null, EndWordId = initial.PlayParts[0].EndWordId }] } };
        Assert.Null(RecordingEdits.Placement(initial.Id, punchline, partial));

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
        Assert.Equal(final["recordingSeams"]!.AsArray().Select(value => value!.GetValue<long>()), plan.RecordingSeams);
        var expectedSources = final["parts"]!.AsArray().SelectMany(part => part!["kept"]!.AsArray()
            .Select(pair => (Text(part, "sourceKey"), pair![0]!.GetValue<long>(), pair[1]!.GetValue<long>())));
        Assert.Equal(expectedSources, plan.Kept.Select(span =>
        {
            var (key, local) = clock.Resolve(span.StartSample)!.Value;
            return (key, local, local + span.EndSample - span.StartSample);
        }));

        var leftOut = Assert.Single(started.Details!.LeftOut);
        Assert.Equal(new[] { leftOut.StartWordId, leftOut.EndWordId }, vectors["leftOut"]!.AsArray().Select(value => value!.GetValue<string>()));
        var restored = Apply(new RecordingEdit.InsertLine(initial.Id, keyB, leftOut.StartWordId, leftOut.EndWordId,
            initial.PlayParts[0].EndWordId), started.Project, "Add part");
        var single = Assert.Single(restored.Project.Edits.Clips);
        AssertRanges(vectors["putBack"]!, single);
        Assert.Equal(initial.PlayParts[0].Id, Assert.Single(single.PlayParts).Id);
        Assert.Equal(2, restored.Details!.Joins.Count);
    }

    [Fact]
    public void ReplacingAMiddleLineKeepsReframesAndThePartBeforeIt()
    {
        var (vectors, project) = Load();
        var joined = vectors["putBack"]![0]!;
        var punchline = vectors["final"]!["ranges"]![3]!;
        var reframe = new ReframeSettings(ReframeSettings.FaceMode, CenterX: 0.4, CenterY: 0.6);
        ClipPart[] parts = [new("main", joined[0]!.GetValue<string>(), joined[1]!.GetValue<string>(), reframe),
            new("existing", punchline[0]!.GetValue<string>(), punchline[1]!.GetValue<string>(), reframe)];
        const string id = "story";
        var clip = new ClipRange(id, parts[0].StartWordId, parts[1].EndWordId, null, ClipOrigin.Manual, null, null, true,
            Parts: parts, Kind: StoryClipKind.Story);
        project = project with { Edits = project.Edits with { Clips = [clip], ActiveClipId = id } };
        var solo = Assert.Single(TakeMatch.Build(ProjectClock.Build(project)).Solo, run => run.Key == Text(vectors, "recordingA"));
        var operation = new RecordingEdit.UseLineVersion(id, solo.AfterBeatId!, solo.Key);
        var result = Apply(operation, project, "Use version");
        var changed = Assert.Single(result.Project.Edits.Clips).PlayParts;
        Assert.Equal(4, changed.Count);
        Assert.Equal(vectors["middle"]!.AsArray().Select(row => (row![0]!.GetValue<string>(), row[1]!.GetValue<string>())),
            changed.Take(3).Select(part => (part.StartWordId, part.EndWordId)));
        Assert.All(changed, part => Assert.Equal(reframe, part.Reframe));
        Assert.Equal(parts[0].Id, changed[0].Id);
        Assert.Equal(parts[1], changed[^1]);
        Assert.Equal(parts[0].Id, result.Details!.SplitPartId);
        Assert.Equal(changed.Skip(1).Take(2).Select(part => part.Id), result.Details.MadePartIds);
        Assert.Equal(changed[1].EndWordId, RecordingEdits.Placement(id, solo, result.Project));
        Assert.Null(Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(operation, result.Project)).UndoStep);
    }

    [Fact]
    public void ConnectedItemsFollowTheirSourceWordsAcrossVersions()
    {
        var (vectors, original) = Load();
        var keyA = Text(vectors, "recordingA");
        var keyB = Text(vectors, "recordingB");
        var project = Apply(new RecordingEdit.StartFromRecording(keyB), original, "Start from recording").Project;
        var id = project.Edits.ActiveClipId!;
        var beat = TakeMatch.Build(ProjectClock.Build(project)).Beats[0];
        MotionKeyframe[] frames = [new(0, 1, 0.5, 0.5), new(1, 1, 0.5, 0.5)];
        project = project with { MotionCues = [new("replaced", id, 0.3, 0.5, frames), new("kept", id, 1.2, 1.4, frames)] };
        var swapped = Apply(new RecordingEdit.UseLineVersion(id, beat.Id, keyA), project, "Use version").Project;
        var restored = Apply(new RecordingEdit.UseLineVersion(id, beat.Id, keyB), swapped, "Use version").Project;
        IReadOnlyList<TimelineItem> Items(Project snapshot)
        {
            var plan = EditingEngine.BuildPlan(EditingEngine.FromProject(snapshot)!, snapshot.Media.Source.DurationSeconds, 48_000);
            return TimelineItems.Layout(snapshot, plan, id, TimelineAxis.Edited).Items;
        }
        var items = Items(swapped);
        Assert.True(Assert.Single(items, item => item.Id == new TimelineItemId(TimelineItemType.Motion, "replaced")).Hidden);
        var kept = Assert.Single(items, item => item.Id == new TimelineItemId(TimelineItemType.Motion, "kept"));
        Assert.False(kept.Hidden);
        Assert.Equal(swapped.Edits.Clips[0].PlayParts[1].Id, kept.PartId);
        Assert.Equal(Items(project).Select(ItemView), Items(restored).Select(ItemView));
        Assert.Equal(project.MotionCues.ToArray(), restored.MotionCues.ToArray());
        static string ItemView(TimelineItem item) => $"{item.Id}/{item.PartId}/{item.SourceAnchor}/{item.Hidden}";
    }

    [Fact]
    public void OnlyTheAlignedClauseComesInFromARunOnVersion()
    {
        var (vectors, project) = Load();
        var row = vectors["runOn"]!;
        var source = Assert.Single(project.Media.SpokenSources!);
        var words = source.Transcript.Words.ToList();
        var index = words.FindIndex(word => word.Id == Text(row, "afterWordId"));
        words[index] = words[index] with { Text = Text(row, "clauseBreak") };
        var tail = row["tail"]!.AsArray().Select(word => new TimedWord(word![0]!.GetValue<string>(), word[1]!.GetValue<string>(),
            WordKind.Word, word[2]!.GetValue<double>(), word[3]!.GetValue<double>(), null, null, null, null, words[index].Timing)).ToArray();
        words.InsertRange(index + 1, tail);
        project = project with { Media = project.Media with { SpokenSources = [source with { Transcript = source.Transcript with { Words = words } }] } };
        var keyA = Text(vectors, "recordingA");
        var keyB = Text(vectors, "recordingB");
        var beat = TakeMatch.Build(ProjectClock.Build(project)).Beats[0];
        Assert.Equal(source.WordIdPrefix + tail[^1].Id, Assert.Single(beat.Takes, take => take.Key == keyA).EndWordId);
        var started = Apply(new RecordingEdit.StartFromRecording(keyB), project, "Start from recording");
        var clip = Assert.Single(started.Project.Edits.Clips);
        var swapped = Apply(new RecordingEdit.UseLineVersion(clip.Id, beat.Id, keyA), started.Project, "Use version");
        AssertRanges(vectors["swapped"]!, Assert.Single(swapped.Project.Edits.Clips));
        var restored = Apply(new RecordingEdit.UseLineVersion(clip.Id, beat.Id, keyB), swapped.Project, "Use version");
        Assert.Equal(clip.PlayParts.ToArray(), Assert.Single(restored.Project.Edits.Clips).PlayParts.ToArray());
    }

    [Fact]
    public void AVersionRoundTripRestoresAnUnmatchedClauseAfterReopening()
    {
        var (vectors, project) = Load();
        var row = vectors["unmatchedRoundTrip"]!;
        TimedWord[] Words(string key) => row[key]!.AsArray().Select((word, index) => new TimedWord($"w{index + 1}",
            word!.GetValue<string>(), WordKind.Word, index / 5d, index / 5d + 0.1, null, null, null, null, TimingSource.Native)).ToArray();
        var source = Assert.Single(project.Media.SpokenSources!);
        var clip = new ClipRange("round-trip", "w1", "w7", null, ClipOrigin.Manual, null, null, true);
        project = project with
        {
            Transcript = project.Transcript! with { Words = Words("original") },
            Media = project.Media with { SpokenSources = [source with { Transcript = source.Transcript with { Words = Words("alternate") } }] },
            Edits = project.Edits with { Clips = [clip] },
        };
        var beat = TakeMatch.Build(ProjectClock.Build(project)).Beats[0];
        var swapped = Apply(new RecordingEdit.UseLineVersion(clip.Id, beat.Id, Text(vectors, "recordingA")), project, "Use version");
        AssertRanges(row["swapped"]!, Assert.Single(swapped.Project.Edits.Clips));
        var reopened = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(swapped.Project));
        var restored = Apply(new RecordingEdit.UseLineVersion(clip.Id, beat.Id, Text(vectors, "recordingB")), reopened, "Use version");
        AssertRanges(row["restored"]!, Assert.Single(restored.Project.Edits.Clips));
    }

    private static (JsonNode Vectors, Project Project) Load()
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/command-cases.json"))!;
        Assert.Equal("voxclip-recording-commands/1", Text(vectors, "schema"));
        return (vectors, ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/recordings/" + Text(vectors, "project"))));
    }

    private static string Text(JsonNode node, string field) => node[field]!.GetValue<string>();

    private static void AssertRanges(JsonNode expected, ClipRange clip) => Assert.Equal(
        expected.AsArray().Select(row => (row![0]!.GetValue<string>(), row[1]!.GetValue<string>())),
        clip.PlayParts.Select(part => (part.StartWordId, part.EndWordId)));

    private static RecordingEditResult.Applied Apply(RecordingEdit edit, Project project, string name)
    {
        var result = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(edit, project));
        Assert.Equal(name, result.UndoName);
        var step = Assert.IsType<RecordingEditStep>(result.UndoStep);
        Assert.Equal(name, step.Name);
        Assert.Equal(ProjectSerialization.Serialize(project), ProjectSerialization.Serialize(step.Before));
        var bytes = ProjectSerialization.Serialize(result.Project);
        Assert.Equal(bytes, ProjectSerialization.Serialize(step.After));
        Assert.Equal(bytes, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(bytes)));
        return result;
    }
}
