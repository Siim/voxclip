#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Settings;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.ClaudeModeTests;
using static VoxClip.Core.Tests.Tracks.WinUi.MakeItPostableTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Claude mode stops waiting for the slowest clip (ai.md §16.12, design §6.7), twin of the Mac <c>ClaudeModeTests</c> added by
/// track/v2-speed: each clip of Make top N postable is applied the moment its plan is ready while the others plan, a failed clip fails
/// alone, Stop cancels every plan in flight, the video's cap covers the sum, the applied clip shares the planner's AI lease with its own
/// Rewrite steps, and the run's stage timings go to the log as numbers. Stub services only: nothing is sent or paid.</summary>
public sealed class ClaudeModeStreamingTests
{
    /// <summary>Each clip's plan, as <see cref="ClaudeModeTests.Video"/>'s stub plans it: a filler cut and one rewrite.</summary>
    private static ClipAutopilotPlan PlanFor(WordSpan span, int index) => Plan(span.Start, span.End, 9 - index) with
    {
        Corrections = [], Zooms = [], Questions = [], Cuts = [new(span.Start + 1, span.Start + 1, ClipAutopilotCutKind.Filler, "um")],
        Rewrites = [new(span.Start + 3, span.Start + 4, "much clearer", "a stumble")]
    };

    /// <summary>A planner that reports each clip as the test's <paramref name="script"/> says, as the live service does.</summary>
    private delegate Task Script(IReadOnlyList<ClipAutopilotPlan> plans, IProgress<ClipAutopilotProgress> progress, CancellationToken ct);

    private static (EditorViewModel Editor, Claude Claude, Stub Stub) Streaming(Script script, Claude? claude = null, Stub? stub = null,
        Func<IReadOnlyList<ClipAutopilotPlan>, ClipAutopilotSeries>? series = null)
    {
        var (editor, mode, made) = Video(claude, stub);
        editor.MakeIt.Services = editor.MakeIt.Services! with
        {
            Plan = async (request, progress, _, ct) =>
            {
                made.Requests.Add(request);
                var plans = ((ClipAutopilotMode.Clips)request.Mode).Spans.Select(PlanFor).ToArray();
                for (var index = 0; index < plans.Length; index++) progress.Report(new ClipAutopilotProgress.Planning(index, plans.Length));
                await script(plans, progress, ct);
                ct.ThrowIfCancellationRequested();
                return series?.Invoke(plans) ?? new(plans, [], []);
            }
        };
        return (editor, mode, made);
    }

    private static void Ready(IProgress<ClipAutopilotProgress> progress, IReadOnlyList<ClipAutopilotPlan> plans, int clip)
    {
        progress.Report(new ClipAutopilotProgress.Ready(clip, plans.Count, plans[clip]));
        progress.Report(new ClipAutopilotProgress.Planned(clip, plans.Count));
    }

    private static async Task StartAsync(EditorViewModel editor, Claude claude)
    {
        claude.Gate.SetResult();
        await editor.ClaudeModeContinueAsync();
        await editor.ClaudeMode.AfterFind!;
    }

