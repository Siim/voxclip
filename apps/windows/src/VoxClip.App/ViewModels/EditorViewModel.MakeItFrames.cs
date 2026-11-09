using System.Globalization;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Frames;

namespace VoxClip.App.ViewModels;

// "Claude sees the picture" in Make it postable (ADR-R48, design.md §6.7.1, ai.md §19.6), twin of the Mac MakeItFrames.swift. The whole
// video's sentence frames are looked at on this PC (the bundled face models, Windows OCR for text) as soon as Find Clips starts, beside
// it. Each clip's plan request takes its frames from that pass just before it is sent: the sheet's summary always, and the 320 px frames
// when the AI takes images on a plan or locally; its opening scan runs beside the request. The review then shows four applied decisions,
// each with ▶ and Undo: the opening, the face-follow crop, blurred screens and the cover. Without the face models (no face source) none
// of this exists: no pass, no rows, no send line, and plans go as text only.

/// <summary>✦ Make it postable's picture (ADR-R48), twin of the Mac <c>EditorModel</c> MakeItFrames extension.</summary>
public sealed partial class EditorViewModel
{
    private VideoFramePass? framePass;
    private string? framePassKey;

    /// <summary>The whole video's frame pass now; null before one started or without faces.</summary>
    public VideoFramePass? FramePass => framePass;

    // MARK: The pass

    /// <summary>Starts the whole video's frame pass for this transcript (again for a new one); the pass is cached on disk, so a reopened
    /// video costs little. Find Clips is never waited for or delayed by it. Null without faces, or for a project it can't look at.</summary>
    public VideoFramePass? StartFramePass()
    {
        if (MakeIt.Services?.FramePass is not { } factory || isLeaving || project.Transcript is not { } transcript) return null;
        var key = project.Media.Source.ContentKey + ":" + transcript.RawKey + ":" + transcript.Words.Count.ToString(CultureInfo.InvariantCulture);
        if (framePassKey == key && framePass is { } running) return running;
        framePass?.Cancel();
        var pass = factory(project);
        framePass = pass;
        framePassKey = pass is null ? null : key;
        pass?.Start(ClaudeMode.Clock);
        return pass;
    }

    /// <summary>Stops the pass and its opening scans (the editor is leaving).</summary>
    public void CancelFramePass()
    {
        framePass?.Cancel();
        framePass = null;
        framePassKey = null;
    }

    // MARK: The request

    /// <summary>The frames of a plan for the runs of <paramref name="clipIds"/> (in span order), once the planner names the AI; null
    /// without faces, so the request goes exactly as it did before the picture.</summary>
    internal MakeItFrameSources? MakeItFrameSource(IReadOnlyList<string> clipIds)
    {
        if (MakeIt.Services is not { FramePass: not null } || project.Transcript is not { } transcript || state is null) return null;
        if (StartFramePass() is not { } pass) return null;
        // The planner asks from its own lanes: everything it reads is taken now, on the editor's thread.
        var words = transcript.Words;
        var cuts = state.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var runs = clipIds.Select(MakeIt.Run).ToArray();
        return ai => async (index, span, ct) =>
        {
            if (index < 0 || index >= runs.Length || runs[index] is not { } run) return null;
            if (FrameClip.Make(words, span.Start, span.End, cuts) is not { } clip) return null;
            if (await pass.FramesAsync(clip, ct).ConfigureAwait(false) is not { } found) return null;
            // The opening scan runs beside the plan request; the apply waits for it.
            pass.StartOpening(clip);
            var frames = ClipAutopilotFrames.FromSheet(found.Sheet, clip.Start, clip.End, ai.SendsImages, await pass.PitchBaselineAsync(ct).ConfigureAwait(false));
            run.Frames = new(ai, frames, found.Sentences);
            return frames;
        };
    }

    // MARK: The send line

    /// <summary>"Claude read the clip's words and 24 small frames (one per sentence, 320 px) on your Claude plan. Faces were measured on
    /// this PC." The bold part is <c>Emphasis</c>. Null when the request carried no frames.</summary>
    public (string Lead, string Emphasis, string Tail)? MakeItSendLine(MakeItRun run)
    {
        if (run.Frames is not { } record || record.Sent.Frames.Count == 0) return null;
        var count = record.Sent.Frames.Count;
        const string faces = " Faces were measured on this PC.";
        var lead = record.Ai.Name + " read the clip's words and ";
        if (!record.Sent.SendsImages) return (lead, $"a text summary of {count} {(count == 1 ? "frame" : "frames")}", "." + faces);
        var billing = record.Ai.Billing switch
        {
            MakeItFrameBilling.Plan plan => $" on your {plan.Name} plan",
            MakeItFrameBilling.Key => " billed to your key",
            _ => ""
        };
        return (lead, $"{count} small {(count == 1 ? "frame" : "frames")}", $" (one per sentence, {FrameSheet.FrameEdge} px){billing}." + faces);
    }

