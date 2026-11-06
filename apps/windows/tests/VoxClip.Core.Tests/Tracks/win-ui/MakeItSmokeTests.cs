#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.MakeItPostableTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The Windows Make it postable smoke, a headless twin of Mac <c>S-make-it</c> and <c>S-make-top3</c>: the run goes through
/// the real view model and, for the voice, the real <see cref="MakeItRewriteDriver"/> over Rewrite's own session with stub connectors
/// and runners (nothing is sent or paid). After every step: I1 something acts, I2 no shown control that can't act, I6 no paid take
/// dropped. At the end: M1 Export is ready, M2 the run is one undo step, M3 spend stays within the cap, M5 the look and speed rows
/// undo. Use publishes takes through Media's scratch audio, which this headless twin has none of, so a made take ends with its
/// session handed back for Change (M4 on the VM). S-claude-does-it-all and M7 (the review's tone row) are owed with Claude mode
/// and the tone strip.</summary>
public sealed class MakeItSmokeTests
{
    private sealed class Smoke
    {
        internal List<string> Log { get; } = [];
        internal List<string> Failures { get; } = [];
        internal List<RewriteSession> Handed { get; } = [];

        internal void Observe(EditorViewModel editor, MakeItRun run, string label)
        {
            Log.Add($"{label}: {run.Phase} · {run.Lines.LastOrDefault()} · {run.Rows.Count} rows");
            var acts = run.Running || run.Phase == MakeItPhase.Failed ? true : editor.ExportBlocked(false, false, run.ClipId) is null || run.Rows.Any(row => row.Undoable && !row.Undone);
            if (!acts) Failures.Add($"{label} I1: nothing acts");
            foreach (var row in run.Rows)
            {
                if (row.Undoable && !row.Undone && !run.Inverses.ContainsKey(row.Id)) Failures.Add($"{label} I2: '{row.Text}' shows Undo that can't act");
                if (row.Kind == MakeItRowKind.Note && row.Undoable) Failures.Add($"{label} I2: note '{row.Text}' shows Undo");
                if (row.Change is MakeItChange.Look or MakeItChange.Speed or MakeItChange.Question && row.Options.Count == 0) Failures.Add($"{label} I2: '{row.Text}' Change has no choices");
                if (row.Change == MakeItChange.Phrase && row.Words is null) Failures.Add($"{label} I2: '{row.Text}' Change has no words");
            }
            foreach (var session in Handed.Where(session => !session.HasPaidTakes)) Failures.Add($"{label} I6: a session without paid takes was handed back");
        }
    }

