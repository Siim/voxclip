using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class RecordingPlanFixtures
{
    [Fact]
    public void AStoredPrimaryVoicePatchKeepsItsOutputBeforeTheRecordingSeam()
    {
        var original = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var primary = VoiceLabOutputPlanner.Build(original, VoiceLabOutputScope.Full);
        var companion = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/recordings/two-recordings.voxclip"));
        var project = original with
        {
            SchemaVersion = 7,
            Media = original.Media with
            {
                AdditionalSources = companion.Media.AdditionalSources,
                SpokenSources = [companion.Media.SpokenSources![0] with { OffsetSeconds = (int)Math.Ceiling(original.Media.Source.DurationSeconds) + 1 }],
            },
        };
        var plan = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full);
        Assert.True(primary.RequiresSyntheticRendering);
        Assert.Equal(primary.Pieces, plan.Pieces.Take(primary.Pieces.Count));
        Assert.Equal(primary.Captions, plan.Captions.Take(primary.Captions.Count));
        var timeline = new TimelinePieces(new RenderTimeline.VoiceLab(plan));
        Assert.Equal(new[] { primary.Pieces.Count }, Enumerable.Range(0, timeline.Pieces.Count).Where(timeline.IsRecordingSeam));
        var next = plan.Captions[primary.Captions.Count];
        Assert.Equal("r2.w1", next.Id);
        Assert.True(next.StartsPart);
    }

    [Fact]
    public void OneRecordingKeepsLegacyPlansOnRandomProjects()
    {
        var original = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/story-clips/story-project.voxclip"));
        var random = new Random(0xC31);
        for (var seed = 0; seed < 64; seed++)
        {
            var time = random.Next(200) / 1000.0;
            var words = original.Transcript!.Words.Select(word =>
            {
                var start = time;
                time += random.Next(1, 701) / 1000.0;
                var end = time;
                time += random.Next(1500) / 1000.0;
                return word with { Start = start, End = end };
            }).ToArray();
            var duration = time + 0.3;
            var rate = seed % 2 == 0 ? 48000 : 44100;
            var early = new ClipRange("early", words[random.Next(2)].Id, words[random.Next(1, 3)].Id, null,
                ClipOrigin.Manual, null, null, true, random.Next(600) / 1000.0);
            var late = early with { Id = "late", StartWordId = words[random.Next(4, 6)].Id, EndWordId = words[random.Next(6, 9)].Id, LeadInSeconds = null };
            var story = early with { Id = "story", EndWordId = late.EndWordId, Kind = StoryClipKind.Story,
                LeadInSeconds = random.Next(600) / 1000.0, Parts = seed % 2 == 0 ? [late.PlayParts[0], early.PlayParts[0]] : [early.PlayParts[0], late.PlayParts[0]] };
            var threshold = random.Next(350, 1050) / 1000.0;
            var pauses = EditingAlgorithms.DetectPauses(words, threshold);
            var project = original with
            {
                Transcript = original.Transcript with { Words = words, DurationSeconds = duration },
                Media = original.Media with { Source = original.Media.Source with { DurationSeconds = duration, Audio = new(rate, 1) } },
                Edits = new(threshold, random.Next(300) / 1000.0, words.Where(_ => random.Next(4) == 0).Select(word => word.Id).ToArray(),
                    pauses.Where(_ => random.Next(2) == 0).Select(pause => pause.Id).ToArray(), new Dictionary<string, string> { [words[1].Id] = "corrected words" },
                    [early, story], null),
            };
            var clock = EditingEngine.FromProject(project)!;
            EditPlan LegacySingle(ClipRange? clip) => EditingEngine.BuildEditPlan(
                EditingEngine.BuildSegments(clock with { Clips = clip is null ? [] : [clip], ActiveClipId = clip?.Id }, duration),
                duration, rate, clock.PauseKeepSeconds);
            foreach (var clip in new ClipRange?[] { null, early, story })
            {
                var state = clock with { ActiveClipId = clip?.Id };
                EditPlan expected;
                if (clip?.Parts is { } parts)
                {
                    var plans = parts.Select((part, index) => LegacySingle(early with { Id = part.Id, StartWordId = part.StartWordId,
                        EndWordId = part.EndWordId, LeadInSeconds = index == 0 ? clip.LeadInSeconds : null })).Where(plan => plan.Kept.Count > 0).ToArray();
                    long output = 0, cursor = 0;
                    var seams = new List<long>();
                    foreach (var plan in plans)
                    {
                        if (output > 0) seams.Add(output);
                        output += plan.OutputSamples;
                    }
                    var kept = plans.SelectMany(plan => plan.Kept).ToArray();
                    var cuts = new List<MediaInterval>();
                    var total = (long)Math.Round(duration * rate);
                    foreach (var span in kept.OrderBy(span => span.StartSample))
                    {
                        if (cursor < span.StartSample) cuts.Add(new(cursor, span.StartSample));
                        cursor = span.EndSample;
                    }
                    if (cursor < total) cuts.Add(new(cursor, total));
                    expected = new EditPlan(rate, total, cuts, kept, output, []) { PartSeams = seams };
                }
                else expected = LegacySingle(clip);
                var actual = EditingEngine.BuildPlan(state, duration, rate);
                Assert.Equal(expected.SampleRate, actual.SampleRate);
                Assert.Equal(expected.TotalSamples, actual.TotalSamples);
                Assert.Equal(expected.OutputSamples, actual.OutputSamples);
                Assert.Equal(expected.Kept, actual.Kept);
                Assert.Equal(expected.Cuts, actual.Cuts);
                Assert.Equal(expected.Joins, actual.Joins);
                Assert.Equal(expected.PartSeams, actual.PartSeams);
                var voice = VoiceLabOutputPlanner.Build(project, new VoiceLabOutputScope(clip?.Id));
                Assert.Equal(expected.SampleRate, voice.SampleRate);
                Assert.Equal(expected.TotalSamples, voice.TotalSourceSamples);
                Assert.Equal(expected.OutputSamples, voice.OutputSamples);
                Assert.Equal(expected.PartSeams, voice.PartSeams);
                Assert.Equal(EditingEngine.CaptionWords(state, expected), voice.Captions);
                Assert.Empty(voice.VideoCuts);
                long offset = 0;
                var pieces = expected.Kept.Select(span => new VoiceLabOutputPiece(VoiceLabOutputPieceKind.Source, span.StartSample, span.EndSample,
                    offset, offset += span.EndSample - span.StartSample, null, null, null)).ToArray();
                Assert.Equal(pieces, voice.Pieces);
            }
        }
    }

    [Fact]
    public void PlansKeepOnlyRecordingSamplesInPlaybackOrder()
    {
        var fixture = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/plan-cases.json"))!;
        Assert.Equal("voxclip-recording-plans/1", fixture["schema"]!.GetValue<string>());
        var rate = fixture["sampleRate"]!.GetValue<double>();
        Assert.NotEmpty(fixture["cases"]!.AsArray());
        foreach (var entry in fixture["cases"]!.AsArray())
        {
            var row = entry!;
            var document = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/" + row["project"]!.GetValue<string>()))!;
            var edits = row["edits"]!.DeepClone();
            var clip = row["clip"];
            edits["clips"] = clip is null ? new JsonArray() : new JsonArray(clip.DeepClone());
            edits["activeClipId"] = clip?["id"]?.DeepClone();
            document["edits"] = edits;
            var project = ProjectSerialization.Deserialize(document.ToJsonString());
            var state = EditingEngine.FromProject(project)!;
            var plan = EditingEngine.BuildPlan(state, project.Media.Source.DurationSeconds, rate);
            IEnumerable<MediaInterval> Intervals(string key) => row[key]!.AsArray().Select(pair => new MediaInterval(Number(pair!, 0), Number(pair!, 1)));
            IEnumerable<long> Samples(string key) => row[key]!.AsArray().Select(sample => sample!.GetValue<long>());
            Assert.Equal(row["totalSamples"]!.GetValue<long>(), plan.TotalSamples);
            Assert.Equal(row["outputSamples"]!.GetValue<long>(), plan.OutputSamples);
            Assert.Equal(Intervals("kept"), plan.Kept);
            Assert.Equal(Intervals("cuts"), plan.Cuts);
            Assert.Equal(Samples("partSeams"), plan.PartSeams);
            Assert.Equal(row["pauseIds"]!.AsArray().Select(value => value!.GetValue<string>()), state.Pauses.Select(pause => pause.Id));
            var fades = row["fades"]!.AsArray();
            var joins = new List<Join>();
            for (var index = 0; index < fades.Count; index++)
            {
                var fade = fades[index]!;
                var fadeIn = Number(fade, 1);
                if (index > 0 || fadeIn > 0) joins.Add(new(Number(fade, 0), index > 0 ? Number(fades[index - 1]!, 2) : 0, fadeIn));
            }
            if (fades.Count > 0 && Number(fades[^1]!, 2) is > 0 and var lastFade) joins.Add(new(plan.OutputSamples, lastFade, 0));
            Assert.Equal(joins, plan.Joins);
            var encoded = JsonSerializer.Serialize(plan, ProjectJsonContext.Default.EditPlan);
            var decoded = JsonSerializer.Deserialize(encoded, ProjectJsonContext.Default.EditPlan)!;
            Assert.Equal(joins, decoded.Joins);
            var voice = VoiceLabOutputPlanner.Build(project, new VoiceLabOutputScope(state.ActiveClipId));
            Assert.Equal(plan.TotalSamples, voice.TotalSourceSamples);
            Assert.Equal(plan.OutputSamples, voice.OutputSamples);
            Assert.Equal(plan.PartSeams, voice.PartSeams);
            Assert.Equal(Intervals("kept"), voice.Pieces.Select(piece => new MediaInterval(piece.SourceStartSample, piece.SourceEndSample)));
            Assert.Equal(plan.Kept, RenderCallerInputs.PlacementPlan(project, state.ActiveClipId).Kept);
            foreach (var timeline in new RenderTimeline[] { new RenderTimeline.Legacy(plan), new RenderTimeline.VoiceLab(voice) })
            {
                var pieces = new TimelinePieces(timeline);
                Assert.Equal(Samples("recordingSeams"), Enumerable.Range(0, pieces.Pieces.Count).Where(pieces.IsRecordingSeam)
                    .Select(index => (long)Math.Round(pieces.Pieces[index].Edited.Start * rate)));
            }
            foreach (var captions in new[] { EditingEngine.CaptionWords(state, plan), voice.Captions })
            {
                Assert.Equal(row["captions"]!.AsArray().Count, captions.Count);
                foreach (var (word, expected) in captions.Zip(row["captions"]!.AsArray()))
                {
                    Assert.Equal(expected![0]!.GetValue<string>(), word.Id);
                    Assert.Equal(expected[1]!.GetValue<string>(), word.Text);
                    Assert.Equal(Number(expected, 2), (long)Math.Round(word.Start * rate));
                    Assert.Equal(Number(expected, 3), (long)Math.Round(word.End * rate));
                    Assert.Equal(expected[4]!.GetValue<bool>(), word.StartsPart == true);
                }
            }
            var clock = ProjectClock.Build(project);
            foreach (var (span, expected) in plan.Kept.Zip(row["sources"]!.AsArray()))
            {
                var resolved = clock.Resolve(span.StartSample)!.Value;
                Assert.Equal(expected![0]!.GetValue<string>(), resolved.Key);
                Assert.Equal(Number(expected, 1), resolved.LocalSample);
                Assert.Equal(Number(expected, 2), resolved.LocalSample + span.EndSample - span.StartSample);
                var middle = (span.StartSample + (span.EndSample - span.StartSample) / 2) / rate;
                Assert.Equal(middle, plan.SourceTime(plan.MapTime(middle)));
                Assert.Equal(middle, voice.SourceTime(voice.MapTime(middle)));
            }
        }
    }

    private static long Number(JsonNode array, int index) => array[index]!.GetValue<long>();
}