    /// <summary>m:ss of a source second on the clip as it renders: its place in the clip's edit, at the clip's speed.</summary>
    public string MakeItClipTime(double source, string clipId)
    {
        if (state is null || !state.Clips.Any(clip => clip.Id == clipId)) return Clock(source);
        try
        {
            var media = project.Media.Source;
            var rate = media.Audio?.SampleRate is > 0 ? media.Audio.SampleRate : 48000;
            var scoped = state with { ActiveClipId = clipId };
            var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(scoped, media.DurationSeconds), media.DurationSeconds, rate, scoped.PauseKeepSeconds);
            var speed = ClipControlsProject.Controls(clipId, project)?.Speed ?? 1;
            return Clock(plan.MapTime(source) / (speed > 0 ? speed : 1));
        }
        catch (VoxClipException) { return Clock(source); }
    }

    // MARK: The rows

    /// <summary>The four picture decisions, applied in the run's step through <see cref="ClipPicture"/> (the CLI autopilot applies the
    /// same): the opening, the face-follow crop, the blurred screens and the cover. Empty when the request carried no frames.</summary>
    private async Task<IReadOnlyList<MakeItRow>> MakeItPictureRowsAsync(ClipAutopilotPlan plan, MakeItRun run)
    {
        if (run.Frames is not { } record || framePass is not { } pass) return [];
        List<MakeItRow> rows = [];
        if (await MakeItOpeningRowAsync(run, pass) is { } opening) rows.Add(opening);
        if (MakeItFaceRow(record, run) is { } face) rows.Add(face);
        rows.AddRange(MakeItScreenRows(record, plan, run, applying: true));
        if (MakeItCoverRow(record, plan, run) is { } cover) rows.Add(cover);
        return rows;
    }

    /// <summary>"Opens on a clear look at you": the start moves back into the pause before the first word (never across a word) when the
    /// first frame is not a clear look and one there is. No row when the start stays.</summary>
    private async Task<MakeItRow?> MakeItOpeningRowAsync(MakeItRun run, VideoFramePass pass)
    {
        if (ClipPicture.OpeningClip(project, run.ClipId) is not { } clip) return null;
        IReadOnlyList<FrameObservation>? scan;
        double? baseline;
        try
        {
            scan = await pass.OpeningAsync(clip, run.Cancellation.Token);
            baseline = await pass.PitchBaselineAsync(run.Cancellation.Token);
        }
        catch (OperationCanceledException) { return null; }
        if (ClipPicture.OpeningOf(project, run.ClipId, scan, baseline) is not { } found) return null;
        run.Inverses[ClipPicture.OpeningRowId] = new MakeItInverse.LeadIn(run.ClipId, found.Opening.PreviousLeadIn);
        ReplaceProject(found.Project, "Make it postable");
        return new(ClipPicture.OpeningRowId, "Opens on a clear look at you")
        {
            Detail = $"{found.Opening.Reason}, so the clip starts in the pause {ClipPicture.OneDecimal(found.Opening.Earlier)} s earlier",
            Play = found.Opening.Start, Undoable = true
        };
    }

    /// <summary>"9:16 follows your face": the crop centred on the median measured face, one static centre for 9:16 and 1:1. No row without
    /// a face or without a portrait or square shape to export.</summary>
    private MakeItRow? MakeItFaceRow(MakeItFrameRecord record, MakeItRun run)
    {
        if (ClipPicture.CropOf(project, run.ClipId, record.Sentences, MakeItStyle.Shapes) is not { } found) return null;
        run.Inverses[ClipPicture.CropRowId] = new MakeItInverse.Reframe(run.ClipId, found.Crop.Previous);
        ReplaceProject(found.Project, "Make it postable");
        return new(ClipPicture.CropRowId, $"{ShapeName(found.Crop.Shape)} follows your face")
        {
            Detail = "The crop is centred on your measured face position, not the middle of the frame",
            Play = ClipPlay(run.ClipId, project), Undoable = true
        };
    }

    /// <summary>One row per detected screen: "Blurred the phone screen at 0:12–0:16" when Claude saw it and judged it private (the
    /// existing blur effect over its span and box), else "Phone screen at 0:12–0:16 left sharp" with an inline Blur. An AI without images
    /// never blurs on its own: it could not see the screen.</summary>
    internal IReadOnlyList<MakeItRow> MakeItScreenRows(MakeItFrameRecord record, ClipAutopilotPlan? plan, MakeItRun run, bool applying)
    {
        var (next, screens) = ClipPicture.Blurs(project, run.ClipId, record.Sent, plan, applying);
        if (!ReferenceEquals(next, project)) ReplaceProject(next, "Make it postable");
        return screens.Select(screen =>
        {
            var candidate = screen.Candidate;
            var rowId = ClipPicture.BlurRowId(candidate.Id);
            if (screen.Applied) run.Inverses[rowId] = new MakeItInverse.Effect(screen.EffectId, null);
            var name = ClipPicture.ScreenName(candidate.Rect, project.Media.Source.Video);
            var span = MakeItClipTime(candidate.Start, run.ClipId) + "–" + MakeItClipTime(candidate.End, run.ClipId);
            var row = new MakeItRow(rowId, "") { Kind = MakeItRowKind.Choice, Play = Math.Max(0, candidate.Start - 0.5), Candidate = candidate.Id };
            if (screen.Blurred)
                return row with
                {
                    Text = $"Blurred the {name} at {span}", Detail = screen.Reason ?? "The action you tap stays sharp",
                    Undoable = run.Inverses.ContainsKey(rowId), Change = MakeItChange.Screens, Options = MakeItScreenOptions(record, run)
                };
            return row with
            {
                Text = $"{char.ToUpperInvariant(name[0])}{name[1..]} at {span} left sharp",
                Detail = !record.Sent.SendsImages ? $"{record.Ai.Name} takes text only, so it couldn't see this screen." : screen.Reason ?? "Nothing private showed on it.",
                Change = MakeItChange.Screen, Action = "Blur"
            };
        }).ToArray();
    }

    /// <summary>The blurred row's Change: each of the clip's screens as a toggle, "Blur …" or "Leave … sharp".</summary>
    private IReadOnlyList<string> MakeItScreenOptions(MakeItFrameRecord record, MakeItRun run) => record.Sent.Blur.Select(candidate =>
    {
        var name = ClipPicture.ScreenName(candidate.Rect, project.Media.Source.Video);
        var span = MakeItClipTime(candidate.Start, run.ClipId) + "–" + MakeItClipTime(candidate.End, run.ClipId);
        return (MakeItScreenBlurred(candidate.Id, run) ? "Leave the " : "Blur the ") + name + " at " + span + (MakeItScreenBlurred(candidate.Id, run) ? " sharp" : "");
    }).ToArray();

    /// <summary>Whether the screen candidate is blurred now.</summary>
    public bool MakeItScreenBlurred(string candidateId, MakeItRun run) => ClipPicture.HasEffect(project, ClipPicture.BlurEffectId(run.ClipId, candidateId));

    /// <summary>A Blur on a sharp screen, or a toggle in the screens list: blurs or unblurs it as its own undo step.</summary>
    public bool MakeItToggleScreen(string candidateId, MakeItRun run)
    {
        if (run.Running || run.Frames is not { } record || record.Sent.BlurCandidateFor(candidateId) is not { } candidate) return false;
        var id = ClipPicture.BlurEffectId(run.ClipId, candidateId);
        var blurred = ClipPicture.HasEffect(project, id);
        Project? next;
        try { next = blurred ? ClipPicture.RemovingEffect(id, project) : ClipEffects.Adding([ClipPicture.BlurEffect(candidate, run.ClipId)], project); }
        catch (VoxClipException) { next = null; }
        if (next is null || !ReplaceProject(next, blurred ? "Unblur screen" : "Blur screen")) return false;
        // A blur Claude made can still be taken back by its row's Undo; one the creator added is undone with Ctrl+Z.
        var rowId = ClipPicture.BlurRowId(candidateId);
        if (blurred) run.Inverses.Remove(rowId);
        foreach (var row in MakeItScreenRows(record, run.Plan, run, applying: false))
            if (run.Rows.FindIndex(item => item.Id == row.Id) is var index and >= 0) run.Rows[index] = row;
        run.OpenChoice = null;
        Announcement?.Invoke(this, blurred ? "Screen left sharp." : "Screen blurred.");
        MakeItNotify();
        return true;
    }

    /// <summary>"Cover frame chosen": Claude's pick among the three best measured frames, or the best when it named none.</summary>
    private MakeItRow? MakeItCoverRow(MakeItFrameRecord record, ClipAutopilotPlan plan, MakeItRun run)
    {
        if (ClipPicture.CoverOf(project, run.ClipId, record.Sent, plan) is not { } found) return null;
        run.Inverses[ClipPicture.CoverRowId] = new MakeItInverse.Cover(run.ClipId, found.Cover.Previous);
        ReplaceProject(found.Project, "Make it postable");
        var detail = found.Cover.Reason ?? "Eyes open, the clearest look measured on this PC";
        return new(ClipPicture.CoverRowId, "Cover frame chosen")
        {
            Kind = MakeItRowKind.Choice, Detail = detail + " · saved next to the export as a cover image", Play = found.Cover.Candidate.Time, Undoable = true,
            Change = MakeItChange.Cover, Options = MakeItCoverOptions(record, run, found.Cover.Candidate.Time)
        };
    }

    /// <summary>The cover row's Change: the other candidates by their time on the clip.</summary>
    private IReadOnlyList<string> MakeItCoverOptions(MakeItFrameRecord record, MakeItRun run, double picked) =>
        record.Sent.Cover.Where(candidate => Math.Abs(candidate.Time - picked) >= 1e-6).Select(candidate => MakeItCoverLabel(candidate, run)).ToArray();

    /// <summary>"Frame 3 at 0:12".</summary>
    private string MakeItCoverLabel(ClipAutopilotFrames.CoverCandidate candidate, MakeItRun run) =>
        $"Frame {candidate.Frame.ToString(CultureInfo.InvariantCulture)} at {MakeItClipTime(candidate.Time, run.ClipId)}";

    /// <summary>A cover candidate picked in the row's Change: the clip's cover, as one undo step ("Change cover").</summary>
    public bool MakeItChooseCover(double time, MakeItRun run)
    {
        var index = run.Rows.FindIndex(row => row.Id == ClipPicture.CoverRowId);
        if (run.Running || run.Frames is not { } record || index < 0) return false;
        if (ClipPicture.SettingControls(run.ClipId, project, controls => controls with { CoverSeconds = time }) is not { } next) return false;
        if (!ReferenceEquals(next, project)) ReplaceProject(next, "Change cover");
        run.Rows[index] = run.Rows[index] with
        {
            Detail = $"You chose the frame at {MakeItClipTime(time, run.ClipId)} · saved next to the export as a cover image", Play = time,
            Options = MakeItCoverOptions(record, run, time)
        };
        run.OpenChoice = null;
        MakeItNotify();
        return true;
    }

    /// <summary>A chip in a picture row's inline choices: a cover candidate, or a screen's toggle.</summary>
    private bool MakeItChoosePicture(string option, MakeItRow row, MakeItRun run)
    {
        if (run.Frames is not { } record) return false;
        if (row.Change == MakeItChange.Cover)
            return record.Sent.Cover.FirstOrDefault(candidate => MakeItCoverLabel(candidate, run) == option) is { } chosen && MakeItChooseCover(chosen.Time, run);
        var options = MakeItScreenOptions(record, run);
        var position = options.ToList().IndexOf(option);
        return position >= 0 && MakeItToggleScreen(record.Sent.Blur[position].Id, run);
    }

    /// <summary>A row's own action ("Blur" on a screen left sharp).</summary>
    public bool MakeItRowAction(string rowId, MakeItRun run) =>
        run.Rows.FirstOrDefault(row => row.Id == rowId) is { Change: MakeItChange.Screen, Candidate: { } candidate } && MakeItToggleScreen(candidate, run);

    /// <summary>A picture row's Undo: the field it changed, as it was before.</summary>
    private bool UndoPicture(MakeItInverse inverse, string name)
    {
        var next = inverse switch
        {
            MakeItInverse.LeadIn leadIn => ClipPicture.SettingLeadIn(leadIn.Previous, leadIn.ClipId, project),
            MakeItInverse.Reframe reframe => ClipPicture.SettingControls(reframe.ClipId, project, controls => controls with { Reframe = reframe.Previous }),
            MakeItInverse.Cover cover => ClipPicture.SettingControls(cover.ClipId, project, controls => controls with { CoverSeconds = cover.Previous }),
            _ => null
        };
        if (next is null) return false;
        if (!ReferenceEquals(next, project)) ReplaceProject(next, name);
        return true;
    }
}
