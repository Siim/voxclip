using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App.ViewModels;

/// <summary>"✦ Claude does it all" (design §6.6, §6.7), twin of the Mac <c>EditorModel</c> Claude mode extension.</summary>
public sealed partial class EditorViewModel
{
    /// <summary>Claude mode for this video.</summary>
    public ClaudeModeState ClaudeMode { get; } = new();
    /// <summary>Export all's state: running, the files written, and the clips that failed.</summary>
    public bool ClaudeExporting { get; private set; }
    public List<string> ClaudeExported { get; } = [];
    public List<string> ClaudeExportProblems { get; } = [];

    private ClipsAutopilotSettings ClipsAutopilot => ClaudeMode.Services?.Settings() ?? new();
    public bool ClaudeModeOn => ClipsAutopilot.Mode == ClipsMode.Claude;

    // MARK: The remembered choice

    /// <summary>Card A ("Who makes the clips?") asks once, inline, until the creator chooses: on a newly imported video, or once a
    /// project has clips. A read-only project never shows it.</summary>
    public bool ShowsClipsModeCard => ClaudeMode.Services is not null && !IsReadOnly && !isLeaving && ClipsAutopilot.Mode is null &&
        (ClaudeMode.Armed || ClaudeMode.Phase != ClaudeModePhase.Idle || project.Edits.Clips.Count > 0);

    /// <summary>Card C or D (or the blocked card) shows: Claude mode has something to say for this video.</summary>
    public bool ShowsClaudeModeCard => ClaudeModeOn && ClaudeMode.Phase != ClaudeModePhase.Idle;

    /// <summary>The choice, remembered in Settings for every new video. Choosing Claude on a video that is still new starts it.</summary>
    public async Task ChooseClipsModeAsync(string mode)
    {
        if (ClaudeMode.Services is not { } services || mode is not (ClipsMode.Claude or ClipsMode.Pick)) return;
        await services.Save(ClipsAutopilot with { Mode = mode });
        ClipStyleReopened = false;
        Announcement?.Invoke(this, mode == ClipsMode.Claude ? "Claude does it all, for every new video." : "You pick the clips. Claude suggests them.");
        if (mode == ClipsMode.Claude) await ClaudeModeContinueAsync();
        else if (ClaudeMode.Phase == ClaudeModePhase.Blocked) { ClaudeMode.Phase = ClaudeModePhase.Idle; ClaudeMode.Blocker = null; }
        MakeItNotify();
    }

    public Task SetClaudeClipCountAsync(int count) => ClaudeMode.Services is { } services && ClipsMode.Counts.Contains(count)
        ? services.Save(ClipsAutopilot with { Count = count }) : Task.CompletedTask;
    public Task SetClaudeSpendCapAsync(int usd) => ClaudeMode.Services is { } services && ClipsMode.CapsUsd.Contains(usd)
        ? services.Save(ClipsAutopilot with { CapUsd = usd }) : Task.CompletedTask;

    /// <summary>"Top 3 clips · up to $2.00 per video for voice · Opus, extra high". Generated music draws on the same cap.</summary>
    public string ClaudeModeMeta
    {
        get
        {
            var settings = ClipsAutopilot;
            var spend = settings.CapUsd == 0 ? "no paid voice" : $"up to {MakeItController.Dollars(settings.CapUsd)} per video for voice";
            return $"Top {settings.Count} {(settings.Count == 1 ? "clip" : "clips")} · {spend} · Opus, extra high";
        }
    }

    /// <summary>"✦ Claude does it all · up to $2.00", or without an amount at $0.</summary>
    public string ClaudeModeButtonTitle => ClipsAutopilot.CapUsd == 0 ? "✦ Claude does it all" : "✦ Claude does it all · up to " + MakeItController.Dollars(ClipsAutopilot.CapUsd);

    // MARK: The automatic run

    /// <summary>A newly imported video: Claude mode may run on it once it is transcribed.</summary>
    public void ArmClaudeMode()
    {
        if (ClaudeMode.Phase != ClaudeModePhase.Idle || IsReadOnly) return;
        ClaudeMode.Armed = true;
        // Numbers only: the transcribe stage runs from the video's arming until its transcript is in.
        ClaudeMode.Clock = new();
        if (!HasTranscript) ClaudeMode.Clock.Begin(ClaudeModeStage.Transcribe);
        if (ClaudeModeOn) ClaudeMode.Phase = ClaudeModePhase.Waiting;
        MakeItNotify();
    }

