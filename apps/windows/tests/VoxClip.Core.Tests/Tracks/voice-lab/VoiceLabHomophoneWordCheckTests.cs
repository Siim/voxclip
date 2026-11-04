using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>The word check's near-homophones of the user's own replacement words (voice-lab.md §8.11), replayed from the
/// independent generator's homophone-word-check-cases.json. The macOS Core replays the same file.</summary>
public sealed class VoiceLabHomophoneWordCheckTests
{
    static readonly Lazy<JsonNode> Vectors = new(() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/homophone-word-check-cases.json"))!);
    static IEnumerable<JsonNode> Rows(string key) => Vectors.Value[key]!.AsArray().Select(row => row!);
    static string[] Strings(JsonNode? node) => node!.AsArray().Select(value => value!.GetValue<string>()).ToArray();
    static readonly float[] Tone = Enumerable.Range(0, 16000).Select(index => (float)(.1 * Math.Sin(2 * Math.PI * 220 * index / 16000))).ToArray();

    [Fact]
    public void SharedVectorsHaveTheirSchemaAndCount()
    {
        var root = Vectors.Value.AsObject();
        Assert.Equal(new[] { "schema", "caseCount", "soundKeys", "soundsAlike", "replacementWords", "checks" }, root.Select(pair => pair.Key));
        Assert.Equal("voxclip-homophone-word-check/1", root["schema"]!.GetValue<string>());
        Assert.Equal(42, root["caseCount"]!.GetValue<int>());
        Assert.Equal(42, Rows("soundKeys").Count() + Rows("soundsAlike").Count() + Rows("replacementWords").Count() + Rows("checks").Count());
    }

    [Fact]
    public void SoundKeysAndNearHomophonesMatchTheGenerator()
    {
        foreach (var row in Rows("soundKeys"))
            Assert.True(row["key"]?.GetValue<string>() == VoiceLabTakeQuality.SoundKey(row["word"]!.GetValue<string>()), row["word"]!.GetValue<string>());
        foreach (var row in Rows("soundsAlike"))
            Assert.True(row["expected"]!.GetValue<bool>() == VoiceLabTakeQuality.SoundsAlike(row["word"]!.GetValue<string>(), row["heard"]!.GetValue<string>()),
                row["word"] + " / " + row["heard"]);
    }

    [Fact]
    public void ReplacementWordsAreTheNewWordsTheWindowDoesNotSay()
    {
        foreach (var row in Rows("replacementWords"))
        {
            var items = row["items"]!.AsArray().Select((item, index) => new TimedWord(item!["id"]!.GetValue<string>(), item["text"]!.GetValue<string>(),
                WordKind.Word, index, index + .5, null, null, null, null, TimingSource.Native)).ToArray();
            var seam = new VoiceLabSeamPlacement(VoiceLabSeamKind.Hard, 0, 0, 288);
            var window = new VoiceLabWindow(row["firstWordId"]!.GetValue<string>(), row["lastWordId"]!.GetValue<string>(), [], [], 0, 1, 0, 24000, seam, seam);
            var words = VoiceLabTakeQuality.ReplacementWords(row["text"]!.GetValue<string>(), items, window);
            Assert.True(Strings(row["expected"]).SequenceEqual(words.Order(StringComparer.Ordinal)), row["id"]!.GetValue<string>());
        }
    }

    [Fact]
    public void WordCheckCountsAHomophoneOfAnAskedWordAsThatWord()
    {
        foreach (var row in Rows("checks"))
        {
            var id = row["id"]!.GetValue<string>();
            var expected = row["expected"]!.GetValue<string>();
            var recognized = Strings(row["recognized"]);
            var replacement = Strings(row["replacementWords"]).ToHashSet(StringComparer.Ordinal);
            Assert.True(Strings(row["normalized"]).SequenceEqual(VoiceLabTakeQuality.NormalizingHomophones(recognized, VoiceLabTakeQuality.Tokens(expected), replacement)), id);
            var qa = VoiceLabTakeQuality.Evaluate(expected, recognized, Tone, 16000, [], .9, .45, replacementWords: replacement);
            Assert.True(row["transcriptMatch"]!.GetValue<double>() == qa.TranscriptMatch, $"{id}: {qa.TranscriptMatch}");
            Assert.True(row["passed"]!.GetValue<bool>() == !qa.Failures.Contains(VoiceLabTakeQaFailure.Transcript), id);
            // Without the replacement words the check reads the recognizer's words as they are.
            var raw = VoiceLabTakeQuality.Evaluate(expected, recognized, Tone, 16000, [], .9, .45);
            Assert.True(row["rawMatch"]!.GetValue<double>() == raw.TranscriptMatch, $"{id}: raw {raw.TranscriptMatch}");
        }
    }
}
