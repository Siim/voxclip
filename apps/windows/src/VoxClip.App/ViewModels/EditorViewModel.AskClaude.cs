using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

/// <summary>✦ Ask Claude on a selection, clip or time range (design §6.8), twin of the Mac <c>EditorModel+AskClaude</c>: one inline field
/// in the right column, the answer applied as one undo step "Ask Claude", a row per change with ▶, Adjust and Undo, Undo all, paid
/// rows behind one priced click and later rows that say why nothing changed.</summary>
public sealed partial class EditorViewModel
{
    /// <summary>The field, the run, the timeline range and the open Adjust row.</summary>
    public AskClaudeState AskClaude { get; } = new();
    /// <summary>The page's live services; null hides every ✦ Ask Claude entry.</summary>
    public AskClaudeServices? AskClaudeServices { get; set; }
    /// <summary>The field or the change list changed: the panel redraws.</summary>
    public event EventHandler? AskClaudeChanged;
    /// <summary>An entry opened the field: the page shows the panel and the viewer.</summary>
    public event EventHandler? AskClaudeShown;
    /// <summary>Done or Cancel: the page closes the panel.</summary>
    public event EventHandler? AskClaudeClosed;
    /// <summary>▶ on a row: the page seeks to this source time and plays.</summary>
    public event EventHandler<double>? AskClaudePlayRequested;
    /// <summary>The music row's click: the page opens Captions' Music section and searches with Claude's mood.</summary>
    public event EventHandler<ClipAutopilotMusicCue>? AskClaudeMusicRequested;

    private void AskClaudeNotify() => AskClaudeChanged?.Invoke(this, EventArgs.Empty);

    // MARK: Opening

    /// <summary>✦ Ask Claude is offered when an AI is chosen and the project can change.</summary>
    public bool CanAskClaude => AskClaudeServices?.Available() == true && HasTranscript && !IsReadOnly && !isLeaving;

    /// <summary>The selected words, in the open clip's tab: what the selection flyout's ✦ Ask Claude asks about.</summary>
    public AskClaudeSelection? AskClaudeWordSelection =>
        HasSelection ? new(new AskClaudeSelection.Scope.Words(SelectionStart, SelectionEnd), state?.ActiveClipId) : null;

    /// <summary>Opens the inline field on <paramref name="selection"/> in the right column (no pop-up). Nothing is sent until Return.</summary>
    public bool OpenAskClaude(AskClaudeSelection selection)
    {
        if (!CanAskClaude || AskClaude.Asking) return false;
        AskClaudeScope scope;
        try { scope = AskClaudeScope.Resolve(selection, project); }
        catch (VoiceLabException) { return false; }
        AskClaude.Selection = selection;
        AskClaude.Label = AskClaudeLabel(scope);
        AskClaude.Error = null;
        AskClaude.Adjusting = null;
        AskClaude.AllTones = false;
        AskClaudeShown?.Invoke(this, EventArgs.Empty);
        AskClaudeNotify();
        Announcement?.Invoke(this, $"Ask Claude about {AskClaude.Label}. Type what you want, then press Return.");
        return true;
    }

    /// <summary>The selection flyout's ✦ Ask Claude.</summary>
    public bool OpenAskClaudeOnSelection() => AskClaudeWordSelection is { } selection && OpenAskClaude(selection);
    /// <summary>A clip row's ⋯ "Ask Claude…": the whole clip.</summary>
    public bool OpenAskClaudeOnClip(string clipId) => OpenAskClaude(new(new AskClaudeSelection.Scope.Clip(clipId), clipId));
    /// <summary>The timeline toolbar's ✦ Ask Claude on the dragged range.</summary>
    public bool OpenAskClaudeOnTimeRange() =>
        AskClaude.TimeRange is { } range && OpenAskClaude(new(new AskClaudeSelection.Scope.Time(range.Start, range.End), state?.ActiveClipId));

    /// <summary>A drag across empty timeline time marks a range (at least 0.1 s); null clears it.</summary>
    public void SetAskClaudeTimeRange((double Start, double End)? range)
    {
        AskClaude.TimeRange = range is { } value && value.End - value.Start >= 0.1 ? (Math.Max(0, value.Start), value.End) : null;
        AskClaudeNotify();
    }

    /// <summary>The toolbar's label for the range: "✦ Ask Claude · 0:12–0:15".</summary>
    public string? AskClaudeTimeRangeTitle => AskClaude.TimeRange is { } range && CanAskClaude ? "✦ Ask Claude · " + Clock(range.Start) + "–" + Clock(range.End) : null;

    /// <summary>"“the invoice for March…”", "Clip 2" or "0:12–0:15".</summary>
    public string AskClaudeLabel(AskClaudeScope scope)
    {
        if (scope.IsClip && scope.ClipId is { } id)
            return Clips.FirstOrDefault(clip => clip.Id == id) is { } row ? "Clip " + row.Number.ToString(CultureInfo.InvariantCulture) : "this clip";
        if (!scope.IsTime && scope.Words is { } range)
        {
            var text = string.Join(" ", range.Indices.Take(8).Select(index => DisplayText(Words[index])));
            return "“" + text + (range.Count > 8 ? "…" : "") + "”";
        }
        return Clock(scope.Start) + "–" + Clock(scope.End);
    }

    /// <summary>m:ss, rounded down.</summary>
    public static string Clock(double seconds)
    {
        var whole = (long)Math.Floor(Math.Max(0, double.IsFinite(seconds) ? seconds : 0));
        return (whole / 60).ToString(CultureInfo.InvariantCulture) + ":" + (whole % 60).ToString("00", CultureInfo.InvariantCulture);
    }

