using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Services.Project;
using ClipProject = VoxClip.Core.Domain.Shared.Project;

namespace VoxClip.Core.Services.LLM;

public sealed partial class AgentChatSession
{
    private static readonly JsonElement EmptyArguments = JsonSerializer.SerializeToElement(new { });

    private async Task PerformAsync(AgentChatReply.Call call, Run run, bool stale, CancellationToken ct)
    {
        var stopwatch = Stopwatch.StartNew();
        var snapshot = Project;
        var candidate = snapshot;
        var turn = run.Turn;
        JsonObject output;
        var ok = false;
        try
        {
            if (!HarnessToolDefinition.AgentTools.TryGetValue(call.Tool, out var tool)) throw new HarnessException($"Unknown tool: {call.Tool}");
            if (tool == HarnessTool.ProposeTimeline && stale) throw new HarnessException("stale: the words changed");
            if (tool == HarnessTool.ProposeTimeline && Mode == AgentMode.AskFirst) throw new HarnessException("Waiting for Go.");
            var arguments = JsonSerializer.SerializeToElement(call.Args);
            var revision = tool == HarnessTool.ProposeTimeline ? HarnessChatTools.Timeline(arguments).Revises : null;
            var basis = snapshot;
            if (revision is not null)
            {
                if (snapshot.AgentThread?.Turns.FirstOrDefault(item => item.Id == revision)?.IsPending != true)
                    throw new HarnessException($"Turn {revision[1..]} is already kept. Propose a new change instead.");
                basis = AgentTurns.Undo(snapshot, AgentTurns.PlanUndo(snapshot, revision));
            }
            var result = await HarnessTools.Call(tool, arguments, basis, sharedRoot, projectPath, cache, decodeFrames, music, check, LiveContext.CapLeft, ct: ct);
            if (stopping || ct.IsCancellationRequested) return;
            if (tool == HarnessTool.ProposeTimeline && snapshot != Project) throw new HarnessException("stale: the words changed");
            candidate = Project;
            output = AgentChatPrompt.Json(result.Fields)!.AsObject();
            var firstOffer = turn.Offers.Count;
            if (result.Proposal is { } wire)
                (candidate, turn) = Apply(HarnessProposal.Read(JsonSerializer.SerializeToElement(wire)), result, output, basis, candidate, turn, revision, run);
            if (tool == HarnessTool.Offer)
                turn = turn with { Offers = [.. turn.Offers, AgentOfferCatalog.Make($"{turn.Id}-o{turn.Offers.Count + 1}", output, candidate)] };
            if (tool == HarnessTool.Check) turn = turn with { Check = ReadCheck(output["checks"]) };
            if (tool == HarnessTool.ReadFrames)
                run.Images = (result.Frames ?? []).Take(4).Select(frame => new LlmImage($"Source frame at {frame.Actual} seconds",
                    "image/jpeg", Convert.FromBase64String(frame.Jpeg), 0, 0)).ToArray();
            if (turn.Offers.Count > firstOffer)
            {
                output.Remove("offerId");
                output["offers"] = AgentChatPrompt.Json(turn.Offers.Skip(firstOffer).ToArray());
            }
            var refusal = AgentChatPrompt.String((output["refusals"] as JsonArray)?.LastOrDefault()?["reason"]);
            if (refusal is not null || run.RefusedTool == call.Tool)
            {
                run.Refusal = refusal;
                run.RefusedTool = refusal is null ? null : call.Tool;
            }
            ok = refusal is null;
        }
        catch (Exception error)
        {
            if (stopping || ct.IsCancellationRequested) return;
            candidate = Project;
            turn = run.Turn;
            var refusal = error is HarnessException ? error.Message : "The change was refused.";
            run.Refusal = refusal;
            run.RefusedTool = call.Tool;
            output = new() { ["refusal"] = refusal };
        }
        var digest = string.Concat(AgentChatPrompt.Text(output).EnumerateRunes().Take(240).Select(rune => rune.ToString()));
        turn = turn with { Steps = [.. turn.Steps, new(call.Tool, ok, digest, (int)Math.Min(int.MaxValue, stopwatch.ElapsedMilliseconds))] };
        run.Results.Add(new JsonObject { ["tool"] = call.Tool, ["args"] = call.Args.DeepClone(), ["result"] = output, ["ok"] = ok });
        Save(turn, candidate);
        run.Turn = turn;
    }

