#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Services.Settings;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.MakeItPostableTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>"✦ Claude does it all" on Windows (design §6.6, §6.7), twin of the Mac <c>ClaudeModeTests</c>: card A asks once and the
/// choice persists; a newly imported video, once transcribed, runs Find Clips and then Make top N postable with the per-video cap as
/// its budget, started only after the find task has ended; the cap stops the run until Continue approves exactly the shortfall;
/// card D exports every ready clip with its post text beside it. Stub services only: nothing is sent or paid.</summary>
public sealed class ClaudeModeTests
{
    /// <summary>In-memory settings and a stub Find Clips that adds four suggestions once its gate opens.</summary>
    internal sealed class Claude
    {
        internal ClipsAutopilotSettings Settings { get; set; } = new(ClipsMode.Claude, 3, 2);
        internal int Saves { get; private set; }
        internal bool Finding { get; private set; }
        internal string? Problem { get; set; }
        internal List<ClaudeModeBlocker> Fixes { get; } = [];
        internal ClaudeModeBlocker? Blocker { get; set; }
        internal TaskCompletionSource Gate { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int Finds { get; private set; }
        /// <summary>The scores of the suggestions the find adds, by start word (0, 20, 40, 60); empty finds nothing.</summary>
        internal int[] Scores { get; set; } = [4, 9, 7, 8];

        internal ClaudeModeServices Services(EditorViewModel editor) => new(
            () => Settings,
            value => { Settings = value; Saves++; return Task.CompletedTask; },
            () => Finding,
            () => Problem,
            () =>
            {
                if (Blocker is { } blocker) return Task.FromResult<ClaudeModeBlocker?>(blocker);
                Finds++;
                Finding = true;
                editor.ClaudeModeFindStarted(FindAsync(editor));
                return Task.FromResult<ClaudeModeBlocker?>(null);
            },
            Fixes.Add);

        private async Task FindAsync(EditorViewModel editor)
        {
            await Gate.Task;
            if (Scores.Length > 0)
                editor.AddAiResult(Result(Scores.Select((score, index) => new AiClip("Clip " + index, "", score, "w" + index * 20, "w" + (index * 20 + 9))).ToArray()));
            else editor.AddAiResult(Result([]));
            Finding = false;
        }
    }

    /// <summary>A newly imported, transcribed video with no clips yet, Claude mode's stubs and Make it postable's.</summary>
    internal static (EditorViewModel Editor, Claude Claude, Stub Stub) Video(Claude? claude = null, Stub? stub = null)
    {
        var editor = RewriteAutoFixTests.Editor();
        claude ??= new Claude();
        stub ??= new Stub();
        // Each clip of the .clips request gets its own plan: a filler cut and one rewrite.
        stub.Series = request => new(((ClipAutopilotMode.Clips)request.Mode).Spans.Select((span, index) => Plan(span.Start, span.End, 9 - index) with
            { Corrections = [], Zooms = [], Questions = [], Cuts = [new(span.Start + 1, span.Start + 1, ClipAutopilotCutKind.Filler, "um")], Rewrites = [new(span.Start + 3, span.Start + 4, "much clearer", "a stumble")] }).ToArray(), [], []);
        editor.MakeIt.Services = stub.Services();
        editor.ClaudeMode.Services = claude.Services(editor);
        editor.ArmClaudeMode();
        return (editor, claude, stub);
    }

    [Fact]
    public async Task CardAAsksOnceAndTheChoicePersists()
    {
        var (editor, claude, _) = Video(new Claude { Settings = new() });
        Assert.True(editor.ShowsClipsModeCard);
        Assert.Equal("Choose how clips are made", editor.ClaudeModeStatus);
        Assert.Equal("Top 3 clips · up to $2.00 per video for voice · Opus, extra high", editor.ClaudeModeMeta);
        Assert.Equal("✦ Claude does it all · up to $2.00", editor.ClaudeModeButtonTitle);
        await editor.ChooseClipsModeAsync(ClipsMode.Pick);
        Assert.Equal((ClipsMode.Pick, 1), (claude.Settings.Mode, claude.Saves));
        Assert.False(editor.ShowsClipsModeCard);
        Assert.Null(editor.ClaudeModeStatus);
        Assert.Equal(0, claude.Finds);
        // The next video reads the remembered choice: no card A.
        var (next, _, _) = Video(new Claude { Settings = claude.Settings });
        Assert.False(next.ShowsClipsModeCard);
        Assert.False(next.ShowsClaudeModeCard);
        // Choosing Claude on a video that is still new starts it.
        var (fresh, chooser, _) = Video(new Claude { Settings = new() });
        await fresh.ChooseClipsModeAsync(ClipsMode.Claude);
        Assert.Equal(1, chooser.Finds);
        Assert.Equal(ClaudeModePhase.Waiting, fresh.ClaudeMode.Phase);
        Assert.Equal("✦ Claude does it all · top 3 · ≤$2", fresh.ClaudeModeStatus);
        await fresh.SetClaudeClipCountAsync(5);
        await fresh.SetClaudeSpendCapAsync(5);
        await fresh.SetClaudeSpendCapAsync(4);
        Assert.Equal((5, 5), (chooser.Settings.Count, chooser.Settings.CapUsd));
    }

