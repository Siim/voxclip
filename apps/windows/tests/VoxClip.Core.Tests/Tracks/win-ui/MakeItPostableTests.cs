#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>✦ Make it postable on Windows (design §6.7), twin of the Mac <c>MakeItPostableTests</c>: one click plans the clip, applies
/// every decision as one undo step within the cap shown on the button, and lists each decision in the review with ▶, Undo and Change.
/// The planner, the voice and the export are stubs: nothing is sent or paid.</summary>
public sealed class MakeItPostableTests
{
    internal static string Root => SharedResources.ResolveRoot();

    /// <summary>The 80-word editor with clip c1 on words 10–40 (a suggestion when <paramref name="suggested"/>), and nothing to undo.</summary>
    internal static EditorViewModel Editor(bool suggested = false, string? title = "Old", int? score = null)
    {
        var editor = RewriteAutoFixTests.Editor();
        var clip = new ClipRange("c1", "w10", "w40", title, suggested ? ClipOrigin.Ai : ClipOrigin.Manual, suggested && score is not null ? "r1" : null, suggested && score is not null ? 0 : null, !suggested);
        var project = editor.Project with { Edits = editor.Project.Edits with { Clips = [clip] } };
        if (suggested && score is { } value)
            project = project with { Ai = new([Result([new AiClip(title ?? "", "", value, "w10", "w40")])]) };
        return new(project, now: () => new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero));
    }

    internal static AiResult Result(IReadOnlyList<AiClip> clips) =>
        new("r1", DateTimeOffset.UnixEpoch, "stub", "model", ClipPreset.Best, null, null, new string('0', 64), clips);

    internal static ClipStyle Style(string preset = "auto") => ClipStyleCatalog.Load(Root).Find(preset).Style;
    internal static IReadOnlySet<string> Library => CaptionStyleLibrary.Load(Root).Styles.Select(style => style.Id).ToHashSet(StringComparer.Ordinal);

    /// <summary>A plan for words 10–40 with every kind of decision.</summary>
    internal static ClipAutopilotPlan Plan(int start = 10, int end = 40, int score = 8) => new()
    {
        StartWord = start, EndWord = end, Title = "Sleep wins", Hook = "Sleep beats coffee",
        Cuts = [new(start + 2, start + 2, ClipAutopilotCutKind.Filler, "a filler")],
        Corrections = [new(start + 4, "word" + (start + 4), "Coffee", "the name")],
        Rewrites = [new(start + 10, start + 11, "much clearer", "a stumble")],
        CaptionChoice = new("vox-bold", new("Inter", 800), ClipAutopilotCaptionCase.Upper, 3, "punchy"),
        ClipLookChoice = new(ClipLook.Warm, "warmth"),
        SpeedChoice = new(1.1, "pace"),
        Zooms = [new(start + 5, start + 7, 1.2, "emphasis")],
        MusicChoices = [new("Morning", "calm", "soft piano", "calm", 18)], MusicPick = 0,
        PostText = "Sleep first. #sleep", Score = score, Verdict = ClipAutopilotVerdict.Post, Seconds = 28,
        Questions = [new("Keep the intro?", "Yes", ["Yes", "No"])]
    };

    /// <summary>Stub services: the plan comes back at once (or after <paramref name="gate"/>), the voice answers with <paramref name="voice"/>.</summary>
    internal sealed class Stub
    {
        internal List<ClipAutopilotRequest> Requests { get; } = [];
        internal List<MakeItRewriteRequest> Voiced { get; } = [];
        internal Func<ClipAutopilotRequest, ClipAutopilotSeries> Series { get; set; } = _ => new([Plan()], [], []);
        internal Func<MakeItRewriteRequest, MakeItRewriteOutcome> Voice { get; set; } = _ => new(new MakeItRewriteResult.NeedsYou("Rewrite is waiting for you."));
        internal TaskCompletionSource? Gate { get; set; }
        internal bool VoiceReady { get; set; }
        internal string? Copied { get; private set; }
        internal List<(string Clip, IReadOnlyList<ExportAspect> Shapes)> Exports { get; } = [];
        internal string ExportFolder { get; } = Path.Combine(Path.GetTempPath(), "voxclip-make-it-" + Guid.NewGuid().ToString("N"));

        internal MakeItServices Services() => new(
            async (request, progress, ct) =>
            {
                Requests.Add(request);
                progress.Report(new ClipAutopilotProgress.Planning(0, 1));
                if (Gate is { } gate) await gate.Task.WaitAsync(ct);
                ct.ThrowIfCancellationRequested();
                return Series(request);
            },
            (rewrite, _) => { Voiced.Add(rewrite); return Task.FromResult(Voice(rewrite)); },
            () => VoiceReady,
            (clip, shapes, _) =>
            {
                Exports.Add((clip, shapes));
                Directory.CreateDirectory(ExportFolder);
                var files = shapes.Select(shape => Path.Combine(ExportFolder, clip + "-" + EditorViewModel.ShapeName(shape).Replace(':', 'x') + ".mp4")).ToArray();
                foreach (var file in files) File.WriteAllText(file, "");
                return Task.FromResult<IReadOnlyList<string>>(files);
            },
            text => Copied = text)
        { SharedRoot = Root, Prices = VoxClip.Core.Services.VoiceLab.VoiceLabPrices.Load(Root), Tones = RewriteToneCatalog.Load(Root) };
    }

    internal static async Task<MakeItRun> RunAsync(EditorViewModel editor, Stub stub, string clip = "c1")
    {
        editor.MakeIt.Services ??= stub.Services();
        Assert.True(editor.MakeItPostable(clip));
        var run = editor.MakeIt.Run(clip)!;
        await run.Task!;
        return run;
    }

    [Fact]
    public async Task OneClickAppliesEveryKindOfDecisionAndListsItInTheReview()
    {
        var editor = Editor();
        var stub = new Stub { VoiceReady = true };
        var run = await RunAsync(editor, stub);
        Assert.Equal(MakeItPhase.Ready, run.Phase);
        var project = editor.Project;
        var state = editor.State!;
        Assert.Contains("w12", state.CutWordIds);
        Assert.Equal("Coffee", state.Corrections["w14"]);
        Assert.Equal("vox-bold", project.Captions.StyleId);
        Assert.Equal("Sleep wins", state.Clips.Single().Title);
        Assert.Equal((ClipLook.Warm, 1.1), (ClipControlsProject.Controls("c1", project)!.Look, ClipControlsProject.Controls("c1", project)!.Speed));
        Assert.True(ClipHookTitle.Existing("c1", project) is not null, "the hook is a title card");
        Assert.Equal("Sleep first. #sleep", project.Share.Captions["c1"]);
        // The zoom applies as the clip's motion cue; this editor has no music sources, so music isn't applied and the review says so.
        Assert.Equal(["c1"], project.MotionCues.Select(cue => cue.ClipID));
        Assert.Empty(project.Music);
        var texts = run.Rows.Select(row => row.Text).ToArray();
        Assert.Contains("Cut “word12”", texts);
        Assert.Contains("Corrected “word14” → “Coffee”", texts);
        Assert.Contains("Claude chose the title “Sleep wins”", texts);
        Assert.Contains("Claude chose the warm look", texts);
        Assert.Contains("Claude chose 1.1× speed", texts);
        Assert.Contains(texts, text => text.StartsWith("Claude chose vox-bold captions, UPPER, 3 per line", StringComparison.Ordinal));
        Assert.Contains("“much clearer” needs you", texts);
        var zoom = run.Rows.Single(row => row.Text.StartsWith("Zoom to ", StringComparison.Ordinal));
        Assert.Equal((true, Math.Max(0, project.MotionCues[0].SourceStart - 1)), (zoom.Undoable, zoom.Play));
        Assert.Contains("Claude suggests music “Morning”", texts);
        Assert.Equal(MakeItController.HookRowText("Sleep beats coffee", "Claude"), run.Rows[^2].Text);
        Assert.Equal(MakeItRowKind.Question, run.Rows[^1].Kind);
        Assert.Equal("Claude chose “Yes”", run.Rows[^1].Detail);
        Assert.Equal(["No"], run.Rows[^1].Options);
        Assert.All(run.Rows.Where(row => row.Kind == MakeItRowKind.Note), row => Assert.False(row.Undoable));
        Assert.Equal(["Reading the clip…", "Cutting 1 filler…", "Voicing 1 fix…", "Picking music…", "Ready to post."], run.Lines);
        Assert.StartsWith("Ready to post · ", editor.MakeItHeadline(run), StringComparison.Ordinal);
        Assert.EndsWith(" · score 8/10", editor.MakeItHeadline(run), StringComparison.Ordinal);
        Assert.Equal("Sleep beats coffee\n\nSleep first. #sleep", EditorViewModel.MakeItPostCopy(run));
        Assert.Contains("Claude's cut: 0:28 finished at 1.1×", editor.MakeItLengthNotes(run));
        // The request is the clip's span, with the style's note and the Auto tone offering the catalogue.
        var request = Assert.Single(stub.Requests);
        Assert.Equal(new WordSpan(10, 40), Assert.IsType<ClipAutopilotMode.Clip>(request.Mode).Span);
        Assert.Equal("Reword only what sounds wrong or what the tone needs.", request.Note);
        Assert.IsType<ClipAutopilotTone.Auto>(request.Tone);
    }

    [Fact]
    public async Task TheWholeRunIsOneUndoStepAndEachDecisionUndoesOnItsOwn()
    {
        var editor = Editor();
        var before = editor.Project;
        var run = await RunAsync(editor, new Stub());
        Assert.Equal("Make it postable", editor.UndoActionName);
        editor.Undo();
        Assert.False(editor.CanUndo);
        Assert.Equal(before.Edits.CutWordIds, editor.Project.Edits.CutWordIds);
        Assert.Equal(before.Captions.StyleId, editor.Project.Captions.StyleId);
        Assert.Empty(editor.Project.ClipControls);
        Assert.Empty(editor.Project.ClipEffects);
        Assert.Empty(editor.Project.MotionCues);
        editor.Redo();
        // Undo on one row takes back that decision only, as its own step.
        var cut = run.Rows.First(row => row.Text == "Cut “word12”");
        Assert.True(editor.MakeItUndo(cut.Id, run));
        Assert.DoesNotContain("w12", editor.State!.CutWordIds);
        Assert.Equal("Coffee", editor.State.Corrections["w14"]);
        Assert.Equal(ClipLook.Warm, ClipControlsProject.Controls("c1", editor.Project)!.Look);
        Assert.True(run.Rows.First(row => row.Id == cut.Id).Undone);
        Assert.False(editor.MakeItUndo(cut.Id, run));
        var look = run.Rows.First(row => row.Change == MakeItChange.Look);
        Assert.True(editor.MakeItUndo(look.Id, run));
        Assert.Equal(ClipLook.Original, ClipControlsProject.Controls("c1", editor.Project)?.Look ?? ClipLook.Original);
        Assert.Equal(1.1, ClipControlsProject.Controls("c1", editor.Project)!.Speed);
        var zoom = run.Rows.First(row => row.Text.StartsWith("Zoom to ", StringComparison.Ordinal));
        Assert.Single(editor.Project.MotionCues);
        Assert.True(editor.MakeItUndo(zoom.Id, run));
        Assert.Empty(editor.Project.MotionCues);
        Assert.Equal(ClipLook.Original, ClipControlsProject.Controls("c1", editor.Project)?.Look ?? ClipLook.Original);
        editor.Undo();
        Assert.Single(editor.Project.MotionCues);
        editor.Undo();
        Assert.Equal(ClipLook.Warm, ClipControlsProject.Controls("c1", editor.Project)!.Look);
    }

    [Fact]
    public async Task UndoAllTakesBackEveryDecisionAsOneStepThePostTextToo()
    {
        var editor = Editor();
        var before = editor.Project;
        var run = await RunAsync(editor, new Stub());
        editor.MakeItUndoAll(run);
        Assert.Equal("Undo Make it postable", editor.UndoActionName);
        Assert.Equal(before.Edits.CutWordIds, editor.Project.Edits.CutWordIds);
        Assert.Empty(editor.Project.Edits.Corrections);
        Assert.Equal("Old", editor.State!.Clips.Single().Title);
        Assert.Equal(before.Captions.StyleId, editor.Project.Captions.StyleId);
        Assert.Empty(editor.Project.ClipEffects);
        Assert.False(editor.Project.Share.Captions.ContainsKey("c1"));
        Assert.Empty(editor.Project.MotionCues);
        Assert.Null(editor.MakeIt.Run("c1"));
        editor.Undo();
        Assert.Contains("w12", editor.State!.CutWordIds);
        editor.Undo();
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public async Task ThePriceIsTheCapAndEachRewriteGetsWhatIsLeft()
    {
        var editor = Editor();
        var stub = new Stub { VoiceReady = true, Voice = request => new(new MakeItRewriteResult.Voiced(["s1"]), 0.01m) };
        var plan = Plan() with { Rewrites = [new(20, 21, "much clearer", "a stumble"), new(30, 31, "far brighter", "a stumble")] };
        stub.Series = _ => new([plan], [], []);
        editor.MakeIt.Services = stub.Services();
        var cap = editor.MakeItCap("c1");
        Assert.NotNull(cap);
        Assert.Equal("✦ Make it postable · up to " + MakeItController.Dollars(cap!.Value), editor.MakeItTitle("c1"));
        var run = await RunAsync(editor, stub);
        Assert.Equal(cap, run.Cap);
        Assert.Equal([cap, cap - 0.01m], stub.Voiced.Select(request => request.Budget).ToArray());
        Assert.Equal(0.02m, run.Spent);
        Assert.Equal(0.02m, run.VoiceSpent);
        Assert.Contains("Voiced “much clearer” in your voice", run.Rows.Select(row => row.Text));
        Assert.True(run.Rows.First(row => row.Text == "Voiced “far brighter” in your voice").Undoable);
    }

    [Fact]
    public async Task AVoiceStepPastTheCapKeepsTheWordsAndSaysWhy()
    {
        var editor = Editor();
        var stub = new Stub { VoiceReady = true, Voice = _ => new(new MakeItRewriteResult.OverCap(0.31m)) };
        var run = await RunAsync(editor, stub);
        var row = run.Rows.Single(row => row.Change == MakeItChange.Phrase);
        Assert.Equal((MakeItRowKind.Note, "Kept your words for “much clearer”", "The next take ($0.31) would pass this click's cap. Your paid takes stay in Rewrite."),
            (row.Kind, row.Text, row.Detail));
        Assert.False(row.Undoable);
        Assert.Equal((20, 21), row.Words);
        Assert.Equal(0m, run.Spent);
    }

    [Fact]
    public async Task NothingThatCostsMoneyMeansNoAmountOnTheButtonAndNoVoiceIsSent()
    {
        var editor = Editor();
        var stub = new Stub { VoiceReady = false };
        editor.MakeIt.Services = stub.Services();
        Assert.Null(editor.MakeItCap("c1"));
        Assert.Equal("✦ Make it postable", editor.MakeItTitle("c1"));
        var run = await RunAsync(editor, stub);
        Assert.Null(run.Cap);
        Assert.Empty(stub.Voiced);
        Assert.Equal("Claude suggests “much clearer”", run.Rows.Single(row => row.Change == MakeItChange.Phrase).Text);
        // A style that never rewords prices nothing either, and keeps the words.
        var never = Editor();
        never.ChooseClipStyle(Style() with { Rewording = "off" }, Library, collapse: true);
        never.MakeIt.Services = new Stub { VoiceReady = true }.Services();
        Assert.Null(never.MakeItCap("c1"));
    }

    [Fact]
    public async Task AQuestionShowsItsPrePickedAnswerNeverBlocksAndAnotherAnswerReplans()
    {
        var editor = Editor();
        var stub = new Stub();
        var run = await RunAsync(editor, stub);
        Assert.Equal(MakeItPhase.Ready, run.Phase);
        var question = run.Rows.Single(row => row.Kind == MakeItRowKind.Question);
        editor.MakeItChangeRow(question.Id, run);
        Assert.Equal(question.Id, run.OpenChoice);
        Assert.True(editor.MakeItAnswer("No", question.Question, run));
        var again = editor.MakeIt.Run("c1")!;
        await again.Task!;
        Assert.Equal(2, stub.Requests.Count);
        Assert.EndsWith("For “Keep the intro?” the creator chose “No”.", stub.Requests[1].Note, StringComparison.Ordinal);
        Assert.Null(stub.Requests.Count > 2 ? stub.Requests[2].Note : null);
    }

    [Fact]
    public async Task ASuggestedClipIsKeptFirstInTheSameUndoStep()
    {
        var editor = Editor(suggested: true);
        Assert.Single(editor.SuggestedClips);
        await RunAsync(editor, new Stub());
        Assert.Empty(editor.SuggestedClips);
        Assert.True(editor.State!.Clips.Single().Selected);
        Assert.Equal("Make it postable", editor.UndoActionName);
        editor.Undo();
        Assert.False(editor.CanUndo);
        Assert.Single(editor.SuggestedClips);
    }

    [Fact]
    public async Task StopEndsAtTheNextSafePointAndKeepsWhatIsDone()
    {
        var editor = Editor();
        var stub = new Stub { Gate = new() };
        editor.MakeIt.Services = stub.Services();
        Assert.True(editor.MakeItPostable("c1"));
        var run = editor.MakeIt.Run("c1")!;
        Assert.True(run.Running);
        Assert.False(editor.CanMakeItPostable("c1"));
        editor.StopMakeIt();
        await run.Task!;
        Assert.Equal(MakeItPhase.Stopped, run.Phase);
        Assert.False(editor.CanUndo);
        Assert.Contains("Stopping after this step…", run.Lines);
        // Stop during the voice step keeps what was applied, as one step.
        var second = Editor();
        var voiced = new Stub { VoiceReady = true };
        second.MakeIt.Services = voiced.Services();
        voiced.Voice = _ => { second.StopMakeIt(); return new(new MakeItRewriteResult.NeedsYou("stopped")); };
        voiced.Series = _ => new([Plan() with { Rewrites = [new(20, 21, "much clearer", "a"), new(30, 31, "far brighter", "b")] }], [], []);
        var stopped = await RunAsync(second, voiced);
        Assert.Equal(MakeItPhase.Stopped, stopped.Phase);
        Assert.Single(voiced.Voiced);
        Assert.Contains("w12", second.State!.CutWordIds);
        Assert.Equal("Make it postable", second.UndoActionName);
    }

    [Fact]
    public async Task AnUndoWhileTheRunHoldsItsStepStopsIt()
    {
        var editor = Editor();
        var stub = new Stub { VoiceReady = true };
        editor.MakeIt.Services = stub.Services();
        stub.Voice = _ => { editor.Undo(); return new(new MakeItRewriteResult.NeedsYou("undone")); };
        stub.Series = _ => new([Plan() with { Rewrites = [new(20, 21, "much clearer", "a"), new(30, 31, "far brighter", "b")] }], [], []);
        var run = await RunAsync(editor, stub);
        Assert.Equal(MakeItPhase.Stopped, run.Phase);
        Assert.Single(stub.Voiced);
    }

    [Fact]
    public async Task TheCreatorsEditWhileClaudePlansIsItsOwnStep()
    {
        var editor = Editor();
        var stub = new Stub { Gate = new() };
        editor.MakeIt.Services = stub.Services();
        Assert.True(editor.MakeItPostable("c1"));
        Assert.True(editor.ApplyBatch([new EditOperation.SetWordCuts(["w50"], true)]));
        stub.Gate.SetResult();
        await editor.MakeIt.Run("c1")!.Task!;
        Assert.Equal("Make it postable", editor.UndoActionName);
        editor.Undo();
        Assert.Contains("w50", editor.State!.CutWordIds);
        Assert.DoesNotContain("w12", editor.State.CutWordIds);
        editor.Undo();
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public async Task TheLookAndSpeedChipsApplyAtOnceAndUndoGoesBackToBeforeTheRun()
    {
        var editor = Editor();
        var run = await RunAsync(editor, new Stub());
        var speed = run.Rows.Single(row => row.Change == MakeItChange.Speed);
        Assert.Equal(["0.75×", "1×", "1.25×", "1.5×", "2×"], speed.Options);
        editor.MakeItChangeRow(speed.Id, run);
        Assert.Equal(speed.Id, run.OpenChoice);
        Assert.True(editor.MakeItChoose("1.25×", speed.Id, run));
        Assert.Null(run.OpenChoice);
        Assert.Equal(1.25, ClipControlsProject.Controls("c1", editor.Project)!.Speed);
        Assert.Equal("Change speed", editor.UndoActionName);
        Assert.Equal("You chose 1.25× speed", run.Rows.Single(row => row.Id == speed.Id).Text);
        var look = run.Rows.Single(row => row.Change == MakeItChange.Look);
        Assert.Equal(["original", "muted", "black and white"], look.Options);
        Assert.True(editor.MakeItChoose("black and white", look.Id, run));
        Assert.Equal(ClipLook.Bw, ClipControlsProject.Controls("c1", editor.Project)!.Look);
        Assert.True(editor.MakeItUndo(speed.Id, run));
        Assert.Equal(1, ClipControlsProject.Controls("c1", editor.Project)!.Speed);
        Assert.Equal(ClipLook.Bw, ClipControlsProject.Controls("c1", editor.Project)!.Look);
        // The original look at 1× adds no row.
        var plain = Editor();
        var stub = new Stub { Series = _ => new([Plan() with { ClipLookChoice = ClipAutopilotPlan.Look.Original, SpeedChoice = new(1, "fine") }], [], []) };
        var quiet = await RunAsync(plain, stub);
        Assert.DoesNotContain(quiet.Rows, row => row.Change is MakeItChange.Look or MakeItChange.Speed);
    }

    [Fact]
    public async Task TheHookIsATitleCardWithInlineChangeAndUndo()
    {
        var editor = Editor();
        var run = await RunAsync(editor, new Stub());
        var hook = run.Rows.Single(row => row.Change == MakeItChange.Hook);
        Assert.Equal((MakeItRowKind.Choice, MakeItController.HookDetail, true), (hook.Kind, hook.Detail, hook.Undoable));
        editor.MakeItChangeRow(hook.Id, run);
        Assert.Equal(hook.Id, run.OpenChoice);
        Assert.True(editor.MakeItSetHook("  Coffee loses  ", hook.Id, run));
        Assert.Equal("Change hook", editor.UndoActionName);
        Assert.Equal("Coffee loses", ClipHookTitle.Existing("c1", editor.Project)!.Value.GetProperty("text").GetString());
        Assert.Equal("You chose the hook “Coffee loses”", run.Rows.Single(row => row.Id == hook.Id).Text);
        Assert.Equal("Coffee loses\n\nSleep first. #sleep", EditorViewModel.MakeItPostCopy(run));
        Assert.False(editor.MakeItSetHook("Coffee loses", hook.Id, run));
        Assert.True(editor.MakeItUndo(hook.Id, run));
        Assert.Null(ClipHookTitle.Existing("c1", editor.Project));
        Assert.Equal("Sleep first. #sleep", EditorViewModel.MakeItPostCopy(run));
    }

    [Fact]
    public async Task TheClipStyleDecidesWhatThePlannerMayChange()
    {
        var editor = Editor();
        var library = Library;
        editor.ChooseClipStyle(Style() with { Captions = "off", Rewording = "off", MaxLengthSec = 20, Shapes = ["1:1"] }, library, collapse: true);
        var style = editor.MakeItStyle;
        Assert.Equal((false, false, 20, "as-said"), (style.Captions, style.Rewrites, style.MaxSeconds, style.Tone));
        Assert.Equal([ExportAspect.Square], style.Shapes);
        var stub = new Stub { VoiceReady = true };
        var captions = editor.Project.Captions;
        var run = await RunAsync(editor, stub);
        Assert.Equal(captions.StyleId, editor.Project.Captions.StyleId);
        Assert.Empty(stub.Voiced);
        Assert.Equal(("Claude suggests “much clearer”", "This clip style keeps your words."),
            (run.Rows.Single(row => row.Change == MakeItChange.Phrase).Text, run.Rows.Single(row => row.Change == MakeItChange.Phrase).Detail));
        var request = stub.Requests.Single();
        Assert.Equal("Keep the finished clip at most 20 s. Never reword the speaker: no rewrites.", request.Note);
        Assert.IsType<ClipAutopilotTone.AsSaid>(request.Tone);
        Assert.Contains("⚠ Longer than this clip style's 20 s", editor.MakeItLengthNotes(run));
        Assert.Equal("Export · 1:1", editor.MakeItExportTitle);
        // A fixed caption style is the planner's styleId; a fixed tone is sent as that tone.
        var pinned = Editor();
        pinned.ChooseClipStyle(Style() with { Captions = "pill", Tone = "viral-youtuber" }, library, collapse: true);
        Assert.Equal("pill", pinned.MakeItStyle.CaptionPreference?.StyleId);
        pinned.MakeIt.Services = new Stub().Services();
        var tone = Assert.IsType<ClipAutopilotTone.Fixed>(pinned.MakeItRequest("c1")!.Tone);
        Assert.Equal("viral-youtuber", tone.Tone.Id);
    }

    [Fact]
    public async Task MakeTopThreeIsOneClipsRequestAndOneStepPerClip()
    {
        var editor = RewriteAutoFixTests.Editor();
        AiClip Clip(int start, int score) => new("Clip " + start, "", score, "w" + start, "w" + (start + 9));
        var project = editor.Project with
        {
            Ai = new([Result([Clip(0, 5), Clip(20, 9), Clip(40, 7), Clip(60, 2)])]),
            Edits = editor.Project.Edits with
            {
                Clips = new[] { 0, 20, 40, 60 }.Select((start, index) => new ClipRange("s" + index, "w" + start, "w" + (start + 9), null, ClipOrigin.Ai, "r1", index, false)).ToArray()
            }
        };
        editor = new(project, now: () => new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero));
        Assert.Equal(["s1", "s2", "s0", "s3"], editor.RankedSuggestions.Select(clip => clip.Id).ToArray());
        var stub = new Stub
        {
            Series = request => new(((ClipAutopilotMode.Clips)request.Mode).Spans.Select(range => Plan(range.Start, range.End) with { Rewrites = [], Cuts = [new(range.Start + 1, range.Start + 1, ClipAutopilotCutKind.Filler, "um")], Corrections = [], Zooms = [], Questions = [] }).ToArray(), [], [])
        };
        editor.MakeIt.Services = stub.Services();
        Assert.True(editor.CanMakeTopPostable);
        Assert.True(editor.MakeTopPostable());
        await editor.MakeIt.WaitForSeriesAsync();
        var request = Assert.Single(stub.Requests);
        Assert.Equal([new WordSpan(20, 29), new WordSpan(40, 49), new WordSpan(0, 9)], ((ClipAutopilotMode.Clips)request.Mode).Spans);
        Assert.Equal(["s1", "s2", "s0"], editor.MakeIt.Series);
        Assert.All(editor.MakeIt.Series, id => Assert.Equal(MakeItPhase.Ready, editor.MakeIt.Run(id)!.Phase));
        Assert.Single(editor.SuggestedClips);
        // One step per clip: three undos take back the three runs, the clip kept with each.
        for (var index = 0; index < 3; index++) { Assert.Equal("Make it postable", editor.UndoActionName); editor.Undo(); }
        Assert.False(editor.CanUndo);
        Assert.Equal(4, editor.SuggestedClips.Count);
    }

    [Fact]
    public async Task ClaudeModesPoolWaitsAtTheCapForExactlyTheShortfall()
    {
        var budget = new MakeItBudget(0.10m);
        var calls = 0;
        var stub = new Stub
        {
            VoiceReady = true,
            Voice = request => ++calls == 1 ? new(new MakeItRewriteResult.OverCap(0.234m)) : new(new MakeItRewriteResult.Voiced(["s1"]), 0.234m),
            Series = _ => new([Plan() with { Rewrites = [new(20, 21, "much clearer", "a")] }], [], [])
        };
        // Claude mode runs through Make top 3: c1 is a suggestion.
        var editor = Editor(suggested: true, score: 9);
        editor.MakeIt.Services = stub.Services();
        budget.Changed += (_, _) => { if (budget.Needed is not null) budget.ApproveNeeded(); };
        Assert.True(editor.MakeTopPostable(3, budget));
        await editor.MakeIt.WaitForSeriesAsync();
        var run = editor.MakeIt.Run("c1")!;
        Assert.Equal(0.10m, run.Cap);
        Assert.Equal([0.10m, 0.24m], stub.Voiced.Select(request => request.Budget).ToArray());
        Assert.Equal(0.24m, budget.Approved);
        Assert.Equal(0.234m, budget.Spent);
        Assert.Contains("Needs about $0.14 more…", run.Lines);
        Assert.Equal("Voiced “much clearer” in your voice", run.Rows.Single(row => row.Change == MakeItChange.Phrase).Text);
        // Stop at the cap keeps the words; a $0 pool sends no voice at all.
        var declined = new MakeItBudget(0.10m);
        Assert.False(await AskThenDeclineAsync(declined));
        var free = Editor(suggested: true, score: 9);
        var none = new Stub { VoiceReady = true, Series = stub.Series };
        free.MakeIt.Services = none.Services();
        Assert.True(free.MakeTopPostable(3, new MakeItBudget(0)));
        await free.MakeIt.WaitForSeriesAsync();
        Assert.Empty(none.Voiced);
        Assert.Equal("Spend is $0 per video, so your words stay. Change voices it in Rewrite.", free.MakeIt.Run("c1")!.Rows.Single(row => row.Change == MakeItChange.Phrase).Detail);
    }

    private static async Task<bool> AskThenDeclineAsync(MakeItBudget budget)
    {
        var asking = budget.AskAsync(0.05m);
        Assert.Equal(0.05m, budget.Needed);
        budget.Decline();
        var approved = await asking;
        Assert.Equal(0.10m, budget.Approved);
        return approved;
    }

    [Fact]
    public async Task CopyAndExportPutThePostTextOnTheClipboardAndBesideEachFile()
    {
        var editor = Editor();
        var stub = new Stub();
        var run = await RunAsync(editor, stub);
        Assert.Equal("Next: Export. The post text is copied with it.", EditorViewModel.MakeItNextStep(run));
        Assert.True(editor.CopyMakeItPostText(run));
        Assert.Equal("Sleep beats coffee\n\nSleep first. #sleep", stub.Copied);
        Assert.Equal("Export · 16:9 + 9:16", editor.MakeItExportTitle);
        try
        {
            Assert.True(await editor.MakeItExportAsync(run));
            var export = Assert.Single(stub.Exports);
            Assert.Equal("c1", export.Clip);
            Assert.Equal([ExportAspect.Landscape, ExportAspect.Portrait], export.Shapes);
            Assert.Equal(2, run.Exported.Count);
            Assert.All(run.Exported, file => Assert.Equal("Sleep beats coffee\n\nSleep first. #sleep", File.ReadAllText(Path.ChangeExtension(file, ".txt"))));
            Assert.Equal("Next: paste the post text where you post.", EditorViewModel.MakeItNextStep(run));
        }
        finally { if (Directory.Exists(stub.ExportFolder)) Directory.Delete(stub.ExportFolder, true); }
    }

    [Fact]
    public async Task APlannerFailureChangesNothingAndSaysWhy()
    {
        var editor = Editor();
        var stub = new Stub { Series = _ => throw new InvalidOperationException("The model declined to plan this clip.") };
        var run = await RunAsync(editor, stub);
        Assert.Equal(MakeItPhase.Failed, run.Phase);
        Assert.Equal("Nothing was changed", editor.MakeItHeadline(run));
        Assert.False(editor.CanUndo);
        Assert.NotEmpty(run.Failure);
        Assert.True(editor.CanMakeItPostable("c1"));
    }

    /// <summary>The driver prices the takes from Rewrite's own windows and makes them only within its budget; it never discards a paid
    /// take. Use publishes takes through Media's scratch audio, which this headless test has none of, so a made take ends as "needs you"
    /// with its session handed to the page.</summary>
    [Fact]
    public async Task TheDriverPressesOnlyPricedStepsWithinItsBudgetAndNeverGivesUpATake()
    {
        RewriteSession? opened = null;
        RewriteSession Open(MakeItRewriteRequest request, EditorViewModel editor)
        {
            opened = RewriteAutoFixTests.Session(new(RewriteAutoFixTests.Reply, (_, ordinals) => RewriteAutoFixTests.Rows(ordinals, "x")), request.First, request.Last, editor: editor);
            RewriteAutoFixTests.Configure(opened, new((_, _) => (RewriteAutoFixTests.Fit, RewriteAutoFixTests.Passed)));
            return opened;
        }
        static Task<VoiceLabMonthlyCap?> NoCap(CancellationToken _) => Task.FromResult<VoiceLabMonthlyCap?>(null);
        var poor = RewriteAutoFixTests.Editor();
        var low = new MakeItRewriteDriver(poor, new(10, 12, RewriteAutoFixTests.Reply, "c1", 0.0001m), request => Task.FromResult<RewriteSession?>(Open(request, poor)), NoCap);
        var refused = await low.RunAsync(CancellationToken.None);
        var over = Assert.IsType<MakeItRewriteResult.OverCap>(refused.Result);
        Assert.True(over.NextUsd > 0.0001m);
        Assert.False(opened!.HasPaidTakes);
        Assert.False(opened.IsOpen);
        Assert.Equal(0m, refused.Spent);
        var rich = RewriteAutoFixTests.Editor();
        RewriteSession? handed = null;
        var driver = new MakeItRewriteDriver(rich, new(10, 12, RewriteAutoFixTests.Reply, "c1", 5m), request => Task.FromResult<RewriteSession?>(Open(request, rich)), NoCap, session => handed = session);
        var outcome = await driver.RunAsync(CancellationToken.None);
        Assert.Contains(driver.Pressed, step => step.StartsWith("Make takes · $", StringComparison.Ordinal));
        Assert.DoesNotContain(driver.Pressed, step => step.Contains("Discard", StringComparison.Ordinal) || step.Contains("Keep original", StringComparison.Ordinal));
        Assert.True(outcome.Spent > 0 && outcome.Spent <= 5m);
        Assert.Equal(5m - over.NextUsd!.Value, opened!.AutoFixCeiling);
        if (outcome.Result is not MakeItRewriteResult.Voiced)
        {
            Assert.IsType<MakeItRewriteResult.NeedsYou>(outcome.Result);
            Assert.Same(opened, handed);
            Assert.True(handed!.HasPaidTakes);
            handed.Dispose();
        }
    }

    [Fact]
    public void TheClipRowsMenuBarAndPaletteOfferMakeItPostable()
    {
        var app = Path.Combine(Path.GetDirectoryName(Root)!, "apps", "windows", "src", "VoxClip.App");
        var window = File.ReadAllText(Path.Combine(app, "MainWindow.xaml"));
        foreach (var key in new[] { "ClipRow", "SuggestionRow" })
        {
            var template = window.Split($"x:Key=\"{key}\"")[1].Split("</DataTemplate>")[0];
            Assert.Contains("Click=\"MakeItClipClicked\" Tapped=\"RowButtonTapped\"", template);
            Assert.Contains("AutomationProperties.Name=\"{x:Bind MakeItName, Mode=OneWay}\"", template);
            var menu = template.Split("</MenuFlyout>")[0];
            Assert.Contains("Text=\"{x:Bind MakeItName, Mode=OneWay}\" Tag=\"{x:Bind ClipId}\" Click=\"MakeItClipClicked\"", menu);
            Assert.Contains("Click=\"RewriteClipClicked\"", menu);
        }
        var header = window.Split("x:Key=\"SuggestedHeaderRow\"")[1].Split("</DataTemplate>")[0];
        Assert.Contains("Click=\"MakeTopPostableClicked\"", header);
        var page = File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.xaml"));
        Assert.Contains("x:Name=\"MakeItCommand\"", page);
        var shell = File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.Shell.cs"));
        Assert.Contains("\"clip.makeIt\"", shell);
        Assert.Contains("\"clips.makeTop\"", shell);
    }
}
#endif