    private (ClipProject Project, AgentTurn Turn) Apply(HarnessProposal proposal, HarnessResult result, JsonObject fields, ClipProject basis,
        ClipProject live, AgentTurn turn, string? revision, Run run)
    {
        var refused = (fields["refusals"] as JsonArray ?? []).Select(refusal => refusal?["timelineIndex"]?.GetValue<int>()).ToHashSet();
        var labels = fields["labels"] as JsonArray ?? [];
        var edited = basis;
        for (var index = 0; index < proposal.Timelines.Count; index++)
        {
            if (refused.Contains(index)) continue;
            var timeline = proposal.Timelines[index];
            var single = new HarnessProposal(timeline, edited);
            var transcript = timeline.RecordingKey is { } key ? HarnessRecording.CachedTranscript(key, cache ?? DataLocations.Resolve().Cache) : null;
            var review = single.Review(edited, sharedRoot, recordingTranscript: transcript, preparedMusic: result.PreparedMusic);
            var label = (index < labels.Count ? AgentChatPrompt.String(labels[index]) : null) ?? timeline.Reason;
            if (revision is null && AgentTurns.Change(edited, review.Project, $"{turn.Id}-c{turn.Changes.Count + 1}", label, "Agent edit") is { } change)
                turn = turn with { Changes = [.. turn.Changes, change] };
            var oldClips = edited.Edits.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
            var target = timeline.ClipId.Length == 0 ? review.Project.Edits.Clips.FirstOrDefault(clip => !oldClips.Contains(clip.Id))?.Id : timeline.ClipId;
            if (target is not null)
            {
                foreach (var action in fields["pricedActions"] as JsonArray ?? [])
                {
                    if (action?["timelineIndex"]?.GetValue<int>() != index || AgentChatPrompt.String(action["kind"]) is not { } kind) continue;
                    var offerFields = new JsonObject { ["kind"] = kind == "generateIllustration" ? "illustration" : kind,
                        ["target"] = target, ["brief"] = action["prompt"]?.DeepClone(), ["quote"] = action["price"]?.DeepClone() };
                    try { turn = turn with { Offers = [.. turn.Offers, AgentOfferCatalog.Make($"{turn.Id}-o{turn.Offers.Count + 1}", offerFields, review.Project)] }; }
                    catch (HarnessException) { }
                }
            }
            edited = review.Project;
        }
        if (Mode == AgentMode.Claude) turn = turn with { WasKept = true };
        if (revision is null) return (edited, turn);
        if (edited == basis) return (live, turn);
        var revised = AgentTurns.Revise(live, edited, revision, turn.Id, $"{revision}-{turn.Id}",
            AgentChatPrompt.String(labels.FirstOrDefault()) ?? proposal.Timelines[0].Reason, "Revise agent edit");
        if (Mode == AgentMode.Claude) return (AgentTurns.Keep(revised, revision), turn);
        run.Claims.AddRange(AgentChatMatch.Kinds(revised.AgentThread?.Turns.FirstOrDefault(item => item.Id == revision)?.Changes ?? []));
        return (revised, turn);
    }

    private static AgentCheck? ReadCheck(JsonNode? value) => value is JsonObject fields && fields["ok"] is JsonValue ok && ok.TryGetValue<bool>(out var flag)
        ? new(flag, (fields["lines"] as JsonArray ?? []).Select(AgentChatPrompt.String).OfType<string>().ToArray()) : null;

