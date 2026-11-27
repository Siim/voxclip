#pragma warning disable CS1591
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

public enum AgentTurnError { WrongProject, UnknownTurn, UnknownChange, NotPending, Unavailable, InvalidPatch, Conflict, ConfirmationRequired, StalePlan, ThreadFull }
public sealed class AgentTurnException(AgentTurnError error, string? detail = null) : InvalidOperationException(detail ?? error.ToString())
{
    public AgentTurnError Error { get; } = error;
}

public static class AgentTurns
{
    public const string PrunedReason = "This turn is too old to undo from the chat. Undo its changes by hand, or use File › Revert To.";
    public sealed record Dependency(string TurnId, string? ChangeId, string UndoName, string? Target);

    public sealed class UndoPlan
    {
        public string TurnId { get; }
        public string? ChangeId { get; }
        public IReadOnlyList<Dependency> Dependants { get; }
        public IReadOnlyList<string> ConflictingPaths { get; }
        public bool RequiresConfirmation => Dependants.Count > 0 || ConflictingPaths.Count > 0;
        internal string ProjectId { get; }
        internal IReadOnlyList<AgentPatch> Checkpoint { get; }

        internal UndoPlan(string turnId, string? changeId, Dependency[] dependants, string[] conflictingPaths, string projectId, IReadOnlyList<AgentPatch> checkpoint)
        {
            TurnId = turnId;
            ChangeId = changeId;
            Dependants = Array.AsReadOnly(dependants);
            ConflictingPaths = Array.AsReadOnly(conflictingPaths);
            ProjectId = projectId;
            Checkpoint = checkpoint;
        }

        internal bool Matches(UndoPlan other) => ProjectId == other.ProjectId && Dependants.SequenceEqual(other.Dependants) &&
            ConflictingPaths.SequenceEqual(other.ConflictingPaths) && Checkpoint.Count == other.Checkpoint.Count &&
            Checkpoint.Zip(other.Checkpoint).All(pair =>
                (pair.First with { Before = default, After = default }) == (pair.Second with { Before = default, After = default }) &&
                JsonElement.DeepEquals(pair.First.Before, pair.Second.Before) && JsonElement.DeepEquals(pair.First.After, pair.Second.After));
    }

    public static AgentChange? Change(Project before, Project after, string id, string label, string undoName)
    {
        var patch = Diff(before, after);
        return patch.Count == 0 ? null : new(id, label, undoName, AgentChangeState.Applied, patch);
    }

    public static Project Record(AgentTurn turn, Project project, string threadId)
    {
        var thread = project.AgentThread ?? new(threadId, AgentMode.Propose, []);
        if (thread.Id != threadId) throw new AgentTurnException(AgentTurnError.WrongProject);
        turn = turn with { Summary = string.Concat(turn.Summary.EnumerateRunes().Take(600)), Steps = turn.Steps.TakeLast(24).ToArray() };
        var turns = thread.Turns.ToList();
        var index = turns.FindIndex(existing => existing.Id == turn.Id);
        if (index < 0) turns.Add(turn);
        else
        {
            if (index != turns.Count - 1 || turns[index].State != AgentTurnState.Running) throw new AgentTurnException(AgentTurnError.NotPending);
            turns[index] = turn;
        }
        return Finish(project, thread with { Turns = turns });
    }

    public static Project Keep(Project project, string turnId)
    {
        var thread = Thread(project);
        var index = Index(thread, turnId);
        var turns = thread.Turns.ToArray();
        if (!turns[index].IsPending) throw new AgentTurnException(AgentTurnError.NotPending);
        turns[index] = MarkKept(turns[index]);
        return Finish(project, thread with { Turns = turns });
    }

    public static Project KeepAll(Project project) => project.AgentThread is { } thread
        ? Finish(project, thread with { Turns = thread.Turns.Select(turn => turn.IsPending ? MarkKept(turn) : turn).ToArray() }) : project;

