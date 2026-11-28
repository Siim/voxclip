#pragma warning disable CS1591
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Services.Project;
using ClipProject = VoxClip.Core.Domain.Shared.Project;
using System.Text.Json.Nodes;

namespace VoxClip.Core.Services.LLM;

/// <summary>Runs agent turns on the owning project's context. It can stage edits and quote offers, but cannot buy them.</summary>
public sealed partial class AgentChatSession
{
    public sealed record Question(string Text, IReadOnlyList<string> Answers);
    public abstract record SessionStatus
    {
        public sealed record Idle : SessionStatus;
        public sealed record Running(string Progress) : SessionStatus;
        public sealed record Finished : SessionStatus;
        public sealed record Stopped : SessionStatus;
        public sealed record Budget(int Steps) : SessionStatus;
        public sealed record Waiting(Question Question) : SessionStatus;
        public sealed record Unavailable(ConnectorStatus Availability) : SessionStatus;
        public sealed record Failed(string Message) : SessionStatus;
        public sealed record ModelUnavailable(string Model) : SessionStatus;
        public sealed record ApprovalRequired(AgentChatApproval Approval) : SessionStatus;
    }

    public sealed record Context(string? ClipId = null, double? Playhead = null, IReadOnlyList<AgentContext>? Selection = null, decimal? CapLeft = null);

    public ClipProject Project { get; private set; }
    public SessionStatus Status { get; private set; } = new SessionStatus.Idle();
    public IReadOnlyList<string> Next { get; private set; } = [];
    public Context LiveContext { get; set; }
    public Action? OnChange { get; set; }

    private readonly string sharedRoot;
    private readonly ILlmConnector connector;
    private readonly string model;
    private readonly Effort effort;
    private readonly int stepBudget;
    private readonly AgentMode defaultMode;
    private readonly string? projectPath;
    private readonly string? cache;
    private readonly Func<string, IReadOnlyList<double>, CancellationToken, IReadOnlyList<HarnessFrame>>? decodeFrames;
    private readonly HarnessMusicLibrary? music;
    private readonly Func<ClipProject, string, IReadOnlyList<string>, System.Text.Json.JsonElement>? check;
    private readonly Func<DateTimeOffset> now;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly AgentChatPrompt prompt;
    private readonly (decimal Minimum, decimal Maximum)? estimatedUSD;
    private readonly HashSet<string> keyApprovedThreads = [];
    private readonly Queue<AgentRequest> queue = [];
    private readonly List<AgentRequest> steering = [];
    private bool active;
    private bool stopping;
    private Run? suspended;

    private sealed class Run(AgentTurn turn)
    {
        internal AgentTurn Turn = turn;
        internal JsonArray Results { get; } = [];
        internal IReadOnlyList<LlmImage> Images = [];
        internal JsonArray Steering { get; } = [];
        internal string? Feedback;
        internal string? Refusal;
        internal string? RefusedTool;
        internal bool DidMatchRetry;
        internal List<string> Claims { get; } = [];
        internal bool Asked;
    }

    public AgentChatSession(ClipProject project, string sharedRoot, ILlmConnector connector, string model, Effort effort = Effort.High,
        int stepBudget = 8, AgentMode defaultMode = AgentMode.Propose, (decimal Minimum, decimal Maximum)? estimatedUSD = null,
        Context? context = null, string? projectPath = null, string? cache = null,
        Func<string, IReadOnlyList<double>, CancellationToken, IReadOnlyList<HarnessFrame>>? decodeFrames = null,
        HarnessMusicLibrary? music = null, Func<ClipProject, string, IReadOnlyList<string>, System.Text.Json.JsonElement>? check = null,
        Func<DateTimeOffset>? now = null, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        Project = project;
        this.sharedRoot = sharedRoot;
        this.connector = connector;
        this.model = model;
        this.effort = effort;
        this.stepBudget = Math.Max(1, stepBudget);
        this.defaultMode = defaultMode;
        this.estimatedUSD = estimatedUSD;
        LiveContext = context ?? new();
        this.projectPath = projectPath;
        this.cache = cache;
        this.decodeFrames = decodeFrames;
        this.music = music;
        this.check = check;
        this.now = now ?? (() => DateTimeOffset.UtcNow);
        this.delay = delay ?? Task.Delay;
        prompt = new(sharedRoot);
    }