    /// <summary>Find Clips started <paramref name="find"/>: Claude goes on once that task has ended, never inside it (it still holds
    /// the project's AI lease).</summary>
    public void ClaudeModeFindStarted(Task find)
    {
        // The whole video's frames are looked at beside Find Clips (ADR-R48), never before or in its way; nothing without faces.
        StartFramePass();
        if (!ClaudeMode.Armed || !ClaudeModeOn) return;
        ClaudeMode.Searched = true;
        ClaudeMode.Phase = ClaudeModePhase.Waiting;
        ClaudeMode.Blocker = null;
        ClaudeMode.Clock?.End(ClaudeModeStage.Transcribe);
        ClaudeMode.Clock?.Begin(ClaudeModeStage.Find);
        MakeItNotify();
        ClaudeMode.AfterFind = AfterFindAsync(find);
    }

    private async Task AfterFindAsync(Task find)
    {
        try { await find; }
        catch (Exception exception) when (exception is not OutOfMemoryException) { }
        ClaudeMode.Clock?.End(ClaudeModeStage.Find);
        await ClaudeModeContinueAsync();
    }

    /// <summary>Goes as far as it can: starts the run when there are suggestions, starts Find Clips when it needs no approval, else
    /// says what blocks it.</summary>
    public async Task ClaudeModeContinueAsync()
    {
        if (ClaudeMode.Services is not { } services || !ClaudeMode.Armed || !ClaudeModeOn || IsReadOnly || isLeaving || !HasTranscript) return;
        ClaudeMode.Clock?.End(ClaudeModeStage.Transcribe);
        if (services.Finding()) { ClaudeMode.Phase = ClaudeModePhase.Waiting; MakeItNotify(); return; }
        if (SuggestedClips.Count > 0) { StartClaudeMode(); return; }
        // Claude finds by itself once per video: a find that added nothing (Windows keeps no empty result) is not run again.
        if (project.Ai.Results.Count > 0 || services.FindProblem() is not null || ClaudeMode.Searched)
        {
            Block(new ClaudeModeBlocker.FindAgain(services.FindProblem() ?? "Claude found no clip worth posting in this video."));
            return;
        }
        ClaudeMode.Phase = ClaudeModePhase.Waiting;
        MakeItNotify();
        if (await services.FindIfFree() is { } blocker) Block(blocker);
    }

    private void Block(ClaudeModeBlocker blocker)
    {
        ClaudeMode.Phase = ClaudeModePhase.Blocked;
        ClaudeMode.Blocker = blocker;
        MakeItNotify();
    }

    /// <summary>The blocked card's one action.</summary>
    public void FixClaudeModeBlocker()
    {
        if (ClaudeMode.Phase != ClaudeModePhase.Blocked || ClaudeMode.Blocker is not { } blocker || ClaudeMode.Services is not { } services) return;
        if (blocker is not ClaudeModeBlocker.SetUp) { ClaudeMode.Phase = ClaudeModePhase.Waiting; ClaudeMode.Blocker = null; MakeItNotify(); }
        services.Fix(blocker);
    }

    /// <summary>Make top N postable with the per-video cap as its budget: the cap is the approval for paid voice.</summary>
    private void StartClaudeMode()
    {
        if (!ClaudeMode.Armed || MakeIt.Active is not null) return;
        var settings = ClipsAutopilot;
        var budget = new MakeItBudget(settings.CapUsd);
        // The card follows the pool from the first ask: a plan that is ready at once may reach the cap before the run returns.
        budget.Changed += (_, _) => MakeItNotify();
        ClaudeMode.Found = SuggestedClips.Count;
        ClaudeMode.Budget = budget;
        ClaudeMode.Clock ??= new();
        if (!MakeTopPostable(settings.Count, budget, ClaudeMode.Clock))
        {
            Block(new ClaudeModeBlocker.FindAgain("Claude couldn't start on these clips."));
            return;
        }
        ClaudeMode.Armed = false;
        ClaudeMode.Budget = budget;
        ClaudeMode.ClipIds = MakeIt.Series;
        ClaudeMode.Phase = ClaudeModePhase.Running;
        Announcement?.Invoke(this, $"Claude is making {ClaudeMode.ClipIds.Count} clips.");
        MakeItNotify();
        ClaudeMode.Task = FinishClaudeModeAsync();
    }