    /// <summary>What "Reword these words" rewrites: the asked words or the asked clip; a time range has no words to reword.</summary>
    public RewriteAsRequest? AskClaudeRewriteTarget(RewriteStripItem item)
    {
        if (!ShowsToneStrip || AskClaude.Selection is not { } selection) return null;
        AskClaudeScope scope;
        try { scope = AskClaudeScope.Resolve(selection, project); }
        catch (VoiceLabException) { return null; }
        if (scope.IsClip && scope.ClipId is { } clip) return new(item.Instruction, item.Title, ClipId: clip);
        if (!scope.IsTime && scope.Words is { } words) return new(item.Instruction, item.Title, Words: (words.Start, words.End));
        return null;
    }

    /// <summary>"Reword these words" before More…: the default, Fix mistakes, Shorter and Punchy Reel, in the strip's order.</summary>
    public IReadOnlyList<RewriteStripItem> AskClaudeQuickTones
    {
        get
        {
            string[] quick = [RewriteStripItem.FixMistakesId, "punchy-reel", RewriteStripItem.ShorterId];
            return RewriteStripItems.Where(item => item.IsDefault || quick.Contains(item.Id)).ToArray();
        }
    }

    /// <summary>The tones the "Reword these words" group shows: the quick four, or every chip after More….</summary>
    public IReadOnlyList<RewriteStripItem> AskClaudeTones => AskClaude.AllTones ? RewriteStripItems : AskClaudeQuickTones;

    /// <summary>A "Reword these words" chip: Rewrite runs at once on the asked words (or clip) with that tone, as the strip's chip does.</summary>
    public bool AskClaudeRewriteAs(RewriteStripItem item)
    {
        if (AskClaudeRewriteTarget(item) is not { } request) return false;
        if (request.ClipId is { } clip && state?.ActiveClipId != clip) SetScope(clip);
        if (request.ClipId is not null) ClearSelection();
        CloseAskClaude();
        Request(item, request);
        return true;
    }

    /// <summary>"More…": every chip of the strip, in place.</summary>
    public void ShowAllAskClaudeTones() { AskClaude.AllTones = true; AskClaudeNotify(); }

    /// <summary>An "Edit the video here" chip: fills the field; nothing is sent.</summary>
    public void FillAskClaude(string text) { AskClaude.Text = text; AskClaudeNotify(); }

    /// <summary>Stop while Claude works: the request is cancelled and the project stays as it was; the field keeps its text.</summary>
    public void StopAskClaude()
    {
        AskClaude.Cancellation?.Cancel();
        AskClaude.Asking = false;
        AskClaude.Progress = null;
        AskClaudeNotify();
        Announcement?.Invoke(this, "Stopped. Nothing changed.");
    }

    /// <summary>Cancel, Done or Escape: the field and the change list close.</summary>
    public void CloseAskClaude()
    {
        AskClaude.Cancellation?.Cancel();
        AskClaude.Selection = null;
        AskClaude.Run = null;
        AskClaude.Adjusting = null;
        AskClaude.Asking = false;
        AskClaude.Progress = null;
        AskClaude.Error = null;
        AskClaudeNotify();
        AskClaudeClosed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The footer's cost: free on a CLI plan or a local model, else what the key bills.</summary>
    public string AskClaudeCostLine => AskClaudeServices?.CostLine() ?? "";

    /// <summary>The footer's line, which always names the next step.</summary>
    public string AskClaudeFooter =>
        AskClaude.Selection is not null && AskClaude.Asking ? "Claude is working · Stop keeps the project as it is"
        : AskClaude.Selection is not null ? "↵ Ask Claude · " + AskClaudeCostLine
        : AskClaude.Run is not null ? "Play a change to check it, then Done" : "";

    // MARK: Asking

    /// <summary>Return or the Ask Claude button: sends the field once (an empty field sends nothing). Detections, the send and tracking
    /// run in order; the answer applies only if the project did not change meanwhile.</summary>
    public Task SendAskClaudeAsync()
    {
        var instruction = AskClaude.Text.Trim();
        if (instruction.Length == 0 || !CanAskClaude || AskClaude.Asking || AskClaude.Selection is not { } selection || AskClaudeServices is not { } services) return Task.CompletedTask;
        AskClaudeScope scope;
        try { scope = AskClaudeScope.Resolve(selection, project); }
        catch (VoiceLabException) { return Task.CompletedTask; }
        AskClaude.Cancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        AskClaude.Cancellation = cancellation;
        AskClaude.Error = null;
        AskClaude.Asking = true;
        AskClaude.Progress = services.Vision is null ? "Claude is working on it" : "Looking at the picture";
        AskClaudeNotify();
        Announcement?.Invoke(this, "Asking Claude");
        var task = PerformAskClaudeAsync(instruction, selection, scope, services, cancellation);
        AskClaude.Task = task;
        return task;
    }

    private async Task PerformAskClaudeAsync(string instruction, AskClaudeSelection selection, AskClaudeScope scope, AskClaudeServices services, CancellationTokenSource cancellation)
    {
        var snapshot = project;
        var token = cancellation.Token;
        try
        {
            IReadOnlyList<AskClaudeDetection> detections = [];
            if (services.Vision is { } vision && snapshot.Media.Source.Video is not null)
            {
                try { detections = await AskClaudeVision.DetectAsync(vision, scope.Start, scope.End, token); }
                catch (Exception exception) when (exception is not (OperationCanceledException or OutOfMemoryException)) { detections = []; }
            }
            token.ThrowIfCancellationRequested();
            AskClaude.Progress = "Claude is working on it";
            AskClaudeNotify();
            var answer = await services.Ask(new(instruction, selection, snapshot, detections, AspectName(snapshot.Export.Aspect), scope.Words?.Count ?? 0), token);
            token.ThrowIfCancellationRequested();
            if (!ReferenceEquals(project, snapshot)) { AskClaude.Error = "The project changed while Claude worked. Ask again."; return; }
            if (services.Vision is { } tracker && snapshot.Media.Source.Video is not null && answer.Operations.Any(Followed))
            {
                AskClaude.Progress = "Following what moves";
                AskClaudeNotify();
                answer = await TrackedAsync(answer, tracker, token);
                token.ThrowIfCancellationRequested();
                if (!ReferenceEquals(project, snapshot)) { AskClaude.Error = "The project changed while Claude worked. Ask again."; return; }
            }
            ApplyAskClaude(answer, instruction, selection);
        }
        catch (Exception exception) when (exception is OperationCanceledException || exception is LlmException { Error.Kind: LlmErrorKind.Cancelled } || token.IsCancellationRequested) { }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            var message = UiError.Message(exception, "Ask Claude");
            AskClaude.Error = message.Length == 0 ? "Claude couldn't answer. Nothing changed." : message;
        }
        finally
        {
            if (ReferenceEquals(AskClaude.Cancellation, cancellation))
            {
                AskClaude.Asking = false;
                AskClaude.Progress = null;
                AskClaude.Cancellation = null;
            }
            cancellation.Dispose();
            AskClaudeNotify();
        }
    }