    public void UpdateProject(ClipProject live)
    {
        if (live.Id == Project.Id) Project = live;
    }

    public async Task SendAsync(AgentRequest request, CancellationToken ct = default)
    {
        if (!active && Status is SessionStatus.Waiting && suspended is not null)
        {
            await ResumeAsync(request, ct);
            return;
        }
        queue.Enqueue(request);
        if (!active && Status is not SessionStatus.ApprovalRequired) await DrainAsync(ct);
    }

    public Task SteerAsync(AgentRequest request, CancellationToken ct = default)
    {
        if (!active || stopping) return SendAsync(request, ct);
        steering.Add(request);
        return Task.CompletedTask;
    }

    public void Stop() { if (active) stopping = true; }

    public async Task RespondAsync(AgentChatApproval approval, bool allow, CancellationToken ct = default)
    {
        if (active || Status is not SessionStatus.ApprovalRequired pending || pending.Approval != approval || approval.ThreadId != ThreadId) return;
        SetStatus(new SessionStatus.Idle());
        if (!allow)
        {
            queue.Clear();
            steering.Clear();
            suspended = null;
            return;
        }
        keyApprovedThreads.Add(approval.ThreadId);
        if (suspended is not null) await ResumeAsync(ct: ct);
        else await DrainAsync(ct);
    }

    public async Task ResumeAsync(AgentRequest? answer = null, CancellationToken ct = default)
    {
        if (active || suspended is not { } run || Project.AgentThread?.Turns.LastOrDefault() is not { } last || last.Id != run.Turn.Id ||
            (Status is SessionStatus.Waiting && answer is null)) return;
        run.Turn = last;
        if (answer is not null) steering.Add(answer);
        active = true;
        stopping = false;
        try
        {
            if (await PreflightAsync(ct) is { } blocker) { SetStatus(blocker); return; }
            suspended = null;
            run.Turn = last with { State = AgentTurnState.Running };
            await ExecuteAsync(run, ct);
        }
        finally { active = false; }
        await DrainAsync(ct);
    }

    private async Task DrainAsync(CancellationToken ct)
    {
        if (active) return;
        active = true;
        try
        {
            while (queue.Count > 0 && Status is not (SessionStatus.Waiting or SessionStatus.ApprovalRequired) && !ct.IsCancellationRequested)
            {
                suspended = null;
                stopping = false;
                if (await PreflightAsync(ct) is { } blocker)
                {
                    if (blocker is not SessionStatus.ApprovalRequired) queue.Dequeue();
                    SetStatus(blocker);
                    break;
                }
                if (stopping || ct.IsCancellationRequested) break;
                var request = queue.Dequeue();
                var ordinal = (Project.AgentThread?.Turns ?? []).Select(turn => int.TryParse(turn.Id.AsSpan(1), out var number) ? number : 0).DefaultIfEmpty().Max() + 1;
                var turn = new AgentTurn($"t{ordinal}", AgentTurnKind.Agent, now(), request, LlmCatalog.WireId(connector.Id), model, "", [],
                    AgentTurnState.Running, [], [], []);
                await ExecuteAsync(new(turn), ct);
                steering.Clear();
            }
        }
        finally { active = false; }
    }

