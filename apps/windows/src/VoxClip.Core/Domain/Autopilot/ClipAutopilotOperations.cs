using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>The background track a plan picked (ai.md §16.6). Windows does not mix music yet, so it stays pending.</summary>
public sealed record ClipAutopilotMusicCue(string ClipId, ClipAutopilotPlan.Music Picked, IReadOnlyList<ClipAutopilotPlan.Music> Alternatives, double Seconds);

/// <summary>What kind of decision an operation is, for the review's row. Ask Claude's toolbox (ai.md §18.2) adds Bleep (a bleep or
/// mute), Blur (blur or pixelate), Overlay (title, lower third, sticker, arrow, circle, progress bar), Freeze, Sound, Stretch,
/// Translate and Duck; the planner's decisions keep their meaning.</summary>
public enum ClipAutopilotDecision
{
#pragma warning disable CS1591
    Clip, Title, Correction, Cut, PauseCut, Rewrite, Captions, Look, Speed, Zoom, Music, Hook, PostText,
    Bleep, Blur, Overlay, Freeze, Sound, Stretch, Translate, Duck
#pragma warning restore CS1591
}

/// <summary>How an operation acts on the project.</summary>
public abstract record ClipAutopilotAction
{
    /// <summary>An editor operation applied as it is: corrections, cuts, pause cuts, the clip and its title.</summary>
    public sealed record Edit(EditOperation Operation) : ClipAutopilotAction;
    /// <summary>A Rewrite proposal for the words: needs a voice, a quote and a paid step, so it stays pending.</summary>
    public sealed record Rewrite(WordSpan Words, string Text) : ClipAutopilotAction;
    /// <summary>The project's caption settings; <c>PendingFont</c> names an unbundled font.</summary>
    public sealed record Captions(ProjectCaptions Settings, ClipAutopilotFont? PendingFont) : ClipAutopilotAction;
    /// <summary>The clip's colour look (clip controls).</summary>
    public sealed record Look(string ClipId, ClipAutopilotPlan.Look Choice) : ClipAutopilotAction;
    /// <summary>The whole clip at a speed, pitch kept (clip controls).</summary>
    public sealed record Speed(string ClipId, ClipAutopilotPlan.Speed Choice) : ClipAutopilotAction;
    /// <summary>A punch-in cue for the clip; pending on Windows, which does not render motion cues yet.</summary>
    public sealed record Motion(MotionCue Cue, ClipAutopilotZoomDirection? Direction = null) : ClipAutopilotAction;
    /// <summary>The picked track; pending on Windows.</summary>
    public sealed record Music(ClipAutopilotMusicCue Cue) : ClipAutopilotAction;
    /// <summary>Reuses a track already present in the project.</summary>
    public sealed record SavedMusic(string ClipId, string TrackId) : ClipAutopilotAction;
    /// <summary>The first 2 seconds' text, applied as the clip's title card.</summary>
    public sealed record Hook(string ClipId, string Text) : ClipAutopilotAction;
    /// <summary>The clip's share text.</summary>
    public sealed record ShareText(string ClipId, string Text) : ClipAutopilotAction;
    /// <summary>An Ask Claude effect (ai.md §18.2), the stored <c>clipEffects</c> entry, already valid.</summary>
    public sealed record Effect(JsonElement Value) : ClipAutopilotAction;
    /// <summary>Places a companion recording on the clip.</summary>
    public sealed record Footage(ProjectFootage Entry) : ClipAutopilotAction;
    /// <summary>A timed request for a library sound or generated illustration.</summary>
    public sealed record Asset(string Id, string Kind, string ClipId, double Start, double End, string Text) : ClipAutopilotAction;
    /// <summary>A stretch played at <c>Rate</c> (source seconds). Over a whole clip it sets that clip's speed; over part of one it stays
    /// pending and the editor offers the speed for the whole clip.</summary>
    public sealed record Stretch(string? ClipId, double Start, double End, double Rate) : ClipAutopilotAction;
    /// <summary>Translated captions for the words (ai.md §18.2): applied as the project's <c>captionTranslations</c>; the voice and
    /// transcript stay.</summary>
    public sealed record TranslateCaptions(string? ClipId, int StartWord, int EndWord, string Language, string Text) : ClipAutopilotAction;
    /// <summary>Duck the clip's music under the voice.</summary>
    public sealed record MusicDucking(string? ClipId, bool On) : ClipAutopilotAction;
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
    public static IReadOnlyList<ClipAutopilotOperation> Operations(ClipAutopilotPlan plan, string clipId, Project project,
        IReadOnlyDictionary<ClipAutopilotFont, string> fonts, IReadOnlySet<string>? stickers = null)
    {
        if (EditingEngine.FromProject(project) is not { } state) throw ClipAutopilotRequestBuilder.Invalid();
        var words = state.Transcript.Words;
        var existing = state.Clips.FirstOrDefault(clip => clip.Id == clipId);
        var proposal = plan.CanonicalProposal(existing?.Id);
        var parts = proposal.Parts ?? [];
        if (plan.StartWord < 0 || plan.EndWord >= words.Count || plan.StartWord > plan.EndWord || !ClipIdPattern().IsMatch(clipId) ||
            parts.Count == 0 || parts.Any(part => part.StartWord < plan.StartWord || part.EndWord > plan.EndWord || part.StartWord > part.EndWord))
            throw ClipAutopilotRequestBuilder.Invalid();
        var operations = new List<ClipAutopilotOperation>();
        void Add(string id, ClipAutopilotDecision decision, ClipAutopilotAction action, string reason = "") => operations.Add(new(id, decision, action, reason));
        var title = plan.Title.Length == 0 ? null : plan.Title;
        var clipParts = parts.Select((part, index) =>
        {
            var previous = existing?.PlayParts.FirstOrDefault(candidate =>
            {
                var lower = words.ToList().FindIndex(word => word.Id == candidate.StartWordId);
                var upper = words.ToList().FindIndex(word => word.Id == candidate.EndWordId);
                return lower >= 0 && lower <= part.StartWord && part.EndWord <= upper;
            });
            return new ClipPart(previous?.Id ?? $"part-{(index + 1).ToString(CultureInfo.InvariantCulture)}", words[part.StartWord].Id, words[part.EndWord].Id, previous?.Reframe);
        }).ToArray();
        if (existing is not null)
        {
            var start = words.ToList().FindIndex(word => word.Id == existing.StartWordId);
            var end = words.ToList().FindIndex(word => word.Id == existing.EndWordId);
            if (existing.Parts is not null || parts.Count > 1)
            {
                if (!existing.PlayParts.SequenceEqual(clipParts))
                    Add("clip", ClipAutopilotDecision.Clip, new ClipAutopilotAction.Edit(new EditOperation.SetClipParts(clipId, clipParts)));
            }
            else if (start != plan.StartWord || end != plan.EndWord) Add("clip", ClipAutopilotDecision.Clip, new ClipAutopilotAction.Edit(new EditOperation.UpdateClip(clipId, plan.StartWord, plan.EndWord)));
            if (title is not null && title != existing.Title) Add("title", ClipAutopilotDecision.Title, new ClipAutopilotAction.Edit(new EditOperation.RenameClip(clipId, title)));
        }
        else
        {
            Add("clip", ClipAutopilotDecision.Clip, new ClipAutopilotAction.Edit(new EditOperation.AddClip(
                new ClipRange(clipId, words[plan.StartWord].Id, words[plan.EndWord].Id, title, ClipOrigin.Ai, null, null, true,
                    Parts: parts.Count > 1 ? clipParts : null, Kind: parts.Count > 1 ? plan.Kind == "showreel" ? StoryClipKind.Showreel : StoryClipKind.Story : null))));
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
        Add("captions", ClipAutopilotDecision.Captions, new ClipAutopilotAction.Captions(settings, file is null ? captions.Font : null), captions.Reason);
        Add("look", ClipAutopilotDecision.Look, new ClipAutopilotAction.Look(clipId, plan.ClipLookChoice), plan.ClipLookChoice.Reason);
        if (plan.SpeedChoice is { } speed) Add("speed", ClipAutopilotDecision.Speed, new ClipAutopilotAction.Speed(clipId, speed), speed.Reason);
        var zoomRanges = new List<TimeRange>();
        var corrections = new Dictionary<string, string>(state.Corrections, StringComparer.Ordinal);
        foreach (var correction in plan.Corrections) corrections[words[correction.Word].Id] = correction.Text;
        for (var index = 0; index < plan.Zooms.Count; index++)
        {
            var zoom = plan.Zooms[index];
            if (zoom.SourceRange(words, new(plan.StartWord, plan.EndWord)) is not { } range || zoom.Scale is not (>= 1 and <= MaximumZoomScale) ||
                zoomRanges.Any(other => other.Start < range.End && range.Start < other.End)) continue;
            var key = "zoom-" + index.ToString(CultureInfo.InvariantCulture);
            var cueId = clipId + "-" + key;
            var reason = zoom.Reason;
            if (zoom.Direction is not null)
            {
                var phraseSpan = new WordSpan(zoom.Word, zoom.UntilWord);
                if (!zoom.HasDirectionalSettings || phraseSpan.Indices.Any(position => state.CutWordIds.Contains(words[position].Id)) ||
                    plan.Cuts.Any(cut => phraseSpan.Overlaps(new(cut.StartWord, cut.EndWord))) ||
                    zoomRanges.Any(other => Math.Abs(other.Start - range.Start) < ClipAutopilotPlan.Zoom.MinimumStartSpacing - ClipAutopilotPlan.Zoom.TimingTolerance)) continue;
                var phrase = string.Join(" ", phraseSpan.Indices.Select(position => words[position]).Where(word => word.Kind == WordKind.Word)
                    .Select(word => corrections.GetValueOrDefault(word.Id, word.Text)));
                var letters = StringInfo.ParseCombiningCharacters(phrase);
                var excerpt = letters.Length > 96 ? phrase[..letters[95]] + "…" : phrase;
                reason = $"“{excerpt}” · {reason}";
                cueId = string.Create(CultureInfo.InvariantCulture, $"{clipId}-zoom-{zoom.Word}-{zoom.UntilWord}");
            }
            MotionKeyframe Frame(double progress, double scale = 1) => new(progress, scale, 0.5, 0.5);
            IReadOnlyList<MotionKeyframe> frames = zoom.Direction switch
            {
                ClipAutopilotZoomDirection.ZoomIn => [Frame(0), Frame(0.28, zoom.Scale), Frame(0.70, zoom.Scale), Frame(1)],
                ClipAutopilotZoomDirection.ZoomOut => [Frame(0, zoom.Scale), Frame(0.18, zoom.Scale), Frame(1)],
                null => [Frame(0, zoom.Scale), Frame(1, zoom.Scale)],
                _ => []
            };
            if (frames.Count == 0) continue;
            var cue = new MotionCue(cueId, clipId, range.Start, range.End, frames);
            Add(key, ClipAutopilotDecision.Zoom, new ClipAutopilotAction.Motion(cue, zoom.Direction), reason);
            zoomRanges.Add(range);
        }
        var cutIds = state.CutWordIds.Concat(plan.Cuts.SelectMany(cut => new WordSpan(cut.StartWord, cut.EndWord).Indices
            .Where(index => index >= 0 && index < words.Count).Select(index => words[index].Id))).ToHashSet(StringComparer.Ordinal);
        var tightened = plan.PauseCuts.Select(pause => pause.AfterWord).Concat(state.Pauses.Where(pause => state.CutPauseIds.Contains(pause.Id))
            .Select(pause => pause.AfterIndex)).ToHashSet();
        var overlayRanges = new List<(double Start, double End)>();
        var first = parts[0];
        var opening = new WordSpan(first.StartWord, first.EndWord).Indices.FirstOrDefault(index => !cutIds.Contains(words[index].Id), first.StartWord);
        var sources = (project.Media.AdditionalSources ?? []).Where(source => source.Video is not null).GroupBy(source => source.FootageKey, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First().DurationSeconds, StringComparer.Ordinal);
        var openingTitle = false;
        var saved = plan.Effects ?? [];
        for (var index = 0; index < Math.Min(saved.Count, ClipPlanEffect.MaximumEntries); index++)
        {
            var id = $"{clipId[..Math.Min(48, clipId.Length)]}-plan-fx-{index.ToString(CultureInfo.InvariantCulture)}";
            var entry = saved[index];
            var part = parts.FirstOrDefault(item => item.StartWord <= entry.StartWord && entry.EndWord <= item.EndWord);
            if (part is null || entry.Operation(id, clipId, new(part.StartWord, part.EndWord), words, cutIds, tightened,
                    stickers ?? new HashSet<string>(), sources) is not { } operation) continue;
            if (part == first && entry.Kind == "motionTemplate" && AiJson.String(entry.ToJson()["template"]?["name"]) is "titleCard" or "logoSting") openingTitle = true;
            if (operation.Action is ClipAutopilotAction.Motion { Cue: var cue })
            {
                if (zoomRanges.Any(other => other.Start < cue.SourceEnd && cue.SourceStart < other.End)) continue;
                zoomRanges.Add(new(cue.SourceStart, cue.SourceEnd));
            }
            else if (operation.Action is ClipAutopilotAction.Effect { Value: var stored } &&
                stored.GetProperty("kind").GetString() is "title" or "lowerThird" or "sticker")
            {
                var overlay = ClipEffect.Parse(stored);
                if (overlayRanges.Any(other => other.Start < overlay.End && overlay.Start < other.End)) continue;
                overlayRanges.Add((overlay.Start, overlay.End));
                openingTitle |= overlay.Kind == "title" && overlay.Start < words[opening].Start + 2;
            }
            operations.Add(operation);
        }
        if (proposal.Music?.TrackId is { } trackId)
            Add("music", ClipAutopilotDecision.Music, new ClipAutopilotAction.SavedMusic(clipId, trackId));
        else if (plan.PickedMusic is { } picked)
            Add("music", ClipAutopilotDecision.Music, new ClipAutopilotAction.Music(new(clipId, picked, plan.MusicChoices.Where(item => item != picked).ToArray(), EditedSeconds(plan, state))), picked.Reason);
        if (plan.Hook.Length > 0 && !openingTitle) Add("hook", ClipAutopilotDecision.Hook, new ClipAutopilotAction.Hook(clipId, plan.Hook));
        if (plan.PostText.Length > 0) Add("post", ClipAutopilotDecision.PostText, new ClipAutopilotAction.ShareText(clipId, plan.PostText));
        return operations;
    }

    /// <summary>The clip's length once the plan's cuts and pause cuts apply, at its own speed.</summary>
    public static double EditedSeconds(ClipAutopilotPlan plan, EditState state)
    {
        var words = state.Transcript.Words;
        if (plan.StartWord < 0 || plan.EndWord >= words.Count || plan.StartWord > plan.EndWord) return 0;
        var cut = plan.Cuts.SelectMany(item => new WordSpan(item.StartWord, item.EndWord).Indices.Select(index => words[index].Id)).Concat(state.CutWordIds).ToHashSet(StringComparer.Ordinal);
        var tightened = plan.PauseCuts.Select(pause => pause.AfterWord).ToHashSet();
        return plan.Parts.Where(part => part.StartWord >= 0 && part.EndWord < words.Count && part.StartWord <= part.EndWord)
            .Sum(part => EditedSeconds(new(part.StartWord, part.EndWord), words, cut, state.Pauses, tightened, state.CutPauseIds, state.PauseKeepSeconds));
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

    /// <summary>Applies what the editor can, in order, to a copy of <paramref name="project"/>: edits, captions, zooms (motion cues
    /// wholly on kept footage and not replacing or overlapping an existing cue), share text, the
    /// look and speed, the hook as the clip's title card (timed on the clip as the operations before it left it), Ask Claude's effects,
    /// a stretch over a whole clip as its speed, translated captions, and ducking music that exists. Stretches over part of a clip,
    /// rewrites and music come back as pending: a clip plays at one speed, a rewrite needs a paid voice, and music needs a source to
    /// fetch from (the App's Music section picks it). Pure: one undo step is the caller's choice.</summary>
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
                case ClipAutopilotAction.Captions captions: result = result with { Captions = captions.Settings }; break;
                case ClipAutopilotAction.Motion motion:
                    if (AddingMotionCue(motion.Cue, result) is { } withCue) result = withCue;
                    else pending.Add(operation);
                    break;
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
                case ClipAutopilotAction.Effect effect: result = ClipEffects.Adding([effect.Value], result); break;
                case ClipAutopilotAction.Footage { Entry: var footage }:
                    var placements = result.Media.Footage ?? [];
                    if (placements.Any(item => item.Id != footage.Id && item.ClipId == footage.ClipId && item.Start < footage.End && footage.Start < item.End))
                        pending.Add(operation);
                    else result = result with { SchemaVersion = Math.Max(4, result.SchemaVersion), Media = result.Media with { Footage = [.. placements.Where(item => item.Id != footage.Id), footage] } };
                    break;
                case ClipAutopilotAction.SavedMusic saved:
                    var track = result.Music.FirstOrDefault(item => item.Id == saved.TrackId);
                    if (track is null) { pending.Add(operation); break; }
                    if (track.ClipId == saved.ClipId) break;
                    var prefix = saved.ClipId[..Math.Min(saved.ClipId.Length, 48)] + "-music";
                    var trackKey = prefix;
                    for (var suffix = 2; result.Music.Any(item => item.Id == trackKey && item.ClipId != saved.ClipId); suffix++)
                        trackKey = prefix + "-" + suffix.ToString(CultureInfo.InvariantCulture);
                    result = MusicProject.Setting(track with { Id = trackKey, ClipId = saved.ClipId }, saved.ClipId, result);
                    break;
                case ClipAutopilotAction.Stretch stretch:
                    if (ClipControlsProject.WholeClip(stretch.ClipId, stretch.Start, stretch.End, result) is { } whole) result = ClipControlsProject.SettingSpeed(stretch.Rate, whole, result);
                    else pending.Add(operation);
                    break;
                case ClipAutopilotAction.TranslateCaptions translate:
                    result = CaptionTranslations.Translating(translate.StartWord, translate.EndWord, translate.ClipId, translate.Language, translate.Text, result);
                    break;
                case ClipAutopilotAction.MusicDucking ducking:
                    if (result.Music.FirstOrDefault(entry => entry.ClipId == ducking.ClipId) is { } music) result = MusicProject.Setting(music with { Ducking = ducking.On }, ducking.ClipId, result);
                    else pending.Add(operation);
                    break;
                default: pending.Add(operation); break;
            }
        }
        return (result, pending);
    }

    /// <summary>Adds each permissible cue, leaving the project unchanged for declined cues.</summary>
    public static Project WithMotionCues(IReadOnlyList<MotionCue> cues, Project project) =>
        cues.Aggregate(project, (current, cue) => AddingMotionCue(cue, current) ?? current);

    /// <summary>Adds a cue only on one kept source interval without replacing or overlapping existing cues; null when declined.</summary>
    public static Project? AddingMotionCue(MotionCue cue, Project project)
    {
        if (project.Transcript is not { } transcript || project.Edits.Clips.FirstOrDefault(clip => clip.Id == cue.ClipID) is not { } clip ||
            project.MotionCues.Any(existing => existing.Id == cue.Id ||
                (existing.ClipID == cue.ClipID && existing.SourceStart < cue.SourceEnd && cue.SourceStart < existing.SourceEnd))) return null;
        var words = transcript.Words.ToList();
        var first = words.FindIndex(word => word.Id == clip.StartWordId);
        var last = words.FindIndex(word => word.Id == clip.EndWordId);
        if (first < 0 || last < first) return null;
        try
        {
            var bounds = EditingAlgorithms.ClipTimes(words, first, last, clip.LeadInSeconds);
            if (cue.SourceStart < bounds.Start || cue.SourceEnd > bounds.End || ClipHookTitle.Timeline(project, cue.ClipID) is not { } edits ||
                !edits.Kept.Any(interval => interval.StartSample - 0.5 <= cue.SourceStart * edits.SampleRate &&
                    cue.SourceEnd * edits.SampleRate <= interval.EndSample + 0.5)) return null;
            return ContextDemoProject.SettingMotionCues([.. project.MotionCues, cue], project);
        }
        catch (Exception exception) when (exception is VoxClipException or ContextDemoException) { return null; }
    }
}
