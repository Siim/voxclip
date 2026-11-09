using System.Globalization;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

// ✦ Make it postable (design §6.7), twin of the Mac MakeItPostable.swift: one click on a clip lets Claude decide everything at
// extra high effort (the planner, ai.md §16), applies every decision as one undo step within an upfront spend cap, and shows one
// review with ▶, Undo or Change per decision, the post text with Copy, and Export. Questions never block: the plan already follows
// Claude's answer, and the review says "Claude chose X · Change". Windows renders neither motion cues nor background music, so a
// plan's zooms and music become note rows and the cap prices the voice only.

/// <summary>How clips should be made, as far as Make it postable needs it: the project's <see cref="ClipStyle"/> (the clip style
/// card, design §6.6), else the defaults a new project starts with.</summary>
public sealed record MakeItStyle
{
    /// <summary>A caption style the creator fixed; null leaves the choice to Claude (Auto).</summary>
    public ClipAutopilotCaptionPreference? CaptionPreference { get; init; }
    /// <summary>Captions at all: the style's captions "off" keeps the project's captions as they are.</summary>
    public bool Captions { get; init; } = true;
    /// <summary>The longest finished length, seconds; the planner is asked to keep within it and the review flags a longer clip.</summary>
    public int? MaxSeconds { get; init; }
    /// <summary>off, fix-only or tighten.</summary>
    public string Rewording { get; init; } = "fix-only";
    /// <summary>Rewrites in the creator's voice (rewording off turns them off).</summary>
    public bool Rewrites => Rewording != "off";
    /// <summary>The shapes Export renders in one click.</summary>
    public IReadOnlyList<ExportAspect> Shapes { get; init; } = [ExportAspect.Landscape, ExportAspect.Portrait];
    /// <summary>The tone Claude writes the words in: null is Auto, "as-said", or a tone id (as-said whenever rewording is off).</summary>
    public string? Tone { get; init; }

    /// <summary>Background music: Auto picks a free track first and may make one within the cap; Off adds no music (design §6.7).</summary>
    public bool Music { get; init; } = true;

    /// <summary>The defaults: Claude picks the captions, fix-only rewording, 16:9 and 9:16, Auto tone.</summary>
    public static MakeItStyle Auto { get; } = new();

    /// <summary>A fixed caption style becomes the planner's styleId; Auto leaves it to Claude; Off keeps captions as they are.</summary>
    public static MakeItStyle From(ClipStyle? style)
    {
        if (style is null) return Auto;
        var fixedStyle = style.FixedCaptionStyle;
        var shapes = style.Shapes.Select(Aspect).OfType<ExportAspect>().Distinct().ToArray();
        return new()
        {
            CaptionPreference = fixedStyle is null or "off" ? null : new(fixedStyle),
            Captions = fixedStyle != "off",
            MaxSeconds = style.MaxLengthSec,
            Rewording = style.Rewording,
            Shapes = shapes.Length == 0 ? Auto.Shapes : shapes,
            Tone = style.EffectiveTone,
            Music = style.Music != "off"
        };
    }

    /// <summary>The clip style's wire shape as an export frame.</summary>
    public static ExportAspect? Aspect(string shape) => shape switch
    {
        "16:9" => ExportAspect.Landscape,
        "9:16" => ExportAspect.Portrait,
        "1:1" => ExportAspect.Square,
        _ => null
    };

    /// <summary>What the planner is told about the style that its request has no field for: the length and the rewording.</summary>
    public string? PlannerNote
    {
        get
        {
            List<string> parts = [];
            if (MaxSeconds is { } seconds) parts.Add($"Keep the finished clip at most {seconds} s.");
            parts.Add(Rewording switch
            {
                "off" => "Never reword the speaker: no rewrites.",
                "tighten" => "Reword freely to tighten.",
                _ => Tone == "as-said" ? "Reword only what sounds wrong." : "Reword only what sounds wrong or what the tone needs."
            });
            return string.Join(" ", parts);
        }
    }
}