    [Fact]
    public async Task ItStartsOnlyAfterTheFindTaskEndsWithTheCapAsItsBudget()
    {
        var (editor, claude, stub) = Video();
        await editor.ClaudeModeContinueAsync();
        Assert.Equal(1, claude.Finds);
        Assert.Equal(ClaudeModePhase.Waiting, editor.ClaudeMode.Phase);
        Assert.Equal("Finding the best moments…", editor.ClaudeModeSteps[1].Text);
        // While the find task runs nothing starts, even when Claude is asked to go on again.
        await editor.ClaudeModeContinueAsync();
        Assert.Empty(stub.Requests);
        Assert.Equal(1, claude.Finds);
        claude.Gate.SetResult();
        await editor.ClaudeMode.WaitAsync();
        await editor.ClaudeMode.WaitAsync();
        var request = Assert.Single(stub.Requests);
        Assert.Equal([new WordSpan(20, 29), new WordSpan(60, 69), new WordSpan(40, 49)], ((ClipAutopilotMode.Clips)request.Mode).Spans);
        Assert.Equal(ClaudeModePhase.Done, editor.ClaudeMode.Phase);
        Assert.Equal(2m, editor.ClaudeMode.Budget!.Cap);
        Assert.Equal(3, editor.ClaudeMode.ClipIds.Count);
        Assert.All(editor.ClaudeModeRuns, run => Assert.Same(editor.ClaudeMode.Budget, run.Budget));
        Assert.Equal(("Found the best moments", "4 · top 3 kept"), (editor.ClaudeModeSteps[1].Text, editor.ClaudeModeSteps[1].Detail));
        Assert.Equal("✦ 3 clips ready", editor.ClaudeModeDoneTitle);
        Assert.Equal(ClaudeClipState.Ready, editor.ClaudeClipStateFor(editor.ClaudeMode.ClipIds[0]));
        Assert.Equal("Export all 3 · 16:9 + 9:16", editor.ClaudeExportAllTitle);
        Assert.Equal("Next: Export. Each post text is copied beside its video.", editor.ClaudeModeNextStep);
        // It ran once: a later transcript or Continue never starts it again on this video.
        await editor.ClaudeModeContinueAsync();
        Assert.Single(stub.Requests);
    }

    [Fact]
    public async Task AReopenedOrReadOnlyProjectNeverStarts()
    {
        var reopened = RewriteAutoFixTests.Editor();
        var claude = new Claude();
        reopened.ClaudeMode.Services = claude.Services(reopened);
        await reopened.ClaudeModeContinueAsync();
        Assert.Equal((0, ClaudeModePhase.Idle), (claude.Finds, reopened.ClaudeMode.Phase));
        Assert.False(reopened.ShowsClaudeModeCard);
        var (locked, lockedClaude, _) = Video();
        locked.SetMediaUnavailable(true);
        await locked.ClaudeModeContinueAsync();
        Assert.Equal(0, lockedClaude.Finds);
        Assert.False(locked.ShowsClipsModeCard);
    }

    [Fact]
    public async Task WithoutAnAIItSaysSoWithTheOneFix()
    {
        var (editor, claude, _) = Video(new Claude { Blocker = new ClaudeModeBlocker.SetUp("Claude isn't set up yet.") });
        await editor.ClaudeModeContinueAsync();
        Assert.Equal(ClaudeModePhase.Blocked, editor.ClaudeMode.Phase);
        Assert.Equal("Set Up Claude…", editor.ClaudeMode.Blocker!.Action);
        editor.FixClaudeModeBlocker();
        Assert.IsType<ClaudeModeBlocker.SetUp>(Assert.Single(claude.Fixes));
        Assert.Equal(ClaudeModePhase.Blocked, editor.ClaudeMode.Phase);
        // A send that asks first waits for Find Clips' own inline approval; its find then goes on as any other.
        var (asking, asker, _) = Video(new Claude { Blocker = new ClaudeModeBlocker.ApproveSend("Claude waits for your OK.") });
        await asking.ClaudeModeContinueAsync();
        Assert.Equal("Find Clips", asking.ClaudeMode.Blocker!.Action);
        asking.FixClaudeModeBlocker();
        Assert.Equal(ClaudeModePhase.Waiting, asking.ClaudeMode.Phase);
        Assert.IsType<ClaudeModeBlocker.ApproveSend>(Assert.Single(asker.Fixes));
        // Find Clips found nothing: find again.
        var (empty, emptyClaude, _) = Video(new Claude { Scores = [] });
        emptyClaude.Gate.SetResult();
        await empty.ClaudeModeContinueAsync();
        await empty.ClaudeMode.WaitAsync();
        Assert.Equal(("Find Clips Again", "Claude found no clip worth posting in this video."), (empty.ClaudeMode.Blocker!.Action, empty.ClaudeMode.Blocker.Reason));
    }

