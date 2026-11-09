using System.Text.Json;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Share;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The picture decisions of a plan (ADR-R48, ai.md §19.6), twin of the Mac <c>ClipPicture</c>, and the export's cover, twin of the
/// Mac <c>ExportCover</c>, on the passage fixture (words 0 So · 1 um, · 2 today · (pause) · 3 we · … · 7 clipper. · 8 Thanks; clip
/// <c>clip-main</c> on 2…7, a 1920 × 1080 source).</summary>
[Trait("Track", "win-ai")]
public sealed class ClipPictureTests
{
    private static Project Passage() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));

    /// <summary>The passage with its clip on "we … clipper." (3…7), as a plan leaves it.</summary>
    private static Project Tightened()
    {
        var project = Passage();
        return project with { Edits = project.Edits with { Clips = [project.Edits.Clips.Single() with { StartWordId = "w4" }] } };
    }

    private static FrameFace Face(double x = 0.3, double eyes = 0.3, double quality = 0.6) => new(new(x, 0.2, 0.2, 0.36), quality, eyes, eyes, 0, 0);
    private static FrameObservation Look(double time, FrameFace? face) => new(time) { FaceCount = face is null ? 0 : 1, Face = face };

    private static ClipAutopilotFrames Frames(bool images, params ClipAutopilotFrames.CoverCandidate[] covers) =>
        new("summary", images ? [new("Frame 1 at 2.95 s", "image/jpeg", [0xFF, 0xD8], 320, 180)] : [],
            [new("B1", 2.0, 4.0, new(0.62, 0.3, 0.12, 0.4), 1)], covers.Length == 0 ? [new("C1", 1, 2.95, 0.8)] : covers, images ? 77 : 0);

    private static ClipAutopilotPlan Plan(ClipAutopilotPlan.FrameChoices? frames) => new()
    {
        StartWord = 3, EndWord = 7, Title = "Ship day", Hook = "", PostText = "", Score = 7, Verdict = ClipAutopilotVerdict.Post,
        CaptionChoice = new("vox-bold", new("Roboto", 900), ClipAutopilotCaptionCase.Upper, 3), Frames = frames
    };

    [Fact]
    public void TheOpeningsReasonsAreTheMacsCopy()
    {
        Assert.Equal("Your face wasn't in the first frame", ClipPicture.OpeningReason(null, null));
        Assert.Equal("Your face wasn't in the first frame", ClipPicture.OpeningReason(Look(1, null), null));
        Assert.Equal("Your eyes were shut on the first frame", ClipPicture.OpeningReason(Look(1, Face(eyes: 0.1)), null));
        var away = Look(1, Face() with { Pitch = 0.9 });
        Assert.Equal("You were looking away on the first frame", ClipPicture.OpeningReason(away, 0.45));
        Assert.Equal("The first frame was blurred", ClipPicture.OpeningReason(away, 0.9));
    }

    [Fact]
    public void TheOpeningMovesIntoThePauseNeverAcrossAWordAndKeepsWhatItReplaced()
    {
        var project = Tightened();
        // Eyes shut on the clip's first frames (2.6, 2.7 s), open in the pause before them.
        var scan = FrameSampling.OpeningTimes(2.6).Select(time => Look(time, Face(eyes: time > 2.5 && time < 2.75 ? 0.1 : 0.3))).ToArray();
        var (next, opening) = ClipPicture.OpeningOf(project, "clip-main", scan, null)!.Value;
        Assert.Equal((0.6, (double?)null), (opening.LeadIn, opening.PreviousLeadIn));
        Assert.Equal("Your eyes were shut on the first frame", opening.Reason);
        Assert.Equal("0.5", ClipPicture.OneDecimal(opening.Earlier));
        Assert.Equal(4, next.SchemaVersion);
        Assert.Equal(0.6, next.Edits.Clips.Single().LeadInSeconds);
        Assert.True(opening.Start >= EditingAlgorithms.ClipLeadInFloor(next.Transcript!.Words, 3) - 1e-9, "never into “today”");
        // A clear first frame stays; a cut first word has no opening clip.
        Assert.Null(ClipPicture.OpeningOf(project, "clip-main", FrameSampling.OpeningTimes(2.6).Select(time => Look(time, Face())).ToArray(), null));
        var cut = project with { Edits = project.Edits with { CutWordIds = ["w4"] } };
        Assert.Null(ClipPicture.OpeningClip(cut, "clip-main"));
        // Undo puts back exactly what was there: no lead-in.
        Assert.Null(ClipPicture.SettingLeadIn(null, "clip-main", next)!.Edits.Clips.Single().LeadInSeconds);
        Assert.Null(ClipPicture.SettingLeadIn(0.7, "clip-main", next));
        Assert.Null(ClipPicture.SettingLeadIn(0.3, "gone", next));
    }

    [Fact]
    public void TheCropFollowsTheMedianFaceOnlyForPortraitOrSquare()
    {
        var project = Tightened();
        var sentences = new[] { Look(2.95, Face()), Look(3.9, Face()) };
        Assert.Null(ClipPicture.CropOf(project, "clip-main", sentences, [ExportAspect.Landscape]));
        Assert.Null(ClipPicture.CropOf(project, "clip-main", [Look(2.95, null)], [ExportAspect.Portrait]));
        var (next, crop) = ClipPicture.CropOf(project, "clip-main", sentences, [ExportAspect.Landscape, ExportAspect.Square])!.Value;
        Assert.Equal((0.4, 0.5, ExportAspect.Square, (ReframeSettings?)null), (crop.CenterX, crop.CenterY, crop.Shape, crop.Previous));
        Assert.Equal(new ReframeSettings(ReframeSettings.FaceMode, 1, 0.4, 0.5), ClipControlsProject.Controls("clip-main", next)!.Reframe);
        Assert.Equal(ExportAspect.Portrait, ClipPicture.CropOf(project, "clip-main", sentences, [ExportAspect.Square, ExportAspect.Portrait])!.Value.Crop.Shape);
    }

    [Fact]
    public void AScreenIsBlurredOnlyWhenClaudeSawItAndChoseTo()
    {
        var project = Tightened();
        var blur = Plan(new([new("B1", true, "It shows calendar entries with names")], null));
        var (blurred, screens) = ClipPicture.Blurs(project, "clip-main", Frames(images: true), blur, applying: true);
        var screen = Assert.Single(screens);
        Assert.Equal((true, true, "It shows calendar entries with names"), (screen.Blurred, screen.Applied, screen.Reason));
        var effect = Assert.Single(blurred.ClipEffects);
        Assert.Equal(["id", "clipId", "kind", "start", "end", "rect", "tracking", "track"], effect.EnumerateObject().Select(property => property.Name));
        Assert.Equal(("fx-screen-b1-clip-main", "blur", "none", 0), (effect.GetProperty("id").GetString(), effect.GetProperty("kind").GetString(),
            effect.GetProperty("tracking").GetString(), effect.GetProperty("track").GetArrayLength()));
        // Text only: Claude couldn't see it. No decision, or "leave it": sharp. Not applying: listed only.
        Assert.False(ClipPicture.Blurs(project, "clip-main", Frames(images: false), blur, applying: true).Blurs[0].Blurred);
        Assert.False(ClipPicture.Blurs(project, "clip-main", Frames(images: true), Plan(null), applying: true).Blurs[0].Blurred);
        Assert.False(ClipPicture.Blurs(project, "clip-main", Frames(images: true), Plan(new([new("B1", false, "")], null)), applying: true).Blurs[0].Blurred);
        Assert.Null(ClipPicture.Blurs(project, "clip-main", Frames(images: true), Plan(new([new("B1", false, "")], null)), applying: true).Blurs[0].Reason);
        Assert.False(ClipPicture.Blurs(project, "clip-main", Frames(images: true), blur, applying: false).Blurs[0].Applied);
        // A blur already there is kept, not added twice; removing it leaves the rest.
        var again = ClipPicture.Blurs(blurred, "clip-main", Frames(images: true), blur, applying: true);
        Assert.Equal((true, false), (again.Blurs[0].Blurred, again.Blurs[0].Applied));
        Assert.Empty(ClipPicture.RemovingEffect("fx-screen-b1-clip-main", blurred)!.ClipEffects);
        // The phone is taller than wide in the 16:9 picture; an id stays within 64 characters; an effect lasts at most 600 s.
        Assert.Equal("phone screen", ClipPicture.ScreenName(new(0.62, 0.3, 0.12, 0.4), project.Media.Source.Video));
        Assert.Equal("screen", ClipPicture.ScreenName(new(0.1, 0.1, 0.6, 0.4), project.Media.Source.Video));
        Assert.Equal(64, ClipPicture.BlurEffectId(new string('c', 80), "B12").Length);
        var long_ = ClipPicture.BlurEffect(new("B2", 10, 900, new(0.1, 0.1, 0.2, 0.2), 3), "clip-main");
        Assert.Equal(610, long_.GetProperty("end").GetDouble());
    }

    [Fact]
    public void TheCoverIsClaudesPickOrTheLocalBestAndKeepsWhatItReplaced()
    {
        var project = Tightened();
        var frames = Frames(true, new("C1", 1, 2.95, 0.8), new("C2", 2, 3.9, 0.7));
        var named = ClipPicture.CoverOf(project, "clip-main", frames, Plan(new([], new("C2", "Eyes open, face centred"))))!.Value;
        Assert.Equal(("C2", true, "Eyes open, face centred", (double?)null), (named.Cover.Candidate.Id, named.Cover.Named, named.Cover.Reason, named.Cover.Previous));
        Assert.Equal(3.9, ClipControlsProject.Controls("clip-main", named.Project)!.CoverSeconds);
        var unknown = ClipPicture.CoverOf(named.Project, "clip-main", frames, Plan(new([], new("C9", "a reason"))))!.Value;
        Assert.Equal(("C1", false, (string?)null, (double?)3.9), (unknown.Cover.Candidate.Id, unknown.Cover.Named, unknown.Cover.Reason, unknown.Cover.Previous));
        var fallback = ClipPicture.CoverOf(project, "clip-main", frames, Plan(new([], new("C1", "the validator's", Fallback: true))))!.Value;
        Assert.Null(fallback.Cover.Reason);
        Assert.Null(ClipPicture.CoverOf(project, "clip-main", new("s", [], [], [], 0), Plan(null)));
    }

    [Fact]
    public void ApplyRunsTheFourInTheMacsOrderOnTheProjectEachLeaves()
    {
        var project = Tightened();
        var scan = FrameSampling.OpeningTimes(2.6).Select(time => Look(time, Face(eyes: time > 2.5 && time < 2.75 ? 0.1 : 0.3))).ToArray();
        var inputs = new ClipPicture.Inputs(Frames(images: true), [Look(2.95, Face())], scan, [ExportAspect.Landscape, ExportAspect.Portrait], null);
        var (next, decisions) = ClipPicture.Apply(Plan(new([new("B1", true, "names")], new("C1", "clear"))), "clip-main", project, inputs);
        Assert.NotNull(decisions.Opening);
        Assert.NotNull(decisions.Crop);
        Assert.True(Assert.Single(decisions.Blurs).Applied);
        Assert.NotNull(decisions.Cover);
        var controls = ClipControlsProject.Controls("clip-main", next)!;
        Assert.Equal((0.6, true, 2.95), (next.Edits.Clips.Single().LeadInSeconds, controls.Reframe is not null, controls.CoverSeconds));
        Assert.Single(next.ClipEffects);
        // It saves and reads back as it is.
        Assert.Equal(ProjectSerialization.Serialize(next), ProjectSerialization.Serialize(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(next))));
    }

    [Fact]
    public void TheExportsCoverIsItsFrameInTheRenderBesideTheVideo()
    {
        Assert.Equal(Path.Combine("out", "clip-1-9x16-cover.jpg"), ExportCover.PathFor(Path.Combine("out", "clip-1-9x16.mp4")));
        var project = Tightened();
        var state = EditingEngine.FromProject(project)! with { ActiveClipId = "clip-main" };
        var duration = project.Media.Source.DurationSeconds;
        var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, duration), duration, 48_000, state.PauseKeepSeconds);
        var media = new MediaInfo("source.mp4", duration, project.Media.Source.Video, project.Media.Source.Audio, new(1920, 1080), "h264", "aac", false, 0, 1, 0);
        ComposeSnapshot Snapshot(double? cover, double speed = 1) => new ComposeSnapshot(media, plan, null, new(new(1080, 1920), 30, 1)) with
        {
            Clip = new(new("clip-main", speed, null, ClipLook.Original, 0, 0, 0, false, false, 0, CoverSeconds: cover), null)
        };
        Assert.Null(ExportCover.Seconds(Snapshot(null), 30));
        Assert.Null(ExportCover.Seconds(new ComposeSnapshot(media, plan, null, new(new(1080, 1920), 30, 1)), 30));
        var at = ExportCover.Seconds(Snapshot(2.95), 30)!.Value;
        Assert.Equal(plan.MapTime(2.95), at, 9);
        Assert.Equal(plan.MapTime(2.95) / 2, ExportCover.Seconds(Snapshot(2.95, 2), 30)!.Value, 9);
        // Kept inside the video: a source second past the clip is its last frame.
        var snapshot = Snapshot(5.9);
        Assert.Equal(Math.Max(0, snapshot.RenderedDuration - 1.0 / 30), ExportCover.Seconds(snapshot, 30)!.Value, 9);
        var frames = (long)Math.Round(snapshot.RenderedDuration * 30);
        Assert.Equal(frames - 1, ExportCover.Frame(snapshot, 30, frames));
        Assert.Equal((long)Math.Round(at * 30, MidpointRounding.AwayFromZero), ExportCover.Frame(Snapshot(2.95), 30, frames));
        Assert.Null(ExportCover.Frame(Snapshot(2.95), 30, 0));
    }
}