/// <summary>The outside world a run talks to. The editor page builds the live one; tests and the smoke pass stubs.</summary>
/// <param name="Plan">The checked plan for a request (a clip, or several), at extra high effort through the chosen AI. With frames (null:
/// the plan goes as text only, as before), the planner names the AI they go to and each clip asks the source for its frames just before
/// its send.</param>
/// <param name="Voice">Voices one rewrite within its budget; the live one drives Rewrite's own session (<see cref="MakeItRewriteDriver"/>).</param>
/// <param name="VoiceAvailable">Whether a voice can be made at all now: Voice Lab on with an ElevenLabs key. Nothing is sent.</param>
/// <param name="Export">Exports one clip in the given shapes without a dialog and returns the files written.</param>
/// <param name="Copy">Puts text on the clipboard.</param>
public sealed record MakeItServices(
    Func<ClipAutopilotRequest, IProgress<ClipAutopilotProgress>, MakeItFrameSources?, CancellationToken, Task<ClipAutopilotSeries>> Plan,
    Func<MakeItRewriteRequest, CancellationToken, Task<MakeItRewriteOutcome>> Voice,
    Func<bool> VoiceAvailable,
    Func<string, IReadOnlyList<ExportAspect>, CancellationToken, Task<IReadOnlyList<string>>>? Export = null,
    Action<string>? Copy = null)
{
    /// <summary>The shared root for the planner's prompt, fonts and prices.</summary>
    public string? SharedRoot { get; init; }
    /// <summary>The Voice Lab price catalog for the cap; null prices nothing.</summary>
    public Core.Domain.VoiceLab.VoiceLabPriceCatalog? Prices { get; init; }
    /// <summary>The tone catalogue and the creator's saved tones; null sends no tone line.</summary>
    public RewriteToneCatalog? Tones { get; init; }
    /// <summary>The creator's saved tones.</summary>
    public IReadOnlyList<RewriteTone> SavedTones { get; init; } = [];
    /// <summary>The whole video's frame pass for a project (ADR-R48), on this PC's face models. Null when faces are unavailable
    /// (<c>AppServices.FrameFaces</c> is null): no pass starts, the review has no picture rows and no send line, and plans go as text
    /// only. The factory returns null for a project it can't look at (no video, no words).</summary>
    public Func<Project, Media.Frames.VideoFramePass?>? FramePass { get; init; }
}

/// <summary>A plan's frames once the planner knows the AI they go to (ADR-R48): each clip's source, from the whole video's pass.</summary>
public delegate ClipAutopilotFrameSource MakeItFrameSources(MakeItFrameAi ai);

/// <summary>Who a clip's frames go to (ADR-R48): the AI's name, whether it takes images, and who pays for them.</summary>
/// <param name="Name">"Claude", "ChatGPT", "Gemini", "Grok", or the connector's label.</param>
/// <param name="Images">The connector takes images.</param>
/// <param name="Billing">Who pays.</param>
public sealed record MakeItFrameAi(string Name, bool Images, MakeItFrameBilling Billing)
{
    /// <summary>The frames go as images: an AI that takes them, on a plan or free. An API key gets the text summary, because this PC
    /// has no image price list to cap them by (the Mac prices them first).</summary>
    public bool SendsImages => Images && Billing is not MakeItFrameBilling.Key;
}

/// <summary>Who pays for a clip's frames.</summary>
public abstract record MakeItFrameBilling
{
    private MakeItFrameBilling() { }
    /// <summary>A CLI on the creator's plan: "on your Claude plan".</summary>
    public sealed record Plan(string Name) : MakeItFrameBilling;
    /// <summary>An API key.</summary>
    public sealed record Key : MakeItFrameBilling;
    /// <summary>A local server: nothing to pay.</summary>
    public sealed record Free : MakeItFrameBilling;
}

