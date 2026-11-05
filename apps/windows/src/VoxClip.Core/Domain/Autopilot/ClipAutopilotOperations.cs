using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>The background track a plan picked (ai.md §16.6). Windows does not mix music yet, so it stays pending.</summary>
public sealed record ClipAutopilotMusicCue(string ClipId, ClipAutopilotPlan.Music Picked, IReadOnlyList<ClipAutopilotPlan.Music> Alternatives, double Seconds);

/// <summary>What kind of decision an operation is, for the review's row.</summary>
public enum ClipAutopilotDecision
{
#pragma warning disable CS1591
    Clip, Title, Correction, Cut, PauseCut, Rewrite, Captions, Look, Speed, Zoom, Music, Hook, PostText
#pragma warning restore CS1591
}

/// <summary>How an operation acts on the project.</summary>
public abstract record ClipAutopilotAction
{
    /// <summary>An editor operation applied as it is: corrections, cuts, pause cuts, the clip and its title.</summary>
    public sealed record Edit(EditOperation Operation) : ClipAutopilotAction;
    /// <summary>A Rewrite proposal for the words: needs a voice, a quote and a paid step, so it stays pending.</summary>
    public sealed record Rewrite(WordSpan Words, string Text) : ClipAutopilotAction;
    /// <summary>The clip's caption style (its pick, design §6.6) and the project's caption overrides in <c>Settings</c>;
    /// <c>PendingFont</c> names an unbundled font.</summary>
    public sealed record Captions(string ClipId, ProjectCaptions Settings, ClipAutopilotFont? PendingFont) : ClipAutopilotAction
    {
        /// <summary>Applies the choice: the overrides to the project's captions, the style as the clip's pick with Claude's
        /// <paramref name="reason"/> (the project default when the project has no clip style yet).</summary>
        public Project Applying(Project project, string reason) =>
            ClipCaptionStyles.Choosing(project with { Captions = project.Captions with { Overrides = Settings.Overrides } }, ClipId, Settings.StyleId,
                reason.Length > 0 && reason != ClipCaptionStyles.YourChoice ? reason : "Claude's pick");
    }
    /// <summary>The clip's colour look (clip controls).</summary>
    public sealed record Look(string ClipId, ClipAutopilotPlan.Look Choice) : ClipAutopilotAction;
    /// <summary>The whole clip at a speed, pitch kept (clip controls).</summary>
    public sealed record Speed(string ClipId, ClipAutopilotPlan.Speed Choice) : ClipAutopilotAction;
    /// <summary>A punch-in cue for the clip; pending on Windows, which does not render motion cues yet.</summary>
    public sealed record Motion(MotionCue Cue) : ClipAutopilotAction;
    /// <summary>The picked track; pending on Windows.</summary>
    public sealed record Music(ClipAutopilotMusicCue Cue) : ClipAutopilotAction;
    /// <summary>The first 2 seconds' text, applied as the clip's title card.</summary>
    public sealed record Hook(string ClipId, string Text) : ClipAutopilotAction;
    /// <summary>The clip's share text.</summary>
    public sealed record ShareText(string ClipId, string Text) : ClipAutopilotAction;
}

/// <summary>One reviewable decision as an editor operation (ai.md §16.6); <c>Id</c> is stable for a plan.</summary>
public sealed record ClipAutopilotOperation(string Id, ClipAutopilotDecision Decision, ClipAutopilotAction Action, string Reason);

/// <summary>Plan to operations, and the operations applied to a project. Twin of the Mac <c>ClipAutopilotMapping</c>.</summary>
public static partial class ClipAutopilotMapping
{
    /// <summary>The largest punch-in scale (Mac <c>MotionCue.maximumScale</c>).</summary>
    public const double MaximumZoomScale = 1.35;

    [GeneratedRegex("\\A(?:[A-Za-z0-9][A-Za-z0-9._:-]{0,63})\\z", RegexOptions.CultureInvariant)]
    private static partial Regex ClipIdPattern();

