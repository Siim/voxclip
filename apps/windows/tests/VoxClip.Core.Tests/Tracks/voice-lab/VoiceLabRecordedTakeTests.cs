using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Mac projects with the user's own microphone take (voice-lab.md §8.13, Mac <c>VoiceLabRecordedTake</c>) on
/// Windows, replayed from generate_render_recorded.py's recorded-take-cases.json and its three projects. A
/// <c>recorded</c> segment opens, validates, renders and saves unchanged; it is not AI speech, so only its lip sync is
/// disclosed; accepting it needs no voice reference; and its recipe keeps the recorded provenance, no consent, no speaker
/// score, no cost and recognized (never synthetic) words.</summary>
public sealed class VoiceLabRecordedTakeTests
{
    static readonly Lazy<JsonNode> Cases = new(() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/recorded-take-cases.json"))!);
    static IEnumerable<JsonNode> Rows(string key) => Cases.Value[key]!.AsArray().Select(row => row!);
    static JsonNode Row(string key, string id) => Rows(key).Single(row => row["id"]!.GetValue<string>() == id);
    static string Source(JsonNode row) => FixtureLoader.ReadText("fixtures/voice-lab/" + row["project"]!.GetValue<string>());
    static string Wire(VoiceLabProjectErrorCode code) => JsonNamingPolicy.CamelCase.ConvertName(code.ToString());
    public static TheoryData<string> Ids(string key) => new(Rows(key).Select(row => row["id"]!.GetValue<string>()));

    [Fact]
    public void SharedCasesHaveTheirSchemaAndCount()
    {
        var root = Cases.Value.AsObject();
        Assert.Equal(new[] { "schema", "caseCount", "renders", "acceptAll", "invalid" }, root.Select(pair => pair.Key));
        Assert.Equal("voxclip-voice-lab-recorded-take-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(17, root["caseCount"]!.GetValue<int>());
        Assert.Equal(17, Rows("renders").Count() + Rows("acceptAll").Count() + Rows("invalid").Count());
    }

    [Theory]
    [MemberData(nameof(Ids), "renders")]
    public void MacRecordedTakesOpenRenderAndSaveUnchanged(string id)
    {
        var row = Row("renders", id);
        var source = Source(row);
        var project = ProjectSerialization.Deserialize(source);
        VoiceLabProject.Validate(project);
        var saved = ProjectSerialization.Serialize(project);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(source), JsonNode.Parse(saved)), "a save changed the Mac project");
        Assert.Equal(saved, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(saved)));
        Assert.Contains(project.VoiceLab.Segments, segment => segment.Kind == VoiceLabSegmentKind.Recorded);

        var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        prepared.Verify(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        var expected = row["disclosure"]!;
        var disclosure = prepared.Disclosure;
        Assert.Equal(expected["required"]!.GetValue<bool>(), disclosure.Required);
        Assert.Equal(expected["kinds"]!.AsArray().Select(kind => kind!.GetValue<string>()), disclosure.Kinds);
        Assert.Equal(expected["aiSeconds"]!.GetValue<double>(), disclosure.OutputAiSeconds, 9);
        Assert.Equal(expected["persistent"]!.GetValue<bool>(), disclosure.Persistent);
        Assert.Equal(expected["labelIntervals"]!.AsArray().Select(pair => new VoiceLabLabelInterval(pair![0]!.GetValue<double>(), pair[1]!.GetValue<double>())),
            disclosure.Intervals);
        Assert.Equal(expected["text"]?.GetValue<string>(), disclosure.PostText);
        // Every selected take is rendered and listed, the recorded one included, under its own kind.
        var segments = row["aiSegments"]!.AsArray();
        Assert.Equal(segments.Select(item => item!["segmentId"]!.GetValue<string>()), prepared.SelectedSegmentRecipes.Select(item => item.SegmentId));
        Assert.Equal(segments.Select(item => item!["kind"]!.GetValue<string>()),
            prepared.SelectedSegmentRecipes.Select(item => VoiceLabRecordedTake.WireKind(project.VoiceLab.Segments.Single(s => s.Id == item.SegmentId).Kind)));
        // Captions come from the recognized words of a recorded take, as from a generated take's words.
        var captions = prepared.OutputPlan.Captions.Where(caption => caption.Id.Contains(":word:", StringComparison.Ordinal)).ToArray();
        var expectedCaptions = row["captions"]!.AsArray();
        Assert.Equal(expectedCaptions.Count, captions.Length);
        foreach (var (caption, item) in captions.Zip(expectedCaptions))
        {
            Assert.Equal(item!["id"]!.GetValue<string>(), caption.Id);
            Assert.Equal(item["text"]!.GetValue<string>(), caption.Text);
            Assert.Equal(item["start"]!.GetValue<double>(), caption.Start, 9);
            Assert.Equal(item["end"]!.GetValue<double>(), caption.End, 9);
        }
    }

