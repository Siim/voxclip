using System.Text.Json;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>Each clip's caption style (design §6.6): the clip's pick where it applies, else the project default. Twin of the Mac
/// package track/v2-mac-clip-finish step 1.</summary>
public sealed class ClipCaptionStyleTests
{
    private static Project Project(string captions = "auto", params (string Clip, string Style, string Reason)[] picks)
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-project.voxclip"));
        ClipRange[] clips = [new("clip-a", "w1", "w3", "Hook", ClipOrigin.Manual, null, null, true),
                             new("clip-b", "w4", "w8", "Story", ClipOrigin.Manual, null, null, true),
                             new("clip-c", "w9", "w9", "Thanks", ClipOrigin.Manual, null, null, true)];
        var map = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal);
        foreach (var (clip, style, reason) in picks) map[clip] = new(style, reason);
        return project with { ClipStyle = new("auto", captions, "auto", 60, ["16:9"], "fix-only", map), ClipControls = [],
            Captions = project.Captions with { StyleId = "vox-bold" }, Edits = project.Edits with { Clips = clips, ActiveClipId = "clip-b" } };
    }

    [Fact]
    public void EachClipResolvesToItsPickElseTheProjectDefault()
    {
        var yours = ClipCaptionStyles.YourChoice;
        var auto = Project("auto", ("clip-a", "punch-in", "Fast."), ("clip-b", "marker", yours), ("clip-c", "off", "Quiet."));
        Assert.Equal(["punch-in", "marker", "off", "vox-bold"], new string?[] { "clip-a", "clip-b", "clip-c", null }.Select(clip => ClipCaptionStyles.StyleId(auto, clip)));
        Assert.Equal("vox-bold", ClipCaptionStyles.StyleId(auto, "clip-gone"));
        // A fixed style is the project default: Claude's picks never override it, the user's own choice does.
        var fixedStyle = Project("glow", ("clip-a", "punch-in", "Fast."), ("clip-b", "marker", yours)) with { Captions = auto.Captions with { StyleId = "glow" } };
        Assert.Equal(["glow", "marker", "glow"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => ClipCaptionStyles.StyleId(fixedStyle, clip)));
        Assert.Equal(["glow", "marker", "glow"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => fixedStyle.ClipStyle!.CaptionStyleFor(clip)));
        // A pick the library lacks falls back to the default; "off" always applies.
        var library = new HashSet<string>(["vox-bold", "marker"], StringComparer.Ordinal);
        Assert.Equal(["vox-bold", "marker", "off"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => ClipCaptionStyles.StyleId(auto, clip, library)));
        // No clip style: every clip renders in the project's style.
        Assert.Equal("vox-bold", ClipCaptionStyles.StyleId(auto with { ClipStyle = null }, "clip-a"));
        // The settings keep the project's overrides and positions with the clip's style.
        var settings = ClipCaptionStyles.Settings(auto, "clip-a");
        Assert.Equal(("punch-in", auto.Captions.Position), (settings.StyleId, settings.Position));
        Assert.Same(auto.Captions, ClipCaptionStyles.Settings(auto, null));
        Assert.Same(auto, ClipCaptionStyles.Rendered(auto, null));
        Assert.Equal(["This clip: Punch · Claude's pick", "This clip: marker · your choice", "This clip: Captions off · Claude's pick", "Project default"],
            new string?[] { "clip-a", "clip-b", "clip-c", null }.Select(clip => ClipCaptionStyles.Source(auto, clip, id => id == "punch-in" ? "Punch" : id)));
        Assert.Equal("Project default", ClipCaptionStyles.Source(fixedStyle, "clip-a", id => id));
    }

    [Fact]
    public void ChoosingIsTheClipsOwnWithAClipAndTheDefaultWithout()
    {
        var project = Project("auto", ("clip-a", "punch-in", "Fast."));
        var chosen = ClipCaptionStyles.Choosing(project, "clip-b", "glow");
        Assert.Equal(new ClipCaptionPick("glow", ClipCaptionStyles.YourChoice), chosen.ClipStyle!.CaptionPicks["clip-b"]);
        Assert.Equal(("vox-bold", "auto", "punch-in"), (chosen.Captions.StyleId, chosen.ClipStyle.Captions, ClipCaptionStyles.StyleId(chosen, "clip-a")));
        // Choosing what the clip already shows keeps Claude's pick as it is.
        Assert.Same(project, ClipCaptionStyles.Choosing(project, "clip-a", "punch-in"));
        Assert.Same(project, ClipCaptionStyles.Choosing(project, "clip-c", "vox-bold"));
        // No clip: the project default, fixed, every pick kept.
        var full = ClipCaptionStyles.Choosing(chosen, null, "marker");
        Assert.Equal(("marker", "marker", "mine"), (full.Captions.StyleId, full.ClipStyle!.Captions, full.ClipStyle.Preset));
        Assert.Equal(["marker", "glow", "marker"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => ClipCaptionStyles.StyleId(full, clip)));
        // Undo restores a pick exactly, or none.
        Assert.False(ClipCaptionStyles.Restoring(chosen, "clip-b", null).ClipStyle!.CaptionPicks.ContainsKey("clip-b"));
        Assert.Equal(new ClipCaptionPick("x", "y"), ClipCaptionStyles.Restoring(chosen, "clip-b", new("x", "y")).ClipStyle!.CaptionPicks["clip-b"]);
        // Long reasons are cut to the schema's 120 characters.
        var long_ = ClipCaptionStyles.Choosing(project, "clip-c", "glow", new string('r', 130));
        Assert.Equal(120, long_.ClipStyle!.CaptionPicks["clip-c"].Reason.Length);
        ProjectSerialization.Validate(long_);
    }

    [Fact]
    public void MakeItPostableRecordsEachClipsStyleWithoutChangingTheDefault()
    {
        var project = Project();
        using var overrides = JsonDocument.Parse("""{"text":{"transform":"uppercase"}}""");
        var result = project;
        foreach (var (clip, style) in new[] { ("clip-a", "punch-in"), ("clip-b", "minimal"), ("clip-c", "glow") })
        {
            var action = new ClipAutopilotAction.Captions(clip, project.Captions with { StyleId = style, Overrides = overrides.RootElement.Clone() }, null);
            result = ClipAutopilotMapping.Apply([new("captions", ClipAutopilotDecision.Captions, action, "Because " + clip)], result).Project;
        }
        Assert.Equal(["punch-in", "minimal", "glow"], new[] { "clip-a", "clip-b", "clip-c" }.Select(clip => ClipCaptionStyles.StyleId(result, clip)));
        Assert.Equal(("vox-bold", "Because clip-b"), (result.Captions.StyleId, result.ClipStyle!.CaptionPicks["clip-b"].Reason));
        Assert.Equal("uppercase", result.Captions.Overrides.GetProperty("text").GetProperty("transform").GetString());
        ProjectSerialization.Validate(result);
        // Before the project has a clip style, the choice is the project's style, as before.
        var bare = project with { ClipStyle = null };
        var applied = new ClipAutopilotAction.Captions("clip-a", bare.Captions with { StyleId = "glow" }, null).Applying(bare, "Fits.");
        Assert.Equal(("glow", (ClipStyle?)null), (applied.Captions.StyleId, applied.ClipStyle));
    }
}
