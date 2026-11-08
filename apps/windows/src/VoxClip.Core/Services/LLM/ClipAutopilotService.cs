using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Core.Services.LLM;

/// <summary>A checked plan and where it came from (ai.md §16).</summary>
public sealed record ClipAutopilotResult(ClipAutopilotSeries Series, string Model, bool UsedFallback, int DroppedItems, LlmUsage? Usage, int PromptVersion, string PromptSha256)
{
    /// <summary>The clip request's plan, or the best clip of a series.</summary>
    public ClipAutopilotPlan? Plan => Series.Plans.FirstOrDefault();
}

/// <summary>What a running plan is doing, for the progress lines (ai.md §16.3). Sent in order from the service; <c>Clip</c> indexes the
/// moments of a series or the spans of a <c>clips</c> request, and is 0 of 1 for a single clip.</summary>
public abstract record ClipAutopilotProgress
{
    /// <summary>The series' first stage was sent.</summary>
    public sealed record PickingMoments : ClipAutopilotProgress;
    /// <summary>The first stage's checked moments.</summary>
    public sealed record Picked(IReadOnlyList<ClipAutopilotMoment> Moments) : ClipAutopilotProgress;
    /// <summary>A clip's plan was sent.</summary>
    public sealed record Planning(int Clip, int Of) : ClipAutopilotProgress;
    /// <summary>A clip's plan came back checked.</summary>
    public sealed record Planned(int Clip, int Of) : ClipAutopilotProgress;
    /// <summary>That clip's checked plan, sent the moment it is ready and before <see cref="Planned"/>, while the other clips are still
    /// planned: Claude mode applies and shows each clip as it comes (ai.md §16.12).</summary>
    public sealed record Ready(int Clip, int Of, ClipAutopilotPlan Plan) : ClipAutopilotProgress;
    /// <summary>A clip's plan failed; the others go on.</summary>
    public sealed record Failed(int Clip, int Of) : ClipAutopilotProgress;
}

/// <summary>The "Make it postable" planner (ai.md §16): asks the chosen connector for every decision a postable clip needs and
/// checks the reply item by item. A clip is one send at extra high effort; a series picks its moments at high effort, then plans
/// each one, at most <see cref="MaxParallelPlans"/> at once. It never applies, generates or bills anything. Twin of the Mac
/// <c>ClipAutopilotService</c>.</summary>
public sealed class ClipAutopilotService(LlmRunner runner, LlmCatalog catalog, string sharedRoot)
{
    /// <summary>A clip plan's effort.</summary>
    public const Effort PlanEffort = Effort.XHigh;
    /// <summary>The series' first stage, which only picks moments.</summary>
    public const Effort MomentsEffort = Effort.High;
    /// <summary>Clip plans in flight at once.</summary>
    public const int MaxParallelPlans = 3;

    /// <summary>A send and what it was prepared from, so the clip's frames can be added when they arrive.</summary>
    private sealed record Prepared(LlmRequest Request, ClipAutopilotContext Context, ClipAutopilotRequest Input, ConnectorId Connector, ClipAutopilotMomentBrief? Moment);

    private sealed class Resources
    {
        internal Resources(string root)
        {
            Prompt = ClipAutopilotPrompt.Load(root);
            Styles = CaptionStyleLibrary.Load(root).Styles;
            Fonts = ClipAutopilotFonts.Load(root);
        }
        internal ClipAutopilotPrompt Prompt { get; }
        internal IReadOnlyList<CaptionStyle> Styles { get; }
        internal IReadOnlyDictionary<ClipAutopilotFont, string> Fonts { get; }
    }

    /// <summary>The first request a plan sends: the clip's plan, the series' moments, or the first span's plan of a clips request, with
    /// <paramref name="frames"/> when given (never on a series' moments stage).</summary>
    public LlmRequest Request(ClipAutopilotRequest input, ConnectorId connector, ClipAutopilotFrames? frames = null) => First(input, connector, frames).Request;

    /// <summary>What the first reply is checked against.</summary>
    public ClipAutopilotContext Context(ClipAutopilotRequest input, ClipAutopilotFrames? frames = null) => First(input, ConnectorId.ClaudeCode, frames).Context;