/// <summary>What a clip's plan request carried of the picture.</summary>
/// <param name="Ai">Who the frames went to.</param>
/// <param name="Sent">The frames as sent: with images, or the text summary only.</param>
/// <param name="Sentences">The clip's sentence frames (the faces the crop follows).</param>
public sealed record MakeItFrameRecord(MakeItFrameAi Ai, ClipAutopilotFrames Sent, IReadOnlyList<Core.Domain.Frames.FrameObservation> Sentences);

/// <summary>One rewrite for the voice step.</summary>
/// <param name="First">The first word index of the words to replace.</param>
/// <param name="Last">The last word index.</param>
/// <param name="Text">The planner's words.</param>
/// <param name="ClipId">The clip the run is on.</param>
/// <param name="Budget">What this rewrite may still spend, USD; null means no paid step may run.</param>
public sealed record MakeItRewriteRequest(int First, int Last, string Text, string ClipId, decimal? Budget);

/// <summary>What voicing one rewrite came to.</summary>
public abstract record MakeItRewriteResult
{
    private MakeItRewriteResult() { }
    /// <summary>Applied in the creator's voice; <see cref="Segments"/> are the Voice Lab segments it added.</summary>
    public sealed record Voiced(IReadOnlyList<string> Segments) : MakeItRewriteResult;
    /// <summary>It stopped before a step past the cap. Paid takes stay in Rewrite.</summary>
    public sealed record OverCap(decimal? NextUsd) : MakeItRewriteResult;
    /// <summary>Rewrite needs the creator (a voice to make, a consent, a stuck phrase). Its panel stays open.</summary>
    public sealed record NeedsYou(string Reason) : MakeItRewriteResult;
    /// <summary>No voice can be made here (Voice Lab off, no key): nothing was sent.</summary>
    public sealed record Unavailable(string Reason) : MakeItRewriteResult;
    /// <summary>Every phrase kept the speaker's words on its own (too long for its time in the video, its take couldn't go into the video,
    /// or the voice check blocked it): nothing was voiced; the line says why and whether the rewrite's text fixes were applied (Mac
    /// <c>keptAsRecorded</c>).</summary>
    public sealed record KeptAsRecorded(string Reason) : MakeItRewriteResult;
}

/// <summary>What one rewrite came to, what it spent, and the phrases whose chosen take only has a join advisory.</summary>
public sealed record MakeItRewriteOutcome(MakeItRewriteResult Result, decimal Spent = 0)
{
    /// <summary>Phrases whose take was chosen with a join-loudness advisory (autopilot accepts it; the row says so).</summary>
    public IReadOnlyList<int> JoinNotes { get; init; } = [];
    /// <summary>Phrases kept as recorded on their own because the voice check blocked them (Mac <c>keptAsRecorded</c>).</summary>
    public int KeptAsRecorded { get; init; }
}

/// <summary>How a decision is taken back on its own (the review's Undo).</summary>
public abstract record MakeItInverse
{
    private MakeItInverse() { }
    /// <summary>Edit operations that restore the words, pauses, clip and title.</summary>
    public sealed record Edits(IReadOnlyList<Core.Domain.Editing.EditOperation> Operations) : MakeItInverse;
    /// <summary>The captions before the run.</summary>
    public sealed record Captions(ProjectCaptions Previous, string ClipId, ClipCaptionPick? PreviousPick) : MakeItInverse;
    /// <summary>The clip's post text before the run.</summary>
    public sealed record Share(string ClipId, string? Previous) : MakeItInverse;
    /// <summary>The Voice Lab segments the voice step added, turned off.</summary>
    public sealed record Voice(IReadOnlyList<string> Segments) : MakeItInverse;
    /// <summary>The clip's look before; the other controls stay.</summary>
    public sealed record Look(string ClipId, ClipLook Previous) : MakeItInverse;
    /// <summary>The clip's speed before; the other controls stay.</summary>
    public sealed record Speed(string ClipId, double Previous) : MakeItInverse;
    /// <summary>An effect the run added (the hook's title card): removed, or put back as it was when the run replaced one.</summary>
    public sealed record Effect(string Id, System.Text.Json.JsonElement? Previous) : MakeItInverse;
    /// <summary>The clip's track before the run (null: none).</summary>
    public sealed record Music(string ClipId, Core.Domain.Music.ProjectMusic? Previous) : MakeItInverse;
    /// <summary>A zoom the run set: removed, or the cue with its id put back as it was.</summary>
    public sealed record Motion(string Id, Core.Domain.ContextDemo.MotionCue? Previous) : MakeItInverse;
    /// <summary>The clip's opening lead-in before "Opens on a clear look at you" (ADR-R48).</summary>
    public sealed record LeadIn(string ClipId, double? Previous) : MakeItInverse;
    /// <summary>The clip's crop before "9:16 follows your face".</summary>
    public sealed record Reframe(string ClipId, ReframeSettings? Previous) : MakeItInverse;
    /// <summary>The clip's cover before "Cover frame chosen".</summary>
    public sealed record Cover(string ClipId, double? Previous) : MakeItInverse;
}