    private async Task ExecuteAsync(Run run, CancellationToken ct)
    {
        Next = [];
        try
        {
            Save(run.Turn);
            var index = 0;
            var badReply = false;
            while (index < stepBudget || run.Feedback is not null && run.DidMatchRetry)
            {
                if (stopping || ct.IsCancellationRequested) break;
                if (index > 0 && await PreflightAsync(ct) is { } blocker) { Finish(run, blocker, resumable: true); return; }
                foreach (var addition in steering) run.Steering.Add(AgentChatPrompt.Json(addition));
                steering.Clear();
                SetStatus(new SessionStatus.Running(run.Turn.Summary));
                var snapshot = Project;
                var request = await MakeRequestAsync(run, ct);
                if (stopping || ct.IsCancellationRequested) break;
                AgentChatReply reply;
                try
                {
                    var raw = await CompleteAsync(request, ct);
                    if (stopping || ct.IsCancellationRequested) break;
                    reply = AgentChatReply.Read(raw);
                    badReply = false;
                }
                catch (LlmException error) when (error.Error.Kind == LlmErrorKind.InvalidOutput && !badReply)
                {
                    if (stopping || ct.IsCancellationRequested) break;
                    badReply = true;
                    run.Feedback = $"Your reply did not match agent_step: {error.Error.Reason} Reply again using the required schema.";
                    continue;
                }
                index++;
                run.Feedback = null;
                run.Turn = run.Turn with { Summary = reply.Say };
                if (!reply.Done) SetStatus(new SessionStatus.Running(reply.Say));
                var stale = snapshot != Project;
                foreach (var call in reply.Calls)
                {
                    if (stopping || ct.IsCancellationRequested) break;
                    await PerformAsync(call, run, stale, ct);
                }
                if (stopping || ct.IsCancellationRequested) break;
                if (reply.Question is { } question && !run.Asked && Mode != AgentMode.Claude)
                {
                    run.Asked = true;
                    Finish(run, new SessionStatus.Waiting(question), resumable: true);
                    return;
                }
                if (!reply.Done || (steering.Count > 0 && index < stepBudget)) continue;
                var mismatch = AgentChatMatch.Missing(reply.Say, run.Turn.Changes, run.Claims);
                if (mismatch is not null && !run.DidMatchRetry)
                {
                    run.DidMatchRetry = true;
                    run.Feedback = $"Your summary mentions {mismatch}, but no {mismatch} change was made. Fix it or correct the summary.";
                    continue;
                }
                Next = reply.Next;
                if (run.Turn.Check is null && check is not null && OpenClipId is { } clip)
                {
                    try { run.Turn = run.Turn with { Check = ReadCheck(JsonNode.Parse(check(Project, clip, []).GetRawText())) }; }
                    catch (Exception) when (!ct.IsCancellationRequested) { }
                }
                if (mismatch is not null) AppendCheck(run, $"Claude said it added {mismatch}, but nothing changed there.");
                if (run.Refusal is not null) AppendCheck(run, $"Couldn't make this change: {run.Refusal}");
                Finish(run, new SessionStatus.Finished());
                return;
            }
            if (stopping || ct.IsCancellationRequested) Finish(run, new SessionStatus.Stopped());
            else Finish(run, new SessionStatus.Budget(stepBudget), resumable: true);
        }
        catch (Exception error)
        {
            var outcome = stopping || ct.IsCancellationRequested ? new SessionStatus.Stopped() : Failure(error);
            try { Finish(run, outcome, resumable: outcome is not SessionStatus.Stopped); }
            catch (Exception) { SetStatus(new SessionStatus.Failed("Couldn't save the chat turn. The project and paid output are intact.")); }
        }
    }

    private async Task<RawCompletion> CompleteAsync(LlmRequest request, CancellationToken ct)
    {
        foreach (var seconds in new[] { 2, 8, 30 })
        {
            try { return await connector.SendAsync(request, model, ct); }
            catch (LlmException error) when (error.Error.Kind is LlmErrorKind.Network or LlmErrorKind.Timeout)
            {
                if (stopping) throw new OperationCanceledException();
                await delay(TimeSpan.FromSeconds(seconds), ct);
                if (stopping) throw new OperationCanceledException();
            }
        }
        return await connector.SendAsync(request, model, ct);
    }

    private SessionStatus Failure(Exception error) => (error as LlmException)?.Error.Kind switch
    {
        LlmErrorKind.ModelNotFound => new SessionStatus.ModelUnavailable(((LlmException)error).Error.Model ?? model),
        LlmErrorKind.InvalidOutput => new SessionStatus.Failed("Claude's reply couldn't be read. What's done is pending."),
        LlmErrorKind.Network or LlmErrorKind.Timeout => new SessionStatus.Failed($"Couldn't reach {LlmCatalog.WireId(connector.Id)}. Nothing changed in this step."),
        LlmErrorKind.Cancelled => new SessionStatus.Stopped(),
        _ => new SessionStatus.Failed("The chat step failed. The project and paid output are intact.")
    };

