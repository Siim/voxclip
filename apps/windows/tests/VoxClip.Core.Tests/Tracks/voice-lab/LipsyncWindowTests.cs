using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class LipsyncWindowTests
{
    [Fact]
    public void HandlesAndMergesMatchTheSharedMacCases()
    {
        using var fixture = JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/lipsync-window-cases.json"));
        var root = fixture.RootElement;
        int count = 0;
        foreach (var row in root.GetProperty("windows").EnumerateArray())
        {
            Expect(Read(row.GetProperty("expected")), LipsyncWindow.Make(Number(row, "seamIn"), Number(row, "seamOut"),
                Number(row, "totalSamples"), (int)Number(row, "sampleRate"), (int)Number(row, "phraseID")));
            count++;
        }
        foreach (var row in root.GetProperty("merges").EnumerateArray())
        {
            var actual = LipsyncWindow.Merge(row.GetProperty("windows").EnumerateArray().Select(Read), 48000);
            var expected = row.GetProperty("expected").EnumerateArray().Select(Read).ToArray();
            Assert.Equal(expected.Length, actual.Count);
            for (int index = 0; index < expected.Length; index++) Expect(expected[index], actual[index]);
            count++;
        }
        Assert.Equal(Number(root, "caseCount"), count);
    }

    private static long Number(JsonElement row, string name) => row.GetProperty(name).GetInt64();
    private static LipsyncWindow Read(JsonElement row) => new(Number(row, "startSample"), Number(row, "endSample"),
        row.GetProperty("phraseIDs").EnumerateArray().Select(id => id.GetInt32()).ToArray());
    private static void Expect(LipsyncWindow expected, LipsyncWindow actual)
    {
        Assert.Equal(expected.StartSample, actual.StartSample);
        Assert.Equal(expected.EndSample, actual.EndSample);
        Assert.Equal(expected.PhraseIds, actual.PhraseIds);
    }
}