/// <summary>Where a decision's Change goes. <see cref="Screens"/>: a blurred screen lists the clip's screens inline, each a toggle;
/// <see cref="Screen"/>: a screen left sharp, whose action blurs it; <see cref="Cover"/>: the cover candidates inline.</summary>
public enum MakeItChange { None, Captions, Rename, Hook, Phrase, Question, Look, Speed, Tone, Music, Screens, Screen, Cover }

/// <summary>What a review row is.</summary>
public enum MakeItRowKind { Decision, Choice, Question, Note }

/// <summary>One line of the review.</summary>
public sealed record MakeItRow(string Id, string Text)
{
    public MakeItRowKind Kind { get; init; } = MakeItRowKind.Decision;
    public string Detail { get; init; } = "";
    /// <summary>▶ jumps here (source seconds) and plays.</summary>
    public double? Play { get; init; }
    public bool Undoable { get; init; }
    public MakeItChange Change { get; init; }
    public bool Undone { get; init; }
    /// <summary>A question's other answers, or the look and speed rows' other choices.</summary>
    public IReadOnlyList<string> Options { get; init; } = [];
    /// <summary>The words a phrase row's Change opens Rewrite on.</summary>
    public (int First, int Last)? Words { get; init; }
    /// <summary>A phrase row's planned words: Change opens Rewrite on <see cref="Words"/> with them filled in.</summary>
    public string? Planned { get; init; }
    /// <summary>A question row's index in the plan.</summary>
    public int Question { get; init; } = -1;
    /// <summary>The row's own action in place of Change ("Blur" on a screen left sharp); null for none.</summary>
    public string? Action { get; init; }
    /// <summary>The frame candidate a screen row is about (<c>B1</c>…).</summary>
    public string? Candidate { get; init; }
}

/// <summary>Claude mode's per-video spend (design §6.7): every run of the video draws on one pool. The cap is the approval for
/// paid voice; a step that needs more waits at the cap until Continue approves exactly the shortfall, or Stop. Nothing is ever
/// spent past <see cref="Approved"/>.</summary>
public sealed class MakeItBudget(decimal cap)
{
    private TaskCompletionSource<bool>? waiting;
    /// <summary>The per-video cap the creator chose.</summary>
    public decimal Cap { get; } = cap;
    /// <summary>The cap plus every amount Continue approved.</summary>
    public decimal Approved { get; private set; } = cap;
    public decimal Spent { get; private set; }
    /// <summary>What the waiting step needs beyond what is left, in whole cents; null while nothing waits.</summary>
    public decimal? Needed { get; private set; }
    public decimal Remaining => Math.Max(0, Approved - Spent);
    /// <summary>A $0 cap means no paid voice at all: fixes are cuts and wording only, and nothing asks for more.</summary>
    public bool PaidAllowed => Cap > 0;
    /// <summary>Raised when <see cref="Needed"/> changes.</summary>
    public event EventHandler? Changed;
    public void Charge(decimal usd) => Spent += usd;

