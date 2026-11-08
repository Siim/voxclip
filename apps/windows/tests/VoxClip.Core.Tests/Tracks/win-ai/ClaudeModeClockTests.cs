using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Claude mode's stage timings (ai.md §16.12), twin of the Mac <c>ClaudeModeClock</c> tests: begin/end pairs per clip, the first
/// postable clip, the CLI's JSON and the log line, all on a virtual clock.</summary>
[Trait("Track", "win-ai")]
public sealed class ClaudeModeClockTests
{
    [Fact]
    public void StagesOverlapPerClipAndTheFirstReadyIsTheEarliestApply()
    {
        var now = 0.0;
        var clock = new ClaudeModeClock(() => now);
        clock.Begin(ClaudeModeStage.Transcribe);
        now = 53.14;
        clock.End(ClaudeModeStage.Transcribe);
        clock.Begin(ClaudeModeStage.Find);
        now = 130.2;
        clock.End(ClaudeModeStage.Find);
        clock.End(ClaudeModeStage.Find);
        foreach (var clip in new[] { 1, 2, 3 }) clock.Begin(ClaudeModeStage.Plan, clip);
        clock.Begin(ClaudeModeStage.Plan, 1);
        now = 191.25;
        clock.End(ClaudeModeStage.Plan, 3);
        var apply = clock.Elapsed;
        now = 192.5;
        clock.Record(ClaudeModeStage.Apply, 3, apply);
        now = 204.0;
        clock.End(ClaudeModeStage.Plan, 1);
        clock.End(ClaudeModeStage.Plan, 2);
        now = 205.0;
        clock.Record(ClaudeModeStage.Apply, 1, 204.0);
        Assert.Equal(192.5, clock.FirstReady);
        Assert.Equal("claude-mode timings transcribe=53.1 find=77.1 plan3=61.1 apply3=1.3 plan1=73.8 plan2=73.8 apply1=1.0 first=192.5 total=205.0", clock.LogLine());
        var json = clock.Json();
        Assert.Equal(7, json["stages"]!.AsArray().Count);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("""{"stage":"plan","seconds":61.05,"start":130.2,"end":191.25,"clip":3}"""), json["stages"]![2]));
        Assert.False(json["stages"]![0]!.AsObject().ContainsKey("clip"));
        Assert.Equal((192.5, 205.0), (json["firstClipSeconds"]!.GetValue<double>(), json["totalSeconds"]!.GetValue<double>()));
        var empty = new ClaudeModeClock(() => 0).Json();
        Assert.Null(empty["firstClipSeconds"]);
        Assert.Equal("claude-mode timings first=none total=0.0", new ClaudeModeClock(() => 0).LogLine());
    }
}
