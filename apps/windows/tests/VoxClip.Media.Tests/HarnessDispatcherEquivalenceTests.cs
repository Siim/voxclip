using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Cli;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class HarnessDispatcherEquivalenceTests
{
    [Fact]
    public async Task SavedHarnessAndLiveDispatcherReturnTheSameJson()
    {
        var ct = TestContext.Current.CancellationToken;
        using var fixture = FixtureLoader.ReadJson("fixtures/agent-chat/tool-cases.json");
        var vector = fixture.RootElement;
        var source = FixtureLoader.ReadText(vector.GetProperty("project").GetString()!);
        var project = ProjectSerialization.Deserialize(source);
        var directory = Directory.CreateTempSubdirectory("voxclip-harness-");
        try
        {
            var path = Path.Combine(directory.FullName, "fixture.voxclip");
            await File.WriteAllTextAsync(path, source, ct);
            var saved = await HarnessProject.OpenAsync(path, ct);
            foreach (var call in vector.GetProperty("savedCalls").EnumerateObject())
            {
                var tool = call.Name switch
                {
                    "read_transcript" => HarnessTool.ReadTranscript,
                    "read_clips" => HarnessTool.ReadClips,
                    "read_takes" => HarnessTool.ReadTakes,
                    "read_decisions" => HarnessTool.ReadDecisions,
                    "propose_timeline" => HarnessTool.ProposeTimeline,
                    _ => throw new InvalidOperationException(call.Name)
                };
                var live = await HarnessTools.Call(tool, call.Value, project, FixtureLoader.SharedRoot, projectPath: path, ct: ct);
                Assert.False(File.Exists(path + ".proposal.json"));
                var cli = await saved.CallAsync(tool, call.Value, ct);
                Assert.True(JsonNode.DeepEquals(Comparable(cli), Comparable(live)), call.Name);
                Assert.Equal(tool == HarnessTool.ProposeTimeline, File.Exists(path + ".proposal.json"));
            }
        }
        finally { directory.Delete(recursive: true); }
    }

    private static JsonNode Comparable(HarnessResult result)
    {
        var fields = JsonSerializer.SerializeToNode(result.Fields, JsonSerializerOptions.Web)!;
        if (fields["proposal"] is JsonObject proposal)
        {
            Assert.True(Guid.TryParse(proposal["id"]!.GetValue<string>(), out _));
            proposal.Remove("id");
        }
        return fields;
    }
}