    private async Task<JsonObject> DigestAsync(CancellationToken ct)
    {
        var snapshot = Project;
        var clip = OpenClipId;
        var listing = await ReadAsync(HarnessTool.ReadClips, EmptyArguments);
        var digest = new JsonObject { ["mode"] = AgentChatPrompt.Json(Mode), ["openClip"] = clip, ["playhead"] = LiveContext.Playhead,
            ["capLeft"] = LiveContext.CapLeft?.ToString(CultureInfo.InvariantCulture) };
        void Add(string name, JsonNode? value)
        {
            var proposed = digest.DeepClone().AsObject();
            proposed[name] = value;
            if (Encoding.UTF8.GetByteCount(AgentChatPrompt.Text(proposed)) <= 3_000) digest = proposed;
        }
        void AddRows(string name, IEnumerable<JsonNode?> rows)
        {
            foreach (var row in rows)
            {
                var kept = (digest[name] as JsonArray)?.DeepClone().AsArray() ?? [];
                kept.Add(row?.DeepClone());
                Add(name, kept);
            }
        }
        AddRows("selection", (LiveContext.Selection ?? []).Select(AgentChatPrompt.Json));
        Add("style", AgentChatPrompt.Json(snapshot.ClipStyle));
        if (clip is not null && await ReadAsync(HarnessTool.ReadDecisions, JsonSerializer.SerializeToElement(new { clipId = clip })) is { } decisions)
            Add("openClipDecisions", decisions);
        AddRows("recordings", listing?["recordings"] as JsonArray ?? []);
        AddRows("clips", (listing?["clips"] as JsonArray ?? []).OrderByDescending(row => AgentChatPrompt.String(row?["id"]) == clip));
        var turns = snapshot.AgentThread?.Turns ?? [];
        AddRows("pending", turns.Where(turn => turn.IsPending).Select(turn => AgentChatPrompt.Json(new { id = turn.Id, changes = turn.Changes.Select(change => change.Label) })));
        AddRows("handEdits", turns.TakeLast(2).SelectMany(turn => turn.Events).Where(item => item.Kind == AgentEventKind.Hand)
            .Select(item => AgentChatPrompt.Json(new { name = item.UndoName, target = item.Target })));
        return digest;

        async Task<JsonNode?> ReadAsync(HarnessTool tool, JsonElement arguments)
        {
            try { return AgentChatPrompt.Json((await HarnessTools.Call(tool, arguments, snapshot, sharedRoot, ct: ct)).Fields); }
            catch (HarnessException) { return null; }
        }
    }

    private JsonArray History(string currentId)
    {
        var turns = (Project.AgentThread?.Turns ?? []).Where(turn => turn.Id != currentId).TakeLast(30).ToArray();
        return new(turns.Select((turn, index) =>
        {
            var fields = new JsonObject { ["id"] = turn.Id, ["user"] = turn.Request.Text, ["summary"] = turn.Summary };
            if (index >= turns.Length - 6)
            {
                fields["state"] = AgentChatPrompt.Json(turn.State);
                fields["changes"] = AgentChatPrompt.Json(turn.Changes.Select(change => new { label = change.Label, state = change.State }));
                fields["offers"] = AgentChatPrompt.Json(turn.Offers);
                fields["events"] = AgentChatPrompt.Json(turn.Events.Select(item => new { kind = item.Kind, name = item.UndoName, target = item.Target }));
            }
            return (JsonNode)fields;
        }).ToArray());
    }
}

internal static class AgentChatMatch
{
    private static readonly (string Name, string[] Mentions, string[] Paths)[] Categories =
    [
        ("music", ["music", "soundtrack", "track"], ["music"]),
        ("captions", ["caption", "subtitles"], ["caption"]),
        ("look", ["look", "grade", "color", "colour"], ["look", "grade"]),
        ("punch-in", ["punch-in", "punch in", "zoom"], ["effects", "frame", "zoom"]),
        ("title", ["title", "headline"], ["title"])
    ];
    private static readonly string[] Negations = ["no ", "not ", "didn't", "couldn't", "can't", "offered", "suggested", "can add"];
    private static readonly string[] Claims = ["added", "set ", "applied", "changed", "updated", "picked", "selected", "removed"];

    internal static IEnumerable<string> Kinds(IReadOnlyList<AgentChange> changes)
    {
        var paths = changes.Where(change => change.State == AgentChangeState.Applied).SelectMany(change => change.Patch).Select(patch => patch.Path.ToLowerInvariant()).ToArray();
        return Categories.Where(category => paths.Any(path => category.Paths.Any(path.Contains))).Select(category => category.Name);
    }

    internal static string? Missing(string summary, IReadOnlyList<AgentChange> changes, IReadOnlyList<string> revised)
    {
        var existing = Kinds(changes).Concat(revised).ToHashSet(StringComparer.Ordinal);
        var clauses = summary.ToLowerInvariant().Split('.', ';', '!', '?', '\n');
        return Categories.FirstOrDefault(category => !existing.Contains(category.Name) &&
            clauses.Any(clause => !Negations.Any(clause.Contains) && Claims.Any(clause.Contains) && category.Mentions.Any(clause.Contains))).Name;
    }
}