    public static Project RecoveringAfterRelaunch(Project project) => project.AgentThread is { } thread
        ? project with { AgentThread = thread with { Turns = thread.Turns.Select(turn => turn.State == AgentTurnState.Running
            ? turn with { State = AgentTurnState.Stopped } : turn).ToArray() } } : project;

    public static Project LogHandEdit(Project before, Project after, string undoName, string target, DateTimeOffset at)
    {
        if (before.AgentThread is not { Turns.Count: > 0 } thread) return after;
        var watched = thread.Turns.SelectMany(turn => turn.Changes).Where(change => change.State == AgentChangeState.Applied).SelectMany(change => change.Patch).ToArray();
        var patch = Diff(before, after).Where(item => watched.Any(other => AgentPatchPath.Overlaps(item, other))).ToArray();
        if (patch.Length == 0) return after;
        var turns = thread.Turns.ToArray();
        turns[^1] = turns[^1] with { Events = [.. turns[^1].Events, new(AgentEventKind.Hand, undoName, target, at, patch)] };
        return Finish(after, thread with { Turns = turns });
    }

    public static UndoPlan PlanUndo(Project project, string turnId, string? changeId = null) => PrepareUndo(project, turnId, changeId).Plan;

    public static Project Undo(Project project, UndoPlan plan, bool confirmed = false)
    {
        var prepared = PrepareUndo(project, plan.TurnId, plan.ChangeId);
        if (!prepared.Plan.Matches(plan)) throw new AgentTurnException(AgentTurnError.StalePlan);
        if (plan.RequiresConfirmation && !confirmed) throw new AgentTurnException(AgentTurnError.ConfirmationRequired);
        return Finish(ProjectFrom(prepared.Document), prepared.Thread);
    }

    public static Project Redo(Project project, string turnId, string changeId)
    {
        var thread = Thread(project);
        var turnIndex = Index(thread, turnId);
        var turns = thread.Turns.ToArray();
        var changes = turns[turnIndex].Changes.ToList();
        var changeIndex = changes.FindIndex(change => change.Id == changeId);
        if (changeIndex < 0) throw new AgentTurnException(AgentTurnError.UnknownChange);
        var change = changes[changeIndex];
        if (change.Patch.Count == 0) throw new AgentTurnException(AgentTurnError.Unavailable, PrunedReason);
        if (change.State != AgentChangeState.Undone) throw new AgentTurnException(AgentTurnError.UnknownChange);
        var wire = Document(project);
        foreach (var patch in change.Patch) AgentPatchPath.Apply(patch, wire, reverse: false);
        changes[changeIndex] = change with { State = AgentChangeState.Applied };
        turns[turnIndex] = RefreshState(turns[turnIndex] with { Changes = changes });
        return Finish(ProjectFrom(wire), thread with { Turns = turns });
    }

    public static Project Revise(Project project, Project proposed, string turnId, string revisionId, string changeId, string label, string undoName)
    {
        var thread = Thread(project);
        var index = Index(thread, turnId);
        var turns = thread.Turns.ToArray();
        if (!turns[index].IsPending) throw new AgentTurnException(AgentTurnError.NotPending);
        var prepared = PrepareUndo(project, turnId, null);
        if (prepared.Plan.RequiresConfirmation) throw new AgentTurnException(AgentTurnError.ConfirmationRequired);
        var revised = Change(ProjectFrom(prepared.Document), proposed, changeId, label, undoName);
        var later = turns.Skip(index + 1).SelectMany(turn => turn.Changes).Where(change => change.State == AgentChangeState.Applied).SelectMany(change => change.Patch).ToArray();
        var conflict = Diff(project, proposed).FirstOrDefault(item => later.Any(other => AgentPatchPath.Overlaps(item, other)));
        if (conflict is not null) throw new AgentTurnException(AgentTurnError.Conflict, conflict.Path);
        turns[index] = turns[index] with { Changes = revised is null ? [] : [revised], RevisionOf = revisionId, State = AgentTurnState.Pending };
        return Finish(proposed, thread with { Turns = turns });
    }

    private sealed record UndoAction(int Turn, int Index, bool Change, IReadOnlyList<AgentPatch> Patch, Dependency? Dependency);