    /// <summary>The operations for one plan, in review order: the clip, its title, corrections, cuts, pause cuts, rewrites, captions,
    /// look, speed, zooms, music, hook and post text. An existing clip is updated; a new id is added as an AI clip.</summary>
    public static IReadOnlyList<ClipAutopilotOperation> Operations(ClipAutopilotPlan plan, string clipId, Project project, IReadOnlyDictionary<ClipAutopilotFont, string> fonts)
    {
        if (EditingEngine.FromProject(project) is not { } state) throw ClipAutopilotRequestBuilder.Invalid();
        var words = state.Transcript.Words;
        if (plan.StartWord < 0 || plan.EndWord >= words.Count || plan.StartWord > plan.EndWord || !ClipIdPattern().IsMatch(clipId)) throw ClipAutopilotRequestBuilder.Invalid();
        var operations = new List<ClipAutopilotOperation>();
        void Add(string id, ClipAutopilotDecision decision, ClipAutopilotAction action, string reason = "") => operations.Add(new(id, decision, action, reason));
        var title = plan.Title.Length == 0 ? null : plan.Title;
        if (state.Clips.FirstOrDefault(clip => clip.Id == clipId) is { } existing)
        {
            var start = words.ToList().FindIndex(word => word.Id == existing.StartWordId);
            var end = words.ToList().FindIndex(word => word.Id == existing.EndWordId);
            if (start != plan.StartWord || end != plan.EndWord) Add("clip", ClipAutopilotDecision.Clip, new ClipAutopilotAction.Edit(new EditOperation.UpdateClip(clipId, plan.StartWord, plan.EndWord)));
            if (title is not null && title != existing.Title) Add("title", ClipAutopilotDecision.Title, new ClipAutopilotAction.Edit(new EditOperation.RenameClip(clipId, title)));
        }
        else
        {
            Add("clip", ClipAutopilotDecision.Clip, new ClipAutopilotAction.Edit(new EditOperation.AddClip(
                new ClipRange(clipId, words[plan.StartWord].Id, words[plan.EndWord].Id, title, ClipOrigin.Ai, null, null, true))));
        }
        for (var index = 0; index < plan.Corrections.Count; index++)
        {
            var correction = plan.Corrections[index];
            if (words[correction.Word].Kind == WordKind.Word)
                Add("correction-" + index, ClipAutopilotDecision.Correction, new ClipAutopilotAction.Edit(new EditOperation.Correct(words[correction.Word].Id, correction.Text)), correction.Reason);
        }
        for (var index = 0; index < plan.Cuts.Count; index++)
        {
            var cut = plan.Cuts[index];
            var ids = new WordSpan(cut.StartWord, cut.EndWord).Indices.Select(position => words[position].Id).Where(id => !state.CutWordIds.Contains(id)).ToArray();
            if (ids.Length > 0) Add("cut-" + index, ClipAutopilotDecision.Cut, new ClipAutopilotAction.Edit(new EditOperation.SetWordCuts(ids, true)), cut.Reason);
        }
        for (var index = 0; index < plan.PauseCuts.Count; index++)
        {
            var pause = plan.PauseCuts[index];
            if (state.Pauses.FirstOrDefault(item => item.AfterIndex == pause.AfterWord) is not { } found || state.CutPauseIds.Contains(found.Id)) continue;
            Add("pause-" + index, ClipAutopilotDecision.PauseCut, new ClipAutopilotAction.Edit(new EditOperation.SetPauseCuts([found.Id], true)), pause.Reason);
        }
        for (var index = 0; index < plan.Rewrites.Count; index++)
        {
            var rewrite = plan.Rewrites[index];
            Add("rewrite-" + index, ClipAutopilotDecision.Rewrite, new ClipAutopilotAction.Rewrite(new(rewrite.StartWord, rewrite.EndWord), rewrite.Text), rewrite.Reason);
        }
        var overrides = project.Captions.Overrides.ValueKind == JsonValueKind.Object
            ? JsonNode.Parse(project.Captions.Overrides.GetRawText())!.AsObject() : new JsonObject();
        void Merge(string key, JsonObject values)
        {
            var target = overrides[key] as JsonObject ?? new JsonObject();
            foreach (var (name, value) in values.ToArray()) target[name] = value?.DeepClone();
            overrides[key] = target;
        }
        var captions = plan.CaptionChoice;
        Merge("text", new JsonObject { ["transform"] = captions.TextCase.Transform() });
        Merge("layout", captions.WordsPerCaption == 1 ? new JsonObject { ["maxWords"] = 1, ["maxLines"] = 1 } : new JsonObject { ["maxWords"] = captions.WordsPerCaption });
        var file = fonts.TryGetValue(captions.Font, out var bundled) ? bundled : null;
        if (file is not null) Merge("font", new JsonObject { ["file"] = file, ["family"] = captions.Font.Family, ["weight"] = captions.Font.Weight });
        using var document = JsonDocument.Parse(overrides.ToJsonString());
        var settings = project.Captions with { StyleId = captions.StyleId, Overrides = document.RootElement.Clone() };
        Add("captions", ClipAutopilotDecision.Captions, new ClipAutopilotAction.Captions(clipId, settings, file is null ? captions.Font : null), captions.Reason);
        Add("look", ClipAutopilotDecision.Look, new ClipAutopilotAction.Look(clipId, plan.ClipLookChoice), plan.ClipLookChoice.Reason);
        if (plan.SpeedChoice is { } speed) Add("speed", ClipAutopilotDecision.Speed, new ClipAutopilotAction.Speed(clipId, speed), speed.Reason);
        for (var index = 0; index < plan.Zooms.Count; index++)
        {
            var zoom = plan.Zooms[index];
            var cue = new MotionCue(string.Join('-', clipId, "zoom", index.ToString(System.Globalization.CultureInfo.InvariantCulture)), clipId, words[zoom.Word].Start, words[zoom.UntilWord].End,
                [new MotionKeyframe(0, zoom.Scale, 0.5, 0.5), new MotionKeyframe(1, zoom.Scale, 0.5, 0.5)]);
            Add("zoom-" + index, ClipAutopilotDecision.Zoom, new ClipAutopilotAction.Motion(cue), zoom.Reason);
        }
        if (plan.PickedMusic is { } picked)
            Add("music", ClipAutopilotDecision.Music, new ClipAutopilotAction.Music(new(clipId, picked, plan.MusicChoices.Where(item => item != picked).ToArray(), EditedSeconds(plan, state))), picked.Reason);
        if (plan.Hook.Length > 0) Add("hook", ClipAutopilotDecision.Hook, new ClipAutopilotAction.Hook(clipId, plan.Hook));
        if (plan.PostText.Length > 0) Add("post", ClipAutopilotDecision.PostText, new ClipAutopilotAction.ShareText(clipId, plan.PostText));
        return operations;
    }

