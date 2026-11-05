#if WIN_UI_TESTS
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.MakeItPostableTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>✦ Ask Claude in the Windows editor (design §6.8), twin of the Mac <c>AskClaudeAppTests</c>: the selection flyout, a timeline
/// range and the clip row open one inline field; chips only fill it; the answer applies as one undo step; each row undoes alone and Undo
/// all takes every row out; a stretch sets a whole clip's speed or offers it; Adjust edits as undo steps and its box follows a flipped or
/// turned clip. The AI is a scripted connector behind the real AskClaudeService; nothing is sent or paid.</summary>
public sealed class AskClaudeAppTests
{
    /// <summary>A Claude Code fake on a plan that answers every Ask Claude request with <see cref="Reply"/>.</summary>
    internal sealed class Fake : ILlmConnector
    {
        internal string Reply { get; set; } = "{\"summary\":\"\",\"ops\":[]}";
        internal List<LlmRequest> Requests { get; } = [];
        internal TaskCompletionSource? Gate { get; set; }
        public ConnectorId Id => ConnectorId.ClaudeCode;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => Task.FromResult<IReadOnlyList<LlmModel>>([]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(200_000);
        public async Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            Requests.Add(request);
            if (Gate is { } gate) await gate.Task.WaitAsync(ct);
            return new(Reply, null, model, new StopKind.Complete(), null, null);
        }
    }

