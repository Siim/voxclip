using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class RecordingClockFixtures
{
    private static (JsonNode Cases, Project Project) Load()
    {
        var cases = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/clock-cases.json"))!;
        Assert.Equal("voxclip-recording-clock/1", cases["schema"]!.GetValue<string>());
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/recordings/" + cases["project"]!.GetValue<string>()));
        return (cases, project);
    }

    [Fact]
    public void MalformedSpokenSourcesAreRefused()
    {
        var (cases, project) = Load();
        var document = JsonNode.Parse(ProjectSerialization.Serialize(project))!;
        var first = document["media"]!["spokenSources"]![0]!.AsObject();
        foreach (var row in cases["invalidSpokenSources"]!.AsArray())
        {
            document["media"]!["spokenSources"] = row!["overrides"] is JsonArray overrides ? new JsonArray(overrides.Select(patch =>
            {
                var source = first.DeepClone().AsObject();
                foreach (var (key, value) in patch!.AsObject()) source[key] = value?.DeepClone();
                return (JsonNode)source;
            }).ToArray()) : null;
            var failure = Record.Exception(() => ProjectSerialization.Deserialize(document.ToJsonString()));
            Assert.True(failure is VoxClipException { Code: VoxClipErrorCode.ProjectUnreadable }, row["name"]!.GetValue<string>());
        }
    }

    [Fact]
    public void TakeReasonUsesTheV7WireAndItsOwnLengthLimit()
    {
        var (_, original) = Load();
        var document = JsonNode.Parse(ProjectSerialization.Serialize(original))!;
        var part = document["edits"]!["clips"]![0]!["parts"]![0]!;
        var reason = string.Concat(Enumerable.Repeat("🟣", 160));
        part["takeReason"] = reason;
        var project = ProjectSerialization.Deserialize(document.ToJsonString());
        Assert.Equal(reason, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project)).Edits.Clips[0].PlayParts[0].TakeReason);
        part["takeReason"] = reason + "🟣";
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(document.ToJsonString()));
        var legacy = JsonNode.Parse(FixtureLoader.ReadText("fixtures/story-clips/story-project.voxclip"))!;
        legacy["schemaVersion"] = 6;
        legacy["edits"]!["clips"]![0]!["parts"]![0]!["takeReason"] = "A clearer opening";
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(legacy.ToJsonString()));
    }

    [Fact]
    public void ResolvesClockEdgesAndResamplesCompanionWords()
    {
        var (cases, project) = Load();
        var clock = ProjectClock.Build(project);
        Assert.Equal(cases["sampleRate"]!.GetValue<int>(), clock.SampleRate);
        Assert.Collection(clock.Regions, cases["regions"]!.AsArray().Select<JsonNode?, Action<ProjectClock.Region>>(row => region =>
        {
            Assert.Equal(row!["key"]!.GetValue<string>(), region.Key);
            Assert.Equal(row["label"]!.GetValue<string>(), region.Label);
            Assert.Equal(row["prefix"]!.GetValue<string>(), region.Prefix);
            Assert.Equal(row["offsetSamples"]!.GetValue<long>(), region.OffsetSamples);
            Assert.Equal(row["durationSamples"]!.GetValue<long>(), region.DurationSamples);
            Assert.Equal(row["gainDb"]!.GetValue<double>(), region.GainDb);
            Assert.Equal(row["colourIndex"]!.GetValue<int>(), region.ColourIndex);
            Assert.Null(clock.MapTime(region.Key, -1));
            Assert.Null(clock.MapTime(region.Key, region.DurationSamples));
        }).ToArray());
        Assert.Equal(cases["guardGaps"]!.AsArray().Select(row => (row![0]!.GetValue<long>(), row[1]!.GetValue<long>())), clock.GuardGaps);
        foreach (var row in cases["resolve"]!.AsArray())
        {
            var sample = row!["clockSample"]!.GetValue<long>();
            var resolved = clock.Resolve(sample);
            Assert.Equal(resolved, clock.SourceTime(sample));
            if (row["source"] is not { } source) { Assert.Null(resolved); continue; }
            var key = source["key"]!.GetValue<string>();
            var local = source["localSample"]!.GetValue<long>();
            Assert.Equal((key, local), resolved);
            Assert.Equal(sample, clock.MapTime(key, local));
            var rate = (double)clock.SampleRate;
            var localTime = clock.LocalTime(sample / rate)!.Value;
            Assert.Equal(sample / rate, clock.ClockTime(localTime.Key, localTime.LocalSeconds));
        }
        foreach (var row in cases["shiftedWords"]!.AsArray())
        {
            var word = Assert.Single(clock.Words, word => word.Id == row!["id"]!.GetValue<string>());
            Assert.Equal("r2.", clock.RegionOf(word.Id)?.Prefix);
            double?[] times = [word.Start, word.End, word.RawStart, word.RawEnd];
            var samples = times.Select(seconds => seconds is null ? (long?)null : (long)EditingMath.Round(seconds.Value * clock.SampleRate));
            Assert.Equal(row!["samples"]!.AsArray().Select(value => value?.GetValue<long>()), samples);
        }
        var primary = project.Transcript!.Words;
        Assert.Equal(primary, clock.Words.Take(primary.Count));
    }

    [Fact]
    public void SourceTimelineOffersWordAnchorsInCompanionParts()
    {
        var (cases, project) = Load();
        var clock = ProjectClock.Build(project);
        var plan = new EditPlan(clock.SampleRate, clock.TotalSamples, [], [], 0, []);
        var layout = TimelineItems.Layout(project, plan, "clip-main", TimelineAxis.Source);
        var expected = cases["shiftedWords"]![0]!["samples"]![0]!.GetValue<long>() / plan.SampleRate;
        Assert.Contains(layout.SnapTargets, target => target.Kind == TimelineSnapKind.Word && target.Time == expected);
    }

    [Fact]
    public void ResolvesEditsAndRefusesSelectionAcrossRecordings()
    {
        var (cases, project) = Load();
        var state = EditingEngine.FromProject(project)!;
        var expected = cases["edits"]!;
        Assert.True(state.CutWordIds.SetEquals(expected["cutWordIds"]!.AsArray().Select(word => word!.GetValue<string>())));
        Assert.True(state.CutPauseIds.SetEquals(expected["cutPauseIds"]!.AsArray().Select(word => word!.GetValue<string>())));
        Assert.Equal(expected["corrections"]!.AsObject().ToDictionary(pair => pair.Key, pair => pair.Value!.GetValue<string>()), state.Corrections);
        Assert.Equal(["pause-after-w1", "pause-after-r2.w1"], state.Pauses.Select(pause => pause.Id));
        var edited = EditingEngine.ApplyToProject(project, state);
        Assert.Same(project.Transcript, edited.Transcript);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(ProjectSerialization.Serialize(project))!["edits"],
            JsonNode.Parse(ProjectSerialization.Serialize(edited))!["edits"]));
        var selection = cases["selection"]!;
        ClipPart part = new("crosses", selection["startWordId"]!.GetValue<string>(), selection["endWordId"]!.GetValue<string>());
        var refusal = Assert.IsType<RecordingEditResult.Refused>(RecordingEdits.Apply(new RecordingEdit.AddPart("clip-main", part), project));
        Assert.Equal(selection["refusal"]!.GetValue<string>(), refusal.Message);
        var removal = new RecordingEdit.RemoveSpokenSource(cases["removal"]!["removedKey"]!.GetValue<string>());
        Assert.Equal("Two recordings uses 1 part from 0010. Remove that part first.",
            Assert.IsType<RecordingEditResult.Refused>(RecordingEdits.Apply(removal, project)).Message);
    }

    [Fact]
    public void RemovingRecordingDoesNotCompactOrReusePrefix()
    {
        var (cases, original) = Load();
        var row = cases["removal"]!;
        var transcript = Assert.Single(original.Media.SpokenSources!).Transcript;
        var clip = original.Edits.Clips[0] with { EndWordId = "w2", Parts = [
            new ClipPart("first", "w1", "w1", TakeReason: "A clearer opening"), new ClipPart("second", "w2", "w2")] };
        var project = original with { Edits = original.Edits with { Clips = [clip], Corrections = new Dictionary<string, string>(), CutWordIds = [], CutPauseIds = [] } };
        var removedKey = row["removedKey"]!.GetValue<string>();
        var nextKey = row["nextKey"]!.GetValue<string>();
        var removed = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.RemoveSpokenSource(removedKey), project));
        Assert.Equal("Remove recording", removed.UndoName);
        Assert.Equal(project.Media.AdditionalSources, removed.Project.Media.AdditionalSources);
        var restored = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(removed.Project));
        Assert.Equal(6, restored.SchemaVersion);
        Assert.Null(restored.Media.SpokenSources);
        Assert.Equal(clip.PlayParts.Select(part => part.Id), restored.Edits.Clips[0].PlayParts.Select(part => part.Id));
        Assert.Null(restored.Edits.Clips[0].PlayParts[0].TakeReason);
        var next = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.AddSpokenSource(nextKey, transcript), restored));
        Assert.Equal("Add recording", next.UndoName);
        Assert.Equal(row["survivingPrefix"]!.GetValue<string>(), Assert.Single(next.Project.Media.SpokenSources!).WordIdPrefix);
        Assert.Null(ProjectClock.Build(next.Project).RegionOf("r2.w1"));
        var readded = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.AddSpokenSource(removedKey, transcript), next.Project)).Project;
        var region = readded.Media.SpokenSources![^1];
        Assert.Equal(row["readdedPrefix"]!.GetValue<string>(), region.WordIdPrefix);
        Assert.Equal(row["afterBothOffset"]!.GetValue<int>(), region.OffsetSeconds);
        var withoutFirst = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.RemoveSpokenSource(nextKey), readded)).Project;
        Assert.Equal(region, Assert.Single(withoutFirst.Media.SpokenSources!));
    }

    [Fact]
    public void SingleRegionPreservesEveryRootTranscriptValue()
    {
        var (_, original) = Load();
        var random = new Random(3101);
        var template = original.Transcript!.Words[0];
        for (var run = 0; run < 64; run++)
        {
            var words = Enumerable.Range(0, run).Select(index =>
            {
                var start = index + 0.2 * random.NextDouble();
                return template with { Id = $"local.{index}", Start = start, End = start + 0.3 + random.NextDouble() * 0.2,
                    RawStart = Math.Max(0, start - 0.001), RawEnd = start + 0.5 };
            }).ToArray();
            var root = original.Transcript with { Words = words, DurationSeconds = run + random.NextDouble() };
            var project = original with { SchemaVersion = 6, Transcript = root, Media = original.Media with { SpokenSources = null } };
            var clock = ProjectClock.Build(project);
            Assert.Same(root, clock.Transcript);
            Assert.Single(clock.Regions);
        }
    }

    [Fact]
    public void ReordersAndTrimsPartsWithoutMovingSourceEdits()
    {
        var (_, project) = Load();
        var clip = Assert.Single(project.Edits.Clips);
        var part = clip.PlayParts[0];
        var reordered = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.MovePart(clip.Id, part.Id, clip.PlayParts[1].Id), project));
        Assert.Equal("Move part", reordered.UndoName);
        Assert.Equal(clip.PlayParts.Reverse(), reordered.Project.Edits.Clips[0].PlayParts);
        var trimmed = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.TrimPart(clip.Id, part.Id, "r2.w1", "r2.w1"), reordered.Project));
        Assert.Equal("Trim part", trimmed.UndoName);
        Assert.Equal(part.Reframe, trimmed.Project.Edits.Clips[0].PlayParts[1].Reframe);
        var removed = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.RemovePart(clip.Id, part.Id), trimmed.Project));
        Assert.Equal("Remove part", removed.UndoName);
        Assert.Equal("w1", Assert.Single(removed.Project.Edits.Clips[0].PlayParts).StartWordId);
        Assert.Equal(project.Edits.CutWordIds, removed.Project.Edits.CutWordIds);
        Assert.Equal(project.Edits.Corrections, removed.Project.Edits.Corrections);
        var added = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.AddPart(clip.Id, part, clip.Id), removed.Project));
        Assert.Equal("Add part", added.UndoName);
        Assert.Equal(part, added.Project.Edits.Clips[0].PlayParts[1]);
    }
}