    private static Task When(EditorViewModel editor, Func<bool> condition)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        editor.MakeItChanged += (_, _) => { if (condition()) done.TrySetResult(); };
        if (condition()) done.TrySetResult();
        return done.Task.WaitAsync(TimeSpan.FromMinutes(1), TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task TheFirstClipIsAppliedWhileTheOthersArePlanned()
    {
        var others = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var (editor, claude, stub) = Streaming(async (plans, progress, ct) =>
        {
            // The best clip's plan comes first; the others wait until it is applied.
            Ready(progress, plans, 0);
            await others.Task.WaitAsync(TimeSpan.FromMinutes(1), ct);
            Ready(progress, plans, 2);
            Ready(progress, plans, 1);
        });
        string? status = null;
        IReadOnlyList<MakeItPhase>? phases = null;
        editor.MakeItChanged += (_, _) =>
        {
            if (phases is not null || editor.ClaudeModeRuns is not [{ Phase: MakeItPhase.Ready }, ..] runs) return;
            phases = runs.Select(run => run.Phase).ToArray();
            status = editor.ClaudeModeStatus;
            others.TrySetResult();
        };
        await StartAsync(editor, claude);
        await editor.ClaudeMode.WaitAsync();
        Assert.Single(stub.Requests);
        Assert.Equal([MakeItPhase.Ready, MakeItPhase.Planning, MakeItPhase.Planning], phases);
        Assert.Equal("✦ Claude does it all · 1 of 3 ready · $0.00 / $2", status);
        Assert.Equal(ClaudeModePhase.Done, editor.ClaudeMode.Phase);
        Assert.All(editor.ClaudeModeRuns, run => Assert.Equal(MakeItPhase.Ready, run.Phase));
        // Each clip is its own "Make it postable" undo step, applied in the order the plans came: 0, 2, then 1.
        var first = editor.ClaudeMode.ClipIds;
        Assert.Contains("w21", editor.State!.CutWordIds);
        Assert.Contains("w41", editor.State.CutWordIds);
        Assert.Contains("w61", editor.State.CutWordIds);
        Assert.Equal(3, first.Count);
        Assert.Equal("Make it postable", editor.UndoActionName);
    }

    [Fact]
    public async Task FindClipsMomentsGoWithTheRequest()
    {
        var (editor, claude, stub) = Streaming((plans, progress, _) => { for (var clip = 0; clip < plans.Count; clip++) Ready(progress, plans, clip); return Task.CompletedTask; });
        await StartAsync(editor, claude);
        await editor.ClaudeMode.WaitAsync();
        var request = Assert.Single(stub.Requests);
        // Best first by score (9, 8, 7), each with Find Clips' title and score and no caption style.
        Assert.Equal([(20, "Clip 1", 9), (60, "Clip 3", 8), (40, "Clip 2", 7)], request.Moments.Select(moment => (moment.StartWord, moment.Title, moment.Score)));
        Assert.All(request.Moments, moment => Assert.Equal("", moment.CaptionStyle));
        Assert.Equal(((ClipAutopilotMode.Clips)request.Mode).Spans, request.Moments.Select(moment => new WordSpan(moment.StartWord, moment.EndWord)));
    }

    [Fact]
    public async Task StopCancelsEveryPlanInFlightAndKeepsTheReadyClip()
    {
        var cancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var (editor, claude, _) = Streaming(async (plans, progress, ct) =>
        {
            Ready(progress, plans, 0);
            try { await Task.Delay(Timeout.Infinite, ct); }
            catch (OperationCanceledException) { cancelled.TrySetResult(); throw; }
        });
        await StartAsync(editor, claude);
        await When(editor, () => editor.ClaudeModeRuns is [{ Phase: MakeItPhase.Ready }, ..]);
        editor.StopClaudeMode();
        await cancelled.Task.WaitAsync(TimeSpan.FromMinutes(1), TestContext.Current.CancellationToken);
        await editor.ClaudeMode.WaitAsync();
        Assert.Equal(ClaudeModePhase.Stopped, editor.ClaudeMode.Phase);
        Assert.Equal([MakeItPhase.Ready, MakeItPhase.Stopped, MakeItPhase.Stopped], editor.ClaudeModeRuns.Select(run => run.Phase));
        Assert.Contains("w21", editor.State!.CutWordIds);
        Assert.DoesNotContain("w61", editor.State.CutWordIds);
    }

    [Fact]
    public async Task AFailedClipDoesNotStopTheOthersEitherWayRound()
    {
        // The first plan fails while the others are still planned.
        var (early, earlyClaude, _) = Streaming((plans, progress, _) =>
        {
            progress.Report(new ClipAutopilotProgress.Failed(0, plans.Count));
            Ready(progress, plans, 1);
            Ready(progress, plans, 2);
            return Task.CompletedTask;
        }, series: plans => new(plans.Skip(1).ToArray(), [], []));
        await StartAsync(early, earlyClaude);
        await early.ClaudeMode.WaitAsync();
        Assert.Equal([MakeItPhase.Failed, MakeItPhase.Ready, MakeItPhase.Ready], early.ClaudeModeRuns.Select(run => run.Phase));
        Assert.Equal("Claude couldn't plan this clip. Nothing was changed.", early.ClaudeModeRuns[0].Failure);
        Assert.Equal(ClaudeModePhase.Done, early.ClaudeMode.Phase);
        Assert.Equal("✦ 2 clips ready", early.ClaudeModeDoneTitle);
        // The last plan fails after the others were applied.
        var (late, lateClaude, _) = Streaming((plans, progress, _) =>
        {
            Ready(progress, plans, 0);
            Ready(progress, plans, 1);
            progress.Report(new ClipAutopilotProgress.Failed(2, plans.Count));
            return Task.CompletedTask;
        }, series: plans => new(plans.Take(2).ToArray(), [], []));
        await StartAsync(late, lateClaude);
        await late.ClaudeMode.WaitAsync();
        Assert.Equal([MakeItPhase.Ready, MakeItPhase.Ready, MakeItPhase.Failed], late.ClaudeModeRuns.Select(run => run.Phase));
    }

    [Fact]
    public async Task APlannerThatSendsNoReadyHasItsClipsAppliedInRankOrder()
    {
        var (editor, claude, _) = Video();
        await StartAsync(editor, claude);
        await editor.ClaudeMode.WaitAsync();
        Assert.All(editor.ClaudeModeRuns, run => Assert.Equal(MakeItPhase.Ready, run.Phase));
    }

    [Fact]
    public async Task TheCapCoversTheSumOfClipsPlannedAtOnce()
    {
        // Each clip's one rewrite costs $0.80 of the $1 cap: the first clip voices it, the second finds $0.20 left and waits at the cap.
        var stub = new Stub { VoiceReady = true };
        stub.Voice = request => request.Budget is { } left && left >= 0.80m ? new(new MakeItRewriteResult.Voiced(["s"]), 0.80m) : new(new MakeItRewriteResult.OverCap(0.80m));
        var (editor, claude, _) = Streaming((plans, progress, _) =>
        {
            for (var clip = 0; clip < plans.Count; clip++) Ready(progress, plans, clip);
            return Task.CompletedTask;
        }, new Claude { Settings = new(ClipsMode.Claude, 2, 1) }, stub);
        await StartAsync(editor, claude);
        await When(editor, () => editor.ClaudeMode.Budget?.Needed is not null);
        Assert.Equal(0.80m, editor.ClaudeMode.Budget!.Spent);
        Assert.Equal(0.60m, editor.ClaudeMode.Budget.Needed);
        Assert.Equal([1m, 0.20m], stub.Voiced.Select(request => request.Budget!.Value));
        editor.StopClaudeMode();
        await editor.ClaudeMode.WaitAsync();
        Assert.Equal(0.80m, editor.ClaudeMode.Budget.Spent);
    }

    [Fact]
    public async Task TheAppliedClipSharesThePlannersLeaseWithItsOwnRewriteSteps()
    {
        var leases = new List<bool>();
        var stub = new Stub { VoiceReady = true };
        EditorViewModel? owner = null;
        stub.Voice = _ =>
        {
            using var lease = owner!.LlmRuns.TryAcquire();
            leases.Add(lease is not null);
            return new(new MakeItRewriteResult.Voiced(["s"]), 0m);
        };
        var others = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        bool? outside = null;
        var (editor, claude, _) = Streaming(async (plans, progress, ct) =>
        {
            // The planner holds the project's AI lease until every plan is in, as the live page does.
            using var held = owner!.LlmRuns.TryAcquire() ?? throw new InvalidOperationException("lease taken");
            // Outside an applied clip nothing else may take a lease while plans are in flight.
            using (var other = owner.LlmRuns.TryAcquire()) outside = other is not null;
            Ready(progress, plans, 0);
            await others.Task.WaitAsync(TimeSpan.FromMinutes(1), ct);
            Ready(progress, plans, 1);
            Ready(progress, plans, 2);
        }, stub: stub);
        owner = editor;
        editor.MakeItChanged += (_, _) => { if (editor.ClaudeModeRuns is [{ Phase: MakeItPhase.Ready }, ..]) others.TrySetResult(); };
        await StartAsync(editor, claude);
        await editor.ClaudeMode.WaitAsync();
        Assert.Equal([true, true, true], leases);
        Assert.False(outside);
        Assert.False(editor.LlmRuns.IsBusy);
    }

    [Fact]
    public async Task TheRunLogsItsStageTimingsAsNumbersOnly()
    {
        var logged = new List<string>();
        var (editor, claude, _) = Streaming((plans, progress, _) => { for (var clip = 0; clip < plans.Count; clip++) Ready(progress, plans, clip); return Task.CompletedTask; });
        editor.ClaudeMode.Services = editor.ClaudeMode.Services! with { Log = logged.Add };
        await StartAsync(editor, claude);
        await editor.ClaudeMode.WaitAsync();
        var line = Assert.Single(logged);
        Assert.Matches("^claude-mode timings find=\\d+\\.\\d( plan\\d=\\d+\\.\\d| apply\\d=\\d+\\.\\d)+ first=\\d+\\.\\d total=\\d+\\.\\d$", line);
        foreach (var stage in new[] { "plan1=", "plan2=", "plan3=", "apply1=", "apply2=", "apply3=" }) Assert.Contains(stage, line, StringComparison.Ordinal);
        Assert.NotNull(editor.ClaudeMode.Clock!.FirstReady);
    }
}
#endif
