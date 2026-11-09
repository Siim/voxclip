using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Frames;

/// <summary>The picture decisions of a clip's plan (ADR-R48, design.md §6.7.1, ai.md §19.6), twin of the Mac <c>ClipPicture</c>: the
/// opening, the face-follow crop, the blurred screens and the cover. Each is one project edit that keeps what it replaced, so it can be
/// taken back on its own. Make it postable's four review rows and the headless <c>voxclip-cli autopilot</c> both apply them through here,
/// in this order, so a project the CLI saves holds exactly what the App's rows apply.</summary>
public static class ClipPicture
{
    /// <summary>The opening row's id.</summary>
    public const string OpeningRowId = "frames-opening";
    /// <summary>The face-follow row's id.</summary>
    public const string CropRowId = "frames-face";
    /// <summary>The cover row's id.</summary>
    public const string CoverRowId = "frames-cover";
    /// <summary>A screen candidate's row id.</summary>
    public static string BlurRowId(string candidate) => "frames-blur-" + candidate;

    /// <summary>The effect id of a screen candidate's blur in a clip.</summary>
    public static string BlurEffectId(string clipId, string candidate)
    {
        var id = "fx-screen-" + candidate.ToLowerInvariant() + "-" + clipId;
        return id.Length > 64 ? id[..64] : id;
    }

    // MARK: The opening

    /// <summary>"Opens on a clear look at you": the clip's start moved back into the pause before its first word.</summary>
    /// <param name="LeadIn">The clip's lead-in now, seconds before its first word.</param>
    /// <param name="PreviousLeadIn">The lead-in it replaced (the row's Undo).</param>
    /// <param name="Earlier">How much earlier the clip starts, seconds.</param>
    /// <param name="Start">The clip's new start, source seconds (▶).</param>
    /// <param name="Chosen">The chosen frame's source second.</param>
    /// <param name="Current">The opening scan's frame at the old start.</param>
    /// <param name="Reason">Why the old first frame was not a clear look.</param>
    public sealed record Opening(double LeadIn, double? PreviousLeadIn, double Earlier, double Start, double Chosen, FrameObservation? Current, string Reason);