    [Fact]
    public async Task TheCapStopsTheRunAndContinueApprovesExactlyTheShortfall()
    {
        var calls = 0;
        var stub = new Stub { VoiceReady = true };
        var (editor, claude, _) = Video(new Claude { Settings = new(ClipsMode.Claude, 1, 1) }, stub);
        stub.Voice = _ => ++calls == 1 ? new(new MakeItRewriteResult.OverCap(1.234m)) : new(new MakeItRewriteResult.Voiced(["s1"]), 1.234m);
        claude.Gate.SetResult();
        var waited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        editor.MakeItChanged += (_, _) => { if (editor.ClaudeMode.Budget?.Needed is not null) waited.TrySetResult(); };
        await editor.ClaudeModeContinueAsync();
        await editor.ClaudeMode.AfterFind!;
        await waited.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Equal(0.24m, editor.ClaudeMode.Budget!.Needed);
        Assert.EndsWith("Next: Continue, or Stop to keep what's done.", editor.ClaudeModeFooter, StringComparison.Ordinal);
        Assert.Equal("✦ Claude does it all · $0.00 / $1", editor.ClaudeModeStatus);
        editor.ContinueClaudeMode();
        await editor.ClaudeMode.WaitAsync();
        Assert.Equal(1.24m, editor.ClaudeMode.Budget.Approved);
        Assert.Equal(1.234m, editor.ClaudeMode.Budget.Spent);
        Assert.Equal(ClaudeModePhase.Done, editor.ClaudeMode.Phase);
        Assert.Equal("Spent $1.24 of $1.24 · 1 phrase in your voice", editor.ClaudeModeSummary);
    }

    [Fact]
    public async Task StopAtTheCapKeepsWhatIsDone()
    {
        var stub = new Stub { VoiceReady = true, Voice = _ => new(new MakeItRewriteResult.OverCap(5m)) };
        var (editor, claude, _) = Video(new Claude { Settings = new(ClipsMode.Claude, 3, 1) }, stub);
        claude.Gate.SetResult();
        var waited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        editor.MakeItChanged += (_, _) => { if (editor.ClaudeMode.Budget?.Needed is not null) waited.TrySetResult(); };
        await editor.ClaudeModeContinueAsync();
        await editor.ClaudeMode.AfterFind!;
        await waited.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        editor.StopClaudeMode();
        await editor.ClaudeMode.WaitAsync();
        Assert.Equal(ClaudeModePhase.Stopped, editor.ClaudeMode.Phase);
        Assert.Equal(1m, editor.ClaudeMode.Budget!.Approved);
        Assert.Equal(0m, editor.ClaudeMode.Budget.Spent);
        Assert.Equal("Stopped · what was done is kept", editor.ClaudeModeDoneTitle);
        // The first clip's cuts stay.
        Assert.Contains("w21", editor.State!.CutWordIds);
    }

    [Fact]
    public async Task AZeroCapNeverVoicesOrAsks()
    {
        var stub = new Stub { VoiceReady = true };
        var (editor, claude, _) = Video(new Claude { Settings = new(ClipsMode.Claude, 3, 0) }, stub);
        Assert.Equal("Top 3 clips · no paid voice · Opus, extra high", editor.ClaudeModeMeta);
        claude.Gate.SetResult();
        await editor.ClaudeModeContinueAsync();
        await editor.ClaudeMode.WaitAsync();
        await editor.ClaudeMode.WaitAsync();
        Assert.Empty(stub.Voiced);
        Assert.Null(editor.ClaudeMode.Budget!.Needed);
        Assert.Equal(ClaudeModePhase.Done, editor.ClaudeMode.Phase);
        Assert.Equal("Spent $0.00 of $0.00 · your own words", editor.ClaudeModeSummary);
    }

    [Theory]
    [InlineData("off", typeof(ClipAutopilotTone.AsSaid))]
    [InlineData("fix-only", typeof(ClipAutopilotTone.Fixed))]
    public async Task TheRunSendsTheClipStylesEffectiveTone(string rewording, Type expected)
    {
        var (editor, claude, stub) = Video();
        editor.ChooseClipStyle(Style() with { Rewording = rewording, Tone = "viral-youtuber" }, Library, collapse: true);
        claude.Gate.SetResult();
        await editor.ClaudeModeContinueAsync();
        await editor.ClaudeMode.WaitAsync();
        await editor.ClaudeMode.WaitAsync();
        Assert.IsType(expected, Assert.Single(stub.Requests).Tone);
    }