    /// <summary>The clip's length once the plan's cuts and pause cuts apply, at its own speed.</summary>
    public static double EditedSeconds(ClipAutopilotPlan plan, EditState state)
    {
        var words = state.Transcript.Words;
        if (plan.StartWord < 0 || plan.EndWord >= words.Count || plan.StartWord > plan.EndWord) return 0;
        var cut = plan.Cuts.SelectMany(item => new WordSpan(item.StartWord, item.EndWord).Indices.Select(index => words[index].Id)).Concat(state.CutWordIds).ToHashSet(StringComparer.Ordinal);
        return EditedSeconds(plan.Span, words, cut, state.Pauses, plan.PauseCuts.Select(pause => pause.AfterWord).ToHashSet(), state.CutPauseIds, state.PauseKeepSeconds);
    }

    /// <summary>The finished clip's length: <see cref="EditedSeconds(ClipAutopilotPlan, EditState)"/> at the plan's speed.</summary>
    public static double FinalSeconds(ClipAutopilotPlan plan, EditState state) => EditedSeconds(plan, state) / (plan.SpeedChoice?.Rate ?? 1);

    internal static double EditedSeconds(WordSpan span, IReadOnlyList<TimedWord> words, IReadOnlySet<string> cut, IReadOnlyList<Pause> pauses,
        IReadOnlySet<int> tightened, IReadOnlySet<string> cutPauseIds, double keepSeconds)
    {
        var seconds = words[span.End].End - words[span.Start].Start;
        foreach (var index in span.Indices.Where(index => cut.Contains(words[index].Id))) seconds -= words[index].End - words[index].Start;
        foreach (var pause in pauses.Where(pause => pause.AfterIndex >= span.Start && pause.AfterIndex < span.End && (tightened.Contains(pause.AfterIndex) || cutPauseIds.Contains(pause.Id))))
            seconds -= Math.Max(0, pause.End - pause.Start - keepSeconds);
        return Math.Max(0, seconds);
    }

    /// <summary>Applies what the editor can, in order, to a copy of <paramref name="project"/>: edits, captions, share text, the look and
    /// speed, and the hook as the clip's title card (timed on the clip as the operations before it left it). Rewrites, music and zooms
    /// come back as pending: a rewrite needs a paid voice, music needs a source to fetch from (the App's Music section picks it), and
    /// Windows renders no motion cues yet (a project holding one refuses to export, <c>VoiceLabRenderContract.RequireWindowsVisualSupport</c>).
    /// Pure: one undo step is the caller's choice.</summary>
    public static (Project Project, IReadOnlyList<ClipAutopilotOperation> Pending) Apply(IReadOnlyList<ClipAutopilotOperation> operations, Project project)
    {
        var result = project;
        var pending = new List<ClipAutopilotOperation>();
        foreach (var operation in operations)
        {
            switch (operation.Action)
            {
                case ClipAutopilotAction.Edit edit:
                    var state = EditingEngine.FromProject(result) ?? throw ClipAutopilotRequestBuilder.Invalid();
                    result = EditingEngine.ApplyToProject(result, EditingEngine.Reduce(state, edit.Operation, result.Ai.Results));
                    break;
                case ClipAutopilotAction.Captions captions: result = captions.Applying(result, operation.Reason); break;
                case ClipAutopilotAction.ShareText share:
                    var texts = new Dictionary<string, string>(result.Share.Captions, StringComparer.Ordinal) { [share.ClipId] = share.Text };
                    result = result with { Share = new(texts) };
                    break;
                case ClipAutopilotAction.Look look: result = ClipControlsProject.SettingLook(look.Choice.Id, look.ClipId, result); break;
                case ClipAutopilotAction.Speed speed: result = ClipControlsProject.SettingSpeed(speed.Choice.Rate, speed.ClipId, result); break;
                case ClipAutopilotAction.Hook hook:
                    if (ClipHookTitle.Effect(hook.Text, hook.ClipId, result) is { } card) result = ClipEffects.Adding([card], result);
                    else pending.Add(operation);
                    break;
                default: pending.Add(operation); break;
            }
        }
        return (result, pending);
    }
}