    private static (UndoPlan Plan, JsonObject Document, AgentThread Thread) PrepareUndo(Project project, string turnId, string? changeId)
    {
        var thread = Thread(project);
        var start = Index(thread, turnId);
        var target = thread.Turns[start];
        var selected = target.Changes.Index().Where(item => item.Item.State == AgentChangeState.Applied && (changeId is null || item.Item.Id == changeId)).ToArray();
        if (selected.Length == 0) throw new AgentTurnException(AgentTurnError.UnknownChange);
        if (selected.Any(item => item.Item.Patch.Count == 0)) throw new AgentTurnException(AgentTurnError.Unavailable, PrunedReason);
        var paths = selected.SelectMany(item => item.Item.Patch).ToList();
        var actions = new List<UndoAction>();
        for (var turnIndex = start; turnIndex < thread.Turns.Count; turnIndex++)
        {
            var turn = thread.Turns[turnIndex];
            foreach (var (index, change) in turn.Changes.Index())
            {
                if (change.State != AgentChangeState.Applied || (turnIndex == start && index < selected[0].Index)) continue;
                var own = turnIndex == start && selected.Any(item => item.Index == index);
                if (!own && !change.Patch.Any(item => paths.Any(other => AgentPatchPath.Overlaps(item, other)))) continue;
                actions.Add(new(turnIndex, index, true, change.Patch, own ? null : new(turn.Id, change.Id, change.UndoName, null)));
                if (!own) paths.AddRange(change.Patch);
            }
            foreach (var (index, item) in turn.Events.Index())
            {
                if (item.Kind != AgentEventKind.Hand || item.Patch is null) continue;
                var relevant = item.Patch.Where(patch => paths.Any(other => AgentPatchPath.Overlaps(patch, other))).ToArray();
                if (relevant.Length == 0) continue;
                actions.Add(new(turnIndex, index, false, relevant, new(turn.Id, null, item.UndoName, item.Target)));
                paths.AddRange(relevant);
            }
        }
        var wire = Document(project);
        var conflicts = new List<string>();
        var turns = thread.Turns.ToArray();
        foreach (var action in actions.AsEnumerable().Reverse())
        {
            foreach (var patch in action.Patch.Reverse())
            {
                try { AgentPatchPath.Apply(patch, wire, reverse: true); }
                catch (AgentTurnException exception) when (exception.Error == AgentTurnError.Conflict)
                {
                    AgentPatchPath.Apply(patch, wire, reverse: true, force: true);
                    if (!conflicts.Contains(patch.Path, StringComparer.Ordinal)) conflicts.Add(patch.Path);
                }
            }
            var turn = turns[action.Turn];
            if (action.Change)
            {
                var changes = turn.Changes.ToArray();
                changes[action.Index] = changes[action.Index] with { State = AgentChangeState.Undone };
                turns[action.Turn] = turn with { Changes = changes, WasKept = turn.State == AgentTurnState.Kept ? true : turn.WasKept };
            }
            else
            {
                var events = turn.Events.ToList();
                var remaining = events[action.Index].Patch!.Except(action.Patch).ToArray();
                if (remaining.Length == 0) events.RemoveAt(action.Index);
                else events[action.Index] = events[action.Index] with { Patch = remaining };
                turns[action.Turn] = turn with { Events = events };
            }
        }
        foreach (var index in actions.Where(action => action.Change).Select(action => action.Turn).Distinct()) turns[index] = RefreshState(turns[index]);
        return (new UndoPlan(turnId, changeId, actions.Select(action => action.Dependency).OfType<Dependency>().ToArray(), conflicts.ToArray(),
            project.Id, actions.SelectMany(action => action.Patch).ToArray()), wire, thread with { Turns = turns });
    }

    private static AgentTurn MarkKept(AgentTurn turn) => turn with { WasKept = true, State = turn.State == AgentTurnState.Partial ? turn.State : AgentTurnState.Kept };

