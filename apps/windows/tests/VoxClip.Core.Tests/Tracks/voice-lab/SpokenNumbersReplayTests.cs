using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Numbers matched however they are written (voice-lab.md §8.11, ADR-R49), replayed from
/// shared/fixtures/spoken-numbers/number-cases.json, which tools/fixtures/spoken-numbers/generate_number_cases.py writes.
/// The macOS Core replays the same file.</summary>
public sealed class SpokenNumbersReplayTests
{
    static readonly Lazy<JsonNode> Vectors = new(() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/spoken-numbers/number-cases.json"))!);
    static IEnumerable<JsonNode> Rows(string key) => Vectors.Value[key]!.AsArray().Select(row => row!);
    static int[] Ints(JsonNode? node) => node!.AsArray().Select(value => value!.GetValue<int>()).ToArray();
    static string[] Strings(JsonNode? node) => node!.AsArray().Select(value => value!.GetValue<string>()).ToArray();
    static readonly float[] Tone = Enumerable.Range(0, 16000).Select(index => (float)(.1 * Math.Sin(2 * Math.PI * 220 * index / 16000))).ToArray();

    [Fact]
    public void SharedVectorsHaveTheirSchemaKeysAndCount()
    {
        var root = Vectors.Value.AsObject();
        Assert.Equal(new[] { "schema", "description", "constants", "caseCount", "counts", "numerals", "alignments", "takeChecks" }, root.Select(pair => pair.Key));
        Assert.Equal("voxclip-spoken-numbers-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(79, root["caseCount"]!.GetValue<int>());
        Assert.Equal(79, Rows("numerals").Count() + Rows("alignments").Count() + Rows("takeChecks").Count());
        Assert.Equal(new[] { "cardinal", "yearPair", "digits", "ordinal", "separators", "currency", "percent", "units", "nonMatch", "otherLanguage", "plain" },
            root["counts"]!.AsObject().Select(pair => pair.Key));
        Assert.Equal(Rows("alignments").Count(), root["counts"]!.AsObject().Sum(pair => pair.Value!.GetValue<int>()));
        Assert.Equal(SpokenNumbers.LongestRun, root["constants"]!["longestRun"]!.GetValue<int>());
        Assert.Equal(SpokenNumbers.LongestUnverifiedRun, root["constants"]!["longestUnverifiedRun"]!.GetValue<int>());
    }

    [Fact]
    public void NumeralsParseAsTheGeneratorSays()
    {
        foreach (var row in Rows("numerals"))
        {
            var raw = row["raw"]!.GetValue<string>();
            var parsed = SpokenNumbers.Parse(raw);
            var expected = row["numeral"];
            if (expected is null) { Assert.True(parsed is null, raw); continue; }
            Assert.True(parsed is not null, raw);
            Assert.True(expected["value"]!.GetValue<string>() == parsed!.Value, raw);
            Assert.True(expected["digits"]!.GetValue<string>() == parsed.Digits, raw);
            Assert.True(expected["ordinal"]!.GetValue<bool>() == parsed.Ordinal, raw);
            Assert.True(expected["unit"]?.GetValue<string>() == parsed.Unit?.ToString().ToLowerInvariant(), raw);
        }
    }

    [Fact]
    public void EveryAlignmentReplays()
    {
        foreach (var row in Rows("alignments"))
        {
            var id = row["id"]!.GetValue<string>();
            var expected = SpokenNumbers.Tokens(row["expected"]!.GetValue<string>());
            var recognized = SpokenNumbers.Tokens(row["recognized"]!.GetValue<string>());
            Assert.True(Strings(row["expectedTokens"]).SequenceEqual(expected.Select(token => token.Text)), id);
            Assert.True(Strings(row["recognizedTokens"]).SequenceEqual(recognized.Select(token => token.Text)), id);
            var alignment = SpokenNumbers.Align(expected, recognized);
            var pairs = row["pairs"]!.AsArray().Select(pair => (pair![0]!.GetValue<int>(), pair[1]!.GetValue<int>())).ToArray();
            Assert.True(pairs.SequenceEqual(alignment.Pairs), $"{id}: {string.Join(" ", alignment.Pairs)}");
            Assert.True(Ints(row["unverifiedExpected"]).SequenceEqual(alignment.UnverifiedExpected), id);
            Assert.True(Ints(row["unverifiedRecognized"]).SequenceEqual(alignment.UnverifiedRecognized), id);
            Assert.True(row["unverifiedNumbers"]!.GetValue<int>() == alignment.UnverifiedNumbers, id);
            Assert.True(row["ratio"]!.GetValue<double>() == alignment.Ratio, $"{id}: {alignment.Ratio}");
            Assert.True(row["complete"]!.GetValue<bool>() == alignment.Complete, id);
        }
    }

    [Fact]
    public void EveryTakeCheckReplays()
    {
        foreach (var row in Rows("takeChecks"))
        {
            var id = row["id"]!.GetValue<string>();
            var qa = VoiceLabTakeQuality.Evaluate(row["expected"]!.GetValue<string>(), Strings(row["recognized"]), Tone, 16000, [], .9, .45);
            Assert.True(row["transcriptMatch"]!.GetValue<double>() == qa.TranscriptMatch, $"{id}: {qa.TranscriptMatch}");
            Assert.True(row["passed"]!.GetValue<bool>() == !qa.Failures.Contains(VoiceLabTakeQaFailure.Transcript), id);
            Assert.True(row["unverifiedNumbers"]!.GetValue<int>() == qa.UnverifiedNumbers, id);
        }
    }

    [Fact]
    public void AShortPhraseThatSaysTheNumberPassesAndAWrongNumberFails()
    {
        var said = VoiceLabTakeQuality.Evaluate("$300 is enough", ["three", "hundred", "dollars", "is", "enough"], Tone, 16000, [], .9, .45);
        Assert.DoesNotContain(VoiceLabTakeQaFailure.Transcript, said.Failures);
        var wrong = VoiceLabTakeQuality.Evaluate("$300 is enough", ["$30", "is", "enough"], Tone, 16000, [], .9, .45);
        Assert.Contains(VoiceLabTakeQaFailure.Transcript, wrong.Failures);
    }
}
