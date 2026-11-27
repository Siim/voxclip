#pragma warning disable CS1591
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Editing;

public static class AgentSuggestions
{
    public sealed record Chip(string Id, string Label, string Prompt, bool Enabled, string? Reason);

    public sealed record Transcription(string Label, int Percent);

    public sealed record State(Project Project, int LengthSeconds, string? Platform = null, Transcription? Transcribing = null,
        bool ExportedSinceLastChange = false, IReadOnlyList<string>? Next = null)
    {
        public string? ComposerReason => Transcribing is { } item
            ? FormattableString.Invariant($"The chat starts when {item.Label} is transcribed · {item.Percent}%.") : null;
    }

    public static IReadOnlyList<Chip> Chips(State state)
    {
        if (state.Transcribing is not null) return [];
        var turns = state.Project.AgentThread?.Turns ?? [];
        var pending = turns.Any(turn => turn.IsPending);
        if (pending && state.Next is not { Count: > 0 }) return [];
        var candidates = AvailableChips(state);
        if (turns.Count == 0) return candidates.Take(4).ToArray();

        var preferred = new List<Chip>();
        var used = new HashSet<string>(StringComparer.Ordinal);
        foreach (var suggestion in state.Next ?? [])
        {
            var text = Normalized(suggestion);
            var chip = candidates.FirstOrDefault(chip => chip.Enabled && (Normalized(chip.Label) == text || Normalized(chip.Prompt) == text));
            if (chip is null || !used.Add(chip.Id)) continue;
            preferred.Add(chip);
            if (preferred.Count == 2) return preferred;
        }
        if (pending) return preferred;
        return preferred.Concat(candidates.Where(chip => !used.Contains(chip.Id))).Take(2).ToArray();
    }

    private static IReadOnlyList<Chip> AvailableChips(State state)
    {
        var project = state.Project;
        var clip = project.Edits.Clips.FirstOrDefault(item => item.Id == project.Edits.ActiveClipId) ?? project.Edits.Clips.FirstOrDefault();
        var clock = ProjectClock.Build(project);
        IReadOnlyList<ProjectClock.Region> spoken;
        if (clock.Regions.Count == 1)
            spoken = clock.Words.Any(word => word.Kind != WordKind.Event) ? clock.Regions : [];
        else
        {
            var spokenKeys = clock.Words.Where(word => word.Kind != WordKind.Event)
                .Select(word => clock.RegionOf(word.Id)?.Key).ToHashSet(StringComparer.Ordinal);
            spoken = clock.Regions.Where(region => spokenKeys.Contains(region.Key)).ToArray();
        }
        var target = string.IsNullOrEmpty(state.Platform) ? null : state.Platform;
        var chips = new List<Chip>();
        if (spoken.Count >= 2)
        {
            var matched = TakeMatch.Build(clock);
            if (clip is null && HasOverlap(matched, clock.Regions[0].Key))
            {
                var prompt = $"Make one{(target is null ? "" : $" {target}")} clip from the best parts";
                chips.Add(MakeChip("best-parts", $"✦ {prompt}", prompt));
            }
            var best = BestFlow(matched, spoken);
            chips.Add(MakeChip("best-flow", $"Start from {best.Label}, the best flow", $"Start from {best.Label}"));
        }
        else if (spoken.Count == 1)
            chips.Add(MakeChip("best-parts", "Make one clip from the best parts",
                reason: "Needs two spoken recordings. Add a recording to compare versions."));

        var tighten = FormattableString.Invariant($"Tighten it to {state.LengthSeconds} s");
        if (clip is null)
        {
            chips.Add(MakeChip("find-three", target is null ? "Find three clips" : $"Find three clips for {target}"));
            chips.Add(MakeChip("tighten", tighten, reason: "Needs a clip. Make one first."));
            return chips;
        }

        var hasMusic = MusicProject.Entry(clip.Id, project) is not null;
        var hasCaptions = project.CaptionsFor(clip.Id).StyleId != "off";
        if (!hasMusic && !hasCaptions) chips.Add(MakeChip("add-music-captions", "Add music and captions, then export"));
        else if (!hasMusic) chips.Add(MakeChip("add-music", "Add music, then export"));
        else if (!hasCaptions) chips.Add(MakeChip("add-captions", "Add captions, then export"));

        if (ClipDuration(clip.Id, project) > state.LengthSeconds) chips.Add(MakeChip("tighten", tighten));
        if (EditingEngine.FromProject(project) is { } edit && EditingEngine.Summarize(edit with { ActiveClipId = clip.Id }).FillerCount > 3)
            chips.Add(MakeChip("cut-fillers", "Cut the fillers"));

        if (state.ExportedSinceLastChange)
        {
            chips.Add(MakeChip("find-two-more", "Find two more clips in these recordings"));
            chips.Add(MakeChip("make-teaser", "Make a 30 s teaser"));
        }
        else if (hasMusic && hasCaptions) chips.Add(MakeChip("check-export", "Check it and export"));
        return chips;
    }

    private static bool HasOverlap(TakeMatch.Result matches, string primary)
    {
        var beats = matches.Beats.Where(beat => beat.Takes.Any(take => take.Key == primary)).ToArray();
        return beats.Length > 0 && beats.Count(beat => beat.Takes.Count > 1) * 10 >= beats.Length * 3;
    }

    private static ProjectClock.Region BestFlow(TakeMatch.Result matches, IReadOnlyList<ProjectClock.Region> spoken)
    {
        var counts = matches.Beats.SelectMany(beat => beat.Takes).GroupBy(take => take.Key, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Sum(take => take.Signals.Restarts + take.Signals.Fillers), StringComparer.Ordinal);
        return spoken.OrderBy(region => (double)counts.GetValueOrDefault(region.Key) / Math.Max(1, region.DurationSamples)).First();
    }

    private static double? ClipDuration(string clipId, Project project)
    {
        try
        {
            var timeline = RenderCallerInputs.Timeline(project, clipId);
            var speed = ClipControlsProject.Controls(clipId, project)?.Speed ?? 1;
            var timing = ClipSpeedTiming.ForEffects(speed, timeline.MapTime, ClipEffects.Rendered(project, clipId), timeline.MapEndTime);
            return timing.Rendered(timeline.Duration);
        }
        catch (Exception error) when (error is VoxClipException or VoiceLabProjectException or ArgumentException) { return null; }
    }

    private static Chip MakeChip(string id, string label, string? prompt = null, string? reason = null) =>
        new(id, label, prompt ?? label, reason is null, reason);

    private static string Normalized(string text) =>
        string.Join(' ', text.Split([' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries)).ToLowerInvariant();
}
