using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Effects;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class ClipPlanEffectTests
{
    public static IEnumerable<object[]> MotionTemplates() =>
        JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-effects/motion-template-cases.json"))!.AsArray()
            .Select(vector => new object[] { (string)vector!["template"]!["name"]!, vector.ToJsonString() });

    [Theory, MemberData(nameof(MotionTemplates))]
    public void ReplaysHarnessTemplateAsAClipScopedProjectEffect(string name, string raw)
    {
        const string clipId = "clip-2f1c";
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip"));
        var vector = JsonNode.Parse(raw)!;
        var entry = ClipPlanEffect.Read(vector);
        Assert.NotNull(entry);
        var words = project.Transcript!.Words;
        var clip = Assert.Single(project.Edits.Clips, clip => clip.Id == clipId);
        var scope = new WordSpan(words.ToList().FindIndex(word => word.Id == clip.StartWordId),
            words.ToList().FindIndex(word => word.Id == clip.EndWordId));
        var cut = project.Edits.CutWordIds.ToHashSet();
        var operation = entry.Operation("harness-test", clipId, scope, words, cut, new HashSet<int>(), new HashSet<string>());
        var overlay = Assert.IsType<ClipAutopilotAction.Effect>(operation?.Action);
        Assert.Equal(ClipAutopilotDecision.Overlay, operation!.Decision);
        var updated = ClipEffects.Adding([overlay.Value], project);
        var saved = ProjectSerialization.Serialize(updated);
        var restored = ProjectSerialization.Deserialize(saved);
        var effect = Assert.Single(ClipEffects.Rendered(restored, clipId));
        Assert.Equal("motionTemplate", effect.Kind);
        Assert.Equal(name, effect.Template?.Name);
        Assert.Equal(5.9, effect.Start);
        Assert.Equal(6.24, effect.End);
        Assert.True(JsonNode.DeepEquals(vector["template"], JsonNode.Parse(saved)!["clipEffects"]![0]!["template"]), name);
        Assert.Empty(ClipEffects.Rendered(restored, null));
        Assert.Null(entry.Operation("harness-test", clipId, scope, words, new HashSet<string> { "w11" },
            new HashSet<int>(), new HashSet<string>()));
    }

    [Fact]
    public void RejectsTheSharedMalformedMotionTemplates()
    {
        var invalid = JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-effects/motion-template-invalid-cases.json"))!.AsArray();
        foreach (var template in invalid)
        {
            var plan = new JsonObject { ["kind"] = "motionTemplate", ["startWord"] = 9, ["endWord"] = 10,
                ["reason"] = "Try a malformed template.", ["template"] = template!.DeepClone() };
            Assert.Null(ClipPlanEffect.Read(plan));
        }
    }

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
        else
        {
            var stored = Assert.IsType<ClipAutopilotAction.Effect>(operation.Action).Value;
            Assert.True(ClipEffects.IsValidEntry(stored, "b2ccf00a-0000-0000-0000-000000000001"));
            var overlay = ClipEffect.Parse(stored);
            Assert.Equal((double)expected["start"]!, overlay.Start);
            Assert.Equal((double)expected["end"]!, overlay.End);
            Assert.Equal((string)expected["overlayKind"]!, overlay.Kind);
            Assert.Equal((string)expected["position"]!, overlay.Position);
            Assert.Equal((string)expected["animation"]!, overlay.Animation);
        }
    }
}
