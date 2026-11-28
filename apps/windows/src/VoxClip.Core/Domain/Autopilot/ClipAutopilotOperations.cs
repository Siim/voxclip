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
using VoxClip.Core.Services.Project;

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
    Bleep, Blur, Overlay, Freeze, Sound, Stretch, Translate, Duck, CoverTitle, Timeline
#pragma warning restore CS1591
}

/// <summary>How an operation acts on the project.</summary>
public abstract record ClipAutopilotAction
{
    /// <summary>An editor operation applied as it is: corrections, cuts, pause cuts, the clip and its title.</summary>
    public sealed record Edit(EditOperation Operation) : ClipAutopilotAction;
    /// <summary>Existing timeline placements to edit together.</summary>
    public sealed record Timeline(string? ClipId, IReadOnlyList<TimelineEditRequest> Edits) : ClipAutopilotAction;
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
    /// <summary>Reuse a track already saved in the project.</summary>
    public sealed record SavedMusic(string ClipId, string TrackId) : ClipAutopilotAction
    {
        /// <summary>Optional timeline shaping when placing the track.</summary>
        public ClipPlanMusicShape? Shape { get; init; }
    }
    /// <summary>Set the title over the clip's cover.</summary>
    public sealed record CoverTitle(string ClipId, string Text) : ClipAutopilotAction;
    /// <summary>Place a companion recording already in the project.</summary>
    public sealed record Footage(ProjectFootage Entry) : ClipAutopilotAction;
    /// <summary>The first 2 seconds' text, applied as the clip's title card.</summary>
    public sealed record Hook(string ClipId, string Text) : ClipAutopilotAction;
    /// <summary>The clip's share text.</summary>
    public sealed record ShareText(string ClipId, string Text) : ClipAutopilotAction;
    /// <summary>An Ask Claude effect (ai.md §18.2), the stored <c>clipEffects</c> entry, already valid.</summary>
    public sealed record Effect(JsonElement Value) : ClipAutopilotAction;
    /// <summary>A timed request for a library sound or generated illustration.</summary>
    public sealed record Asset(string Id, string Kind, string ClipId, double Start, double End, string Text) : ClipAutopilotAction
    {
        /// <summary>Fades and volume points to place with the asset.</summary>
        public ItemShape Shape { get; init; } = new();
        /// <summary>Optional sound level in dB.</summary>
        public double? GainDb { get; init; }
        /// <summary>Optional start within the downloaded sound.</summary>
        public double? SoundFrom { get; init; }
    }
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
        IReadOnlyDictionary<ClipAutopilotFont, string> fonts, IReadOnlySet<string>? stickers = null) =>
        Operations(ClipProposal.FromPlan(plan, clipId, project), clipId, project, fonts, stickers, plan);

    /// <summary>Map canonical proposal intent without saving, contacting providers, or spending.</summary>
    public static IReadOnlyList<ClipAutopilotOperation> Operations(ClipProposal proposal, string clipId, Project project,
        IReadOnlyDictionary<ClipAutopilotFont, string> fonts, IReadOnlySet<string>? stickers = null) =>
        Operations(proposal, clipId, project, fonts, stickers, null);

    private static IReadOnlyList<ClipAutopilotOperation> Operations(ClipProposal proposal, string clipId, Project project,
        IReadOnlyDictionary<ClipAutopilotFont, string> fonts, IReadOnlySet<string>? stickers, ClipAutopilotPlan? plan)
    {
        if (EditingEngine.FromProject(project) is not { } state) throw ClipAutopilotRequestBuilder.Invalid();
        var words = state.Transcript.Words;
        var existing = state.Clips.FirstOrDefault(clip => clip.Id == clipId);
        if (!ClipIdPattern().IsMatch(clipId) || (existing is null
            ? proposal.Target.ClipId is not null || proposal.Target.New is null
            : proposal.Target.ClipId != clipId || proposal.Target.New is not null)) throw ClipAutopilotRequestBuilder.Invalid();
        var previous = existing?.PlayParts ?? [];
        var previousRanges = plan?.OrderedParts is null ? null : existing?.PlayPartIndices(words);
        var parts = proposal.Parts?.Select((range, index) =>
        {
            if (range.StartWord < 0 || range.EndWord >= words.Count || range.StartWord > range.EndWord) throw ClipAutopilotRequestBuilder.Invalid();
            var start = words[range.StartWord].Id;
            var end = words[range.EndWord].Id;
            if (previousRanges is not null)
                for (var partIndex = 0; partIndex < previousRanges.Count; partIndex++)
                    if (previousRanges[partIndex] is var bound && bound.Start <= range.StartWord && range.EndWord <= bound.End)
                        return previous[partIndex] with { StartWordId = start, EndWordId = end, TakeReason = plan is null ? previous[partIndex].TakeReason : range.TakeReason };
            var id = "proposal-part-" + (index + 1).ToString(CultureInfo.InvariantCulture);
            while (previous.Any(part => part.Id == id)) id += "-new";
            var exact = previous.FirstOrDefault(part => part.StartWordId == start && part.EndWordId == end);
            return exact is not null ? exact with { TakeReason = plan is null ? exact.TakeReason : range.TakeReason } : new ClipPart(id, start, end, TakeReason: plan is null ? null : range.TakeReason);
        }).ToArray() ?? previous;
        if (parts.Count is < 1 or > 12 || StoryClips.Indices(parts.Select(part => (part.StartWordId, part.EndWordId)), words) is not { } ranges ||
            proposal.Target.New is { } create && (create.Kind == "stretch") != (parts.Count == 1))
            throw new HarnessException("Choose nonoverlapping parts in play order.");
        var spans = ranges.Select(range => new WordSpan(range.Start, range.End)).ToArray();
        var startWord = spans.Min(span => span.Start);
        var endWord = spans.Max(span => span.End);
        WordSpan? Scope(int start, int end) => start <= end
            ? spans.Where(span => span.Contains(start) && span.Contains(end)).Select(span => (WordSpan?)span).FirstOrDefault() : null;
        var strictScope = plan is null || parts.Count > 1;
        var operations = new List<ClipAutopilotOperation>();
        void Add(string id, ClipAutopilotDecision decision, ClipAutopilotAction action, string reason = "") => operations.Add(new(id, decision, action, reason));
        var title = string.IsNullOrEmpty(proposal.Title) ? null : proposal.Title;
        if (existing is not null)
        {
            if (!parts.SequenceEqual(previous))
            {
                EditOperation command = parts.Count == 1 && existing.Parts is null
                    ? new EditOperation.UpdateClip(clipId, startWord, endWord) : new EditOperation.SetClipParts(clipId, parts);
                if (command is EditOperation.SetClipParts)
                {
                    var candidate = EditingEngine.Reduce(state, command, project).Clips.First(clip => clip.Id == clipId);
                    if (!candidate.PlayParts.Select(part => (part.StartWordId, part.EndWordId)).SequenceEqual(parts.Select(part => (part.StartWordId, part.EndWordId))))
                        throw new HarnessException("These parts would replace protected work. Propose a new clip instead.");
                }
                Add("clip", ClipAutopilotDecision.Clip, new ClipAutopilotAction.Edit(command), proposal.Reason);
            }
            if (title is not null && title != existing.Title) Add("title", ClipAutopilotDecision.Title, new ClipAutopilotAction.Edit(new EditOperation.RenameClip(clipId, title)));
        }
        else
        {
            Add("clip", ClipAutopilotDecision.Clip, new ClipAutopilotAction.Edit(new EditOperation.AddClip(
                new ClipRange(clipId, words[startWord].Id, words[endWord].Id,
                    title ?? (proposal.Target.New?.Title is { Length: > 0 } name ? name : null), ClipOrigin.Ai, null, null, true,
                    Parts: parts.Count > 1 ? parts : null,
                    Kind: parts.Count > 1 ? proposal.Target.New?.Kind == "showreel" ? StoryClipKind.Showreel : StoryClipKind.Story : null))), proposal.Reason);
        }
        var correctionsToApply = proposal.Corrections ?? [];
        for (var index = 0; index < correctionsToApply.Count; index++)
        {
            var correction = correctionsToApply[index];
            if (correction.Word < 0 || correction.Word >= words.Count || strictScope && Scope(correction.Word, correction.Word) is null)
                throw new HarnessException("A correction is outside the clip.");
            if (words[correction.Word].Kind != WordKind.Word)
            {
                if (plan is not null) continue;
                throw new HarnessException("A correction is outside the clip or does not name a spoken word.");
            }
            Add("correction-" + index, ClipAutopilotDecision.Correction, new ClipAutopilotAction.Edit(new EditOperation.Correct(words[correction.Word].Id, correction.Text)), correction.Reason);
        }
        var cuts = proposal.Cuts ?? [];
        var cutIds = state.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var requestedCuts = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < cuts.Count; index++)
        {
            var cut = cuts[index];
            if (cut.StartWord < 0 || cut.EndWord >= words.Count || cut.StartWord > cut.EndWord || strictScope && Scope(cut.StartWord, cut.EndWord) is null)
                throw new HarnessException("A cut is outside a clip part.");
            var spoken = new WordSpan(cut.StartWord, cut.EndWord).Indices.Select(position => words[position]).Where(word => plan is not null || word.Kind == WordKind.Word).Select(word => word.Id).ToArray();
            if (plan is null && (spoken.Length == 0 || requestedCuts.Overlaps(spoken))) throw new HarnessException("Cuts must name distinct spoken words.");
            requestedCuts.UnionWith(spoken);
            var ids = spoken.Where(cutIds.Add).ToArray();
            if (ids.Length > 0) Add("cut-" + index, ClipAutopilotDecision.Cut, new ClipAutopilotAction.Edit(new EditOperation.SetWordCuts(ids, true)), cut.Reason);
        }
        if (plan is null && !spans.SelectMany(span => span.Indices).Any(index => words[index].Kind == WordKind.Word && !cutIds.Contains(words[index].Id)))
            throw new HarnessException("Keep at least one spoken word in the clip.");
        var tightened = state.Pauses.Where(pause => state.CutPauseIds.Contains(pause.Id)).Select(pause => pause.AfterIndex).ToHashSet();
        var pauses = proposal.PauseCuts ?? [];
        for (var index = 0; index < pauses.Count; index++)
        {
            var pause = pauses[index];
            if (strictScope && (Scope(pause.AfterWord, pause.AfterWord) is not { } part || pause.AfterWord >= part.End) ||
                state.Pauses.FirstOrDefault(item => item.AfterIndex == pause.AfterWord) is not { } found)
            {
                if (plan is null) throw new HarnessException("Choose a detected pause inside a clip part.");
                continue;
            }
            if (!tightened.Add(pause.AfterWord)) continue;
            Add("pause-" + index, ClipAutopilotDecision.PauseCut, new ClipAutopilotAction.Edit(new EditOperation.SetPauseCuts([found.Id], true)), pause.Reason);
        }
        var rewrites = proposal.Rewrites ?? [];
        for (var index = 0; index < rewrites.Count; index++)
        {
            var rewrite = rewrites[index];
            if (rewrite.StartWord < 0 || rewrite.EndWord >= words.Count || rewrite.StartWord > rewrite.EndWord ||
                strictScope && Scope(rewrite.StartWord, rewrite.EndWord) is null) throw new HarnessException("A rewrite crosses a clip part.");
            Add("rewrite-" + index, ClipAutopilotDecision.Rewrite, new ClipAutopilotAction.Rewrite(new(rewrite.StartWord, rewrite.EndWord), rewrite.Text), rewrite.Reason);
        }
        if (proposal.CaptionStyle is not null || proposal.Font is not null || proposal.TextCase is not null || proposal.WordsPerCaption is not null)
        {
        var current = plan is null ? ClipCaptionStyles.Settings(project, clipId) : project.Captions;
        var overrides = current.Overrides.ValueKind == JsonValueKind.Object
            ? JsonNode.Parse(current.Overrides.GetRawText())!.AsObject() : new JsonObject();
        void Merge(string key, JsonObject values)
        {
            var target = overrides[key] as JsonObject ?? new JsonObject();
            foreach (var (name, value) in values.ToArray()) target[name] = value?.DeepClone();
            overrides[key] = target;
        }
        if (proposal.TextCase is { } textCase) Merge("text", new JsonObject { ["transform"] = textCase.Transform() });
        if (proposal.WordsPerCaption is { } count)
            Merge("layout", count == 1 ? new JsonObject { ["maxWords"] = 1, ["maxLines"] = 1 } : new JsonObject { ["maxWords"] = count });
        var file = proposal.Font is { } wanted && fonts.TryGetValue(wanted, out var bundled) ? bundled : null;
        if (file is not null && proposal.Font is { } font) Merge("font", new JsonObject { ["file"] = file, ["family"] = font.Family, ["weight"] = font.Weight });
        using var document = JsonDocument.Parse(overrides.ToJsonString());
        var settings = current with { StyleId = proposal.CaptionStyle ?? current.StyleId, Overrides = document.RootElement.Clone() };
        Add("captions", ClipAutopilotDecision.Captions, new ClipAutopilotAction.Captions(settings, file is null ? proposal.Font : null), plan?.CaptionChoice.Reason ?? "");
        }
        if (proposal.Look is { } look) Add("look", ClipAutopilotDecision.Look, new ClipAutopilotAction.Look(clipId, look), look.Reason);
        if (proposal.Speed is { } speed) Add("speed", ClipAutopilotDecision.Speed, new ClipAutopilotAction.Speed(clipId, speed), speed.Reason);
        var zoomRanges = new List<TimeRange>();
        var corrections = new Dictionary<string, string>(state.Corrections, StringComparer.Ordinal);
        foreach (var correction in correctionsToApply) corrections[words[correction.Word].Id] = correction.Text;
        var zooms = plan?.Zooms ?? [];
        for (var index = 0; index < zooms.Count; index++)
        {
            var zoom = zooms[index];
            if (Scope(zoom.Word, zoom.UntilWord) is not { } part || zoom.SourceRange(words, part) is not { } range || zoom.Scale is not (>= 1 and <= MaximumZoomScale) ||
                zoomRanges.Any(other => other.Start < range.End && range.Start < other.End)) continue;
            var key = "zoom-" + index.ToString(CultureInfo.InvariantCulture);
            var cueId = clipId + "-" + key;
            var reason = zoom.Reason;
            if (zoom.Direction is not null)
            {
                var phraseSpan = new WordSpan(zoom.Word, zoom.UntilWord);
                if (!zoom.HasDirectionalSettings || phraseSpan.Indices.Any(position => state.CutWordIds.Contains(words[position].Id)) ||
                    cuts.Any(cut => phraseSpan.Overlaps(new(cut.StartWord, cut.EndWord))) ||
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
        var overlayRanges = new List<(double Start, double End)>();
        var opening = spans[0].Indices.FirstOrDefault(index => !cutIds.Contains(words[index].Id), spans[0].Start);
        var openingTitle = false;
        var saved = proposal.Effects ?? [];
        var sources = (project.Media.AdditionalSources ?? []).Where(source => source.Video is not null)
            .ToDictionary(source => source.FootageKey, source => source.DurationSeconds, StringComparer.Ordinal);
        for (var index = 0; index < Math.Min(saved.Count, ClipPlanEffect.MaximumEntries); index++)
        {
            var id = $"{clipId[..Math.Min(48, clipId.Length)]}-plan-fx-{index.ToString(CultureInfo.InvariantCulture)}";
            if (Scope(saved[index].StartWord, saved[index].EndWord) is not { } part ||
                saved[index].Operation(id, clipId, part, words, cutIds, tightened, stickers ?? new HashSet<string>(), sources) is not { } operation)
            {
                if (plan is null) throw new HarnessException($"Effect {index + 1} doesn’t fit those kept words or its selected footage.");
                continue;
            }
            if (operation.Action is ClipAutopilotAction.Motion { Cue: var cue })
            {
                if (zoomRanges.Any(other => other.Start < cue.SourceEnd && cue.SourceStart < other.End))
                {
                    if (plan is null) throw new HarnessException("The proposed zooms overlap.");
                    continue;
                }
                zoomRanges.Add(new(cue.SourceStart, cue.SourceEnd));
            }
            else if (operation.Action is ClipAutopilotAction.Effect { Value: var entry } &&
                     entry.GetProperty("kind").GetString() is "title" or "lowerThird" or "sticker")
            {
                var overlay = ClipEffect.Parse(entry);
                if (overlayRanges.Any(other => other.Start < overlay.End && overlay.Start < other.End))
                {
                    if (plan is null) throw new HarnessException("The proposed overlays overlap.");
                    continue;
                }
                overlayRanges.Add((overlay.Start, overlay.End));
                openingTitle |= part == spans[0] && overlay.Kind == "title" && overlay.Start < words[opening].Start + 2;
            }
            operations.Add(operation);
        }
        if (proposal.Music?.TrackId is { } trackId) Add("music", ClipAutopilotDecision.Music,
            new ClipAutopilotAction.SavedMusic(clipId, trackId) { Shape = proposal.Music.Shape });
        else if (proposal.Music?.Brief is { } brief)
        {
            var picked = plan?.PickedMusic ?? new("Proposed music", "", brief, proposal.Reason, 18);
            if (proposal.Music.Shape is { } shape) picked = picked with { TimelineShape = shape };
            var length = spans.Sum(part => EditedSeconds(part, words, cutIds, state.Pauses, tightened, state.CutPauseIds, state.PauseKeepSeconds));
            Add("music", ClipAutopilotDecision.Music, new ClipAutopilotAction.Music(new(clipId, picked, (plan?.MusicChoices ?? []).Where(item => item != picked).ToArray(), length)), picked.Reason);
        }
        if (proposal.Hook is { Length: > 0 } hook && !openingTitle && plan?.Kind != "showreel") Add("hook", ClipAutopilotDecision.Hook, new ClipAutopilotAction.Hook(clipId, hook));
        if (proposal.PostText is { Length: > 0 } post) Add("post", ClipAutopilotDecision.PostText, new ClipAutopilotAction.ShareText(clipId, post));
        if (plan is null && proposal.CoverTitle is { } cover) Add("cover", ClipAutopilotDecision.CoverTitle, new ClipAutopilotAction.CoverTitle(clipId, cover));
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
    public static (Project Project, IReadOnlyList<ClipAutopilotOperation> Pending) Apply(IReadOnlyList<ClipAutopilotOperation> operations, Project project,
        (string Id, ClipStyle Style)? clipCaptions = null)
    {
        var result = project;
        var pending = new List<ClipAutopilotOperation>();
        foreach (var operation in operations)
        {
            switch (operation.Action)
            {
                case ClipAutopilotAction.Edit edit:
                    var state = EditingEngine.FromProject(result) ?? throw ClipAutopilotRequestBuilder.Invalid();
                    result = EditingEngine.ApplyToProject(result, EditingEngine.Reduce(state, edit.Operation, result));
                    break;
                case ClipAutopilotAction.Captions captions:
                    if (clipCaptions is { } target)
                        result = ClipCaptionStyles.Restoring(result with { ClipStyle = result.ClipStyle ?? target.Style }, target.Id,
                            new(captions.Settings.StyleId, "") { By = "user", Overrides = captions.Settings.Overrides });
                    else result = result with { Captions = captions.Settings };
                    break;
                case ClipAutopilotAction.SavedMusic saved:
                    var track = result.Music.FirstOrDefault(entry => entry.Id == saved.TrackId)
                        ?? throw new HarnessException("Choose a saved music track from this project.");
                    var taken = result.Music.Where(entry => entry.ClipId != saved.ClipId).Select(entry => entry.Id).ToHashSet(StringComparer.Ordinal);
                    var id = track.Id;
                    for (var suffix = 2; taken.Contains(id); suffix++) id = string.Create(CultureInfo.InvariantCulture, $"{track.Id}-{suffix}");
                    track = track with { Id = id, ClipId = saved.ClipId };
                    result = MusicProject.Setting(saved.Shape?.Place(track, result, saved.ClipId) ?? track, saved.ClipId, result);
                    break;
                case ClipAutopilotAction.CoverTitle cover:
                    var firstId = result.Edits.Clips.FirstOrDefault(clip => clip.Id == cover.ClipId)?.PlayParts[0].StartWordId;
                    if (result.Transcript?.Words.FirstOrDefault(word => word.Id == firstId) is not { } first ||
                        ClipControlsProject.Controls(cover.ClipId, result) is not { } controls || ClipHookTitle.Text(cover.Text) != cover.Text)
                        throw new HarnessException("Choose a short, single-line cover title.");
                    result = ClipControlsProject.Setting(controls with { CoverTitle = cover.Text, CoverSeconds = controls.CoverSeconds ?? first.Start }, result);
                    break;
                case ClipAutopilotAction.Footage footage:
                    var placements = result.Media.Footage ?? [];
                    if (placements.Any(existing => existing.Id == footage.Entry.Id ||
                        (existing.ClipId == footage.Entry.ClipId && existing.Start < footage.Entry.End && footage.Entry.Start < existing.End))) pending.Add(operation);
                    else result = TimelineEditFields.Promoting(result with { SchemaVersion = Math.Max(4, result.SchemaVersion),
                        Media = result.Media with { Footage = [.. placements, footage.Entry] } });
                    break;
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
