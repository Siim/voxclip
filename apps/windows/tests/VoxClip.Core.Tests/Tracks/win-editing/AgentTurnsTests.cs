using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class AgentTurnsTests
{
    private static readonly DateTimeOffset At = DateTimeOffset.FromUnixTimeSeconds(1_795_790_000);

    [Fact]
    public void SharedPatchCases()
    {
        var basis = Basis();
        foreach (var fixture in Cases("patch-cases.json"))
        {
            var before = fixture["before"] is { } overrides ? Setting(overrides, basis) : basis;
            var after = Setting(fixture["after"]!, before);
            var change = AgentTurns.Change(before, after, "change", Text(fixture, "name"), "Edit clip");
            var actual = change is null ? new JsonArray() : JsonSerializer.SerializeToNode(before with {
                AgentThread = new("th-test", AgentMode.Propose, [Turn("t1", [change])]) }, ProjectJsonContext.Default.Project)!["agentThread"]!["turns"]![0]!["changes"]![0]!["patch"];
            Assert.True(JsonNode.DeepEquals(fixture["patch"], actual), $"{fixture["name"]}: {actual}");
            if (change is null) continue;
            var recorded = Record("t1", [change], after);
            var undone = AgentTurns.Undo(recorded, AgentTurns.PlanUndo(recorded, "t1", "change"));
            Assert.Equal(EditingBytes(before), EditingBytes(undone));
            Assert.Equal(EditingBytes(after), EditingBytes(AgentTurns.Redo(undone, "t1", "change")));
        }
    }

    [Fact]
    public void SharedUndoCases()
    {
        var basis = Basis();
        foreach (var fixture in Cases("undo-cases.json"))
        {
            var project = basis;
            foreach (var turn in Items(fixture, "turns"))
            {
                var changes = new List<AgentChange>();
                foreach (var edit in Items(turn, "changes"))
                {
                    var after = Setting(edit["set"]!, project);
                    var id = Text(edit, "id");
                    changes.Add(Assert.IsType<AgentChange>(AgentTurns.Change(project, after, id, id, id)));
                    project = after;
                }
                project = Record(Text(turn, "id"), changes, project);
                if (turn["hand"] is { } hand) project = AgentTurns.LogHandEdit(project, Setting(hand["set"]!, project), "Hand edit", Text(hand, "target"), At);
            }
            if (fixture["unlogged"] is { } unlogged) project = Setting(unlogged, project);
            var wire = ProjectSerialization.Serialize(project);
            project = ProjectSerialization.Deserialize(wire);
            Assert.Equal(wire, ProjectSerialization.Serialize(project));
            var turnId = Text(fixture, "turnId");
            var changeId = fixture["changeId"]?.GetValue<string>();
            var plan = AgentTurns.PlanUndo(project, turnId, changeId);
            Assert.Equal(Strings(fixture, "dependants"), plan.Dependants.Select(item => item.ChangeId ?? item.Target));
            Assert.Equal(Strings(fixture, "conflicts"), plan.ConflictingPaths);
            if (Strings(fixture, "dependants").Any() || Strings(fixture, "conflicts").Any())
                Assert.Equal(AgentTurnError.ConfirmationRequired, Assert.Throws<AgentTurnException>(() => AgentTurns.Undo(project, plan)).Error);
            var undone = AgentTurns.Undo(project, plan, confirmed: plan.RequiresConfirmation);
            Assert.Equal(Strings(fixture, "states"), undone.AgentThread!.Turns.Select(turn => JsonNamingPolicy.CamelCase.ConvertName(turn.State.ToString())));
            Assert.All(undone.AgentThread.Turns, turn => Assert.Empty(turn.Events));
            Assert.Equal(EditingBytes(Setting(fixture["expected"]!, basis)), EditingBytes(undone));
            if (fixture["redo"]?.GetValue<bool>() == true && changeId is not null)
                Assert.Equal(wire, ProjectSerialization.Serialize(AgentTurns.Redo(undone, turnId, changeId)));
        }
    }

    [Fact]
    public void RevisionRetainsTheOriginalBeforeValueAndKeepDoesNotEdit()
    {
        var basis = Basis();
        var first = Setting(JsonNode.Parse("""{"captions":{"styleId":"off"}}""")!, basis);
        var change = Assert.IsType<AgentChange>(AgentTurns.Change(basis, first, "style", "Style", "Style"));
        var pending = Record("t1", [change], first);
        var proposed = Setting(JsonNode.Parse("""{"captions":{"styleId":"vox-bold"}}""")!, pending);
        var revised = AgentTurns.Revise(pending, proposed, "t1", "follow-up", "style", "Style", "Style");
        Assert.Equal("follow-up", Assert.Single(revised.AgentThread!.Turns).RevisionOf);
        var kept = AgentTurns.KeepAll(revised);
        Assert.Equal(AgentTurnState.Kept, Assert.Single(kept.AgentThread!.Turns).State);
        Assert.Equal(EditingBytes(revised), EditingBytes(kept));
        Assert.Equal(AgentTurnError.NotPending, Assert.Throws<AgentTurnException>(() =>
            AgentTurns.Revise(kept, proposed, "t1", "another", "style", "Style", "Style")).Error);
        Assert.Equal(EditingBytes(basis), EditingBytes(AgentTurns.Undo(kept, AgentTurns.PlanUndo(kept, "t1"))));
    }

    [Fact]
    public void KeepPrunesTheThirtyFirstKeptCheckpointButNeverAPendingOne()
    {
        var before = Basis();
        var after = Setting(JsonNode.Parse("""{"captions":{"styleId":"off"}}""")!, before);
        var change = Assert.IsType<AgentChange>(AgentTurns.Change(before, after, "style", "Style", "Style"));
        var project = Record("pending", [change], after);
        for (var index = 1; index <= 31; index++) project = AgentTurns.Keep(Record($"kept-{index}", [change], project), $"kept-{index}");
        Assert.Single(project.AgentThread!.Turns[0].Changes[0].Patch);
        Assert.Empty(project.AgentThread.Turns[1].Changes[0].Patch);
        Assert.Equal("Changed the edit", project.AgentThread.Turns[1].Summary);
        Assert.Single(project.AgentThread.Turns[2].Changes[0].Patch);
        var error = Assert.Throws<AgentTurnException>(() => AgentTurns.PlanUndo(project, "kept-1"));
        Assert.Equal(AgentTurnError.Unavailable, error.Error);
        Assert.Equal(AgentTurns.PrunedReason, error.Message);
    }

    private static AgentTurn Turn(string id, IReadOnlyList<AgentChange> changes) => new(id, AgentTurnKind.Agent, At,
        new("Edit this", []), "claude-code", "default", "Changed the edit", [], AgentTurnState.Pending, changes, [], []);

    private static Project Record(string id, IReadOnlyList<AgentChange> changes, Project project) => AgentTurns.Record(Turn(id, changes), project, "th-test");

    private static Project Basis()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "clip-from-long-take.voxclip")));
        return ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project with { AgentThread = new("th-test", AgentMode.Propose, []) }));
    }

    private static string EditingBytes(Project project) => ProjectSerialization.Serialize(project with { AgentThread = project.AgentThread! with { Turns = [] } });

    private static Project Setting(JsonNode changes, Project project)
    {
        static void Merge(JsonObject basis, JsonObject changes)
        {
            foreach (var (key, value) in changes)
            {
                if (basis[key] is JsonObject oldObject && value is JsonObject newObject) Merge(oldObject, newObject);
                else basis[key] = value?.DeepClone();
            }
        }
        var document = JsonNode.Parse(ProjectSerialization.Serialize(project))!.AsObject();
        Merge(document, changes.AsObject());
        return ProjectSerialization.Deserialize(document.ToJsonString());
    }

    private static IEnumerable<JsonNode> Cases(string name) => JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "agent-chat", name)))!.AsArray().OfType<JsonNode>();
    private static string Text(JsonNode node, string key) => node[key]!.GetValue<string>();
    private static IEnumerable<JsonNode> Items(JsonNode node, string key) => node[key]?.AsArray().OfType<JsonNode>() ?? [];
    private static IEnumerable<string> Strings(JsonNode node, string key) => Items(node, key).Select(item => item.GetValue<string>());
}