    [Fact]
    public async Task ExportAllWritesEachPostTextBesideItsVideosAndNamesAFailure()
    {
        var (editor, claude, stub) = Video();
        claude.Gate.SetResult();
        await editor.ClaudeModeContinueAsync();
        await editor.ClaudeMode.WaitAsync();
        await editor.ClaudeMode.WaitAsync();
        Assert.True(editor.CanClaudeExportAll);
        try
        {
            Assert.True(await editor.ClaudeExportAllAsync());
            Assert.Equal(6, editor.ClaudeExported.Count);
            Assert.Equal(3, stub.Exports.Count);
            Assert.Equal(EditorViewModel.MakeItPostCopy(editor.ClaudeModeReady[0]), stub.Copied);
            foreach (var run in editor.ClaudeModeReady)
                Assert.All(run.Exported, file => Assert.Equal(EditorViewModel.MakeItPostCopy(run), File.ReadAllText(Path.ChangeExtension(file, ".txt"))));
            Assert.Equal("Next: post them. The first post text is copied; each is beside its video.", editor.ClaudeModeNextStep);
        }
        finally { if (Directory.Exists(stub.ExportFolder)) Directory.Delete(stub.ExportFolder, true); }
        // A clip that fails is named; the rest still render.
        var (broken, brokenClaude, brokenStub) = Video();
        brokenClaude.Gate.SetResult();
        await broken.ClaudeModeContinueAsync();
        await broken.ClaudeMode.WaitAsync();
        await broken.ClaudeMode.WaitAsync();
        var failing = broken.ClaudeMode.ClipIds[1];
        var services = broken.MakeIt.Services!;
        broken.MakeIt.Services = services with
        {
            Export = (clip, shapes, ct) => clip == failing ? throw new IOException("disk full") : services.Export!(clip, shapes, ct)
        };
        try
        {
            Assert.False(await broken.ClaudeExportAllAsync());
            Assert.Equal(4, broken.ClaudeExported.Count);
            Assert.StartsWith("“Sleep wins” didn't export", Assert.Single(broken.ClaudeExportProblems), StringComparison.Ordinal);
        }
        finally { if (Directory.Exists(brokenStub.ExportFolder)) Directory.Delete(brokenStub.ExportFolder, true); }
    }

    [Fact]
    public void TheCardSaysEachRunsLineInItsOwnWords()
    {
        Assert.Equal("rewording 2 phrases in your voice…", EditorViewModel.ClaudeLine("Voicing 2 fixes…"));
        Assert.Equal("rewording 1 phrase in your voice…", EditorViewModel.ClaudeLine("Voicing 1 fix…"));
        Assert.Equal("cutting 3 fillers…", EditorViewModel.ClaudeLine("Cutting 3 fillers…"));
        Assert.Equal(["Ready", "Making…", "Waiting", "Stopped", "Not made"],
            new[] { ClaudeClipState.Ready, ClaudeClipState.Making, ClaudeClipState.Waiting, ClaudeClipState.Stopped, ClaudeClipState.Failed }.Select(EditorViewModel.ClaudeClipLabel));
    }

    [Fact]
    public void TheCardsSettingsAndHooksAreWired()
    {
        var app = Path.Combine(Path.GetDirectoryName(Root)!, "apps", "windows", "src", "VoxClip.App");
        var window = File.ReadAllText(Path.Combine(app, "MainWindow.xaml"));
        Assert.Contains("x:Name=\"ClaudeModeHost\"", window);
        var import = File.ReadAllText(Path.Combine(app, "MainWindow.xaml.cs"));
        Assert.True(import.IndexOf("ArmClaudeMode()", StringComparison.Ordinal) is > 0 and var arm && arm < import.IndexOf("await incoming.PromptTranscriptionAsync()", StringComparison.Ordinal));
        var page = File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.MakeIt.cs"));
        Assert.Contains("FindClips.Started += (_, find) => ViewModel.ClaudeModeFindStarted(find)", page);
        var find = File.ReadAllText(Path.Combine(app, "Controls", "FindClipsJob.cs"));
        Assert.Contains("Started?.Invoke(this, task)", find);
        var settings = File.ReadAllText(Path.Combine(app, "SettingsWindow.xaml"));
        Assert.Contains("Tag=\"Clips\"", settings);
        var card = File.ReadAllText(Path.Combine(app, "Controls", "ClipStyleCardPanel.cs"));
        foreach (var row in new[] { "\"Clips\"", "\"Spend\"", "\"Tone\"", "\"Mode\"" }) Assert.Contains(row, card);
    }
}
#endif