    private sealed class NoKeys : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => Task.FromResult<string?>(null);
    }

    /// <summary>A scripted on-screen observer: <paramref name="frame"/> answers every sampled time.</summary>
    internal sealed class Vision(Func<double, AskClaudeFrameFindings> frame) : IAskClaudeVision
    {
        public Task<AskClaudeFrameFindings> ObserveAsync(double time, bool text, CancellationToken ct) => Task.FromResult(frame(time));
    }

    internal static JsonObject Op(string kind, params (string Key, JsonNode Value)[] fields)
    {
        var value = new JsonObject
        {
            ["kind"] = kind, ["startWord"] = -1, ["endWord"] = -1, ["start"] = -1, ["end"] = -1, ["text"] = "", ["target"] = "", ["x"] = 0, ["y"] = 0,
            ["width"] = 0, ["height"] = 0, ["tracking"] = "", ["position"] = "", ["rate"] = 0, ["scale"] = 0, ["sound"] = "", ["language"] = "",
            ["choice"] = "", ["reason"] = kind + " because it was asked"
        };
        foreach (var (key, field) in fields) value[key] = field;
        return value;
    }

    internal static string Reply(params JsonObject[] ops) => new JsonObject { ["summary"] = "Done as asked.", ["ops"] = new JsonArray(ops) }.ToJsonString();

    /// <summary>The 80-word editor with clip c1 on words 10–40, the real Ask Claude service on <paramref name="fake"/>, and prices.</summary>
    internal static (EditorViewModel Editor, Fake Fake) Open(string? reply = null, IAskClaudeVision? vision = null, bool available = true)
    {
        var editor = Editor();
        var fake = new Fake();
        if (reply is not null) fake.Reply = reply;
        var catalog = LlmCatalog.Load(Root);
        var service = new AskClaudeService(new LlmRunner(new NoKeys(), catalog, new Redactor()), catalog, AskClaudePrompt.Load(Root));
        editor.AskClaudeServices = new AskClaudeServices
        {
            Ask = async (ask, ct) => (await service.AskAsync(ask.Instruction, ask.Selection, ask.Project, ask.Detections, ask.Aspect, fake, "fixture", ct)).Answer,
            Available = () => available, CostLine = () => "Free on your Claude plan", Vision = vision, Prices = VoiceLabPrices.Load(Root)
        };
        return (editor, fake);
    }

    private static void Select(EditorViewModel editor, int first, int last) { editor.Select(first); editor.Select(last, extend: true); }

    private static string[] Kinds(EditorViewModel editor) => editor.Project.ClipEffects.Select(effect => effect.GetProperty("kind").GetString()!).ToArray();

    private static async Task AskAsync(EditorViewModel editor, string text)
    {
        editor.AskClaude.Text = text;
        await editor.SendAskClaudeAsync();
    }

    [Fact]
    public async Task TheSelectionFlyoutOpensOneInlineFieldAndChipsOnlyFillIt()
    {
        var (editor, fake) = Open();
        var shown = 0;
        var closed = 0;
        editor.AskClaudeShown += (_, _) => shown++;
        editor.AskClaudeClosed += (_, _) => closed++;
        Select(editor, 2, 5);
        Assert.True(editor.CanAskClaude);
        Assert.Equal(new AskClaudeSelection(new AskClaudeSelection.Scope.Words(2, 5), null), editor.AskClaudeWordSelection);
        Assert.True(editor.OpenAskClaudeOnSelection());
        Assert.NotNull(editor.AskClaude.Selection);
        Assert.Equal("“word2 word3 word4 word5”", editor.AskClaude.Label);
        Assert.Equal(1, shown);
        Assert.Equal("↵ Ask Claude · Free on your Claude plan", editor.AskClaudeFooter);
        Assert.Equal("Say what to change: reword it, bleep it, blur, add a title…", AskClaudeState.Placeholder);
        // Chips fill the field; nothing is sent until Return.
        editor.FillAskClaude(AskClaudeState.Chips[0].Text);
        Assert.Equal("Bleep these words", editor.AskClaude.Text);
        Assert.Empty(fake.Requests);
        // An empty field sends nothing either.
        await AskAsync(editor, "   ");
        Assert.Empty(fake.Requests);
        // Eight words and more read as the first eight with an ellipsis.
        Select(editor, 0, 11);
        Assert.True(editor.OpenAskClaudeOnSelection());
        Assert.Equal("“word0 word1 word2 word3 word4 word5 word6 word7…”", editor.AskClaude.Label);
        editor.CloseAskClaude();
        Assert.False(editor.AskClaude.IsOpen);
        Assert.Equal(1, closed);
    }

    [Fact]
    public async Task TheAnswerAppliesAsOneUndoStepAndEachRowUndoesAlone()
    {
        var reply = Reply(Op("bleep", ("startWord", 3), ("endWord", 4)), Op("title", ("text", "Day 1"), ("position", "top")), Op("sound", ("sound", "pop")),
            Op("rewrite", ("startWord", 2), ("endWord", 5), ("text", "this is new")), Op("speed", ("rate", 1.5)));
        var (editor, fake) = Open(reply);
        Select(editor, 2, 5);
        editor.OpenAskClaudeOnSelection();
        var before = editor.Project;
        await AskAsync(editor, "bleep the swear, add a title and a pop");
        var request = Assert.Single(fake.Requests);
        Assert.Equal((LlmFeature.AskClaude, Effort.XHigh), (request.Feature, request.Effort!.Value));
        Assert.Contains("Instruction: bleep the swear, add a title and a pop", request.Instruction, StringComparison.Ordinal);
        Assert.Contains("exported 9:16", request.Instruction, StringComparison.Ordinal);
        var run = Assert.IsType<AskClaudeRun>(editor.AskClaude.Run);
        Assert.Null(editor.AskClaude.Error);
        Assert.False(editor.AskClaude.Asking);
        Assert.Null(editor.AskClaude.Selection);
        Assert.Equal(5, run.Rows.Count);
        Assert.All(run.Rows.Take(3), row => Assert.Equal(AskClaudeRowStatus.Applied, row.Status));
        Assert.Equal(["Bleep", "Title", "Sound: Pop", "Rewrite in your voice", "Speed up 1.5×"], run.Rows.Select(row => row.Title));
        Assert.Equal(AskClaudeRowStatus.Paid, run.Rows[3].Status);
        Assert.StartsWith("Voice it · about $", run.Rows[3].Price, StringComparison.Ordinal);
        // A speed on Full Take words that no clip holds: a clip plays at one speed, so the row says why and changes nothing.
        Assert.Null(EditorViewModel.StretchClip(run.Rows[4].Operation, editor.Project));
        Assert.Equal((AskClaudeRowStatus.Later, "A clip plays at one speed. Ask on a clip to change its speed. Nothing changed."), (run.Rows[4].Status, run.Rows[4].Reason));
        Assert.Equal(["bleep", "title", "sound"], Kinds(editor));
        Assert.Equal(3, run.AppliedCount);
        Assert.Equal("“word2 word3 word4 word5”", run.Label);
        Assert.Equal("Play a change to check it, then Done", editor.AskClaudeFooter);
        Assert.Equal("Ask Claude", editor.UndoActionName);
        Assert.Equal("2 words · 0:04–0:05", run.Rows[0].Detail);
        // The paid row waits for its click: nothing else was sent, and the click hands Claude's words to Rewrite.
        Assert.Single(fake.Requests);
        var rewrites = new List<RewriteAsRequest>();
        editor.RewriteAsRequested += (_, value) => rewrites.Add(value);
        Assert.True(editor.RunPaidAskClaudeRow(run.Rows[3].Id));
        Assert.Equal(new RewriteAsRequest("Say exactly: this is new", "Rewrite", Words: (2, 5)), Assert.Single(rewrites));
        Assert.Single(fake.Requests);

        // One undo step for the whole answer.
        editor.Undo();
        Assert.Empty(editor.Project.ClipEffects);
        Assert.Equal(before.Edits, editor.Project.Edits);
        editor.Redo();
        Assert.Equal(3, editor.Project.ClipEffects.Count);

        // Undo one row: the others stay.
        Assert.True(editor.UndoAskClaudeRow(run.Rows[1].Id));
        Assert.Equal(["bleep", "sound"], Kinds(editor));
        Assert.Equal(AskClaudeRowStatus.Undone, run.Rows[1].Status);
        Assert.Equal("Undo Title", editor.UndoActionName);
        // Undo all: the rest, in one step.
        Assert.True(editor.UndoAllAskClaude());
        Assert.Empty(editor.Project.ClipEffects);
        Assert.Equal(0, run.AppliedCount);
        Assert.Equal("Undo Ask Claude", editor.UndoActionName);
        editor.Undo();
        Assert.Equal(["bleep", "sound"], Kinds(editor));
    }

    private static string[] ShownWords(EditorViewModel editor)
    {
        var project = editor.ScopedProject(editor.State);
        var plan = ExportRenderInput.Plan(ExportRenderInput.Media(project), editor.State);
        return ExportRenderInput.CaptionWords(project, editor.State!, plan, null, ClipEffects.Rendered(project, project.Edits.ActiveClipId)).Select(word => word.Text).ToArray();
    }

    /// <summary>"Translate these captions to Spanish" (Mac <c>translatedCaptionsApplyRenderAndUndo</c>): the row applies in the answer's one
    /// undo step, the render's caption words show the translation over those words, the export is new, and the row's Undo takes it
    /// back as its own step.</summary>
    [Fact]
    public async Task TranslatedCaptionsApplyRenderAndUndo()
    {
        var (editor, _) = Open(Reply(Op("translate", ("startWord", 2), ("endWord", 5), ("language", "es"), ("text", "esto es lo nuevo ahora"))));
        Assert.True(editor.ReplaceProject(editor.Project with { Captions = editor.Project.Captions with { StyleId = "vox-highlight" } }, "Captions on"));
        var plain = ShownWords(editor);
        var plainFingerprint = ExportFingerprint.For(editor.Project, new ExportTarget.FullEdit());
        Select(editor, 2, 5);
        editor.OpenAskClaudeOnSelection();
        await AskAsync(editor, "translate these captions to Spanish");
        var run = Assert.IsType<AskClaudeRun>(editor.AskClaude.Run);
        Assert.Null(editor.AskClaude.Error);
        var row = Assert.Single(run.Rows);
        Assert.Equal((AskClaudeRowStatus.Applied, "Captions in Spanish", "“esto es lo nuevo ahora”", ""), (row.Status, row.Title, row.Detail, row.Reason));
        Assert.Equal("Ask Claude", editor.UndoActionName);
        var stored = Assert.Single(editor.Project.CaptionTranslations);
        Assert.Equal(("es", (string?)null, "w2", "w5"), (stored.Language, stored.ClipId, stored.StartWordId, stored.EndWordId));
        Assert.Equal(4, editor.Project.SchemaVersion);
        // Preview and export show the translation over those words; the rest stay.
        var first = Array.IndexOf(plain, "word2");
        Assert.Equal(plain[..first].Concat(["esto", "es", "lo", "nuevo", "ahora"]).Concat(plain[(first + 4)..]), ShownWords(editor));
        Assert.NotEqual(plainFingerprint, ExportFingerprint.For(editor.Project, new ExportTarget.FullEdit()));
        // One undo step for the answer; the row's Undo; Undo all.
        editor.Undo();
        Assert.Empty(editor.Project.CaptionTranslations);
        editor.Redo();
        Assert.Single(editor.Project.CaptionTranslations);
        Assert.True(editor.UndoAskClaudeRow(row.Id));
        Assert.Empty(editor.Project.CaptionTranslations);
        Assert.Equal(AskClaudeRowStatus.Undone, row.Status);
        Assert.Equal("Undo Captions in Spanish", editor.UndoActionName);
        Assert.Equal(plain, ShownWords(editor));
        editor.Undo();
        Assert.Single(editor.Project.CaptionTranslations);
    }

    /// <summary>"Play this clip at 1.25×" on a clip: the stretch covers the whole clip (within 0.25 s at each end), so it applies as the
    /// clip's speed in the answer's one undo step, and its Undo takes the speed back.</summary>
    /// <summary>With zooms and music rendering on Windows (track/v2-win-render-2): a zoom on a clip applies in the answer's undo step and
    /// its row undoes alone; the music row offers "Find music · free library first", whose click hands Claude's mood to the Music section
    /// and sends or spends nothing.</summary>
    [Fact]
    public async Task AZoomAppliesAndTheMusicRowOpensMusicWithClaudesMood()
    {
        var (editor, fake) = Open(Reply(Op("zoom", ("scale", 1.2)), Op("music", ("text", "warm lo-fi"))));
        editor.SetScope("c1");
        Assert.True(editor.OpenAskClaudeOnClip("c1"));
        await AskAsync(editor, "punch in and add some music");
        var run = Assert.IsType<AskClaudeRun>(editor.AskClaude.Run);
        Assert.Equal(["Zoom in", "Music change"], run.Rows.Select(row => row.Title));
        Assert.Equal(AskClaudeRowStatus.Applied, run.Rows[0].Status);
        var cue = Assert.Single(editor.Project.MotionCues);
        Assert.Equal(("c1-ask-1", "c1"), (cue.Id, cue.ClipID));
        Assert.All(cue.Keyframes, frame => Assert.Equal(1.2, frame.Scale, 6));
        Assert.Equal((AskClaudeRowStatus.Paid, "Find music · free library first"), (run.Rows[1].Status, run.Rows[1].Price));
        var moods = new List<string>();
        editor.AskClaudeMusicRequested += (_, music) => moods.Add(music.Picked.Mood);
        Assert.True(editor.RunPaidAskClaudeRow(run.Rows[1].Id));
        Assert.Equal("warm lo-fi", Assert.Single(moods));
        Assert.Single(fake.Requests);
        Assert.Empty(editor.Project.Music);
        Assert.True(editor.UndoAskClaudeRow(run.Rows[0].Id));
        Assert.Empty(editor.Project.MotionCues);
    }

    [Fact]
    public async Task AStretchOverTheWholeClipSetsTheClipsSpeed()
    {
        var (editor, _) = Open(Reply(Op("speed", ("rate", 1.25))));
        editor.SetScope("c1");
        Assert.True(editor.OpenAskClaudeOnClip("c1"));
        Assert.Equal("Clip 1", editor.AskClaude.Label);
        await AskAsync(editor, "play this clip a bit faster");
        var row = Assert.Single(editor.AskClaude.Run!.Rows);
        var stretch = Assert.IsType<ClipAutopilotAction.Stretch>(row.Operation.Action);
        var span = ClipControlsProject.SourceSpan("c1", editor.Project)!.Value;
        Assert.True(Math.Abs(stretch.Start - span.Start) <= 0.25 && Math.Abs(stretch.End - span.End) <= 0.25);
        Assert.Equal(AskClaudeRowStatus.Applied, row.Status);
        Assert.Equal(1.25, ClipControlsProject.Controls("c1", editor.Project)!.Speed);
        Assert.Equal("Ask Claude", editor.UndoActionName);
        Assert.True(editor.UndoAskClaudeRow(row.Id));
        Assert.Empty(editor.Project.ClipControls);
        Assert.Equal(AskClaudeRowStatus.Undone, row.Status);
    }

    /// <summary>"Slow this bit down" on words inside a clip: nothing changes and the row offers one inline action, "Apply 0.5× to the
    /// whole clip", which applies it as one undo step; Undo all takes it back.</summary>
    [Fact]
    public async Task AStretchOverPartOfAClipOffersItsSpeedForTheWholeClip()
    {
        var (editor, _) = Open(Reply(Op("speed", ("rate", 0.5))));
        editor.SetScope("c1");
        Select(editor, 12, 14);
        Assert.True(editor.OpenAskClaudeOnSelection());
        Assert.Equal("c1", editor.AskClaude.Selection!.ClipId);
        await AskAsync(editor, "slow this bit down");
        var row = Assert.Single(editor.AskClaude.Run!.Rows);
        Assert.Equal((AskClaudeRowStatus.WholeClip, "c1", "Slow-mo 0.5×"), (row.Status, row.WholeClipId, row.Title));
        Assert.Equal("Apply 0.5× to the whole clip", EditorViewModel.WholeClipTitle(row.Operation));
        Assert.Empty(editor.Project.ClipControls);
        Assert.True(editor.ApplyAskClaudeStretchToClip(row.Id));
        Assert.Equal(0.5, ClipControlsProject.Controls("c1", editor.Project)!.Speed);
        Assert.Equal(AskClaudeRowStatus.Applied, row.Status);
        Assert.StartsWith("Whole clip · ", row.Detail, StringComparison.Ordinal);
        Assert.Equal("Change speed", editor.UndoActionName);
        Assert.True(editor.UndoAllAskClaude());
        Assert.Empty(editor.Project.ClipControls);
        Assert.Equal(AskClaudeRowStatus.Undone, row.Status);
    }

    [Fact]
    public async Task AdjustNudgesTheRangeEditsTextAndMovesTheBoxAsUndoSteps()
    {
        var (editor, _) = Open(Reply(Op("title", ("text", "Day 1"), ("position", "top")),
            Op("blur", ("x", 0.1), ("y", 0.1), ("width", 0.2), ("height", 0.2), ("tracking", "none")), Op("sticker", ("text", "🔥")), Op("sound", ("sound", "pop"))));
        Select(editor, 2, 8);
        editor.OpenAskClaudeOnSelection();
        await AskAsync(editor, "title and blur");
        var run = editor.AskClaude.Run!;
        var (title, blur, sticker, sound) = (run.Rows[0].Id, run.Rows[1].Id, run.Rows[2].Id, run.Rows[3].Id);
        Assert.All(run.Rows, row => Assert.True(editor.CanAdjustAskClaude(row)));
        var start = editor.AskClaudeEffect(title)!.Start;
        Assert.True(editor.NudgeAskClaudeEffect(title, true, 0.1));
        Assert.Equal(start + 0.1, editor.AskClaudeEffect(title)!.Start, 9);
        Assert.Equal("Adjust Title", editor.UndoActionName);
        Assert.True(editor.SetAskClaudeText(title, "  Day 2 "));
        Assert.True(editor.SetAskClaudePosition(title, "bottom"));
        Assert.Equal(("Day 2", "bottom"), (editor.AskClaudeEffect(title)!.Text, editor.AskClaudeEffect(title)!.Position));
        Assert.True(editor.StepAskClaudeScale(sticker, 1));
        Assert.Equal(1.25, editor.AskClaudeEffect(sticker)!.Scale);
        Assert.True(editor.SetAskClaudeSound(sound, "ding"));
        Assert.Equal(("ding", 0.8), (editor.AskClaudeEffect(sound)!.Sound!.Id, Math.Round(editor.AskClaudeEffect(sound)!.End - editor.AskClaudeEffect(sound)!.Start, 6)));
        Assert.Null(editor.AskClaudeAdjustingRect);
        editor.ToggleAskClaudeAdjust(blur);
        Assert.Equal(blur, editor.AskClaudeAdjustingRect!.Value.Id);
        Assert.True(editor.MoveAskClaudeBox(blur, 0.85, 0));
        Assert.Equal(new ClipEffectRect(0.8, 0.1, 0.2, 0.2), editor.AskClaudeEffect(blur)!.Rect);
        editor.Undo();
        Assert.Equal(0.1, editor.AskClaudeEffect(blur)!.Rect!.Value.X, 9);
        // Undo one row closes its Adjust editor.
        Assert.True(editor.UndoAskClaudeRow(blur));
        Assert.Null(editor.AskClaude.Adjusting);
        Assert.False(editor.CanAdjustAskClaude(run.Rows[1]));
        // The box on the viewer maps through the export crop: the frame's middle is the stage's middle.
        var frame = AskClaudeRectGeometry.Frame(new(0.25, 0.25, 0.5, 0.5), editor.Project, 320, 180)!.Value;
        Assert.Equal((160.0, 90.0), (Math.Round(frame.X + frame.Width / 2, 6), Math.Round(frame.Y + frame.Height / 2, 6)));
        // The FX lane lists them with their names.
        Assert.Equal(["Emoji", "Sound: Ding", "Title"], editor.TimelineEffects().Select(effect => effect.Label).Order(StringComparer.Ordinal));
        // A click on a block opens its row's Adjust.
        var shown = 0;
        editor.AskClaudeShown += (_, _) => shown++;
        var titleEffect = editor.AskClaudeEffect(title)!.Id;
        Assert.True(editor.AdjustAskClaudeFromTimeline(titleEffect));
        Assert.Equal((title, 1), (editor.AskClaude.Adjusting, shown));
    }

    [Fact]
    public void ATimelineRangeAndAClipRowOpenTheFieldToo()
    {
        var (editor, _) = Open();
        var words = editor.Words;
        editor.SetAskClaudeTimeRange((words[1].Start, words[6].End));
        Assert.Equal("✦ Ask Claude · 0:02–0:07", editor.AskClaudeTimeRangeTitle);
        Assert.True(editor.OpenAskClaudeOnTimeRange());
        var time = Assert.IsType<AskClaudeSelection.Scope.Time>(editor.AskClaude.Selection!.Kind);
        Assert.Equal(words[1].Start, time.Start);
        Assert.Equal("0:02–0:07", editor.AskClaude.Label);
        // A time range has no words to reword, so "Reword these words" is left out.
        Assert.Null(editor.AskClaudeRewriteTarget(new("fix-mistakes", "Fix mistakes", "x", "", RewriteStripKind.Fix)));
        // A short drag marks no range; a click anywhere clears it.
        editor.SetAskClaudeTimeRange((1, 1.05));
        Assert.Null(editor.AskClaudeTimeRangeTitle);
        editor.SetAskClaudeTimeRange(null);
        Assert.Null(editor.AskClaude.TimeRange);
        Assert.True(editor.OpenAskClaudeOnClip("c1"));
        Assert.Equal(new AskClaudeSelection(new AskClaudeSelection.Scope.Clip("c1"), "c1"), editor.AskClaude.Selection);
        Assert.Equal("Clip 1", editor.AskClaude.Label);
    }

    [Fact]
    public void AnEditorWithNoAiOrReadOnlyOffersNoAskClaude()
    {
        var (editor, _) = Open(available: false);
        Select(editor, 2, 5);
        Assert.False(editor.CanAskClaude);
        Assert.False(editor.OpenAskClaudeOnSelection());
        Assert.Null(editor.AskClaude.Selection);
        var (other, _) = Open();
        other.AskClaudeServices = null;
        Assert.False(other.CanAskClaude);
        var (offline, _) = Open();
        offline.SetMediaUnavailable(true);
        Assert.False(offline.CanAskClaude);
    }

    [Fact]
    public async Task DetectionsReachTheRequestAndAFaceBlurIsTracedWhileTheMovingSubjectHoldsStill()
    {
        var face = new ClipEffectRect(0.4, 0.2, 0.2, 0.3);
        var vision = new Vision(time => new([face with { X = 0.4 + time / 1000 }], [new("INVOICE 1042", new(0.6, 0.7, 0.3, 0.1))]));
        var reply = Reply(Op("blur", ("target", "D1"), ("tracking", "face")), Op("pixelate", ("target", "face"), ("tracking", "saliency")));
        var (editor, fake) = Open(reply, vision);
        Select(editor, 2, 8);
        editor.OpenAskClaudeOnSelection();
        await AskAsync(editor, "blur the face");
        var request = Assert.Single(fake.Requests);
        Assert.Contains("D1 face", request.Instruction, StringComparison.Ordinal);
        Assert.Contains("reads \"INVOICE 1042\"", request.Instruction, StringComparison.Ordinal);
        var run = editor.AskClaude.Run!;
        Assert.Equal(["Blur, tracked", "Pixelate, tracked"], run.Rows.Select(row => row.Title));
        var traced = editor.AskClaudeEffect(run.Rows[0].Id)!;
        Assert.NotEmpty(traced.Track);
        Assert.Equal(traced.Start, traced.Track[0].T);
        Assert.Null(EditorViewModel.AskClaudeFollowNote(traced));
        var held = editor.AskClaudeEffect(run.Rows[1].Id)!;
        Assert.Empty(held.Track);
        Assert.Equal("Windows follows faces only, so this box holds still where Claude put it.", EditorViewModel.AskClaudeFollowNote(held));
        // Hold still drops the track as one undo step; a face is traced again.
        Assert.True(await editor.RetrackAskClaudeEffectAsync(run.Rows[0].Id, "none"));
        Assert.Empty(editor.AskClaudeEffect(run.Rows[0].Id)!.Track);
        Assert.Equal("Hold the blur still", editor.UndoActionName);
        Assert.True(await editor.RetrackAskClaudeEffectAsync(run.Rows[0].Id, "face"));
        Assert.NotEmpty(editor.AskClaudeEffect(run.Rows[0].Id)!.Track);
        Assert.Equal("Track the blur", editor.UndoActionName);
        // Moving a traced box makes it hold still until it is traced again.
        Assert.True(editor.MoveAskClaudeBox(run.Rows[0].Id, 0.05, 0));
        Assert.Empty(editor.AskClaudeEffect(run.Rows[0].Id)!.Track);
    }

    [Fact]
    public async Task StopKeepsTheProjectAndAnEditWhileClaudeWorksAppliesNothing()
    {
        var (editor, fake) = Open(Reply(Op("title", ("text", "Day 1"))));
        fake.Gate = new();
        Select(editor, 2, 5);
        editor.OpenAskClaudeOnSelection();
        editor.AskClaude.Text = "add a title";
        var task = editor.SendAskClaudeAsync();
        Assert.True(editor.AskClaude.Asking);
        Assert.Equal("Claude is working · Stop keeps the project as it is", editor.AskClaudeFooter);
        editor.StopAskClaude();
        await task;
        Assert.Empty(editor.Project.ClipEffects);
        Assert.Null(editor.AskClaude.Run);
        Assert.Equal("add a title", editor.AskClaude.Text);
        // The creator edits while Claude works: the answer is not applied.
        fake.Gate = new();
        var second = editor.SendAskClaudeAsync();
        editor.CutSelection();
        fake.Gate.SetResult();
        await second;
        Assert.Empty(editor.Project.ClipEffects);
        Assert.Equal("The project changed while Claude worked. Ask again.", editor.AskClaude.Error);
    }

    /// <summary>Adjust on a flipped or turned clip (design §6.8, §6.9): the viewer's box maps through the clip's flip and quarter turns, so
    /// it sits where the render draws the blur, and a drag maps back to the rect as filmed; dragging the box moves it by exactly the drag.</summary>
    [Theory]
    [InlineData(true, 0)]
    [InlineData(true, 90)]
    [InlineData(false, 270)]
    public void TheAdjustBoxFollowsAFlippedOrTurnedClipBothWays(bool flip, int degrees)
    {
        var editor = Editor();
        var project = editor.Project with { Export = editor.Project.Export with { Aspect = ExportAspect.Landscape } };
        project = ClipControlsProject.Setting(ClipControlsProject.Controls("c1", project)! with { FlipHorizontal = flip, RotationDegrees = degrees }, project);
        project = project with { Edits = project.Edits with { ActiveClipId = "c1" } };
        const double width = 320, height = 180;
        var filmed = new ClipEffectRect(0.3, 0.35, 0.1, 0.1);
        var shown = ClipControlsProject.Controls("c1", project).MapRect(filmed);
        var scale = AskClaudeRectGeometry.PictureScale(project, width, height);
        var frame = AskClaudeRectGeometry.Frame(filmed, project, width, height)!.Value;
        Assert.Equal(width / 2 + (shown.X + shown.Width / 2 - 0.5) * scale.Width, frame.X + frame.Width / 2, 6);
        Assert.Equal(height / 2 + (shown.Y + shown.Height / 2 - 0.5) * scale.Height, frame.Y + frame.Height / 2, 6);
        if (flip && degrees == 0) Assert.Equal(160 + 0.15 * 320, frame.X + frame.Width / 2, 6);
        var moved = AskClaudeRectGeometry.Dragged(filmed, 12, -8, project, width, height);
        var after = AskClaudeRectGeometry.Frame(moved, project, width, height)!.Value;
        Assert.Equal(frame.X + 12, after.X, 6);
        Assert.Equal(frame.Y - 8, after.Y, 6);
        Assert.Equal((filmed.Width, filmed.Height), (Math.Round(moved.Width, 9), Math.Round(moved.Height, 9)));
        // Unflipped, the same drag would have moved the stored rect the other way (or across) on the source.
        var naive = filmed with { X = filmed.X + 12 / scale.Width, Y = filmed.Y - 8 / scale.Height };
        Assert.True(Math.Abs(naive.X - moved.X) > 1e-3 || Math.Abs(naive.Y - moved.Y) > 1e-3);
        // Mapping there and back is the identity.
        var controls = ClipControlsProject.Controls("c1", project);
        Assert.Equal(filmed, Round(controls.UnmapRect(controls.MapRect(filmed))));
    }

    private static ClipEffectRect Round(ClipEffectRect rect) => new(Math.Round(rect.X, 9), Math.Round(rect.Y, 9), Math.Round(rect.Width, 9), Math.Round(rect.Height, 9));

    [Fact]
    public void TheConsentNamesWhatAskClaudeSends()
    {
        Assert.Equal("Ask Claude sends your request and these 4 words, with what is detected on screen (no audio or video), to Anthropic using your API key.",
            ConnectorConsent.Text(ConnectorConsentAction.AskClaude, ConnectorId.Anthropic, "Anthropic", 4, null));
        var plan = ConnectorConsent.Text(ConnectorConsentAction.AskClaude, ConnectorId.ClaudeCode, "Claude Code", 4, new CliDetectionInfo("claude", "1.0", "claude.ai", false));
        Assert.Equal("VoxClip will run your installed Claude Code with your own sign-in. Your request and these words are sent to Anthropic and count toward your Claude plan's usage.", plan);
    }

    [Fact]
    public void TheEntryPointsAreWiredWhereTheCreatorAsks()
    {
        var app = Path.Combine(Path.GetDirectoryName(Root)!, "apps", "windows", "src", "VoxClip.App");
        var flyout = File.ReadAllText(Path.Combine(app, "Controls", "SelectionFlyout.cs"));
        // ✦ Ask Claude is the flyout's first command, with a divider after it.
        Assert.True(flyout.IndexOf("flyout.PrimaryCommands.Add(askClaude);", StringComparison.Ordinal) < flyout.IndexOf("flyout.PrimaryCommands.Add(make);", StringComparison.Ordinal));
        Assert.Contains("flyout.PrimaryCommands.Add(askSeparator);", flyout);
        var transcript = File.ReadAllText(Path.Combine(app, "Controls", "TranscriptView.cs"));
        Assert.Contains("selectionFlyout.AskClaude = () => model?.OpenAskClaudeOnSelection();", transcript);
        var window = File.ReadAllText(Path.Combine(app, "MainWindow.xaml"));
        Assert.Contains("AutomationProperties.AutomationId=\"Clip.AskClaude\"", window.Split("x:Key=\"ClipRow\"")[1].Split("</MenuFlyout>")[0]);
        var timeline = File.ReadAllText(Path.Combine(app, "Controls", "TimelineView.cs"));
        Assert.Contains("model?.OpenAskClaudeOnTimeRange()", timeline);
        Assert.Contains("model.AdjustAskClaudeFromTimeline(hit)", timeline);
        var page = File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.xaml"));
        Assert.Contains("<controls:AskClaudeBoxOverlay x:Name=\"AskClaudeBox\"/>", page);
        var services = File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.AskClaude.cs"));
        Assert.Contains("ConnectorConsentAction.AskClaude", services);
        Assert.Contains("new WindowsAskClaudeVision(", services);
        // No pop-ups: the panel is an inline job in the right column.
        var panel = File.ReadAllText(Path.Combine(app, "Controls", "AskClaudePanel.cs"));
        Assert.Contains("internal sealed class AskClaudePanel : InlineEditorJob", panel);
        Assert.DoesNotContain("ContentDialog", panel);
    }
}
#endif