    private async Task FinishClaudeModeAsync()
    {
        await MakeIt.WaitForSeriesAsync();
        ClaudeMode.Phase = ClaudeModeRuns.Any(run => run.Phase == MakeItPhase.Stopped) ? ClaudeModePhase.Stopped : ClaudeModePhase.Done;
        var ready = ClaudeModeReady.Count;
        Announcement?.Invoke(this, ClaudeMode.Phase == ClaudeModePhase.Done ? $"{ready} {(ready == 1 ? "clip" : "clips")} ready. Next: Export all." : "Stopped. What was done is kept.");
        // Numbers only (ai.md §16.12): each stage's wall time, never a title, word or path.
        if (ClaudeMode.Clock is { } clock)
        {
            try { ClaudeMode.Services?.Log?.Invoke(clock.LogLine()); }
            catch (Exception exception) when (exception is not OutOfMemoryException) { }
        }
        MakeItNotify();
    }

    /// <summary>Stop: the clip in progress ends at its next safe point; finished clips stay.</summary>
    public void StopClaudeMode() { if (ClaudeMode.Running) StopMakeIt(); }

    /// <summary>Continue at the cap: approves exactly the amount shown.</summary>
    public void ContinueClaudeMode() => ClaudeMode.Budget?.ApproveNeeded();

    public IReadOnlyList<MakeItRun> ClaudeModeRuns => ClaudeMode.ClipIds.Select(MakeIt.Run).OfType<MakeItRun>().ToArray();
    public IReadOnlyList<MakeItRun> ClaudeModeReady => ClaudeModeRuns.Where(run => run.Phase == MakeItPhase.Ready).ToArray();

    // MARK: The card's lines

    /// <summary>The clip row's pill while Claude mode makes it: Ready, Making… or Waiting.</summary>
    public ClaudeClipState? ClaudeClipStateFor(string clipId)
    {
        if (!ClaudeMode.ClipIds.Contains(clipId) || MakeIt.Run(clipId) is not { } run) return null;
        return run.Phase switch
        {
            MakeItPhase.Ready => ClaudeClipState.Ready,
            MakeItPhase.Stopped => ClaudeClipState.Stopped,
            MakeItPhase.Failed => ClaudeClipState.Failed,
            MakeItPhase.Applying => ClaudeClipState.Making,
            _ => run.Lines.LastOrDefault() == "Waiting for Claude…" && MakeIt.ShownClipId != clipId ? ClaudeClipState.Waiting : ClaudeClipState.Making
        };
    }

    /// <summary>"Ready", "Making…", "Waiting", "Stopped", "Not made".</summary>
    public static string ClaudeClipLabel(ClaudeClipState state) => state switch
    {
        ClaudeClipState.Ready => "Ready", ClaudeClipState.Making => "Making…", ClaudeClipState.Waiting => "Waiting",
        ClaudeClipState.Stopped => "Stopped", _ => "Not made"
    };

    /// <summary>Card C's title: "✦ Claude is making 3 clips".</summary>
    public string ClaudeModeTitle
    {
        get
        {
            var making = ClaudeMode.ClipIds.Count == 0 ? ClipsAutopilot.Count : ClaudeMode.ClipIds.Count;
            return $"✦ Claude is making {making} {(making == 1 ? "clip" : "clips")}";
        }
    }