    private static AgentTurn RefreshState(AgentTurn turn)
    {
        var applied = turn.Changes.Count(change => change.State == AgentChangeState.Applied);
        return turn with { State = applied == 0 ? AgentTurnState.Undone : applied != turn.Changes.Count ? AgentTurnState.Partial :
            turn.WasKept == true ? AgentTurnState.Kept : AgentTurnState.Pending };
    }

    private static AgentThread Thread(Project project) => project.AgentThread ?? throw new AgentTurnException(AgentTurnError.UnknownTurn);

    private static int Index(AgentThread thread, string id)
    {
        foreach (var (index, turn) in thread.Turns.Index()) if (turn.Id == id) return index;
        throw new AgentTurnException(AgentTurnError.UnknownTurn);
    }

    private static Project Finish(Project project, AgentThread source)
    {
        var turns = source.Turns.ToList();
        while (turns.Count > AgentThreadWire.MaxTurns)
        {
            var index = turns.FindIndex(turn => !turn.IsPending && turn.State != AgentTurnState.Running);
            if (index < 0) throw new AgentTurnException(AgentTurnError.ThreadFull);
            turns.RemoveAt(index);
        }
        var kept = turns.Index().Where(item => item.Item.State == AgentTurnState.Kept || item.Item.WasKept == true).ToArray();
        foreach (var (index, turn) in kept.SkipLast(AgentThreadWire.MaxKeptCheckpoints)) turns[index] = Prune(turn);
        var thread = source with { Turns = turns };
        for (var index = 0; index < turns.Count && AgentThreadWire.Size(thread) > AgentThreadWire.MaxBytes; index++)
        {
            var turn = turns[index] with { Steps = [] };
            turns[index] = !turn.IsPending && turn.State != AgentTurnState.Running ? Prune(turn) : turn;
        }
        if (AgentThreadWire.Size(thread) > AgentThreadWire.MaxBytes) throw new AgentTurnException(AgentTurnError.ThreadFull);
        var result = ProjectSerialization.ForWriting(project with { AgentThread = thread with { Turns = turns.AsReadOnly() } });
        _ = ProjectSerialization.Serialize(result);
        return result;
    }

    private static AgentTurn Prune(AgentTurn turn) => turn with { Changes = turn.Changes.Select(change => change with { Patch = [] }).ToArray(),
        Events = turn.Events.Select(item => item with { Patch = null }).ToArray() };

    private static IReadOnlyList<AgentPatch> Diff(Project before, Project after)
    {
        if (before.Id != after.Id) throw new AgentTurnException(AgentTurnError.WrongProject);
        var old = Document(before);
        var next = Document(after);
        var patches = new List<AgentPatch>();
        foreach (var root in AgentPatchPath.Roots.Order(StringComparer.Ordinal))
        {
            if (root == "voiceLab")
            {
                var older = old[root]!.AsObject();
                var newer = next[root]!.AsObject();
                foreach (var key in AgentPatchPath.VoiceUses.Order(StringComparer.Ordinal))
                    AgentPatchPath.Diff(older[key], older.ContainsKey(key), newer[key], newer.ContainsKey(key), $"/{root}/{key}", patches);
            }
            else AgentPatchPath.Diff(old[root], old.ContainsKey(root), next[root], next.ContainsKey(root), $"/{root}", patches);
        }
        if (patches.FirstOrDefault(item => !AgentPatchPath.IsValid(item)) is { } invalid) throw new AgentTurnException(AgentTurnError.InvalidPatch, invalid.Path);
        return patches.AsReadOnly();
    }

    private static JsonObject Document(Project project)
    {
        if (project.SchemaVersion < 4) project = ContextDemoProject.UpgradeToV4(project);
        var wire = JsonSerializer.SerializeToNode(project with { AgentThread = null }, ProjectJsonContext.Default.Project)!.AsObject();
        foreach (var root in AgentPatchPath.OptionalCollections) if (!wire.ContainsKey(root)) wire[root] = new JsonArray();
        return wire;
    }

    private static Project ProjectFrom(JsonObject document) => document.Deserialize(ProjectJsonContext.Default.Project)!;
}