    /// <summary>Waits at the cap: true once Continue approved <paramref name="shortfall"/> (rounded up to the cent), false after Stop.</summary>
    public Task<bool> AskAsync(decimal shortfall)
    {
        if (!PaidAllowed || shortfall <= 0 || waiting is not null) return Task.FromResult(false);
        Needed = Math.Ceiling(shortfall * 100) / 100;
        var pending = waiting = new(TaskCreationOptions.RunContinuationsAsynchronously);
        Changed?.Invoke(this, EventArgs.Empty);
        return pending.Task;
    }

    /// <summary>Continue: approves exactly what the waiting step needs, and it goes on.</summary>
    public void ApproveNeeded()
    {
        if (Needed is not { } needed || waiting is not { } pending) return;
        Approved += needed;
        Needed = null; waiting = null;
        Changed?.Invoke(this, EventArgs.Empty);
        pending.TrySetResult(true);
    }

    /// <summary>Stop while a step waits: it keeps the creator's words, and nothing more is approved.</summary>
    public void Decline()
    {
        var pending = waiting;
        Needed = null; waiting = null;
        Changed?.Invoke(this, EventArgs.Empty);
        pending?.TrySetResult(false);
    }
}

/// <summary>Where a run is.</summary>
public enum MakeItPhase { Planning, Applying, Ready, Stopped, Failed }

/// <summary>One clip's run, from the click to the review.</summary>
public sealed class MakeItRun(string clipId, decimal? cap, MakeItBudget? budget = null)
{
    public string ClipId { get; } = clipId;
    /// <summary>The click's approved ceiling, USD; null when nothing can cost anything.</summary>
    public decimal? Cap { get; } = cap;
    /// <summary>Claude mode: the video's shared pool this run draws on instead of its own cap.</summary>
    public MakeItBudget? Budget { get; } = budget;
    public MakeItPhase Phase { get; internal set; } = MakeItPhase.Planning;
    public string Failure { get; internal set; } = "";
    /// <summary>Progress lines, newest last: "Reading the clip…", "Cutting 6 fillers…", "Voicing 2 fixes…".</summary>
    public List<string> Lines { get; } = [];
    public ClipAutopilotPlan? Plan { get; internal set; }
    /// <summary>What the clip's plan request carried of the picture; null when it went as text only without frames.</summary>
    public MakeItFrameRecord? Frames { get; internal set; }
    public List<MakeItRow> Rows { get; } = [];
    public decimal Spent { get; private set; }
    /// <summary>What voicing the rewrites spent.</summary>
    public decimal VoiceSpent { get; internal set; }
    /// <summary>The clip's rendered length: its edited length divided by its speed, as the export renders it.</summary>
    public double Seconds { get; internal set; }
    public string PostText { get; internal set; } = "";
    public string Hook { get; internal set; } = "";
    public bool Copied { get; internal set; }
    public List<string> Exported { get; } = [];
    public bool Exporting { get; internal set; }
    /// <summary>The row whose other choices (or the hook's text field, or a question's answers) show.</summary>
    public string? OpenChoice { get; internal set; }
    internal Dictionary<string, MakeItInverse> Inverses { get; } = [];
    internal CancellationTokenSource Cancellation { get; } = new();
    internal Task? Task { get; set; }
    public bool Cancelled { get; internal set; }

    public bool Running => Phase is MakeItPhase.Planning or MakeItPhase.Applying;
    /// <summary>What the run may still spend: its own cap's rest, or the video pool's.</summary>
    public decimal? Remaining => Budget is { } pool ? pool.Remaining : Cap is { } cap ? Math.Max(0, cap - Spent) : null;
    public void Charge(decimal usd) { Spent += usd; Budget?.Charge(usd); }
    public void Line(string text) { if (Lines.Count == 0 || Lines[^1] != text) Lines.Add(text); }
}

