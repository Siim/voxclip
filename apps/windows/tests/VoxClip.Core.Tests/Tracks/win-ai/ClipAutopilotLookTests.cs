using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Services.Project;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.ClipAutopilotTests;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The planner's look (looks spec 2026-11-28, sections 9.1–9.5), twin of the Mac <c>ClipAutopilotLookTests</c>: prompt version 14
/// lists the visible looks of shared/looks/clip-looks.json, the reply's look, amount, fix and alternatives are checked against it, and
/// plan version 5 keeps them. Shared vectors: shared/fixtures/autopilot/plan-look-cases.json.</summary>
public sealed class ClipAutopilotLookTests
{
    private static ClipAutopilotContext WithFrames(JsonNode? frames)
    {
        var context = Context(new(0, 29));
        if (frames is not JsonArray items) return context;
        var sheet = items.Select((light, index) => new FrameSheetFrame(index + 1,
            new FrameObservation(index) { Light = light is null ? null : FrameJson.ReadLight(light) ?? throw new InvalidDataException("light") }, [], 320, 180)).ToArray();
        return context with { Frames = new ClipAutopilotFrames("", [], [], [], 0) { Frames = sheet } };
    }

    [Fact]
    public void ThePromptListsExactlyTheVisibleLooks()
    {
        var prompt = ClipAutopilotPrompt.Load(Root);
        var library = ClipLookLibrary.Load(Root);
        Assert.Equal(14, prompt.PromptVersion);
        Assert.Equal(library.Visible.Select(look => look.Id), prompt.Looks);
        var document = JsonNode.Parse(File.ReadAllText(Path.Combine(Root, ClipAutopilotPrompt.Path)))!.AsObject();
        Assert.Equal(3, document["schemaVersion"]!.GetValue<int>());
        foreach (var (item, look) in document["looks"]!.AsArray().Zip(library.Visible))
        {
            var line = item!["line"]!.GetValue<string>();
            Assert.StartsWith($"{look.Id}: {look.Label} (", line, StringComparison.Ordinal);
            Assert.Contains(look.Line, line, StringComparison.Ordinal);
            Assert.EndsWith($"Start at {look.PlannerAmount}.", line, StringComparison.Ordinal);
            Assert.Contains("\n- " + line, prompt.System, StringComparison.Ordinal);
        }
        Assert.Contains("Use the frames' light notes", prompt.System, StringComparison.Ordinal);
        Assert.DoesNotContain("You cannot see the footage", prompt.System, StringComparison.Ordinal);
        Assert.Contains("Never choose or describe a look by skin colour.", prompt.System, StringComparison.Ordinal);
        var required = prompt.Schema["required"]!.AsArray().Select(item => item!.GetValue<string>()).ToHashSet();
        Assert.Superset(new HashSet<string> { "look", "lookAmount", "lookFix", "lookAlternatives", "lookReason" }, required);
    }