    /// <summary>Card C's steps: the transcript, Find Clips, then each clip.</summary>
    public IReadOnlyList<ClaudeModeStep> ClaudeModeSteps
    {
        get
        {
            List<ClaudeModeStep> steps = [];
            if (project.Transcript is { } transcript)
                steps.Add(new("transcribed", ClaudeModeStepState.Done, "Transcribed " + Duration(transcript.Words.LastOrDefault()?.End ?? 0)));
            else steps.Add(new("transcribed", ClaudeModeStepState.Now, "Waiting for the transcript"));
            if (ClaudeMode.Services?.Finding() == true) steps.Add(new("found", ClaudeModeStepState.Now, "Finding clips…"));
            else if (ClaudeMode.Found > 0) steps.Add(new("found", ClaudeModeStepState.Done, "Found the best moments", $"{ClaudeMode.Found} · top {ClaudeMode.ClipIds.Count} kept"));
            var runs = ClaudeModeRuns;
            for (var index = 0; index < runs.Count; index++)
            {
                var run = runs[index];
                var number = index + 1;
                var title = Clips.FirstOrDefault(clip => clip.Id == run.ClipId)?.Title is { } name ? $" “{name}”" : "";
                steps.Add(run.Phase switch
                {
                    MakeItPhase.Ready => new(run.ClipId, ClaudeModeStepState.Done, $"Clip {number}{title} ready", Duration(run.Seconds)),
                    MakeItPhase.Stopped => new(run.ClipId, ClaudeModeStepState.Note, $"Clip {number} stopped · what was done is kept"),
                    MakeItPhase.Failed => new(run.ClipId, ClaudeModeStepState.Note, $"Clip {number}: {run.Failure}"),
                    _ when ClaudeClipStateFor(run.ClipId) == ClaudeClipState.Waiting => new(run.ClipId, ClaudeModeStepState.Todo, $"Clip {number} waits"),
                    _ => new(run.ClipId, ClaudeModeStepState.Now, $"Clip {number}: " + ClaudeLine(run.Lines.LastOrDefault() ?? "Reading the clip…"),
                        run.Spent > 0 ? MakeItController.Dollars(run.Spent) : "")
                });
            }
            return steps;
        }
    }

    /// <summary>A run's progress line as the card says it: "Voicing 2 fixes…" reads "rewording 2 phrases in your voice…".</summary>
    public static string ClaudeLine(string line)
    {
        if (line.StartsWith("Voicing ", StringComparison.Ordinal) && int.TryParse(new string(line[8..].TakeWhile(char.IsDigit).ToArray()), out var count))
            return $"rewording {count} {(count == 1 ? "phrase" : "phrases")} in your voice…";
        return line.Length == 0 ? line : char.ToLowerInvariant(line[0]) + line[1..];
    }

    /// <summary>Card C's progress: finished clips over all, the running one counting half.</summary>
    public double ClaudeModeProgress
    {
        get
        {
            var runs = ClaudeModeRuns;
            if (runs.Count == 0) return 0;
            return runs.Sum(run => run.Running ? (run.Phase == MakeItPhase.Applying ? 0.5 : 0.1) : 1) / runs.Count;
        }
    }

    /// <summary>"Spent $0.42 of $2.00".</summary>
    public string ClaudeModeSpent => ClaudeMode.Budget is { } budget ? $"Spent {MakeItController.Dollars(budget.Spent)} of {MakeItController.Dollars(budget.Approved)}" : "";

    /// <summary>Card C's footer: what was spent and the next step.</summary>
    public string ClaudeModeFooter => !ClaudeMode.Running ? "Next: wait. Claude starts once the clips are found."
        : ClaudeModeSpent + (ClaudeMode.Budget?.Needed is not null ? " · Next: Continue, or Stop to keep what's done." : " · Next: wait, or Stop to keep what's done.");

    /// <summary>Card D's summary: "Spent $0.61 of $2.00 · 4 phrases in your voice".</summary>
    public string ClaudeModeSummary
    {
        get
        {
            var voiced = ClaudeModeRuns.SelectMany(run => run.Rows).Count(row => row.Id.StartsWith("rewrite-", StringComparison.Ordinal) && row.Undoable && !row.Undone);
            return string.Join(" · ", new[] { ClaudeModeSpent, voiced == 0 ? "your own words" : $"{voiced} {(voiced == 1 ? "phrase" : "phrases")} in your voice" }.Where(part => part.Length > 0));
        }
    }

    /// <summary>Card D's title: "✦ 3 clips ready", or "Stopped · what was done is kept".</summary>
    public string ClaudeModeDoneTitle => ClaudeMode.Phase == ClaudeModePhase.Stopped ? "Stopped · what was done is kept"
        : $"✦ {ClaudeModeReady.Count} {(ClaudeModeReady.Count == 1 ? "clip" : "clips")} ready";

