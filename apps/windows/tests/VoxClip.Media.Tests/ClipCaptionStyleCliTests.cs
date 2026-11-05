using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Captions;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Each clip renders in its own caption style (design §6.6): its pick (Claude's under Auto, or the user's own), else the
/// project default. The CLI export path is the one the App's preview, export and Export all share (ClipCaptionStyles).</summary>
[Collection("CLI console")]
public sealed class ClipCaptionStyleCliTests
{
    private static Project ThreeClips()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/clip-controls/clip-controls-project.voxclip"));
        ClipRange[] clips = [new("clip-a", "w1", "w3", "Hook", ClipOrigin.Manual, null, null, true),
                             new("clip-b", "w4", "w8", "Story", ClipOrigin.Manual, null, null, true),
                             new("clip-c", "w9", "w9", "Thanks", ClipOrigin.Manual, null, null, true)];
        var picks = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal)
        {
            ["clip-a"] = new("punch-in", "Fast hook."),
            ["clip-b"] = new("minimal", ClipCaptionStyles.YourChoice),
        };
        var style = new ClipStyle("auto", "auto", "auto", 60, ["16:9", "9:16"], "fix-only", picks);
        return project with { ClipStyle = style, ClipControls = [], Captions = project.Captions with { StyleId = "vox-bold" },
            Edits = project.Edits with { Clips = clips, ActiveClipId = null } };
    }

    private static async Task<ExportJob> ExportClipAsync(Project project, string clip, params string[] style)
    {
        var (exit, job, output) = await ClipRenderCliTests.ExportStyledAsync(project, style, ["--clip", clip]);
        Assert.True(exit == 0, output);
        return Assert.IsType<ExportJob>(job);
    }

    [Fact]
    public async Task TwoClipsRenderInTheirOwnStylesAndThePickChangesThePixels()
    {
        var project = ThreeClips();
        var a = await ExportClipAsync(project, "clip-a");
        var b = await ExportClipAsync(project, "clip-b");
        Assert.Equal("punch-in", a.Snapshot.Captions!.Style.Id);
        Assert.Equal("minimal", b.Snapshot.Captions!.Style.Id);
        // The same clip in the project default draws different pixels: the pick reaches the rasterizer.
        var asDefault = await ExportClipAsync(project, "clip-b", "--style", "vox-bold");
        Assert.Equal("vox-bold", asDefault.Snapshot.Captions!.Style.Id);
        var rasterizer = new SkiaCaptionRasterizer(FixtureLoader.SharedRoot);
        var time = b.Snapshot.Captions.Words[1].Start + 0.05;
        var picked = await rasterizer.RenderAsync(new(b.Snapshot.Captions, time, Scale: 0.25), TestContext.Current.CancellationToken);
        var plain = await rasterizer.RenderAsync(new(asDefault.Snapshot.Captions, time, Scale: 0.25), TestContext.Current.CancellationToken);
        Assert.Equal((picked.Width, picked.Height), (plain.Width, plain.Height));
        var differing = 0;
        var left = picked.Pixels.ToArray(); var right = plain.Pixels.ToArray();
        for (var index = 0; index < left.Length; index++) if (Math.Abs(left[index] - right[index]) > 8) differing++;
        Assert.True(differing > left.Length / 1000, $"{differing} differing bytes");
    }

    [Fact]
    public async Task ExportAllRendersThreeClipsInThreeStyles()
    {
        var project = ThreeClips();
        string[] styles = [];
        foreach (var clip in project.Edits.Clips)
            styles = [.. styles, (await ExportClipAsync(project, clip.Id)).Snapshot.Captions!.Style.Id];
        // Claude's pick, the user's own choice, and the project default for the clip without a pick.
        Assert.Equal(["punch-in", "minimal", "vox-bold"], styles);
        // A fixed clip style is never overridden by Claude's pick; the user's own choice still is the clip's.
        var fixedStyle = project with { ClipStyle = project.ClipStyle!.FixingCaptions("vox-bold") };
        Assert.Equal("vox-bold", (await ExportClipAsync(fixedStyle, "clip-a")).Snapshot.Captions!.Style.Id);
        Assert.Equal("minimal", (await ExportClipAsync(fixedStyle, "clip-b")).Snapshot.Captions!.Style.Id);
        // The full video renders in the project default.
        var (exit, full, output) = await ClipRenderCliTests.ExportStyledAsync(project, [], []);
        Assert.True(exit == 0, output);
        Assert.Equal("vox-bold", full!.Snapshot.Captions!.Style.Id);
    }
}
