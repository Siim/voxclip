using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabAudioTagTests
{
    private static JsonNode Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/audio-tag-cases.json"))!;
    private static VoiceLabAudioTag[] Tags(JsonNode value) => value.AsArray().Select(tag => new VoiceLabAudioTag(tag!["beforeToken"]!.GetValue<int>(), tag["tag"]!.GetValue<string>())).ToArray();

    public static IEnumerable<object[]> EdgeCases() => Cases()["edgeExtents"]!.AsArray().Select(row => new object[] { row!["id"]!.GetValue<string>() });
    public static IEnumerable<object[]> EventCases() => Cases()["eventFilters"]!.AsArray().Select(row => new object[] { row!["id"]!.GetValue<string>() });
    [Theory]
    [MemberData(nameof(EdgeCases))]
    public void SharedEdgeExtentsReplayExactly(string id)
    {
        var row = Cases()["edgeExtents"]!.AsArray().Single(value => value!["id"]!.GetValue<string>() == id)!;
        var samples = new float[row["sampleCount"]!.GetValue<int>()];
        foreach (var run in row["sampleRuns"]!.AsArray())
            Array.Fill(samples, .1f, run![0]!.GetValue<int>(), run[1]!.GetValue<int>() - run[0]!.GetValue<int>());
        var words = row["words"]!.AsArray().Select(word => new VoiceLabWord(word!["text"]!.GetValue<string>(), word["start"]!.GetValue<double>(), word["end"]!.GetValue<double>(), true)).ToArray();
        var characters = row["characters"]!.AsArray().Select(time => new VoiceLabCharacterTiming(time!["character"]!.GetValue<string>(), time["start"]!.GetValue<double>(), time["end"]!.GetValue<double>())).ToArray();
        var rate = row["sampleRate"]!.GetValue<int>();
        var extended = VoiceLabAudioTags.ExtendEdges(words, samples, rate, Tags(row["audioTags"]!), row["tokenCount"]!.GetValue<int>(), row["modelID"]!.GetValue<string>(), characters);
        Assert.Equal(BitConverter.DoubleToInt64Bits(row["expectedStart"]!.GetValue<double>()), BitConverter.DoubleToInt64Bits(extended[0].Start));
        Assert.Equal(BitConverter.DoubleToInt64Bits(row["expectedEnd"]!.GetValue<double>()), BitConverter.DoubleToInt64Bits(extended[^1].End));
        Assert.Equal(words.Select(word => word.Text), extended.Select(word => word.Text));
        if (row["expectedTrimStart"] is { } start && row["expectedTrimEnd"] is { } end)
        {
            var trim = VoiceLabAlignment.Trim(extended, samples.Length / (double)rate);
            Assert.Equal(Math.Floor(start.GetValue<double>() * rate + .5), Math.Floor(trim.Start * rate + .5));
            Assert.Equal(Math.Floor(end.GetValue<double>() * rate + .5), Math.Floor(trim.End * rate + .5));
        }
    }
    [Theory]
    [MemberData(nameof(EventCases))]
    public void SharedEventFiltersReplayByteExactly(string id)
    {
        var row = Cases()["eventFilters"]!.AsArray().Single(value => value!["id"]!.GetValue<string>() == id)!;
        var expected = VoiceLabTakeQuality.Tokens(row["expected"]!.GetValue<string>());
        var filtered = VoiceLabAudioTags.FilterScribeEvents(expected, row["recognized"]!.AsArray().Select(value => value!.GetValue<string>()).ToArray(), row["tagged"]!.GetValue<bool>());
        Assert.Equal(Encoding.UTF8.GetBytes(row["filtered"]!.ToJsonString()), Encoding.UTF8.GetBytes(JsonSerializer.Serialize(filtered)));
    }

    [Fact]
    public void SharedRequestWhitelistAndAllowanceVectorsAreExact()
    {
        var root = Cases();
        Assert.Equal("voxclip-voice-audio-tags/1", root["schema"]!.GetValue<string>());
        Assert.Equal(71, root["caseCount"]!.GetValue<int>());
        foreach (var row in root["requests"]!.AsArray())
        {
            var text = row!["words"]!.GetValue<string>();
            var model = row["modelID"]!.GetValue<string>();
            Assert.Equal(row["expected"]!.GetValue<string>(), VoiceLabAudioTags.RequestText(text, Tags(row["audioTags"]!), model));
            Assert.Equal(row["allowance"]!.GetValue<double>(), VoiceLabAudioTags.Allowance(Tags(row["audioTags"]!), text, model));
        }
        var drop = root["drop"]!;
        Assert.Equal(Tags(drop["expected"]!), VoiceLabAudioTags.Validated(Tags(drop["audioTags"]!), drop["words"]!.GetValue<string>()));
        foreach (var row in root["durations"]!.AsArray())
            Assert.Equal(row!["seconds"]!.GetValue<double>(), VoiceLabAudioTags.Allowance([new(1, row["tag"]!.GetValue<string>())], "Hello", "eleven_v4"));
        Assert.Equal(new[] { new VoiceLabAudioTag(1, "laughs") }, VoiceLabAudioTags.Parse(JsonNode.Parse(
            "[{\"beforeToken\":0,\"tag\":\"shouts\"},{\"beforeToken\":0.5,\"tag\":\"laughs\"},{\"beforeToken\":1,\"tag\":\"laughs\"},{\"beforeToken\":1,\"tag\":\"sighs\"}]"), "Hello there"));
    }

    [Fact]
    public void SharedAlignmentsPreserveExactTypedWordsAndStarts()
    {
        foreach (var row in Cases()["alignments"]!.AsArray())
        {
            var words = VoiceLabAlignment.Words(row!["characters"]!.AsArray().Select(value => value!.GetValue<string>()).ToArray(),
                row["starts"]!.AsArray().Select(value => value!.GetValue<double>()).ToArray(), row["ends"]!.AsArray().Select(value => value!.GetValue<double>()).ToArray(), row["expectedText"]!.GetValue<string>());
            Assert.Equal(row["expectedWords"]!.AsArray().Select(value => value!.GetValue<string>()), words.Select(word => word.Text));
            Assert.Equal(row["expectedStarts"]!.AsArray().Select(value => value!.GetValue<double>()), words.Select(word => word.Start));
        }
        foreach (var row in Cases()["normalized"]!.AsArray())
        {
            var text = row!["normalized"]!.GetValue<string>();
            var raw = text.Select((character, index) => new VoiceLabCharacterTiming(character.ToString(), index / 100.0, (index + 1) / 100.0)).ToArray();
            var mapped = VoiceLabProviderTiming.Retime(raw.Select(item => item.Character).ToArray(), raw.Select(item => item.Start).ToArray(),
                raw.Select(item => item.End).ToArray(), row["typed"]!.GetValue<string>(), raw[^1].End);
            Assert.Equal(row["expectedWords"]!.AsArray().Select(value => value!.GetValue<string>()), mapped.Where(value => value.Character != " ").Select(value => value.Character));
            Assert.Equal(raw[0].Start, mapped[0].Start);
            Assert.Equal(raw[^1].End, mapped[^1].End);
        }
    }

    [Fact]
    public void ScribeEventsAreNormalizedAndOnlyExtraOccurrencesOnTaggedTakesAreDropped()
    {
        foreach (var entry in Cases()["qaEvents"]!.AsArray())
        {
            var eventText = entry!.GetValue<string>();
            Assert.True(VoiceLabAudioTags.IsScribeEvent(eventText));
            var qa = VoiceLabTakeQuality.Evaluate("Hello there [laughs]", ["Hello", eventText.ToUpperInvariant(), "there"],
                Enumerable.Repeat(0.1f, 480).ToArray(), 24000, [], .8, .5, hasTags: true);
            Assert.Equal(1, qa.TranscriptMatch);
        }
        Assert.Equal(new[] { "hello", "haha", "there" }, VoiceLabAudioTags.FilterScribeEvents(["hello", "haha", "there"], ["hello", "haha", "haha", "there"], true));
        Assert.Equal(new[] { "hello", "haha", "haha", "there" }, VoiceLabAudioTags.FilterScribeEvents(["hello", "haha", "there"], ["hello", "haha", "haha", "there"], false));
        Assert.Empty(VoiceLabAudioTags.FilterScribeEvents([], VoiceLabTakeQuality.Tokens("[LAUGHS] (sighs)"), true));
        Assert.Equal(new[] { "hello", "haha", "there" }, VoiceLabAudioTags.FilterScribeEvents(["Hello", "Haha!", "there"], ["HELLO", "[HAHA]", "haha", "there"], true));
    }

    [Fact]
    public void RepeatedWordsCannotStealTagsAndEditingUsesOrderedDiff()
    {
        var source = new[] { "Hello", "one", "two", "three", "old" }.Select((text, index) => Word(index, text, index, index + 1)).ToArray();
        var diff = VoiceLabWordDiff.Diff(source, "Hello one two three Hello", [new(1, "laughs"), new(5, "sighs")]);
        Assert.Equal(new[] { new VoiceLabAudioTag(1, "sighs") }, Assert.Single(diff.Hunks).AudioTags);
        Assert.Equal(new[] { new VoiceLabAudioTag(2, "laughs"), new VoiceLabAudioTag(4, "sighs") },
            VoiceLabAudioTags.Reanchored([new(1, "laughs"), new(2, "sighs")], "Hello there", "Well Hello there now"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void EdgeTagsExtendOnlyAcousticWordsThenUseNormalTrim(bool tagCharacters)
    {
        const int rate = 24000;
        var samples = new float[rate * 3];
        Array.Fill(samples, .2f, (int)(rate * (tagCharacters ? .7 : .3)), (int)(rate * (tagCharacters ? 1.1 : 1.9)));
        VoiceLabWord[] words = [new("Hello", 1, 1.2, true), new("there", 1.3, 1.5, true)];
        VoiceLabCharacterTiming[] alignment = tagCharacters ? [new("[laughs]", .3, .8), new("Hello there", 1, 1.5), new("[sighs]", 1.6, 2.2)] : [new("Hello there", 1, 1.5)];
        var tags = new[] { new VoiceLabAudioTag(0, "laughs"), new VoiceLabAudioTag(2, "sighs") };
        var extended = VoiceLabAudioTags.ExtendEdges(words, samples, rate, tags, 2, "eleven_v4", alignment);
        Assert.InRange(extended[0].Start, .3 - 1.0 / rate, .3);
        Assert.InRange(extended[^1].End, 2.2, 2.21);
        var trim = VoiceLabAlignment.Trim(extended, 3);
        Assert.True(trim.Start > 0);
        Assert.True(trim.End < 3);
        Assert.Equal(words, VoiceLabAudioTags.ExtendEdges(words, samples, rate, tags, 2, "eleven_multilingual_v2", alignment));
        Assert.Equal(words, VoiceLabAudioTags.ExtendEdges(words, samples, rate, [new(1, "laughs")], 2, "eleven_v4", alignment));
    }

    [Fact]
    public void TagCharactersDoNotBecomeAlignedWords()
    {
        const string text = "Hello [laughs] there";
        var characters = text.Select(character => character.ToString()).ToArray();
        var starts = Enumerable.Range(0, text.Length).Select(index => index * 0.01).ToArray();
        var ends = starts.Select(start => start + 0.01).ToArray();
        Assert.Equal(new[] { "Hello", "there" }, VoiceLabAlignment.Words(characters, starts, ends, text).Select(word => word.Text));
    }

    [Fact]
    public void OptionalAnnotationsDecodeValidateAndPreserveWithoutChangingWords()
    {
        using var fixture = JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/audio-tag-cases.json"));
        var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        foreach (var row in fixture.RootElement.GetProperty("roundTrips").EnumerateArray())
        {
            var text = JsonSerializer.Deserialize<VoiceLabText>(row.GetRawText(), options)!;
            Assert.True(VoiceLabProject.ValidAudioTags(text));
            using var encoded = JsonDocument.Parse(JsonSerializer.Serialize(text, options));
            Assert.Equal(row.GetProperty("new").GetString(), encoded.RootElement.GetProperty("new").GetString());
            Assert.Equal(row.TryGetProperty("audioTags", out _), encoded.RootElement.TryGetProperty("audioTags", out _));
            if (text.AudioTags is not null)
                Assert.Equal(text.AudioTags, JsonSerializer.Deserialize<VoiceLabText>(encoded.RootElement.GetRawText(), options)!.AudioTags);
        }
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var segments = project.VoiceLab.Segments.ToArray();
        segments[0] = segments[0] with { Text = segments[0].Text! with { AudioTags = [new(1, "laughs")] } };
        var changed = project with { VoiceLab = project.VoiceLab with { Segments = segments } };
        VoiceLabProject.Validate(changed);
        var saved = ProjectSerialization.Serialize(changed);
        var restored = ProjectSerialization.Deserialize(saved);
        Assert.Equal("laughs", restored.VoiceLab.Segments[0].Text!.AudioTags![0].Tag);
        Assert.Equal(project.VoiceLab.Segments[0].Words, restored.VoiceLab.Segments[0].Words);
    }

    [Theory]
    [InlineData(-1, "laughs")]
    [InlineData(3, "laughs")]
    [InlineData(1, "shouts")]
    public void InvalidAnnotationsAreRejected(int boundary, string tag)
        => Assert.False(VoiceLabProject.ValidAudioTags(new("Old words", "Hello there") { AudioTags = [new(boundary, tag)] }));
}