    [Fact]
    public async Task SMakeIt()
    {
        var smoke = new Smoke();
        var editor = Editor();
        var stub = new Stub { VoiceReady = true };
        var services = stub.Services() with
        {
            Voice = (request, ct) =>
            {
                var session = RewriteAutoFixTests.Session(new(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "x")), request.First, request.Last, editor: editor);
                RewriteAutoFixTests.Configure(session, new((_, _) => (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed)));
                var driver = new MakeItRewriteDriver(editor, request, _ => Task.FromResult<RewriteSession?>(session), _ => Task.FromResult<VoiceLabMonthlyCap?>(null), smoke.Handed.Add);
                return driver.RunAsync(ct);
            }
        };
        editor.MakeIt.Services = services;
        var before = editor.Project;
        var cap = editor.MakeItCap("c1");
        Assert.True(editor.MakeItPostable("c1"));
        var run = editor.MakeIt.Run("c1")!;
        smoke.Observe(editor, run, "click ✦ Make it postable");
        await run.Task!;
        smoke.Observe(editor, run, "the run ends");
        // M1: ready, with Export in the style's shapes.
        if (run.Phase != MakeItPhase.Ready || editor.MakeItExportTitle != "Export · 16:9 + 9:16") smoke.Failures.Add($"M1: {run.Phase} / {editor.MakeItExportTitle}");
        // M3: never past the cap shown on the button.
        if (run.Spent > (cap ?? 0)) smoke.Failures.Add($"M3: spent {run.Spent} past the cap {cap}");
        // M4: the rewrite row says what happened to the voice.
        var phrase = run.Rows.Single(row => row.Change == MakeItChange.Phrase);
        smoke.Log.Add("M4: " + phrase.Text + " · " + phrase.Detail);
        if (phrase.Detail.Length == 0) smoke.Failures.Add("M4: the rewrite row doesn't say why");
        // M5: the look and speed rows undo on their own.
        foreach (var change in new[] { MakeItChange.Look, MakeItChange.Speed })
        {
            var row = run.Rows.Single(row => row.Change == change);
            if (!editor.MakeItUndo(row.Id, run)) smoke.Failures.Add($"M5: {change} doesn't undo");
            smoke.Observe(editor, run, "Undo " + row.Text);
        }
        // M2: Undo all, then the editor's Undo, leaves the project as before the click.
        editor.MakeItUndoAll(run);
        smoke.Observe(editor, run, "Undo all");
        if (editor.Project.Edits.CutWordIds.Count != before.Edits.CutWordIds.Count || editor.Project.ClipEffects.Count != 0) smoke.Failures.Add("M2: Undo all left decisions behind");
        foreach (var session in smoke.Handed) session.Dispose();
        Assert.True(smoke.Failures.Count == 0, string.Join("\n", smoke.Failures) + "\n--- log ---\n" + string.Join("\n", smoke.Log));
    }

    /// <summary>One ✦ Make it postable run over a plan whose only rewrite is <paramref name="words"/> for words 20–21, voiced by the real
    /// driver with <paramref name="runner"/>. Returns the run, its rewrite row and the sessions handed back.</summary>
    private static async Task<(EditorViewModel Editor, MakeItRun Run, MakeItRow Row, Smoke Smoke, RewriteSession? Opened)> RunRewriteAsync(string words,
        RewriteAutoFixTests.Runner runner)
    {
        var smoke = new Smoke();
        var editor = Editor();
        RewriteSession? opened = null;
        var stub = new Stub { VoiceReady = true, Series = _ => new([Plan() with { Rewrites = [new(20, 21, words, "a stumble")] }], [], []) };
        editor.MakeIt.Services = stub.Services() with
        {
            Voice = (request, ct) =>
            {
                opened = RewriteAutoFixTests.Session(new(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "x")), request.First, request.Last, editor: editor);
                RewriteAutoFixTests.Configure(opened, runner);
                return new MakeItRewriteDriver(editor, request, _ => Task.FromResult<RewriteSession?>(opened), _ => Task.FromResult<VoiceLabMonthlyCap?>(null), smoke.Handed.Add).RunAsync(ct);
            }
        };
        Assert.True(editor.MakeItPostable("c1"));
        var run = editor.MakeIt.Run("c1")!;
        smoke.Observe(editor, run, "click ✦ Make it postable");
        await run.Task!;
        smoke.Observe(editor, run, "the run ends");
        return (editor, run, run.Rows.Single(row => row.Change == MakeItChange.Phrase), smoke, opened);
    }

    /// <summary>Mac S-duration-claude (DC1): ✦ Make it postable rewrites two words with a wording the estimate fits; its take lands far shorter, and no video duration carries it. The driver keeps it as
    /// recorded with no click, the row says why, a take was paid for, nothing is voiced into the project, the Rewrite is closed and the
    /// clip is ready to export.</summary>
    [Fact]
    public async Task SDurationClaude()
    {
        // Each quoted action at $0.001, so the take fits inside the click's cap.
        var runner = new RewriteAutoFixTests.Runner((_, _) => (RewriteDurationSettleTests.TooShort, RewriteAutoFixTests.Passed)) { Price = _ => .001m };
        var (editor, run, row, smoke, opened) = await RunRewriteAsync("much clearer wordings here", runner);
        const string line = "Phrase 1's take can't fit its place in the video, so it keeps your original audio.";
        smoke.Log.Add($"DC1: {row.Text} · {row.Detail} · spent {run.Spent} · {run.Phase}");
        if (row.Text != "Kept your words for “much clearer wordings here”" || !row.Detail.StartsWith(line, StringComparison.Ordinal)) smoke.Failures.Add($"DC1: the row reads '{row.Text} · {row.Detail}'");
        if (runner.Sends != 1 || run.Spent <= 0) smoke.Failures.Add($"DC1: {runner.Sends} takes made, {run.Spent} spent");
        if (editor.Project.VoiceLab.Segments.Count != 0) smoke.Failures.Add("DC1: a take was voiced into the project");
        if (opened?.IsOpen != false || smoke.Handed.Count != 0) smoke.Failures.Add("DC1: the Rewrite was left open");
        if (run.Phase != MakeItPhase.Ready || editor.ExportBlocked(false, false, "c1") is not null) smoke.Failures.Add($"DC1: {run.Phase}, not ready to export");
        Assert.True(smoke.Failures.Count == 0, string.Join("\n", smoke.Failures) + "\n--- log ---\n" + string.Join("\n", smoke.Log));
    }

    /// <summary>Mac S-make-it-long (MK1, ADR-R42): a planned rewrite longer than its time in the video keeps the speaker's words with no click.
    /// Nothing is priced or spent, the Rewrite ends, and the clip is ready to export.</summary>
    [Fact]
    public async Task SMakeItLong()
    {
        var runner = new RewriteAutoFixTests.Runner((_, _) => (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed));
        var (editor, run, row, smoke, opened) = await RunRewriteAsync("a much much longer phrasing than this little slot could ever hold in its time", runner);
        smoke.Log.Add($"MK1: {row.Text} · {row.Detail} · spent {run.Spent} · {run.Phase}");
        if (!row.Text.StartsWith("Kept your words for", StringComparison.Ordinal) ||
            row.Detail != "Change 1 keeps your original words: still longer than its time in the video after a fit.")
            smoke.Failures.Add($"MK1: the row reads '{row.Text} · {row.Detail}'");
        if (runner.Sends != 0 || run.VoiceSpent != 0) smoke.Failures.Add($"MK1: {runner.Sends} takes made, {run.VoiceSpent} spent on the voice");
        if (editor.Project.VoiceLab.Segments.Count != 0 || opened?.IsOpen != false || smoke.Handed.Count != 0) smoke.Failures.Add("MK1: the Rewrite didn't end");
        if (run.Phase != MakeItPhase.Ready || editor.ExportBlocked(false, false, "c1") is not null) smoke.Failures.Add($"MK1: {run.Phase}, not ready to export");
        Assert.True(smoke.Failures.Count == 0, string.Join("\n", smoke.Failures) + "\n--- log ---\n" + string.Join("\n", smoke.Log));
    }

    /// <summary>S-claude-does-it-all: a newly imported video is transcribed; Claude mode finds the clips, makes the top 3 postable
    /// within the per-video cap through the real driver, and Export all writes each post text beside its videos. After every step:
    /// C1 the card shows something that acts, C2 spend never passes what was approved, C3 the status item names the mode. At the end:
    /// CD1 done, CD2 three clips ready and kept, CD3 Export all wrote a post text beside every video, CD4 one undo step per clip.</summary>
    [Fact]
    public async Task SClaudeDoesItAll()
    {
        var failures = new List<string>();
        var log = new List<string>();
        var handed = new List<RewriteSession>();
        var (editor, claude, stub) = ClaudeModeTests.Video(stub: new Stub { VoiceReady = true });
        var services = editor.MakeIt.Services!;
        editor.MakeIt.Services = services with
        {
            Voice = (request, ct) =>
            {
                var session = RewriteAutoFixTests.Session(new(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "x")), request.First, request.Last, editor: editor);
                RewriteAutoFixTests.Configure(session, new((_, _) => (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed)));
                return new MakeItRewriteDriver(editor, request, _ => Task.FromResult<RewriteSession?>(session), _ => Task.FromResult<VoiceLabMonthlyCap?>(null), handed.Add).RunAsync(ct);
            }
        };
        void Observe(string label)
        {
            var phase = editor.ClaudeMode.Phase;
            log.Add($"{label}: {phase} · {editor.ClaudeMode.Blocker?.Reason} · {string.Join(" / ", editor.ClaudeModeSteps.Select(step => step.Text))} · runs {string.Join(", ", editor.ClaudeModeRuns.Select(run => run.Phase + " " + run.Failure))}");
            var acts = phase switch
            {
                ClaudeModePhase.Waiting => true,
                ClaudeModePhase.Running => true,
                ClaudeModePhase.Blocked => editor.ClaudeMode.Blocker is not null,
                ClaudeModePhase.Done or ClaudeModePhase.Stopped => editor.CanClaudeExportAll || editor.ClaudeModeRuns.Count > 0,
                _ => false
            };
            if (!editor.ShowsClaudeModeCard || !acts) failures.Add($"{label} C1: no card that acts ({phase})");
            if (editor.ClaudeMode.Budget is { } budget && budget.Spent > budget.Approved) failures.Add($"{label} C2: spent {budget.Spent} past {budget.Approved}");
            if (editor.ClaudeModeStatus?.StartsWith("✦ Claude does it all", StringComparison.Ordinal) != true) failures.Add($"{label} C3: status '{editor.ClaudeModeStatus}'");
        }
        Observe("open a new video");
        editor.SetTranscript(editor.Project.Transcript!);
        await editor.ClaudeModeContinueAsync();
        Observe("the transcript arrives; Find Clips starts");
        claude.Gate.SetResult();
        await editor.ClaudeMode.WaitAsync();
        Observe("the clips are made");
        if (editor.ClaudeMode.Phase != ClaudeModePhase.Done) failures.Add($"CD1: {editor.ClaudeMode.Phase}");
        if (editor.ClaudeModeReady.Count != 3 || editor.SuggestedClips.Count != 1) failures.Add($"CD2: {editor.ClaudeModeReady.Count} ready, {editor.SuggestedClips.Count} suggestions left");
        try
        {
            await editor.ClaudeExportAllAsync();
            Observe("Export all");
            if (editor.ClaudeExported.Count != 6 || editor.ClaudeExported.Any(file => !File.Exists(Path.ChangeExtension(file, ".txt")))) failures.Add($"CD3: {editor.ClaudeExported.Count} files");
        }
        finally { if (Directory.Exists(stub.ExportFolder)) Directory.Delete(stub.ExportFolder, true); }
        for (var index = 0; index < 3; index++)
        {
            if (editor.UndoActionName != "Make it postable") failures.Add($"CD4: step {index} is '{editor.UndoActionName}'");
            editor.Undo();
        }
        foreach (var session in handed) session.Dispose();
        Assert.True(failures.Count == 0, string.Join("\n", failures) + "\n--- log ---\n" + string.Join("\n", log));
    }

    [Fact]
    public async Task SMakeTop3()
    {
        var editor = RewriteAutoFixTests.Editor();
        AiClip Clip(int start, int score) => new("Clip " + start, "", score, "w" + start, "w" + (start + 9));
        var project = editor.Project with
        {
            Ai = new([Result([Clip(0, 4), Clip(20, 9), Clip(40, 7), Clip(60, 8)])]),
            Edits = editor.Project.Edits with
            {
                Clips = new[] { 0, 20, 40, 60 }.Select((start, index) => new ClipRange("s" + index, "w" + start, "w" + (start + 9), null, ClipOrigin.Ai, "r1", index, false)).ToArray()
            }
        };
        editor = new(project, now: () => new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero));
        var stub = new Stub
        {
            Series = request => new(((ClipAutopilotMode.Clips)request.Mode).Spans.Select((span, index) => Plan(span.Start, span.End, 9 - index) with
            { Rewrites = [], Corrections = [], Zooms = [], Questions = [], Cuts = [new(span.Start + 1, span.Start + 1, ClipAutopilotCutKind.Filler, "um")] }).ToArray(), [], [])
        };
        editor.MakeIt.Services = stub.Services();
        Assert.True(editor.MakeTopPostable());
        await editor.MakeIt.WaitForSeriesAsync();
        // T1 ranking, T2 all ready, T3 kept, T4 one step each.
        Assert.Equal(["s1", "s3", "s2"], editor.MakeIt.Series);
        Assert.All(editor.MakeIt.Series, id => Assert.Equal(MakeItPhase.Ready, editor.MakeIt.Run(id)!.Phase));
        Assert.Equal(["s0"], editor.SuggestedClips.Select(clip => clip.Id).ToArray());
        for (var index = 0; index < 3; index++) { Assert.Equal("Make it postable", editor.UndoActionName); editor.Undo(); }
        Assert.False(editor.CanUndo);
    }
}
#endif