    /// <summary>The export shape as the request names it (the project's wire value): "source", "16:9", "9:16" or "1:1".</summary>
    public static string AspectName(ExportAspect aspect) => aspect switch
    {
        ExportAspect.Landscape => "16:9", ExportAspect.Portrait => "9:16", ExportAspect.Square => "1:1", _ => "source"
    };

    private static bool Followed(ClipAutopilotOperation operation) =>
        operation.Action is ClipAutopilotAction.Effect { Value: var value } && ClipEffect.Parse(value) is { Kind: "blur" or "pixelate" } effect &&
        AskClaudeVision.Follows(effect.Tracking) && effect.Rect is not null;

    /// <summary>Face-tracked censors traced through their range; Windows traces faces only, so "the moving subject" holds its box.</summary>
    private static async Task<AskClaudeAnswer> TrackedAsync(AskClaudeAnswer answer, IAskClaudeVision vision, CancellationToken token)
    {
        var operations = answer.Operations.ToList();
        for (var index = 0; index < operations.Count; index++)
        {
            if (!Followed(operations[index]) || operations[index].Action is not ClipAutopilotAction.Effect { Value: var value }) continue;
            var effect = ClipEffect.Parse(value);
            IReadOnlyList<ClipEffectTrackSample> track;
            try { track = await AskClaudeVision.TrackAsync(vision, effect.Tracking, effect.Start, effect.End, effect.Rect!.Value, token); }
            catch (Exception exception) when (exception is not (OperationCanceledException or OutOfMemoryException)) { continue; }
            if (track.Count == 0) continue;
            var node = JsonNode.Parse(value.GetRawText())!.AsObject();
            node["track"] = new JsonArray(track.Select(sample => (JsonNode)new JsonObject
            {
                ["t"] = sample.T, ["x"] = sample.Rect.X, ["y"] = sample.Rect.Y, ["width"] = sample.Rect.Width, ["height"] = sample.Rect.Height
            }).ToArray());
            operations[index] = operations[index] with { Action = new ClipAutopilotAction.Effect(Element(node)) };
        }
        return answer with { Operations = operations };
    }

    private static JsonElement Element(JsonObject node)
    {
        using var document = JsonDocument.Parse(node.ToJsonString());
        return document.RootElement.Clone();
    }

    /// <summary>Applies the free operations as one undo step "Ask Claude" and lists every operation as a row. Paid ones wait for their
    /// priced click; ones the editor cannot make yet are listed as later.</summary>
    public bool ApplyAskClaude(AskClaudeAnswer answer, string instruction, AskClaudeSelection selection)
    {
        var run = new AskClaudeRun(instruction, selection, AskClaude.Label) { Summary = answer.Summary, Repairs = answer.Repairs, Base = project };
        var paid = answer.Paid.Select(operation => operation.Id).ToHashSet(StringComparer.Ordinal);
        HashSet<string> pending;
        try
        {
            var (next, left) = ClipAutopilotMapping.Apply(answer.Operations.Where(operation => !paid.Contains(operation.Id)).ToArray(), project);
            pending = left.Select(operation => operation.Id).ToHashSet(StringComparer.Ordinal);
            if (!ReferenceEquals(next, project) && !ReplaceProject(next, "Ask Claude")) throw new InvalidOperationException("Ask Claude");
        }
        catch (Exception exception) when (exception is VoxClipException or VoiceLabException or InvalidOperationException or KeyNotFoundException)
        {
            AskClaude.Error = "Claude's changes could not be applied. Try different wording.";
            AskClaudeNotify();
            return false;
        }
        foreach (var operation in answer.Operations)
        {
            var title = AskClaudeRowTitle(operation);
            var detail = AskClaudeRowDetail(operation);
            var choice = answer.Choices.GetValueOrDefault(operation.Id);
            AskClaudeRow row;
            if (paid.Contains(operation.Id))
                row = AskClaudePrice(operation) is { Length: > 0 } price
                    ? new(operation, AskClaudeRowStatus.Paid, title, detail, choice) { Price = price }
                    : new(operation, AskClaudeRowStatus.Later, title, detail, choice) { Reason = AskClaudeLaterReason(operation) };
            else if (pending.Contains(operation.Id) && operation.Action is ClipAutopilotAction.Stretch && StretchClip(operation, project) is { } clip)
                row = new(operation, AskClaudeRowStatus.WholeClip, title, detail, choice) { WholeClipId = clip };
            else if (pending.Contains(operation.Id))
                row = new(operation, AskClaudeRowStatus.Later, title, detail, choice) { Reason = AskClaudeLaterReason(operation) };
            else row = new(operation, AskClaudeRowStatus.Applied, title, detail, choice);
            run.Rows.Add(row);
        }
        AskClaude.Run = run;
        AskClaude.Selection = null;
        AskClaude.Text = "";
        AskClaude.Error = null;
        var count = run.AppliedCount;
        AskClaudeNotify();
        Announcement?.Invoke(this, count == 0 ? "Claude made no changes" : count == 1 ? "Done, 1 change" : $"Done, {count} changes");
        return true;
    }

