using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Cli;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

[Collection("CLI console")]
public sealed class CliFindClipsTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ResultMatchesSharedExpectedOutput(bool emptyClips)
    {
        var expected = Fixture()["result"]!["expected"]!.DeepClone().AsObject();
        if (emptyClips) expected["clips"] = new JsonArray();
        var payload = expected.DeepClone().AsObject();
        foreach (var key in new[] { "ok", "command", "version" }) payload.Remove(key);
        var result = JsonSerializer.Deserialize(payload, ProjectJsonContext.Default.AiResult)!;
        var actual = AiMergeAdapter.ClipResult(result);
        actual["ok"] = true; actual["command"] = "find-clips";
        Assert.True(JsonNode.DeepEquals(expected, actual), actual.ToJsonString());
    }

    [Fact]
    public async Task DryRunMatchesSharedExpectedShapeWithoutChangingProject()
    {
        var fixture = Fixture()["dryRun"]!;
        var project = Path.Combine(FixtureLoader.SharedRoot, "fixtures", fixture["project"]!.GetValue<string>());
        var original = await File.ReadAllBytesAsync(project, TestContext.Current.CancellationToken);
        var arguments = new List<string> { "find-clips", "--open", project, "--dry-run", "--json" };
        arguments.AddRange(fixture["arguments"]!.AsArray().Select(value => value!.GetValue<string>()));
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(arguments.ToArray(), TestContext.Current.CancellationToken);
            Assert.Equal(0, exit);
            var actual = JsonNode.Parse(output.ToString())!.AsObject();
            var keys = fixture["keys"]!.AsArray().Select(value => value!.GetValue<string>()).Order(StringComparer.Ordinal);
            Assert.Equal(keys, actual.Select(pair => pair.Key).Order(StringComparer.Ordinal));
            foreach (var pair in fixture["expected"]!.AsObject()) Assert.True(JsonNode.DeepEquals(pair.Value, actual[pair.Key]), pair.Key);
            Assert.False(string.IsNullOrEmpty(actual["version"]?.GetValue<string>()), "version");
            var prompts = actual["prompts"]!.AsArray();
            Assert.Equal(fixture["promptCount"]!.GetValue<int>(), prompts.Count);
            var promptKeys = fixture["promptKeys"]!.AsArray().Select(value => value!.GetValue<string>()).Order(StringComparer.Ordinal);
            foreach (var prompt in prompts)
            {
                Assert.Equal(promptKeys, prompt!.AsObject().Select(pair => pair.Key).Order(StringComparer.Ordinal));
                foreach (var key in promptKeys) Assert.False(string.IsNullOrEmpty(prompt[key]!.GetValue<string>()));
            }
            Assert.Equal(original, await File.ReadAllBytesAsync(project, TestContext.Current.CancellationToken));
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }

    private static JsonObject Fixture() => JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot,
        "fixtures", "cli", "find-clips.json")))!.AsObject();
}