    /// <summary>"Export all 3 · 16:9 + 9:16".</summary>
    public string ClaudeExportAllTitle => $"Export all {ClaudeModeReady.Count} · " + string.Join(" + ", MakeItStyle.Shapes.Select(ShapeName));

    public bool CanClaudeExportAll => ClaudeModeReady.Count > 0 && !ClaudeExporting && MakeIt.Services?.Export is not null &&
        ClaudeModeReady.All(run => ExportBlocked(false, false, run.ClipId) is null);

    /// <summary>Card D's next step.</summary>
    public string ClaudeModeNextStep => ClaudeExporting ? "Next: wait for the export."
        : ClaudeExported.Count > 0 ? "Next: post them. The first post text is copied; each is beside its video."
        : ClaudeModeReady.Count == 0 ? "Next: Review, or ✦ Make it postable on a clip."
        : "Next: Export. Each post text is copied beside its video.";

    // MARK: Export all

    /// <summary>Every ready clip in its style's shapes, into the export folder. Each post text is written beside its videos as
    /// <c>&lt;name&gt;.txt</c>, and the first one is copied. A clip that fails is named; the rest still render.</summary>
    public async Task<bool> ClaudeExportAllAsync()
    {
        if (!CanClaudeExportAll || MakeIt.Services?.Export is not { } export) return false;
        var runs = ClaudeModeReady;
        CopyMakeItPostText(runs[0]);
        ClaudeExporting = true;
        ClaudeExported.Clear();
        ClaudeExportProblems.Clear();
        MakeItNotify();
        try
        {
            foreach (var run in runs)
            {
                try
                {
                    var files = await export(run.ClipId, MakeItStyle.Shapes, CancellationToken.None);
                    var post = MakeItPost(run);
                    foreach (var file in files)
                    {
                        run.Exported.Add(file);
                        ClaudeExported.Add(file);
                        if (post.Length > 0) await File.WriteAllTextAsync(Path.ChangeExtension(file, ".txt"), post);
                    }
                }
                catch (Exception exception) when (exception is not OutOfMemoryException)
                {
                    var title = Clips.FirstOrDefault(clip => clip.Id == run.ClipId)?.Title ?? run.ClipId;
                    var message = UiError.Message(exception, "Export");
                    ClaudeExportProblems.Add($"“{title}” didn't export{(message.Length == 0 ? "." : ": " + message)}");
                }
                MakeItNotify();
            }
            Announcement?.Invoke(this, ClaudeExported.Count == 1 ? "Exported 1 video." : $"Exported {ClaudeExported.Count} videos.");
            return ClaudeExportProblems.Count == 0;
        }
        finally
        {
            ClaudeExporting = false;
            MakeItNotify();
        }
    }

    /// <summary>Review: the Make it postable panel on the first ready clip (its series list reaches the others).</summary>
    public void ReviewClaudeMode()
    {
        if ((ClaudeModeReady.FirstOrDefault() ?? ClaudeModeRuns.FirstOrDefault()) is not { } first) return;
        MakeIt.ShownClipId = first.ClipId;
        SetScope(first.ClipId);
        MakeItShownRequest();
    }

    // MARK: Status bar

    /// <summary>"✦ Claude does it all · top 3 · ≤$2"; "✦ Claude does it all · Finding clips…" while Find Clips runs for it; "✦ Claude does
    /// it all · 1 of 3 ready · $0.42 / $2" while it runs, each clip counted as it is ready (design §6.7); "Choose how clips are made" until
    /// chosen; null in "I'll pick" mode, where the clip style item reads "Style: …".</summary>
    public string? ClaudeModeStatus
    {
        get
        {
            var settings = ClipsAutopilot;
            if (settings.Mode == ClipsMode.Claude)
            {
                if (ClaudeMode.Running && ClaudeMode.Budget is { } budget)
                    return $"✦ Claude does it all · {ClaudeModeReady.Count} of {ClaudeMode.ClipIds.Count} ready · {MakeItController.Dollars(budget.Spent)} / ${settings.CapUsd}";
                return ClaudeMode.Armed && ClaudeMode.Services?.Finding() == true ? "✦ Claude does it all · Finding clips…" : settings.Summary;
            }
            return settings.Mode is null && ShowsClipsModeCard ? "Choose how clips are made" : null;
        }
    }
}