    // MARK: Rows

    /// <summary>"Bleep", "Blur, tracked", "Title", "Emoji", "Sound: Pop", "Zoom in", "Rewrite in your voice"…</summary>
    public static string AskClaudeRowTitle(ClipAutopilotOperation operation)
    {
        switch (operation.Action)
        {
            case ClipAutopilotAction.Effect { Value: var value }:
                var effect = ClipEffect.Parse(value);
                var still = effect.Tracking is null or "none";
                return effect.Kind switch
                {
                    "bleep" => "Bleep", "mute" => "Mute", "blur" => still ? "Blur" : "Blur, tracked", "pixelate" => still ? "Pixelate" : "Pixelate, tracked",
                    "title" => "Title", "lowerThird" => "Lower third", "sticker" => "Emoji", "arrow" => "Arrow", "circle" => "Circle",
                    "progress" => "Progress bar", "freeze" => "Freeze frame",
                    "sound" => "Sound: " + (value.TryGetProperty("sound", out var sound) && sound.TryGetProperty("title", out var name) ? name.GetString() : "effect"),
                    _ => effect.Kind
                };
            case ClipAutopilotAction.Motion: return "Zoom in";
            case ClipAutopilotAction.Edit { Operation: EditOperation.Correct }: return "Fix a word";
            case ClipAutopilotAction.Edit { Operation: EditOperation.CutSelection }: return "Jump cut";
            case ClipAutopilotAction.Rewrite: return "Rewrite in your voice";
            case ClipAutopilotAction.Stretch stretch: return (stretch.Rate < 1 ? "Slow-mo " : "Speed up ") + Rate(stretch.Rate);
            case ClipAutopilotAction.TranslateCaptions translate: return "Captions in " + LanguageName(translate.Language);
            case ClipAutopilotAction.Music: return "Music change";
            case ClipAutopilotAction.MusicDucking: return "Duck the music";
            default:
                var decision = operation.Decision.ToString();
                return decision;
        }
    }

    /// <summary>"1.25×", "0.5×", "2×".</summary>
    public static string Rate(double value) => MakeItController.SpeedLabel(ClipControlsProject.NormalizedSpeed(value));

    private static string LanguageName(string code)
    {
        try { return CultureInfo.GetCultureInfo(code.Split('-')[0]).EnglishName; }
        catch (CultureNotFoundException) { return code; }
    }

    /// <summary>The row's detail line: its time range and text.</summary>
    public string AskClaudeRowDetail(ClipAutopilotOperation operation)
    {
        switch (operation.Action)
        {
            case ClipAutopilotAction.Effect { Value: var value }:
            {
                var effect = ClipEffect.Parse(value);
                var range = Clock(effect.Start) + "–" + Clock(effect.End);
                if (effect.Text is { } text) return "“" + text + "” · " + range;
                if (effect.UsesWords) return (effect.WordIds.Count == 1 ? "1 word" : effect.WordIds.Count.ToString(CultureInfo.InvariantCulture) + " words") + " · " + range;
                return range;
            }
            case ClipAutopilotAction.Motion { Cue: var cue }: return Clock(cue.SourceStart) + "–" + Clock(cue.SourceEnd);
            case ClipAutopilotAction.Edit { Operation: EditOperation.Correct correct }:
                return (Index(correct.Id) is var at and >= 0 ? DisplayText(Words[at]) : "") + " → " + correct.Text;
            case ClipAutopilotAction.Edit { Operation: EditOperation.CutSelection cut }:
                return string.Join(" ", cut.Ids.Select(Index).Where(at => at >= 0).Select(at => DisplayText(Words[at])));
            case ClipAutopilotAction.Rewrite rewrite: return "“" + rewrite.Text + "”";
            case ClipAutopilotAction.Stretch stretch: return Clock(stretch.Start) + "–" + Clock(stretch.End);
            case ClipAutopilotAction.TranslateCaptions translate: return "“" + translate.Text + "”";
            case ClipAutopilotAction.Music music: return music.Cue.Picked.Mood;
            default: return operation.Reason;
        }
    }

    /// <summary>Why a later row changed nothing.</summary>
    public static string AskClaudeLaterReason(ClipAutopilotOperation operation) => operation.Action switch
    {
        ClipAutopilotAction.Stretch => "A clip plays at one speed. Ask on a clip to change its speed. Nothing changed.",
        ClipAutopilotAction.MusicDucking => "This clip has no music to duck.",
        _ => "Not available yet. Nothing changed."
    };

