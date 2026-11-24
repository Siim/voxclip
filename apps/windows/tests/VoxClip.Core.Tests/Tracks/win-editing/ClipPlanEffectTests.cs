using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class ClipPlanEffectTests
{
    public static IEnumerable<object[]> Cases()
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-effects/clip-plan-effect-cases.json"))!;
        return vectors["cases"]!.AsArray().Select(vector => new object[] { (string)vector!["id"]!, vector.ToJsonString(), vectors["words"]!.ToJsonString() });
    }

    [Theory, MemberData(nameof(Cases))]
    public void ReplaysSharedSourceTimeMotionAndOverlays(string name, string raw, string rawWords)
    {
        var vector = JsonNode.Parse(raw)!;
        var words = JsonNode.Parse(rawWords)!.AsArray();
        var cut = vector["cutWords"]?.AsArray().Select(index => (int)index!).ToHashSet() ?? [];
        var entry = ClipPlanEffect.Read(vector["entry"]);
        Assert.True((entry is null) == ((bool?)vector["invalid"] == true), name);
        var operation = entry?.Operation("plan-fx", "clip", new(0, words.Count - 1),
            index => ((double)words[index]!["start"]!, (double)words[index]!["end"]!), cut.Contains, new HashSet<string> { "🔥" });
        var expected = vector["placement"];
        Assert.True((operation is null) == (expected is null), name);
        if (operation is null || expected is null) return;
        Assert.Equal(entry!.Reason, operation.Reason);
        if (operation.Action is ClipAutopilotAction.Motion motion)
        {
            Assert.Equal((double)expected["start"]!, motion.Cue.SourceStart);
            Assert.Equal((double)expected["end"]!, motion.Cue.SourceEnd);
            Assert.Equal(expected["scales"]!.AsArray().Select(scale => (double)scale!), motion.Cue.Keyframes.Select(frame => frame.Scale));
        }
        else if (expected["asset"] is { } asset)
        {
            var request = Assert.IsType<ClipAutopilotAction.Asset>(operation.Action);
            Assert.Equal((double)expected["start"]!, request.Start);
            Assert.Equal((double)expected["end"]!, request.End);
            Assert.Equal((string)asset!, request.Text);
        }
        else
        {
            var stored = Assert.IsType<ClipAutopilotAction.Effect>(operation.Action).Value;
            Assert.True(ClipEffects.IsValidEntry(stored, "b2ccf00a-0000-0000-0000-000000000001"));
            var overlay = ClipEffect.Parse(stored);
            Assert.Equal((double)expected["start"]!, overlay.Start);
            Assert.Equal((double)expected["end"]!, overlay.End);
            Assert.Equal((string)expected["overlayKind"]!, overlay.Kind);
            Assert.Equal((string?)expected["position"], overlay.Position);
            Assert.Equal((string?)expected["animation"], overlay.Animation);
            Assert.Equal((string?)expected["look"], stored.TryGetProperty("look", out var look) ? look.GetString() : null);
            Assert.Equal((double?)expected["rate"], stored.TryGetProperty("rate", out var rate) ? rate.GetDouble() : null);
        }
    }
}