    [Theory]
    [MemberData(nameof(Ids), "acceptAll")]
    public void AcceptingARecordedTakeNeedsNoVoiceReference(string id)
    {
        var row = Row("acceptAll", id);
        var source = Source(row);
        var target = ProjectSerialization.Deserialize(source);
        var segmentId = row["segment"]!.GetValue<string>();
        var segment = target.VoiceLab.Segments.Single(item => item.Id == segmentId);
        // The same take as a cloned one: generated (synthetic) words with the same own-voice recipe and no consent.
        if (row["kind"]!.GetValue<string>() == "tts")
        {
            static IReadOnlyList<VoiceLabWord> Synthetic(IReadOnlyList<VoiceLabWord> words) => words.Select(word => word with { Synthetic = true }).ToArray();
            segment = segment with { Kind = VoiceLabSegmentKind.Tts, Words = Synthetic(segment.Words!),
                Candidates = segment.Candidates.Select(candidate => candidate with { Recipe = candidate.Recipe! with { Words = Synthetic(candidate.Recipe.Words!) } }).ToArray() };
        }
        else Assert.Equal("recorded", row["kind"]!.GetValue<string>());
        var assetIds = segment.Candidates.Select(candidate => candidate.AssetId).ToHashSet(StringComparer.Ordinal);
        var assets = target.VoiceLab.Assets!.Where(asset => assetIds.Contains(asset.Id)).ToArray();
        var before = target with { VoiceLab = target.VoiceLab with { Segments = target.VoiceLab.Segments.Where(item => item.Id != segmentId).ToArray(),
            Assets = target.VoiceLab.Assets!.Where(asset => !assetIds.Contains(asset.Id)).ToArray() } };
        VoiceLabProject.Validate(before);
        Assert.Empty(before.VoiceLab.Voices!);
        var command = new VoiceLabEditCommand.AcceptAll([segment], assets, null);
        if (row["error"]?.GetValue<string>() is { } error)
        {
            Assert.Equal(error, Wire(Assert.Throws<VoiceLabProjectException>(() => VoiceLabProject.AcceptAll(before, assets, [segment])).Code));
            Assert.Equal(error, Wire(Assert.Throws<VoiceLabProjectException>(() => command.ApplyingTo(before)).Code));
            return;
        }
        var accepted = command.ApplyingTo(before);
        Assert.Empty(accepted.VoiceLab.Voices!);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(source), JsonNode.Parse(ProjectSerialization.Serialize(accepted))), "accepting changed the recorded take");
        var history = new VoiceLabEditHistory(before).Apply([segment], assets, null, VoiceLabOutputScope.Full, "Rewrite 2 words");
        Assert.True(history.Present.ModifiedAt > before.ModifiedAt);
        Assert.Equal(ProjectSerialization.Serialize(accepted with { ModifiedAt = history.Present.ModifiedAt }), ProjectSerialization.Serialize(history.Present));
    }

    [Theory]
    [MemberData(nameof(Ids), "invalid")]
    public void ChangedRecordedRecipesAreRefused(string id)
    {
        var row = Row("invalid", id);
        var node = JsonNode.Parse(Source(row))!;
        var segmentId = row["segment"]!.GetValue<string>();
        var segment = node["voiceLab"]!["segments"]!.AsArray().Single(item => item!["id"]!.GetValue<string>() == segmentId)!;
        foreach (var (path, value) in row["set"]!.AsObject())
        {
            var parts = path.Split('/');
            var parent = parts[..^1].Aggregate(segment, (current, part) => int.TryParse(part, out var index) ? current[index]! : current[part]!);
            if (int.TryParse(parts[^1], out var last)) parent[last] = value?.DeepClone();
            else parent[parts[^1]] = value?.DeepClone();
        }
        var json = node.ToJsonString();
        var expected = row["error"]!.GetValue<string>();
        Assert.Equal(expected, Wire(Assert.Throws<VoiceLabProjectException>(() => ProjectSerialization.Deserialize(json)).Code));
    }

    [Fact]
    public void ARecordedTakeBuildsTheRecipeMacSavesAndIsAcceptedWithoutAVoice()
    {
        var project = ProjectSerialization.Deserialize(Source(Row("renders", "recorded-source")));
        var stored = project.VoiceLab.Segments.Single();
        var saved = stored.Candidates[0].Recipe!;
        var window = new VoiceLabWindow(stored.Replace.FirstWordId, stored.Replace.LastWordId, [], [], 2.5, 3.2, 2500, 3200,
            new(VoiceLabSeamKind.Gap, 2.5, 2500, 20), new(VoiceLabSeamKind.Gap, 3.2, 3200, 20));
        var words = saved.Words!.Select(word => word with { Synthetic = true }).ToArray();
        var plan = new VoiceLabFitPlan([], new(0, 0), new(0, 0), 2400, 19200, 2.5, 3.2, 2500, 3200, 16800, words);
        var input = new VoiceLabTakeInput("new words", "fixture-model", "own-take", "en", 7, project.Media.Source.ContentKey, [], 1000,
            project.Transcript!.Words, new HashSet<string>(), window, null, null, false, true);
        var take = new VoiceLabTakeAudio(24000, [], [], 0, 0, [], 0, saved.RoomTone, new VoiceLabFitResult.Exact(plan));
        // An own take is never sent anywhere: no receipt or quote, and no speaker score.
        var row = new VoiceLabTakeRow(Guid.Parse(saved.Provenance.RequestId!), 0, 7, Audio: take,
            Qa: new(1, .2, -1, null, []) { SpeakerUnmeasured = true }, Score: .9);
        var published = new VoiceLabPublishedTake([project.VoiceLab.Assets![0]], saved.Audio with { Stretch = 1 }, .7, words, saved.Chunks);
        var createdAt = saved.Provenance.CreatedAt;
        var candidate = VoiceLabRecordedTake.Candidate(row, input, published, "apple-speech", createdAt);
        var recipe = candidate.Recipe!;
        Assert.Equal(saved.Provenance, recipe.Provenance);
        Assert.Equal(saved.Cost, recipe.Cost);
        Assert.Equal(saved.Qa, recipe.Qa);
        Assert.Equal(saved.Words, recipe.Words);
        Assert.Equal(saved.Seams, recipe.Seams);
        Assert.Equal(saved.Video, recipe.Video);
        Assert.Equal((VoiceLabVoiceSource.Own, (string?)null, (DateTimeOffset?)null), (recipe.VoiceSource, recipe.VoiceRefId, recipe.ConsentVerifiedAt));
        var segment = VoiceLabRecordedTake.Segment("own-take", candidate, input, plan);
        Assert.Equal(VoiceLabSegmentKind.Recorded, segment.Kind);
        Assert.All(segment.Words!, word => Assert.False(word.Synthetic));
        var empty = project with { VoiceLab = project.VoiceLab with { Segments = [], Assets = [] } };
        var accepted = new VoiceLabEditCommand.AcceptAll([segment], published.Assets, null).ApplyingTo(empty);
        Assert.Equal(VoiceLabSegmentKind.Recorded, Assert.Single(accepted.VoiceLab.Segments).Kind);
        Assert.Empty(accepted.VoiceLab.Voices!);
        Assert.False(VoiceLabRenderContract.Prepare(accepted, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight).Disclosure.Required);

        // Anything that was sent or voice-checked is not an own take.
        Assert.Throws<VoiceLabProjectException>(() => VoiceLabRecordedTake.Candidate(row with { Qa = new(1, .2, -1, .9, []) }, input, published, "apple-speech", createdAt));
        Assert.Throws<VoiceLabProjectException>(() => VoiceLabRecordedTake.Candidate(row, input, published, "", createdAt));
        Assert.Throws<VoiceLabProjectException>(() => VoiceLabRecordedTake.Candidate(row, input, published with { Audio = published.Audio with { Stretch = .9 } }, "apple-speech", createdAt));
    }

    [Fact]
    public void SpokenWordsTimeTheirCharactersAsAnAlignmentDoes()
    {
        var timing = VoiceLabRecordedTake.Alignment([new("Hello,", .3, .7), new("world", .8, 1.2)]);
        Assert.Equal("Hello, world", string.Concat(timing.Select(item => item.Character)));
        Assert.Equal(.3, timing[0].Start);
        Assert.Equal(1.2, timing[^1].End);
        Assert.All(timing.Zip(timing.Skip(1)), pair => Assert.True(pair.First.End <= pair.Second.Start + 1e-12));
        // A space joins the words from the end of one to the start of the next; empty and zero-length words are skipped.
        Assert.Equal(new VoiceLabCharacterTiming(" ", .7, .8), timing[6]);
        Assert.Equal(VoiceLabRecordedTake.Alignment([new("a", .1, .2)]), VoiceLabRecordedTake.Alignment([new("", 0, .1), new("a", .1, .2), new("b", .3, .3)]));
    }

    [Fact]
    public void RecordedProvenanceNamesNoVoiceOrConsent()
    {
        var provenance = new VoiceLabProvenance(VoiceLabRecordedTake.Provider, VoiceLabRecordedTake.Endpoint, "apple-speech",
            VoiceLabRecordedTake.VoiceId, null, "take", 0, DateTimeOffset.UnixEpoch) { Region = VoiceLabRecordedTake.Region };
        Assert.True(VoiceLabRecordedTake.IsRecorded(provenance));
        Assert.False(VoiceLabRecordedTake.IsRecorded(provenance with { ConsentRecordId = "record" }));
        Assert.False(VoiceLabRecordedTake.IsRecorded(provenance with { Provider = "elevenlabs" }));
        Assert.False(VoiceLabRecordedTake.IsRecorded(provenance with { Pace = 1.1 }));
        Assert.False(VoiceLabRecordedTake.IsRecorded(provenance with { Region = null }));
    }

    [Fact]
    public void RecordedSegmentsDecodeAndStayDistinct()
    {
        var json = JsonSerializer.Serialize(new[] { VoiceLabSegmentKind.Recorded, VoiceLabSegmentKind.Tts, VoiceLabSegmentKind.VoiceChanger });
        Assert.Equal("""["recorded","tts","voiceChanger"]""", json);
        Assert.Equal([VoiceLabSegmentKind.Recorded, VoiceLabSegmentKind.Tts, VoiceLabSegmentKind.VoiceChanger], JsonSerializer.Deserialize<VoiceLabSegmentKind[]>(json));
    }

    [Fact]
    public void OnlyGeneratedSpeechOrLipSyncIsAIModified()
    {
        var recorded = ProjectSerialization.Deserialize(Source(Row("renders", "recorded-source"))).VoiceLab.Segments.Single();
        var synced = ProjectSerialization.Deserialize(Source(Row("renders", "recorded-lipsync"))).VoiceLab.Segments.Single();
        var beside = ProjectSerialization.Deserialize(Source(Row("renders", "recorded-beside-tts"))).VoiceLab.Segments;
        Assert.False(recorded.HasAISpeech());
        Assert.False(recorded.IsAIModified());
        Assert.False(synced.HasAISpeech());
        Assert.True(synced.IsAIModified());
        Assert.True(beside.Single(segment => segment.Kind == VoiceLabSegmentKind.Tts).IsAIModified());
        Assert.False(synced with { SelectedCandidateIndex = 1 } is var plain && plain.IsAIModified());
    }
}