    /// <summary>"Voice it · about $0.04": the rewrite's text at the text-to-speech rate, which Rewrite confirms exactly; music's click
    /// reads "Find music · free library first". Empty when the row has no click.</summary>
    public string AskClaudePrice(ClipAutopilotOperation operation)
    {
        if (operation.Action is ClipAutopilotAction.Music) return "Find music · free library first";
        if (operation.Action is not ClipAutopilotAction.Rewrite rewrite) return "";
        if (AskClaudeServices?.Prices is not { } prices) return "Voice it · priced next";
        try
        {
            var estimate = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsTextToSpeech, "eleven_multilingual_v2", rewrite.Text.EnumerateRunes().Count(), 1, null, prices);
            return estimate.Usd is { } usd ? "Voice it · about $" + AskClaudePrompt.Number((double)Math.Max(usd, 0.01m)) : "Voice it · priced next";
        }
        catch (VoiceLabException) { return "Voice it · priced next"; }
    }

    /// <summary>The paid row's click: Rewrite opens on its words with Claude's wording, where the take's exact price is one more inline
    /// click. Nothing is spent here.</summary>
    public bool RunPaidAskClaudeRow(string id)
    {
        if (AskClaude.Run?.Rows.FirstOrDefault(row => row.Id == id) is { Status: AskClaudeRowStatus.Paid, Operation.Action: ClipAutopilotAction.Music music })
        {
            Announcement?.Invoke(this, "Music: " + music.Cue.Picked.Mood + ". Pick a track in Music.");
            AskClaudeMusicRequested?.Invoke(this, music.Cue);
            return true;
        }
        if (AskClaude.Run?.Rows.FirstOrDefault(row => row.Id == id) is not { Status: AskClaudeRowStatus.Paid, Operation.Action: ClipAutopilotAction.Rewrite rewrite }) return false;
        if (rewrite.Words.Start < 0 || rewrite.Words.End >= Words.Count) return false;
        Announcement?.Invoke(this, "Rewrite opens with Claude's words. Approve the price there to voice them.");
        RewriteAsRequested?.Invoke(this, new("Say exactly: " + rewrite.Text, "Rewrite", Words: (rewrite.Words.Start, rewrite.Words.End)));
        return true;
    }

    /// <summary>▶: plays the row's stretch from half a second before it.</summary>
    public bool PlayAskClaudeRow(string id)
    {
        if (AskClaude.Run?.Rows.FirstOrDefault(row => row.Id == id) is not { } row || SourceRange(row.Operation, Words) is not { } range) return false;
        AskClaudePlayRequested?.Invoke(this, Math.Max(0, range.Start - 0.5));
        return true;
    }

    /// <summary>The source seconds a change covers, for ▶; null when it has none.</summary>
    public static (double Start, double End)? SourceRange(ClipAutopilotOperation operation, IReadOnlyList<TimedWord> words)
    {
        switch (operation.Action)
        {
            case ClipAutopilotAction.Effect { Value: var value }: var effect = ClipEffect.Parse(value); return (effect.Start, effect.End);
            case ClipAutopilotAction.Motion { Cue: var cue }: return (cue.SourceStart, cue.SourceEnd);
            case ClipAutopilotAction.Stretch stretch: return (stretch.Start, stretch.End);
            case ClipAutopilotAction.Edit { Operation: EditOperation.Correct correct }:
                return words.FirstOrDefault(word => word.Id == correct.Id) is { } found ? (found.Start, found.End) : null;
            case ClipAutopilotAction.Edit { Operation: EditOperation.CutSelection cut }:
                var cutWords = words.Where(word => cut.Ids.Contains(word.Id)).ToArray();
                return cutWords.Length == 0 ? null : (cutWords[0].Start, cutWords[^1].End);
            case ClipAutopilotAction.Rewrite rewrite:
                return rewrite.Words.Start >= 0 && rewrite.Words.End < words.Count ? (words[rewrite.Words.Start].Start, words[rewrite.Words.End].End) : null;
            default: return null;
        }
    }

    // MARK: Speed

    /// <summary>The clip a stretch's speed would apply to: the one it covers whole, else its own clip, else the one clip holding it.</summary>
    public static string? StretchClip(ClipAutopilotOperation operation, Project snapshot)
    {
        if (operation.Action is not ClipAutopilotAction.Stretch stretch) return null;
        if (ClipControlsProject.WholeClip(stretch.ClipId, stretch.Start, stretch.End, snapshot) is { } whole) return whole;
        if (stretch.ClipId is { } own && snapshot.Edits.Clips.Any(clip => clip.Id == own)) return own;
        const double tolerance = ClipControlsProject.WholeClipToleranceSeconds;
        var holding = snapshot.Edits.Clips.Select(clip => clip.Id).Where(id =>
            ClipControlsProject.SourceSpan(id, snapshot) is { } span && span.Start - tolerance <= stretch.Start && stretch.End <= span.End + tolerance).ToArray();
        return holding.Length == 1 ? holding[0] : null;
    }

    /// <summary>"Apply 1.25× to the whole clip".</summary>
    public static string WholeClipTitle(ClipAutopilotOperation operation) =>
        operation.Action is ClipAutopilotAction.Stretch stretch ? "Apply " + Rate(stretch.Rate) + " to the whole clip" : "";

    /// <summary>The partial stretch's one inline action: that speed for its whole clip, as one undo step "Change speed".</summary>
    public bool ApplyAskClaudeStretchToClip(string id)
    {
        if (AskClaude.Run?.Rows.FirstOrDefault(row => row.Id == id) is not { Status: AskClaudeRowStatus.WholeClip, WholeClipId: { } clip, Operation.Action: ClipAutopilotAction.Stretch stretch } row) return false;
        var rate = ClipControlsProject.NormalizedSpeed(stretch.Rate);
        if (ClipControlsProject.Controls(clip, project)?.Speed != rate)
        {
            try { if (!ReplaceProject(ClipControlsProject.SettingSpeed(rate, clip, project), "Change speed")) return false; }
            catch (VoxClipException) { return false; }
        }
        row.Status = AskClaudeRowStatus.Applied;
        row.Detail = "Whole clip" + (ClipControlsProject.SourceSpan(clip, project) is { } span ? " · " + Clock(span.Start) + "–" + Clock(span.End) : "");
        AskClaudeNotify();
        Announcement?.Invoke(this, Rate(rate) + " for the whole clip");
        return true;
    }

    // MARK: Undo

    /// <summary>Takes one applied row out as its own undo step; the other rows stay.</summary>
    public bool UndoAskClaudeRow(string id)
    {
        if (AskClaude.Run is not { } run || run.Rows.FirstOrDefault(row => row.Id == id) is not { Status: AskClaudeRowStatus.Applied } row) return false;
        Project next;
        try { next = AskClaudeUndone([row.Operation], run.Base, project); }
        catch (Exception exception) when (exception is VoxClipException or VoiceLabException) { return false; }
        if (!ReferenceEquals(next, project) && !ReplaceProject(next, "Undo " + row.Title)) return false;
        row.Status = AskClaudeRowStatus.Undone;
        if (AskClaude.Adjusting == id) AskClaude.Adjusting = null;
        AskClaudeNotify();
        Announcement?.Invoke(this, "Undid " + row.Title);
        return true;
    }

    /// <summary>Undo all: every applied row out in one step.</summary>
    public bool UndoAllAskClaude()
    {
        if (AskClaude.Run is not { } run) return false;
        var applied = run.Rows.Where(row => row.Status == AskClaudeRowStatus.Applied).ToArray();
        if (applied.Length == 0) return false;
        Project next;
        try { next = AskClaudeUndone(applied.Select(row => row.Operation).ToArray(), run.Base, project); }
        catch (Exception exception) when (exception is VoxClipException or VoiceLabException) { return false; }
        if (!ReferenceEquals(next, project) && !ReplaceProject(next, "Undo Ask Claude")) return false;
        foreach (var row in applied) row.Status = AskClaudeRowStatus.Undone;
        AskClaude.Adjusting = null;
        AskClaudeNotify();
        Announcement?.Invoke(this, "Undid all of Claude's changes");
        return true;
    }

    /// <summary><paramref name="snapshot"/> with <paramref name="operations"/> taken out: their effects removed, corrections, cuts, ducking,
    /// translated captions and a clip's speed back to <paramref name="before"/>.</summary>
    public static Project AskClaudeUndone(IReadOnlyList<ClipAutopilotOperation> operations, Project? before, Project snapshot)
    {
        var next = snapshot;
        var effects = new HashSet<string>(StringComparer.Ordinal);
        var cues = new HashSet<string>(StringComparer.Ordinal);
        foreach (var operation in operations)
        {
            switch (operation.Action)
            {
                case ClipAutopilotAction.Effect { Value: var value }: effects.Add(value.GetProperty("id").GetString()!); break;
                case ClipAutopilotAction.Motion { Cue: var cue }: cues.Add(cue.Id); break;
                case ClipAutopilotAction.Edit { Operation: EditOperation.Correct correct }:
                {
                    var corrections = new Dictionary<string, string>(next.Edits.Corrections, StringComparer.Ordinal);
                    if (before?.Edits.Corrections.TryGetValue(correct.Id, out var previous) == true) corrections[correct.Id] = previous; else corrections.Remove(correct.Id);
                    next = next with { Edits = next.Edits with { Corrections = corrections } };
                    break;
                }
                case ClipAutopilotAction.Edit { Operation: EditOperation.CutSelection cut }:
                {
                    var kept = (before?.Edits.CutWordIds ?? []).ToHashSet(StringComparer.Ordinal);
                    next = next with { Edits = next.Edits with { CutWordIds = next.Edits.CutWordIds.Where(word => !cut.Ids.Contains(word) || kept.Contains(word)).ToArray() } };
                    break;
                }
                case ClipAutopilotAction.MusicDucking ducking:
                    if (next.Music.FirstOrDefault(entry => entry.ClipId == ducking.ClipId) is { } entry && before?.Music.FirstOrDefault(item => item.ClipId == ducking.ClipId) is { } original)
                        next = MusicProject.Setting(entry with { Ducking = original.Ducking }, ducking.ClipId, next);
                    break;
                case ClipAutopilotAction.TranslateCaptions translate:
                    // The words' captions go back to what they showed before the answer.
                    next = VoxClip.Core.Domain.Captions.CaptionTranslations.Untranslating(translate.StartWord, translate.EndWord, translate.ClipId, before, next);
                    break;
                case ClipAutopilotAction.Stretch:
                    if (StretchClip(operation, next) is { } clip)
                        next = ClipControlsProject.SettingSpeed(before is null ? 1 : ClipControlsProject.Controls(clip, before)?.Speed ?? 1, clip, next);
                    break;
            }
        }
        if (effects.Count > 0)
        {
            next = next with { ClipEffects = next.ClipEffects.Where(effect => !effects.Contains(effect.GetProperty("id").GetString()!)).ToArray() };
            ClipEffects.Validate(next);
        }
        if (cues.Count > 0) next = next with { MotionCues = next.MotionCues.Where(cue => !cues.Contains(cue.Id)).ToArray() };
        return next;
    }

    // MARK: Adjust

    /// <summary>The effect a row added, as the project has it now (after any Adjust); null when it was undone.</summary>
    public ClipEffect? AskClaudeEffect(string id) => AskClaudeEffectEntry(id) is { } entry ? ClipEffect.Parse(entry) : null;

    private JsonElement? AskClaudeEffectEntry(string id)
    {
        if (AskClaude.Run?.Rows.FirstOrDefault(row => row.Id == id) is not { Operation.Action: ClipAutopilotAction.Effect { Value: var value } }) return null;
        var effectId = value.GetProperty("id").GetString();
        foreach (var entry in project.ClipEffects) if (entry.GetProperty("id").GetString() == effectId) return entry;
        return null;
    }

    /// <summary>Whether a row has an Adjust editor: an applied effect still in the project.</summary>
    public bool CanAdjustAskClaude(AskClaudeRow row) => row.Status == AskClaudeRowStatus.Applied && row.Operation.Action is ClipAutopilotAction.Effect && AskClaudeEffect(row.Id) is not null;

    /// <summary>Opens or closes a row's Adjust editor.</summary>
    public void ToggleAskClaudeAdjust(string id) { AskClaude.Adjusting = AskClaude.Adjusting == id ? null : id; AskClaudeNotify(); }

    /// <summary>Replaces an applied effect with <paramref name="change"/> applied, as one undo step ("Adjust Blur"). Times stay in order,
    /// a freeze at most 5 s, a sound its own length, a rect inside the frame; a moved tracked box holds still until traced again.</summary>
    public bool AdjustAskClaudeEffect(string id, Action<JsonObject> change, string? name = null)
    {
        if (AskClaudeEffectEntry(id) is not { } entry) return false;
        var current = ClipEffect.Parse(entry);
        var node = JsonNode.Parse(entry.GetRawText())!.AsObject();
        change(node);
        var start = Math.Max(0, node["start"]!.GetValue<double>());
        var end = node["end"]!.GetValue<double>();
        if (end <= start + 0.05) end = start + 0.05;
        if (current.Kind == "freeze") end = Math.Min(end, start + 5);
        if (node["sound"] is JsonObject sound) end = start + sound["durationSeconds"]!.GetValue<double>();
        node["start"] = start;
        node["end"] = end;
        if (node["rect"] is JsonObject rect)
        {
            var clamped = AskClaudeValidator.Clamped(new(rect["x"]!.GetValue<double>(), rect["y"]!.GetValue<double>(), rect["width"]!.GetValue<double>(), rect["height"]!.GetValue<double>()));
            node["rect"] = new JsonObject { ["x"] = clamped.X, ["y"] = clamped.Y, ["width"] = clamped.Width, ["height"] = clamped.Height };
        }
        var next = Element(node);
        var moved = ClipEffect.Parse(next);
        // A moved or nudged tracked box holds still until it is traced again.
        if (current.Kind is "blur" or "pixelate" && moved.Track.Count > 0 && (moved.Rect != current.Rect || moved.Start != current.Start || moved.End != current.End) &&
            JsonElement.DeepEquals(entry.GetProperty("track"), next.GetProperty("track")))
        {
            node["track"] = new JsonArray();
            next = Element(node);
        }
        if (JsonElement.DeepEquals(entry, next) || !ClipEffects.IsValidEntry(next, project.Id)) return false;
        try { return ReplaceProject(ClipEffects.Adding([next], project), name ?? "Adjust " + AskClaudeRowTitle(new(id, ClipAutopilotDecision.Overlay, new ClipAutopilotAction.Effect(next), ""))); }
        catch (VoxClipException) { return false; }
    }

    /// <summary>Start or End earlier or later by a tenth of a second.</summary>
    public bool NudgeAskClaudeEffect(string id, bool start, double delta) =>
        AdjustAskClaudeEffect(id, node => node[start ? "start" : "end"] = node[start ? "start" : "end"]!.GetValue<double>() + delta);

    /// <summary>A title or lower third's new text (trimmed, at most 80 scalars).</summary>
    public bool SetAskClaudeText(string id, string text)
    {
        var trimmed = AskClaudeValidator.Scalars(text.Trim(), ClipHookTitle.MaximumTitleScalars);
        return trimmed.Length > 0 && AdjustAskClaudeEffect(id, node => node["text"] = trimmed);
    }

    /// <summary>A frame kind's position.</summary>
    public bool SetAskClaudePosition(string id, string position) => AdjustAskClaudeEffect(id, node => node["position"] = position);

    /// <summary>The emoji's size, in 25 % steps, 50–300 %.</summary>
    public bool StepAskClaudeScale(string id, int steps) =>
        AdjustAskClaudeEffect(id, node => node["scale"] = Math.Clamp((node["scale"]?.GetValue<double>() ?? 1) + steps * 0.25, 0.5, 3));

    /// <summary>The box moved by (dx, dy) of the frame, or scaled about its centre.</summary>
    public bool MoveAskClaudeBox(string id, double dx, double dy, double factor = 1, string? name = null) => AdjustAskClaudeEffect(id, node =>
    {
        if (node["rect"] is not JsonObject rect) return;
        var box = new ClipEffectRect(rect["x"]!.GetValue<double>() + dx, rect["y"]!.GetValue<double>() + dy, rect["width"]!.GetValue<double>(), rect["height"]!.GetValue<double>());
        if (factor != 1) box = AskClaudeRectGeometry.Scaled(box, factor);
        node["rect"] = new JsonObject { ["x"] = box.X, ["y"] = box.Y, ["width"] = box.Width, ["height"] = box.Height };
    }, name);

    /// <summary>The box set to <paramref name="filmed"/> (a drag on the viewer, mapped back to the source as filmed).</summary>
    public bool SetAskClaudeBox(string id, ClipEffectRect filmed) => AdjustAskClaudeEffect(id, node =>
        node["rect"] = new JsonObject { ["x"] = filmed.X, ["y"] = filmed.Y, ["width"] = filmed.Width, ["height"] = filmed.Height },
        "Move " + (AskClaudeEffect(id) is { } effect ? effect.Kind switch { "pixelate" => "Pixelate", "arrow" => "Arrow", "circle" => "Circle", _ => "Blur" } : "Blur"));

    /// <summary>A sound's new bundled sound, at its own length.</summary>
    public bool SetAskClaudeSound(string id, string sound)
    {
        if (!AskClaudeValidator.SoundSeconds.TryGetValue(sound, out var seconds)) return false;
        return AdjustAskClaudeEffect(id, node =>
        {
            node["sound"] = new JsonObject { ["source"] = "bundled", ["id"] = sound, ["durationSeconds"] = seconds, ["title"] = char.ToUpperInvariant(sound[0]) + sound[1..], ["license"] = "cc0" };
            node["end"] = node["start"]!.GetValue<double>() + seconds;
        });
    }

    /// <summary>What a blur or pixelate follows: Hold still keeps its box; A face is traced again on this PC; Windows cannot follow
    /// the moving subject, so that choice holds the box and the row says so.</summary>
    public async Task<bool> RetrackAskClaudeEffectAsync(string id, string tracking)
    {
        if (AskClaudeEffect(id) is not { Kind: "blur" or "pixelate" } current || current.Tracking == tracking) return false;
        if (!AskClaudeVision.Follows(tracking) || AskClaudeServices?.Vision is not { } vision || project.Media.Source.Video is null || current.Rect is not { } rect)
            return AdjustAskClaudeEffect(id, node => { node["tracking"] = tracking; node["track"] = new JsonArray(); }, tracking == "none" ? "Hold the blur still" : "Track the blur");
        AskClaude.Progress = "Following what moves";
        AskClaudeNotify();
        try
        {
            var track = await AskClaudeVision.TrackAsync(vision, tracking, current.Start, current.End, rect, CancellationToken.None);
            if (AskClaudeEffect(id) != current) return false;
            return AdjustAskClaudeEffect(id, node =>
            {
                node["tracking"] = tracking;
                node["track"] = new JsonArray(track.Select(sample => (JsonNode)new JsonObject
                {
                    ["t"] = sample.T, ["x"] = sample.Rect.X, ["y"] = sample.Rect.Y, ["width"] = sample.Rect.Width, ["height"] = sample.Rect.Height
                }).ToArray());
            }, "Track the blur");
        }
        catch (Exception exception) when (exception is not OutOfMemoryException) { return false; }
        finally { AskClaude.Progress = null; AskClaudeNotify(); }
    }

    /// <summary>The Follow row's note on Windows, which follows faces only: "The moving subject" holds the box still.</summary>
    public static string? AskClaudeFollowNote(ClipEffect effect) => effect.Tracking switch
    {
        "saliency" => "Windows follows faces only, so this box holds still where Claude put it.",
        "face" when effect.Track.Count == 0 => "No face was traced on this PC, so this box holds still where Claude put it.",
        _ => null
    };

    /// <summary>The Adjust row's effect, when it has a box to drag on the viewer.</summary>
    public (string Id, ClipEffect Effect)? AskClaudeAdjustingRect =>
        AskClaude.Adjusting is { } id && AskClaudeEffect(id) is { UsesRect: true } effect ? (id, effect) : null;

    /// <summary>A click on an effect in the FX lane opens its row's Adjust editor, from the run that made it.</summary>
    public bool AdjustAskClaudeFromTimeline(string effectId)
    {
        if (AskClaude.Run?.Rows.FirstOrDefault(row => row.Status == AskClaudeRowStatus.Applied &&
                row.Operation.Action is ClipAutopilotAction.Effect { Value: var value } && value.GetProperty("id").GetString() == effectId) is not { } row) return false;
        AskClaude.Adjusting = row.Id;
        AskClaudeShown?.Invoke(this, EventArgs.Empty);
        AskClaudeNotify();
        return true;
    }

    // MARK: Timeline

    /// <summary>The FX lane's effects in the open scope, in source seconds, with their row names: censors everywhere, others in their clip.</summary>
    public IReadOnlyList<(string Id, double Start, double End, string Label)> TimelineEffects()
    {
        var scope = state?.ActiveClipId is { } clip ? ClipControlsProject.SourceSpan(clip, project) : null;
        var lower = scope?.Start ?? 0;
        var upper = scope?.End ?? Math.Max(0, project.Media.Source.DurationSeconds);
        return ClipEffects.Rendered(project, state?.ActiveClipId).Select(effect =>
        {
            var entry = project.ClipEffects.First(item => item.GetProperty("id").GetString() == effect.Id);
            var label = AskClaudeRowTitle(new(effect.Id, ClipAutopilotDecision.Overlay, new ClipAutopilotAction.Effect(entry), ""));
            return (effect.Id, Math.Max(lower, effect.Start), Math.Min(upper, effect.End), label);
        }).Where(item => item.Item3 > item.Item2).ToArray();
    }
}