    private async Task<SessionStatus?> PreflightAsync(CancellationToken ct)
    {
        if (connector.Id is not (ConnectorId.ClaudeCode or ConnectorId.Codex or ConnectorId.Anthropic or ConnectorId.OpenAI))
            return new SessionStatus.Unavailable(new ConnectorStatus.Unavailable("This connector isn't available for agent chat."));
        var availability = await connector.GetStatusAsync(ct);
        if (availability is not ConnectorStatus.Ready) return new SessionStatus.Unavailable(availability);
        var usesKey = connector.Id is ConnectorId.ClaudeCode or ConnectorId.Codex ? AgentChatApproval.UsesKey(connector.KnownCliAuthMethod, connector.Id) : true;
        if (usesKey is null) return new SessionStatus.Unavailable(new ConnectorStatus.Unavailable("VoxClip couldn't tell how this connector is signed in."));
        return usesKey == true && !keyApprovedThreads.Contains(ThreadId) ? new SessionStatus.ApprovalRequired(new(connector.Id, model, estimatedUSD, ThreadId)) : null;
    }

    private void Finish(Run run, SessionStatus outcome, bool resumable = false)
    {
        var state = outcome switch
        {
            SessionStatus.Finished => Mode == AgentMode.Claude || (run.Turn.Changes.Count == 0 && run.Turn.Offers.Count == 0) ? AgentTurnState.Kept : AgentTurnState.Pending,
            SessionStatus.Waiting => run.Turn.Changes.Count == 0 ? AgentTurnState.Running : AgentTurnState.Pending,
            SessionStatus.Failed or SessionStatus.ModelUnavailable => run.Turn.Changes.Count == 0 ? AgentTurnState.Failed : AgentTurnState.Partial,
            _ => AgentTurnState.Stopped
        };
        run.Turn = run.Turn with { State = state };
        Save(run.Turn);
        if (resumable) suspended = run;
        SetStatus(outcome);
    }

    private void Save(AgentTurn turn, ClipProject? candidate = null)
    {
        var basis = candidate ?? Project;
        var thread = basis.AgentThread ?? new AgentThread(ThreadId, Mode, []);
        if (thread.Turns.LastOrDefault() is { } current && current.Id == turn.Id)
        {
            var offers = current.Offers.ToDictionary(offer => offer.Id);
            turn = turn with { Events = current.Events, Offers = turn.Offers.Select(offer => offers.GetValueOrDefault(offer.Id) ?? offer).ToArray() };
        }
        Project = AgentTurns.Record(turn, basis with { AgentThread = thread }, thread.Id);
        OnChange?.Invoke();
    }

    private AgentMode Mode => Project.AgentThread?.Mode ?? defaultMode;
    private string ThreadId => Project.AgentThread?.Id ?? $"agent-{Project.Id}";
    private string? OpenClipId => LiveContext.ClipId ?? Project.Edits.Clips.FirstOrDefault(clip => clip.Selected)?.Id;
    private void SetStatus(SessionStatus value) { Status = value; OnChange?.Invoke(); }

    private static void AppendCheck(Run run, string line) => run.Turn = run.Turn with { Check = new(false, [.. run.Turn.Check?.Lines ?? [], line]) };

    private async Task<LlmRequest> MakeRequestAsync(Run run, CancellationToken ct)
    {
        var instruction = prompt.Instruction(await DigestAsync(ct), History(run.Turn.Id), AgentChatPrompt.Json(run.Turn.Request)!, run.Results, run.Steering, run.Feedback);
        return new(LlmFeature.AgentChat, prompt.System, null, instruction, prompt.SchemaName, prompt.Schema, 4096,
            effort, TimeSpan.FromSeconds(120), null, "agent-chat-v1") { Images = run.Images, AgentChatKeyApproved = keyApprovedThreads.Contains(ThreadId) };
    }
}
