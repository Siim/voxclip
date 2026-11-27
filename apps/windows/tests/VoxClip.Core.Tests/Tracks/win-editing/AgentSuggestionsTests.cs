using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class AgentSuggestionsTests
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private sealed record Vector(string Id, string Project, int LengthSeconds, string? Platform,
        AgentSuggestions.Transcription? Transcribing, bool? Exported, string[]? Next, JsonNode Expected, string? ComposerReason);

    [Fact]
    public void SharedVectorsReplayExactly()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot,
            "fixtures", "agent-chat", "suggestion-cases.json")));
        var projects = fixture.RootElement.GetProperty("projects");
        var cases = fixture.RootElement.GetProperty("cases").Deserialize<Vector[]>(Options)!;
        Assert.NotEmpty(cases);
        foreach (var vector in cases)
        {
            var project = ProjectSerialization.Deserialize(projects.GetProperty(vector.Project).GetRawText());
            var state = new AgentSuggestions.State(project, vector.LengthSeconds, vector.Platform, vector.Transcribing,
                vector.Exported ?? false, vector.Next);
            var actual = JsonSerializer.SerializeToNode(AgentSuggestions.Chips(state), Options);
            Assert.True(JsonNode.DeepEquals(vector.Expected, actual), $"{vector.Id}\nExpected: {vector.Expected}\nActual: {actual}");
            Assert.Equal(vector.ComposerReason, state.ComposerReason);
        }
    }
}
