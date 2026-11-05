using System.Text.Json;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>Each clip's caption look (design §6.6) on Windows: the clip's pick where it applies (the creator's own, <c>by: "user"</c>,
/// always; Claude's under Auto or when it keeps the fixed style), with its overrides, else the project's captions. Twin of the Mac
/// package track/v2-mac-clip-finish (ClipStyle.choosingCaptionStyle, recordingLook, EditorModel.mutateCaptions); CaptionLookVectorTests
/// replays the shared resolution vectors.</summary>
public sealed class ClipCaptionStyleTests
{
    private static ClipCaptionPick Yours(string style) => new(style, "") { By = "user" };

    private static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();

    private static Project Project(string captions = "auto", params (string Clip, ClipCaptionPick Pick)[] picks)
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-project.voxclip"));
        ClipRange[] clips = [new("clip-a", "w1", "w3", "Hook", ClipOrigin.Manual, null, null, true),
                             new("clip-b", "w4", "w8", "Story", ClipOrigin.Manual, null, null, true),
                             new("clip-c", "w9", "w9", "Thanks", ClipOrigin.Manual, null, null, true)];
        var map = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal);
        foreach (var (clip, pick) in picks) map[clip] = pick;
        return project with { ClipStyle = new("auto", captions, "auto", 60, ["16:9"], "fix-only", map), ClipControls = [],
            Captions = project.Captions with { StyleId = "vox-bold" }, Edits = project.Edits with { Clips = clips, ActiveClipId = "clip-b" } };
    }

    [Fact]
    public void EachClipResolvesToItsPickElseTheProjectDefault()
    {
        var auto = Project("auto", ("clip-a", new("punch-in", "Fast.")), ("clip-b", Yours("marker")), ("clip-c", new("off", "Quiet.")));
        Assert.Equal(["punch-in", "marker", "off", "vox-bold"], new string?[] { "clip-a", "clip-b", "clip-c", null }.Select(clip => ClipCaptionStyles.StyleId(auto, clip)));
        Assert.Equal("vox-bold", ClipCaptionStyles.StyleId(auto, "clip-gone"));
        // A fixed style is the project default: Claude's other picks never override it, the creator's own choice does.
        var fixedStyle = Project("glow", ("clip-a", new("punch-in", "Fast.")), ("clip-b", Yours("marker")), ("clip-c", new("glow", "Fits."))) with { Captions = auto.Captions with { StyleId = "glow" } };
        Assert.Equal(["glow", "marker", "glow"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => ClipCaptionStyles.StyleId(fixedStyle, clip)));
        // A pick the library lacks falls back to the default; "off" always applies.
        var library = new HashSet<string>(["vox-bold", "marker"], StringComparer.Ordinal);
        Assert.Equal(["vox-bold", "marker", "off"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => ClipCaptionStyles.StyleId(auto, clip, library)));
        Assert.Equal("vox-bold", ClipCaptionStyles.StyleId(auto with { ClipStyle = null }, "clip-a"));
        // The pick's overrides render; a pick without them keeps the project's only while the styles match. Positions stay the project's.
        var looks = Project("auto", ("clip-a", new("punch-in", "Fast.") { Overrides = Json("""{"text":{"transform":"uppercase"}}""") }),
            ("clip-b", new("vox-bold", "Same.")), ("clip-c", new("glow", "Other."))) with { Captions = auto.Captions with { Overrides = Json("""{"layout":{"maxWords":2}}""") } };
        var settings = ClipCaptionStyles.Settings(looks, "clip-a");
        Assert.Equal(("punch-in", "uppercase", looks.Captions.Position), (settings.StyleId, settings.Overrides.GetProperty("text").GetProperty("transform").GetString(), settings.Position));
        Assert.Equal(2, ClipCaptionStyles.Settings(looks, "clip-b").Overrides.GetProperty("layout").GetProperty("maxWords").GetInt32());
        Assert.False(ClipCaptionStyles.Settings(looks, "clip-c").Overrides.TryGetProperty("layout", out _));
        Assert.Same(auto.Captions, ClipCaptionStyles.Settings(auto, null));
        Assert.Same(auto, ClipCaptionStyles.Rendered(auto, null));
        Assert.Equal(["This clip: Punch · Claude's pick", "This clip: marker · your pick", "This clip: Off · Claude's pick", "Project default"],
            new string?[] { "clip-a", "clip-b", "clip-c", null }.Select(clip => ClipCaptionStyles.Source(auto, clip, id => id == "punch-in" ? "Punch" : id)));
        Assert.Equal("Project default", ClipCaptionStyles.Source(fixedStyle, "clip-a", id => id));
    }

    [Fact]
    public void ChoosingIsTheClipsOwnWithAClipAndTheDefaultWithout()
    {
        var project = Project("auto", ("clip-a", new("punch-in", "Fast.")));
        var chosen = ClipCaptionStyles.Choosing(project, "clip-b", "glow");
        Assert.Equal(Yours("glow"), chosen.ClipStyle!.CaptionPicks["clip-b"]);
        Assert.Equal(("vox-bold", "auto", "punch-in"), (chosen.Captions.StyleId, chosen.ClipStyle.Captions, ClipCaptionStyles.StyleId(chosen, "clip-a")));
        ProjectSerialization.Validate(chosen);
        // Choosing what the clip already shows keeps Claude's pick as it is.
        Assert.Same(project, ClipCaptionStyles.Choosing(project, "clip-a", "punch-in"));
        Assert.Same(project, ClipCaptionStyles.Choosing(project, "clip-c", "vox-bold"));
        // Claude never replaces the creator's own pick.
        Assert.Equal("glow", chosen.ClipStyle.Recording(new Dictionary<string, ClipCaptionPick> { ["clip-b"] = new("minimal", "Later.") }).CaptionPicks["clip-b"].StyleId);
        // No clip: the project default, fixed, every pick kept.
        var full = ClipCaptionStyles.Choosing(chosen, null, "marker");
        Assert.Equal(("marker", "marker", "mine"), (full.Captions.StyleId, full.ClipStyle!.Captions, full.ClipStyle.Preset));
        Assert.Equal(["marker", "glow", "marker"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => ClipCaptionStyles.StyleId(full, clip)));
        // Undo restores a pick exactly, or none.
        Assert.False(ClipCaptionStyles.Restoring(chosen, "clip-b", null).ClipStyle!.CaptionPicks.ContainsKey("clip-b"));
        Assert.Equal(new ClipCaptionPick("x", "y"), ClipCaptionStyles.Restoring(chosen, "clip-b", new("x", "y")).ClipStyle!.CaptionPicks["clip-b"]);
    }

    [Fact]
    public void MakeItRecordsEachClipsLookAndFineTuneEditsTheOpenClipsOwn()
    {
        var project = Project();
        var uppercase = Json("""{"text":{"transform":"uppercase"}}""");
        var result = project;
        foreach (var (clip, style) in new[] { ("clip-a", "punch-in"), ("clip-b", "minimal"), ("clip-c", "glow") })
            result = ClipCaptionStyles.RecordingLook(result, clip, project.Captions with { StyleId = style, Overrides = uppercase }, "Because " + clip)!;
        Assert.Equal(["punch-in", "minimal", "glow"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => ClipCaptionStyles.StyleId(result, clip)));
        Assert.Equal(("vox-bold", "Because clip-b", null), (result.Captions.StyleId, result.ClipStyle!.CaptionPicks["clip-b"].Reason, result.ClipStyle.CaptionPicks["clip-b"].By));
        Assert.Equal("uppercase", ClipCaptionStyles.Settings(result, "clip-b").Overrides.GetProperty("text").GetProperty("transform").GetString());
        Assert.False(result.Captions.Overrides.ValueKind == JsonValueKind.Object && result.Captions.Overrides.TryGetProperty("text", out _));
        ProjectSerialization.Validate(result);
        // The creator's own pick stays, and a style fixed to another one takes no look; long reasons are cut to 120 characters.
        Assert.Null(ClipCaptionStyles.RecordingLook(Project("auto", ("clip-a", Yours("marker"))), "clip-a", project.Captions with { StyleId = "glow" }, "No."));
        Assert.Null(ClipCaptionStyles.RecordingLook(Project("marker"), "clip-a", project.Captions with { StyleId = "glow" }, "No."));
        Assert.NotNull(ClipCaptionStyles.RecordingLook(Project("glow"), "clip-a", project.Captions with { StyleId = "glow" }, "Yes."));
        Assert.Equal(120, ClipCaptionStyles.RecordingLook(project, "clip-a", project.Captions with { StyleId = "glow" }, new string('r', 130))!.ClipStyle!.CaptionPicks["clip-a"].Reason.Length);
        // Before the project has a clip style, the look is the project's captions.
        var bare = ClipCaptionStyles.RecordingLook(project with { ClipStyle = null }, "clip-a", project.Captions with { StyleId = "glow" }, "Fits.")!;
        Assert.Equal(("glow", (ClipStyle?)null), (bare.Captions.StyleId, bare.ClipStyle));
        // Fine tune with clip-b open edits its pick; clip-a and the project's captions stay.
        var words = Json("""{"layout":{"maxWords":1}}""");
        var tuned = ClipCaptionStyles.Tuning(result, "clip-b", ClipCaptionStyles.Settings(result, "clip-b") with { Overrides = words });
        Assert.Equal(1, ClipCaptionStyles.Settings(tuned, "clip-b").Overrides.GetProperty("layout").GetProperty("maxWords").GetInt32());
        Assert.Equal("uppercase", ClipCaptionStyles.Settings(tuned, "clip-a").Overrides.GetProperty("text").GetProperty("transform").GetString());
        Assert.Equal(result.Captions, tuned.Captions);
        // With no pick it is the project's captions.
        var plain = ClipCaptionStyles.Tuning(project, "clip-b", project.Captions with { Overrides = words });
        Assert.Equal(1, plain.Captions.Overrides.GetProperty("layout").GetProperty("maxWords").GetInt32());
    }
}