    /// <summary>The clip as its opening scan sees it: null when the clip is gone or its first item is cut.</summary>
    public static FrameClip? OpeningClip(Project project, string clipId)
    {
        if (project.Transcript is not { } transcript || project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId) is not { } range) return null;
        var first = IndexOf(transcript.Words, range.StartWordId);
        if (first < 0 || FrameClip.Make(transcript, range, project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal)) is not { } clip) return null;
        return clip.Kept[0] == first ? clip : null;
    }

    /// <summary>The start moves back (<see cref="OpeningFrame.Choose"/>, never across a word) when the first frame of
    /// <paramref name="scan"/> is not a clear look and one in the pause before it is. Null when the start stays: the frame is clear, no
    /// frame there is better, or the move is under a frame. Facing is judged against <paramref name="pitchBaseline"/>.</summary>
    public static (Project Project, Opening Opening)? OpeningOf(Project project, string clipId, IReadOnlyList<FrameObservation>? scan, double? pitchBaseline)
    {
        if (scan is null || OpeningClip(project, clipId) is not { } clip) return null;
        if (OpeningFrame.Choose(clip, scan, pitchBaseline) is not { Shift: < 0 } choice) return null;
        if (project.Edits.Clips.FirstOrDefault(item => item.Id == clipId) is not { } range) return null;
        var lead = Math.Min(FrameSampling.OpeningSpan, Math.Round((clip.Start - choice.Time) * 1000, MidpointRounding.AwayFromZero) / 1000);
        if (!(lead > 0)) return null;
        TimeRange before, after;
        try
        {
            before = EditingAlgorithms.ClipTimes(clip.Words, clip.First, clip.Last, range.LeadInSeconds);
            after = EditingAlgorithms.ClipTimes(clip.Words, clip.First, clip.Last, lead);
        }
        catch (ArgumentOutOfRangeException) { return null; }
        if (before.Start - after.Start < 1.0 / 30 || SettingLeadIn(lead, clipId, project) is not { } next) return null;
        FrameObservation? current = null;
        foreach (var frame in scan)
            if (current is null || Math.Abs(frame.Time - clip.Start) < Math.Abs(current.Time - clip.Start)) current = frame;
        return (next, new(lead, range.LeadInSeconds, before.Start - after.Start, after.Start, choice.Time, current, OpeningReason(current, pitchBaseline)));
    }

    /// <summary>Why the frame at the clip's start is not a clear look.</summary>
    public static string OpeningReason(FrameObservation? frame, double? pitchBaseline)
    {
        if (frame?.Face is not { } face) return "Your face wasn't in the first frame";
        if (face.Eyes == FrameEyes.Closed) return "Your eyes were shut on the first frame";
        if (face.FacesCamera(pitchBaseline) == false) return "You were looking away on the first frame";
        return "The first frame was blurred";
    }

    // MARK: The crop

    /// <summary>"9:16 follows your face": one static crop centre for 9:16 and 1:1.</summary>
    /// <param name="CenterX">The face's centre, 0–1 from the left of the source, to three decimals.</param>
    /// <param name="CenterY">The face's centre, 0–1 from the top.</param>
    /// <param name="Previous">The crop it replaced (the row's Undo).</param>
    /// <param name="Shape">The shape the row names: 9:16 when it is exported, else 1:1.</param>
    public sealed record Crop(double CenterX, double CenterY, ReframeSettings? Previous, ExportAspect Shape);

    /// <summary>The crop centred on the median measured face (<see cref="FaceFollowCrop"/>). Null without a face in
    /// <paramref name="sentences"/> or without a 9:16 or 1:1 shape among <paramref name="shapes"/>.</summary>
    public static (Project Project, Crop Crop)? CropOf(Project project, string clipId, IReadOnlyList<FrameObservation> sentences, IReadOnlyList<ExportAspect> shapes)
    {
        if (!shapes.Contains(ExportAspect.Portrait) && !shapes.Contains(ExportAspect.Square) || !sentences.Any(frame => frame.Face is not null)) return null;
        if (FaceFollowCrop.Plan(sentences.Select(frame => new FaceFollowSample(frame.Time, frame.Face?.Rect)), SourceAspect(project.Media.Source.Video), 9.0 / 16.0) is not { } plan)
            return null;
        if (ClipControlsProject.Controls(clipId, project) is not { } controls) return null;
        var x = Math.Round(plan.CenterX * 1000, MidpointRounding.AwayFromZero) / 1000;
        var y = Math.Round(plan.CenterY * 1000, MidpointRounding.AwayFromZero) / 1000;
        if (SettingControls(clipId, project, current => current with { Reframe = new(ReframeSettings.FaceMode, 1, x, y) }) is not { } next) return null;
        return (next, new(x, y, controls.Reframe, shapes.Contains(ExportAspect.Portrait) ? ExportAspect.Portrait : ExportAspect.Square));
    }

    // MARK: The screens

    /// <summary>One detected screen: blurred, or left sharp.</summary>
    /// <param name="Candidate">The screen as the request listed it.</param>
    /// <param name="EffectId">Its blur effect's id.</param>
    /// <param name="Blurred">The screen is blurred in the project now.</param>
    /// <param name="Applied">This apply added the blur (the row's Undo removes it).</param>
    /// <param name="Decision">What the reply decided for it; null when it named nothing for this screen.</param>
    public sealed record Blur(ClipAutopilotFrames.BlurCandidate Candidate, string EffectId, bool Blurred, bool Applied, ClipAutopilotPlan.FrameChoices.Blur? Decision)
    {
        /// <summary>Claude's reason, null when empty.</summary>
        public string? Reason => Decision is { Reason.Length: > 0 } decision ? decision.Reason : null;
    }

    /// <summary>The existing blur effect over a screen candidate, held still over its span and box (<c>tracking</c> none).</summary>
    public static JsonElement BlurEffect(ClipAutopilotFrames.BlurCandidate candidate, string clipId)
    {
        var node = new JsonObject
        {
            ["id"] = BlurEffectId(clipId, candidate.Id), ["clipId"] = clipId, ["kind"] = "blur",
            ["start"] = candidate.Start, ["end"] = Math.Min(candidate.End, candidate.Start + MaximumEffectSeconds),
            ["rect"] = new JsonObject { ["x"] = candidate.Rect.X, ["y"] = candidate.Rect.Y, ["width"] = candidate.Rect.Width, ["height"] = candidate.Rect.Height },
            ["tracking"] = "none", ["track"] = new JsonArray()
        };
        using var document = JsonDocument.Parse(node.ToJsonString());
        return document.RootElement.Clone();
    }

    /// <summary>An effect lasts at most this long (Mac <c>ClipEffect.maximumSeconds</c>).</summary>
    public const double MaximumEffectSeconds = 600;

    /// <summary>Every screen of <paramref name="frames"/>. With <paramref name="applying"/>, a screen the reply chose to blur is blurred,
    /// but only when the frames went as images: an AI that got text only could not see it.</summary>
    public static (Project Project, IReadOnlyList<Blur> Blurs) Blurs(Project project, string clipId, ClipAutopilotFrames frames, ClipAutopilotPlan? plan, bool applying)
    {
        var result = new List<Blur>();
        foreach (var candidate in frames.Blur)
        {
            var decision = plan?.Frames?.BlurChoices.FirstOrDefault(choice => choice.Id == candidate.Id);
            var id = BlurEffectId(clipId, candidate.Id);
            var applied = false;
            if (applying && frames.SendsImages && decision?.Blurred == true && !HasEffect(project, id))
            {
                try
                {
                    project = ClipEffects.Adding([BlurEffect(candidate, clipId)], project);
                    applied = true;
                }
                catch (Exception exception) when (Refused(exception)) { }
            }
            result.Add(new(candidate, id, HasEffect(project, id), applied, decision));
        }
        return (project, result);
    }

    /// <summary>The project has an effect with this id.</summary>
    public static bool HasEffect(Project project, string id) => project.ClipEffects.Any(effect => effect.GetProperty("id").GetString() == id);

    /// <summary>The project without the effect <paramref name="id"/>; null when it can't be removed.</summary>
    public static Project? RemovingEffect(string id, Project project)
    {
        var kept = project.ClipEffects.Where(effect => effect.GetProperty("id").GetString() != id).ToArray();
        if (kept.Length == project.ClipEffects.Count) return project;
        try
        {
            var next = project with { ClipEffects = kept };
            ClipEffects.Validate(next);
            return next;
        }
        catch (Exception exception) when (Refused(exception)) { return null; }
    }

    /// <summary>"phone screen" for a framed screen taller than wide, "screen" for a wider one.</summary>
    public static string ScreenName(ClipEffectRect rect, VideoTrackInfo? video) => rect.Width * SourceAspect(video) < rect.Height ? "phone screen" : "screen";

    // MARK: The cover

    /// <summary>"Cover frame chosen".</summary>
    /// <param name="Candidate">The cover taken.</param>
    /// <param name="Named">The reply named this candidate; false when the local best was taken.</param>
    /// <param name="Reason">Claude's reason; null when it named none or fell back.</param>
    /// <param name="Previous">The cover it replaced (the row's Undo).</param>
    public sealed record Cover(ClipAutopilotFrames.CoverCandidate Candidate, bool Named, string? Reason, double? Previous);

    /// <summary>The reply's pick among the cover candidates, or the best measured one when it named none. Null without candidates.</summary>
    public static (Project Project, Cover Cover)? CoverOf(Project project, string clipId, ClipAutopilotFrames frames, ClipAutopilotPlan plan)
    {
        var named = plan.Frames?.CoverChoice is { } choice ? frames.CoverCandidateFor(choice.Id) : null;
        if ((named ?? frames.Cover.FirstOrDefault()) is not { } candidate || ClipControlsProject.Controls(clipId, project) is not { } controls) return null;
        if (SettingControls(clipId, project, current => current with { CoverSeconds = candidate.Time }) is not { } next) return null;
        var reason = named is null ? null : plan.Frames?.CoverChoice is { Fallback: false, Reason.Length: > 0 } picked ? picked.Reason : null;
        return (next, new(candidate, named is not null, reason, controls.CoverSeconds));
    }

    // MARK: All four

    /// <summary>What a clip's plan request carried of the picture, for the apply.</summary>
    /// <param name="Frames">The frames as sent: with images, or the text summary only.</param>
    /// <param name="Sentences">The clip's sentence frames (the faces the crop follows).</param>
    /// <param name="OpeningScan">The opening scan of the clip as the plan leaves it (<see cref="OpeningClip"/>); null when it could not be read.</param>
    /// <param name="Shapes">The shapes the clip exports in.</param>
    /// <param name="PitchBaseline">The recording's typical pitch the opening judges facing by.</param>
    public sealed record Inputs(ClipAutopilotFrames Frames, IReadOnlyList<FrameObservation> Sentences, IReadOnlyList<FrameObservation>? OpeningScan,
        IReadOnlyList<ExportAspect> Shapes, double? PitchBaseline);

    /// <summary>The four decisions as applied.</summary>
    public sealed record Decisions(Opening? Opening, Crop? Crop, IReadOnlyList<Blur> Blurs, Cover? Cover);

    /// <summary>The opening, the crop, the screens and the cover applied in turn, each on the project the one before left.</summary>
    public static (Project Project, Decisions Decisions) Apply(ClipAutopilotPlan plan, string clipId, Project project, Inputs inputs)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(inputs);
        var next = project;
        var opening = OpeningOf(next, clipId, inputs.OpeningScan, inputs.PitchBaseline);
        if (opening is { } moved) next = moved.Project;
        var crop = CropOf(next, clipId, inputs.Sentences, inputs.Shapes);
        if (crop is { } cropped) next = cropped.Project;
        var screens = Blurs(next, clipId, inputs.Frames, plan, applying: true);
        next = screens.Project;
        var cover = CoverOf(next, clipId, inputs.Frames, plan);
        if (cover is { } covered) next = covered.Project;
        return (next, new(opening?.Opening, crop?.Crop, screens.Blurs, cover?.Cover));
    }

    // MARK: Project edits

    /// <summary><paramref name="project"/> with the clip's opening lead-in set (null removes it); a lead-in promotes the project to v4.
    /// Null when the clip is gone or the lead-in is refused.</summary>
    public static Project? SettingLeadIn(double? lead, string clipId, Project project)
    {
        var index = project.Edits.Clips.ToList().FindIndex(clip => clip.Id == clipId);
        // The wire allows a lead-in above 0 and at most the opening span (ADR-R48 part 2).
        if (index < 0 || lead is { } value && !(value > 0 && value <= FrameSampling.OpeningSpan)) return null;
        try
        {
            var next = lead is null || project.SchemaVersion >= 4 ? project : ContextDemoProject.UpgradeToV4(project);
            if (lead is not null && next.SchemaVersion < 4) return null;
            var clips = next.Edits.Clips.ToArray();
            clips[index] = clips[index] with { LeadInSeconds = lead };
            next = next with { Edits = next.Edits with { Clips = clips } };
            ProjectSerialization.Validate(next);
            return next;
        }
        catch (Exception exception) when (Refused(exception)) { return null; }
    }

    /// <summary><paramref name="project"/> with one clip's controls changed by <paramref name="change"/>, the others kept; null when the
    /// change is refused.</summary>
    public static Project? SettingControls(string clipId, Project project, Func<ProjectClipControls, ProjectClipControls> change)
    {
        ArgumentNullException.ThrowIfNull(change);
        if (ClipControlsProject.Controls(clipId, project) is not { } controls) return null;
        try { return ClipControlsProject.Setting(change(controls), project); }
        catch (Exception exception) when (Refused(exception)) { return null; }
    }

    /// <summary>The source picture's display width over height (after its rotation); 16:9 without video facts.</summary>
    public static double SourceAspect(VideoTrackInfo? video)
    {
        if (video is null || video.Width <= 0 || video.Height <= 0) return 16.0 / 9.0;
        double width = video.Width, height = video.Height;
        return video.RotationDegrees % 180 == 0 ? width / height : height / width;
    }

    private static bool Refused(Exception exception) =>
        exception is VoxClipException or ContextDemoException or VoiceLabException or VoiceLabProjectException or InvalidOperationException;

    private static int IndexOf(IReadOnlyList<TimedWord> words, string id)
    {
        for (var index = 0; index < words.Count; index++) if (words[index].Id == id) return index;
        return -1;
    }

    /// <summary>"0.5" as the Mac's <c>String(format: "%.1f")</c> writes a positive shift.</summary>
    public static string OneDecimal(double value) => FrameSheetFrame.Fixed(value, 1);
}