    private Prepared First(ClipAutopilotRequest input, ConnectorId connector, ClipAutopilotFrames? frames)
    {
        var resources = new Resources(sharedRoot);
        if (input.Mode is ClipAutopilotMode.Clips clips)
        {
            if (clips.Spans.Count == 0) throw ClipAutopilotRequestBuilder.Invalid();
            var moment = input.Moments.Count == clips.Spans.Count ? Briefs(input.Moments)[0] : null;
            return Prepare(input.ForClip(clips.Spans[0]), resources, connector, moment, frames);
        }
        return Prepare(input, resources, connector, null, input.IsSeries ? null : frames);
    }

    /// <summary>Plans <paramref name="input"/>. <paramref name="lanes"/> are extra connectors of the same kind, one per parallel clip
    /// plan; without them the clip plans go one after another. A failed clip plan is left out and listed in the repairs; the run
    /// fails only when every clip plan does, or on cancellation. <paramref name="frames"/> gives each clip plan its frames when it is
    /// about to be sent (never the series' moments stage).</summary>
    public async Task<ClipAutopilotResult> PlanAsync(ClipAutopilotRequest input, ILlmConnector connector, string model, IReadOnlyList<ILlmConnector>? lanes = null,
        Action<ClipAutopilotProgress>? progress = null, CancellationToken ct = default, ClipAutopilotFrameSource? frames = null)
    {
        lanes ??= [];
        if (!VoiceLabLlmChecks.IsValidModel(model) || lanes.Any(lane => lane.Id != connector.Id)) throw ClipAutopilotRequestBuilder.Invalid();
        var resources = new Resources(sharedRoot);
        var all = new[] { connector }.Concat(lanes.Take(MaxParallelPlans - 1)).ToArray();
        switch (input.Mode)
        {
            case ClipAutopilotMode.Clip:
            {
                var text = Prepare(input, resources, connector.Id);
                progress?.Invoke(new ClipAutopilotProgress.Planning(0, 1));
                var prepared = await ShowingAsync(text, frames, 0, resources, ct).ConfigureAwait(false);
                var reply = await SendAsync(prepared, all[0], model, ct).ConfigureAwait(false);
                var plan = ClipAutopilotValidator.Plan(reply.Object, prepared.Context)
                    ?? throw LlmErrors.Create(LlmErrorKind.InvalidOutput, "", model, LlmFeature.ClipAutopilot, detail: "The plan has no words of the clip.");
                progress?.Invoke(new ClipAutopilotProgress.Planned(0, 1));
                return Result(new ClipAutopilotSeries([plan]), [reply], reply.Model, resources);
            }
            case ClipAutopilotMode.Clips clips:
            {
                if (clips.Spans.Count == 0 || clips.Spans.Count > resources.Prompt.Limits.MaxClips ||
                    input.Moments.Count != 0 && input.Moments.Count != clips.Spans.Count) throw ClipAutopilotRequestBuilder.Invalid();
                // With Find Clips' moments each plan knows its rank and the other clips, as a series' second stage does.
                var briefs = input.Moments.Count == 0 ? null : Briefs(input.Moments);
                var items = clips.Spans.Select((span, index) => Prepare(input.ForClip(span), resources, connector.Id, briefs?[index])).ToArray();
                var outcome = await PlanAllAsync(items, all, model, resources, frames, progress, ct).ConfigureAwait(false);
                var series = ClipAutopilotValidator.Series(outcome.Plans, [], outcome.Failures, []);
                return Result(series, outcome.Replies, outcome.Replies.FirstOrDefault()?.Model ?? model, resources);
            }
            default:
            {
                var prepared = Prepare(input, resources, connector.Id);
                progress?.Invoke(new ClipAutopilotProgress.PickingMoments());
                var reply = await SendAsync(prepared, all[0], model, ct).ConfigureAwait(false);
                var (moments, repairs) = ClipAutopilotValidator.Moments(reply.Object, prepared.Context);
                progress?.Invoke(new ClipAutopilotProgress.Picked(moments));
                if (moments.Count == 0) return Result(new ClipAutopilotSeries([], [], repairs), [reply], reply.Model, resources);
                var items = Briefs(moments).Select(brief => Prepare(input.ForClip(new(brief.Moment.StartWord, brief.Moment.EndWord)), resources, connector.Id, brief)).ToArray();
                var outcome = await PlanAllAsync(items, all, model, resources, frames, progress, ct).ConfigureAwait(false);
                var series = ClipAutopilotValidator.Series(outcome.Plans, moments, outcome.Failures, repairs);
                return Result(series, [reply, .. outcome.Replies], outcome.Replies.FirstOrDefault()?.Model ?? reply.Model, resources);
            }
        }
    }