    [Fact]
    public void APromptWhoseLooksAreNotTheLibrarysRefusesToLoad()
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(Root, ClipAutopilotPrompt.Path)))!.AsObject();
        var library = ClipLookLibrary.Load(Root);
        _ = new ClipAutopilotPrompt(root.DeepClone().AsObject(), "", library);
        var broken = root.DeepClone().AsObject();
        broken["looks"] = new JsonArray(root["looks"]!.AsArray().Where(item => item!["id"]!.GetValue<string>() != "softSkin").Select(item => item!.DeepClone()).ToArray());
        Assert.Throws<Domain.Shared.VoxClipException>(() => new ClipAutopilotPrompt(broken, "", library));
        broken = root.DeepClone().AsObject();
        broken["looks"]!.AsArray().Add(new JsonObject { ["id"] = "neonDream", ["line"] = "neonDream: Neon" });
        Assert.Throws<Domain.Shared.VoxClipException>(() => new ClipAutopilotPrompt(broken, "", library));
        broken = root.DeepClone().AsObject();
        broken["schemaVersion"] = 2;
        Assert.Throws<Domain.Shared.VoxClipException>(() => new ClipAutopilotPrompt(broken, "", library));
    }

    [Fact]
    public void TheReplysLookReplays()
    {
        var fixture = Fixture("plan-look-cases.json");
        var library = ClipLookLibrary.Load(Root);
        var bytes = File.ReadAllBytes(Path.Combine(Root, ClipLookLibrary.Path));
        var normal = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace("\r\n", "\n", StringComparison.Ordinal));
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(normal)), fixture["sources"]!["shared/looks/clip-looks.json"]!.GetValue<string>());
        Assert.Equal(ClipAutopilotValidator.DimFaceLooks, fixture["dimFaceLooks"]!.AsArray().Select(item => item!.GetValue<string>()));
        Assert.Equal(ClipAutopilotValidator.DimFaceReplacement, fixture["dimFaceReplacement"]!.GetValue<string>());
        var cases = fixture["cases"]!.AsArray();
        Assert.Equal(21, cases.Count);
        foreach (var item in cases)
        {
            var id = item!["id"]!.GetValue<string>();
            var log = new ClipAutopilotValidator.Log();
            var look = ClipAutopilotValidator.Look(item["reply"], WithFrames(item["frames"]), log);
            var expect = item["expect"]!["look"]!;
            Assert.True(look.Id == expect["id"]!.GetValue<string>() && look.Amount == expect["amount"]!.GetValue<int>(), $"{id}: {look}");
            Assert.True(look.Fix == expect["fix"]!.GetValue<bool>() && look.Reason == expect["reason"]!.GetValue<string>(), $"{id}: {look}");
            Assert.True(look.Alternatives.SequenceEqual(expect["alternatives"]!.AsArray().Select(alternative => alternative!.GetValue<string>())), id);
            Assert.NotNull(library.Look(look.Id));
            var repairs = log.Repairs.Select(repair => repair.Field + "|" + (repair.Dropped ? "dropped" : "repaired")).Order(StringComparer.Ordinal);
            var wanted = item["expect"]!["repairs"]!.AsArray().Select(pair => pair![0]!.GetValue<string>() + "|" + pair[1]!.GetValue<string>()).Order(StringComparer.Ordinal);
            Assert.True(repairs.SequenceEqual(wanted), $"{id}: {string.Join(", ", repairs)}");
        }
    }

    /// <summary>Plan version 5 keeps the look's amount, Fix and alternatives; a version 4 plan reads with the whole look, no Fix and no
    /// alternatives, and its four look IDs are looks of the library.</summary>
    [Fact]
    public void AVersionFourPlanReadsWithTheWholeLook()
    {
        Assert.Equal(5, ClipAutopilotPlan.CurrentVersion);
        var old = ClipAutopilotPlan.Look.FromJson(JsonNode.Parse("""{"id":"warm","reason":"Friendly"}""")!);
        Assert.Equal(new ClipAutopilotPlan.Look(ClipLook.Warm, "Friendly"), old);
        Assert.Equal((100, false, 0), (old.Amount, old.Fix, old.Alternatives.Count));
        var library = ClipLookLibrary.Load(Root);
        foreach (var look in Enum.GetValues<ClipLook>()) Assert.Equal(look, library.Look(look.Name())!.Base);
        var fresh = new ClipAutopilotPlan.Look("warmPrint", "Memories") { Amount = 70, Fix = true, Alternatives = ["goldenHour"] };
        Assert.Equal("""{"id":"warmPrint","amount":70,"fix":true,"alternatives":["goldenHour"],"reason":"Memories"}""", fresh.ToJson().ToJsonString());
        Assert.Equal(fresh, ClipAutopilotPlan.Look.FromJson(fresh.ToJson()));
        Assert.Equal("""{"id":"warm","reason":"Friendly"}""", old.ToJson().ToJsonString());
        Assert.Equal(new ClipAutopilotPlan.Look("warmPrint", "Memories") { Amount = 70 }, fresh.ToProposal());
    }
}