/// <summary>The editor's Make it postable state: the runs by clip, the series under way, and the scores the planner gave.</summary>
public sealed class MakeItController
{
    private readonly Dictionary<string, MakeItRun> runs = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (int Score, ClipAutopilotVerdict Verdict)> scores = new(StringComparer.Ordinal);
    /// <summary>The clip the panel shows.</summary>
    public string? ShownClipId { get; set; }
    /// <summary>The series the panel lists while it runs and after: ranked clips.</summary>
    public IReadOnlyList<string> Series { get; private set; } = [];
    /// <summary>Claude mode's pool for the series under way.</summary>
    public MakeItBudget? Budget { get; private set; }
    /// <summary>The live services; null until the page sets them (no run can start).</summary>
    public MakeItServices? Services { get; set; }
    internal Task? SeriesTask { get; set; }
    /// <summary>The tone a Change on the review's tone row asks for, used by the next request only.</summary>
    public string? ToneOverride { get; set; }

    public MakeItRun? Shown => ShownClipId is { } id ? runs.GetValueOrDefault(id) : null;
    public MakeItRun? Active => runs.Values.FirstOrDefault(run => run.Running);
    public IReadOnlyList<MakeItRun> Running => runs.Values.Where(run => run.Running).ToArray();
    public MakeItRun? Run(string clipId) => runs.GetValueOrDefault(clipId);
    public (int Score, ClipAutopilotVerdict Verdict)? Score(string clipId) => scores.TryGetValue(clipId, out var score) ? score : null;
    internal void Record(int score, ClipAutopilotVerdict verdict, string clipId) => scores[clipId] = (score, verdict);
    internal void Forget(string clipId) { runs.Remove(clipId); scores.Remove(clipId); if (ShownClipId == clipId) ShownClipId = null; }
    internal void Insert(MakeItRun run) { runs[run.ClipId] = run; ShownClipId = run.ClipId; }
    internal void SetSeries(IReadOnlyList<string> ids, MakeItBudget? budget) { Series = ids; Budget = budget; }
    /// <summary>Waits until the series under way has run (tests and the smoke).</summary>
    public Task WaitForSeriesAsync() => SeriesTask ?? Task.CompletedTask;

    /// <summary>Cents, rounded up: a ceiling never reads lower than it is.</summary>
    public static string Dollars(decimal usd)
    {
        var cents = (long)Math.Ceiling(usd * 100);
        return "$" + (cents / 100).ToString(CultureInfo.InvariantCulture) + "." + (cents % 100).ToString("00", CultureInfo.InvariantCulture);
    }

    /// <summary>The Clip section's speed presets.</summary>
    public static IReadOnlyList<double> SpeedPresets { get; } = [0.75, 1, 1.1, 1.25, 1.5, 2];

    /// <summary>"1.1×", "0.75×", "2×".</summary>
    public static string SpeedLabel(double rate) =>
        Math.Round(rate, 2).ToString("0.##", CultureInfo.InvariantCulture) + "×";

    /// <summary>"warm", "black and white".</summary>
    public static string LookName(ClipLook look) => look switch
    {
        ClipLook.Muted => "muted",
        ClipLook.Warm => "warm",
        ClipLook.Bw => "black and white",
        _ => "original"
    };

    /// <summary>The look row's other choices.</summary>
    public static IReadOnlyList<string> LookOptions(ClipLook except) => Enum.GetValues<ClipLook>().Where(look => look != except).Select(LookName).ToArray();

    /// <summary>The speed row's other choices: the presets.</summary>
    public static IReadOnlyList<string> SpeedOptions(double except) => SpeedPresets.Where(rate => rate != except).Select(SpeedLabel).ToArray();

    /// <summary>"Claude chose the hook “…”".</summary>
    public static string HookRowText(string hook, string who) => $"{who} chose the hook “{hook}”";
    public const string HookDetail = "Title card for the first 2 s · the post text keeps it";
}
