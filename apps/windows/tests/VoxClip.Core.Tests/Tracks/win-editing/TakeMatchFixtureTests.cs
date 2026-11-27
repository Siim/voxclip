using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class TakeMatchFixtureTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private sealed record Recording(string Key, IReadOnlyList<TimedWord> Words);

    [Fact]
    public void SharedVectorsReplayExactly()
    {
        var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR") ??
            throw new InvalidOperationException("VOXCLIP_SHARED_DIR required");
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(shared, "fixtures", "recordings", "take-match-cases.json")));
        var cases = fixture.RootElement.GetProperty("cases");
        Assert.True(cases.GetArrayLength() > 0);
        foreach (var vector in cases.EnumerateArray())
        {
            var recordings = vector.GetProperty("recordings").Deserialize<Recording[]>(JsonOptions)!;
            var result = TakeMatch.Build(recordings.Select(recording => (recording.Key, recording.Words)).ToArray());
            var actual = JsonSerializer.SerializeToNode(result, JsonOptions);
            var expected = JsonNode.Parse(vector.GetProperty("expected").GetRawText());
            Assert.True(JsonNode.DeepEquals(expected, actual), $"{vector.GetProperty("id").GetString()}\nExpected: {expected}\nActual: {actual}");
        }
    }

    [Fact]
    public void SharedOpeningUsesOpaqueWordIds()
    {
        TimedWord[] primary = [new("left:opaque", "Opening.", WordKind.Word, 0, 1, null, null, null, null, TimingSource.Native)];
        TimedWord[] alternate = [new("r2.w14", "opening!", WordKind.Word, 2, 3, null, null, null, null, TimingSource.Native)];
        var result = TakeMatch.Build([("first", primary), ("second", alternate)]);
        Assert.Equal(["left:opaque", "r2.w14"], Assert.Single(result.Beats).Takes.Select(take => take.StartWordId));
    }
}