    /// <summary>The same send with the clip's frames from <paramref name="source"/>: the summary and candidates in the instruction, the
    /// images on the request. Unchanged without a source, for a series' moments stage, or when the source has none.</summary>
    private async Task<Prepared> ShowingAsync(Prepared prepared, ClipAutopilotFrameSource? source, int clip, Resources resources, CancellationToken ct)
    {
        if (source is null || prepared.Input.IsSeries) return prepared;
        ct.ThrowIfCancellationRequested();
        var frames = await source(clip, prepared.Context.Scope, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return frames is null ? prepared : Prepare(prepared.Input, resources, prepared.Connector, prepared.Moment, frames);
    }

    /// <summary>One send, after the model's context check (ai.md §12.8). The frames count too: Anthropic's estimate per image, which
    /// only a connector that takes images is sent.</summary>
    private async Task<LlmResult> SendAsync(Prepared prepared, ILlmConnector connector, string model, CancellationToken ct)
    {
        if (connector.Id != ConnectorId.AppleFoundation)
        {
            var context = await catalog.ResolveContextTokensAsync(connector, model, ct).ConfigureAwait(false);
            var safety = catalog.Data["policy"]!["tokenEstimate"]!["contextSafetyFactor"]!.GetValue<double>();
            var images = connector.SupportsImages ? prepared.Request.Images.Sum(image => image.EstimatedTokens) : 0;
            if (!VoiceLabLlmChecks.ContextFits(context, VoiceLabLlmChecks.RequiredTokens(catalog, prepared.Request) + images, safety))
                throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", model, LlmFeature.ClipAutopilot);
        }
        ct.ThrowIfCancellationRequested();
        var reply = await runner.RunAsync(prepared.Request, connector, model, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return reply;
    }

    /// <summary>The clip plans of <paramref name="items"/>, each lane sending one at a time, in item order as lanes free up.</summary>
    private async Task<(ClipAutopilotPlan?[] Plans, IReadOnlyList<LlmResult> Replies, IReadOnlyDictionary<int, string> Failures)> PlanAllAsync(
        IReadOnlyList<Prepared> items, IReadOnlyList<ILlmConnector> lanes, string model, Resources resources, ClipAutopilotFrameSource? frames,
        Action<ClipAutopilotProgress>? progress, CancellationToken ct)
    {
        var plans = new ClipAutopilotPlan?[items.Count];
        var replies = new LlmResult?[items.Count];
        var failures = new Dictionary<int, string>();
        Exception? firstError = null;
        var gate = new object();
        var next = -1;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var cancelled = false;
        async Task Lane(ILlmConnector connector)
        {
            while (true)
            {
                int item;
                lock (gate)
                {
                    if (cancelled || next + 1 >= items.Count) return;
                    item = ++next;
                    progress?.Invoke(new ClipAutopilotProgress.Planning(item, items.Count));
                }
                try
                {
                    var shown = await ShowingAsync(items[item], frames, item, resources, linked.Token).ConfigureAwait(false);
                    var reply = await SendAsync(shown, connector, model, linked.Token).ConfigureAwait(false);
                    var plan = ClipAutopilotValidator.Plan(reply.Object, shown.Context);
                    lock (gate)
                    {
                        if (cancelled) return;
                        replies[item] = reply;
                        plans[item] = plan;
                        if (plan is null) failures[item] = "the plan has no words of the clip";
                        if (plan is not null) progress?.Invoke(new ClipAutopilotProgress.Ready(item, items.Count, plan));
                        progress?.Invoke(plan is null ? new ClipAutopilotProgress.Failed(item, items.Count) : new ClipAutopilotProgress.Planned(item, items.Count));
                    }
                }
                catch (Exception error) when (error is OperationCanceledException || error is LlmException { Error.Kind: LlmErrorKind.Cancelled } || ct.IsCancellationRequested)
                {
                    lock (gate) cancelled = true;
                    await linked.CancelAsync().ConfigureAwait(false);
                    return;
                }
                catch (Exception error) when (error is LlmException or VoxClip.Core.Domain.Shared.VoxClipException)
                {
                    lock (gate)
                    {
                        failures[item] = "the plan failed: " + (error is LlmException llm ? llm.Error.Kind.ToString() : "error");
                        firstError ??= error;
                        progress?.Invoke(new ClipAutopilotProgress.Failed(item, items.Count));
                    }
                }
            }
        }
        await Task.WhenAll(lanes.Select(Lane)).ConfigureAwait(false);
        if (cancelled) throw LlmErrors.Create(LlmErrorKind.Cancelled, "");
        if (plans.All(plan => plan is null) && firstError is not null) throw firstError;
        return (plans, replies.OfType<LlmResult>().ToArray(), failures);
    }

    private static ClipAutopilotResult Result(ClipAutopilotSeries series, IReadOnlyList<LlmResult> replies, string model, Resources resources)
    {
        long? Sum(Func<LlmUsage, long?> part)
        {
            var values = replies.Select(reply => reply.Usage is null ? null : part(reply.Usage)).OfType<long>().ToArray();
            return values.Length == 0 ? null : values.Sum();
        }
        var usage = replies.Any(reply => reply.Usage is not null) ? new LlmUsage(Sum(item => item.Input), Sum(item => item.Output), Sum(item => item.CacheRead), Sum(item => item.CacheWrite)) : null;
        return new(series, model, replies.Any(reply => reply.UsedFallback), replies.Sum(reply => reply.DroppedItems), usage,
            resources.Prompt.PromptVersion, resources.Prompt.Sha256);
    }

    /// <summary>The second stage's briefs: each moment's rank, the caption styles of the others and the others themselves.</summary>
    private static IReadOnlyList<ClipAutopilotMomentBrief> Briefs(IReadOnlyList<ClipAutopilotMoment> moments) =>
        moments.Select((moment, index) =>
        {
            var others = moments.Where((_, other) => other != index).ToArray();
            return new ClipAutopilotMomentBrief(index + 1, moments.Count, moment, others.Select(item => item.CaptionStyle).Where(style => style.Length > 0).ToArray(), others);
        }).ToArray();

    private static string TimeoutKind(ConnectorId id) => id switch
    {
        ConnectorId.ClaudeCode or ConnectorId.Codex => "cli", ConnectorId.Ollama or ConnectorId.LmStudio => "localServer",
        ConnectorId.AppleFoundation => "appleFoundation", _ => "cloud"
    };

    private Prepared Prepare(ClipAutopilotRequest input, Resources resources, ConnectorId connector, ClipAutopilotMomentBrief? moment = null, ClipAutopilotFrames? frames = null)
    {
        var prompt = resources.Prompt;
        var pauses = EditingAlgorithms.DetectPauses(input.Transcript.Words, input.Edits.PauseThresholdSeconds);
        var shown = input.IsSeries ? null : frames;
        var rendered = ClipAutopilotRequestBuilder.Render(input, prompt, resources.Styles, resources.Fonts, pauses, moment, shown);
        var moments = input.IsSeries;
        var system = moments ? prompt.MomentsSystem : prompt.System;
        if (System.Text.Encoding.UTF8.GetByteCount(system + rendered.CachedBlock + rendered.Instruction) > 400_000)
            throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", "", LlmFeature.ClipAutopilot);
        var output = catalog.Cap(connector, moments ? prompt.MomentsOutputTokens : prompt.ClipOutputTokens);
        var timeout = catalog.Timeout(TimeoutKind(connector));
        if (timeout < prompt.MinimumTimeout) timeout = prompt.MinimumTimeout;
        var request = new LlmRequest(LlmFeature.ClipAutopilot, system, rendered.CachedBlock, rendered.Instruction,
            moments ? prompt.MomentsSchemaName : prompt.SchemaName, (moments ? prompt.MomentsSchema : prompt.Schema).DeepClone().AsObject(), output,
            moments ? MomentsEffort : PlanEffort, timeout, input.Language ?? input.Transcript.Language,
            moments ? "clip-autopilot-moments" : moment is null ? "clip-autopilot" : "clip-autopilot-series-clip") { Images = shown?.Images ?? [] };
        var context = new ClipAutopilotContext(input.Transcript.Words, input.Edits.Corrections, input.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal),
            pauses, input.Edits.CutPauseIds.ToHashSet(StringComparer.Ordinal), input.Edits.PauseKeepSeconds, rendered.Scope,
            resources.Styles.Select(style => style.Id).ToHashSet(StringComparer.Ordinal), resources.Fonts, input.CaptionPreference, prompt, moments ? null : input.Tone, shown);
        return new(request, context, input, connector, moment);
    }
}
