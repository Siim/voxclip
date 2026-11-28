using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The colour grade in the one compose path preview and export share (looks spec 2026-11-28, sections 5.2, 5.7, 5.8 and
/// 11.2): FrameComposer grades with the clip's whole grade, gates on what changes the picture, finishes after the motion crop
/// with the rendered frame's grain, and leaves grain out of a context demo. These run on synthetic frames without FFmpeg.</summary>
public sealed class ClipGradeComposeTests
{
    private const int Rate = 48_000;

    private static ProjectClipControls Controls(ClipLook look = ClipLook.Original, ClipColorAdjustments? adjustments = null, ClipColorGrade? grade = null,
        double speed = 1) => ClipGradeMediaTests.Basis with { Speed = speed, Look = look, ColorAdjustments = adjustments, ColorGrade = grade };

    private static ComposeSnapshot Snapshot(ClipRenderInput? clip, PixelSize? size = null, long samples = 480_000)
    {
        var output = size ?? new PixelSize(320, 180);
        return new(new("synthetic.mp4", samples / (double)Rate, new(output.Width, output.Height, 30, 0), new(Rate, 2), output, "h264", "aac", false, 0, 1, 0),
            TestPlan.FromKept(Rate, samples, [new(0, samples)]), null, new(output, 30, 1_000_000)) { Clip = clip };
    }

    private static PixelBuffer Copy(PixelBuffer frame) => new(frame.Pixels.ToArray(), frame.Width, frame.Height, frame.Stride);

    private static PixelBuffer Grey(int width, int height, byte value = 150)
    {
        var pixels = new byte[width * height * 4];
        Array.Fill(pixels, value);
        for (var index = 3; index < pixels.Length; index += 4) pixels[index] = 255;
        return new(pixels, width, height, width * 4);
    }

    private static PixelBuffer Finished(PixelBuffer frame, ComposeSnapshot snapshot, double editedTime)
    {
        var result = Copy(frame);
        new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot)
            .FinishClipFrame(result, snapshot, editedTime, frame.Width, frame.Height, new(0, 0, frame.Width, frame.Height), CancellationToken.None);
        return result;
    }

    /// <summary>The reference: the grade, then the finish with the frame index <paramref name="index"/>.</summary>
    private static PixelBuffer Expected(PixelBuffer frame, ClipGradeRecipe recipe, uint index, ClipGrain.Hole? hole = null)
    {
        var result = Copy(frame);
        ClipPicture.Grade(result, recipe, CancellationToken.None);
        ClipPicture.Finish(result, recipe, ClipGrain.FrameHash(index), hole, CancellationToken.None);
        return result;
    }

    [Fact]
    public void AtAmountZeroWithoutAFixNothingTouchesThePicture()
    {
        var frame = ClipGradeMediaTests.Gradient(320, 180);
        var controls = Controls(ClipLook.Warm, new(10, 20, 30, 40), new ClipColorGrade { Amount = 0, Highlights = 30, Vignette = 80, Grain = 40 });
        Assert.Equal(frame.Pixels.ToArray(), Finished(frame, Snapshot(new(controls, null)), 1).Pixels.ToArray());
        Assert.False(controls.HasColorGrade());
        Assert.False(controls.ChangesPicture());
    }

    [Fact]
    public void AFixAloneGradesAndAtAmountZeroStillApplies()
    {
        var frame = ClipGradeMediaTests.Gradient(320, 180);
        foreach (var grade in new[] { new ClipColorGrade { Exposure = 40, Temperature = -30 }, new ClipColorGrade { Amount = 0, Exposure = 40, Vignette = 50 } })
        {
            var controls = Controls(ClipLook.Bw, grade: grade);
            var found = Finished(frame, Snapshot(new(controls, null)), 1);
            Assert.NotEqual(frame.Pixels.ToArray(), found.Pixels.ToArray());
            Assert.Equal(Expected(frame, ClipGradeRecipe.For(controls), 30).Pixels.ToArray(), found.Pixels.ToArray());
            Assert.True(controls.HasColorGrade() && controls.ChangesPicture());
        }
    }

    [Fact]
    public void TheWholeGradeAndTheFinishRunOnTheFrame()
    {
        var frame = ClipGradeMediaTests.Gradient(320, 180);
        var library = ClipLookLibrary.Load(FixtureLoader.SharedRoot);
        var controls = ClipGradeMediaTests.Basis.WithLook(library.Look("warmPrint")!, 70, new(20, 15, -10)) is var look
            ? look with { ColorGrade = look.ColorGrade! with { Vignette = 30, Grain = 25 } } : null!;
        var found = Finished(frame, Snapshot(new(controls, null)), 0.5);
        Assert.Equal(Expected(frame, ClipGradeRecipe.For(controls), 15).Pixels.ToArray(), found.Pixels.ToArray());
    }

    [Fact]
    public void TheFinishRunsAfterTheMotionCropSoAZoomNeverScalesTheVignette()
    {
        // A flat picture is the same zoomed or not, so only the vignette's place can tell the order apart.
        var frame = Grey(320, 180);
        var zoom = new MotionCue("c-zoom-0", "c", 0.5, 2.5, [new(0, 1, 0.5, 0.5), new(1, 1.3, 0.25, 0.75)]);
        var controls = Controls(grade: new ClipColorGrade { Vignette = 70 });
        var zoomed = Finished(frame, Snapshot(new(controls, null) { Motion = [zoom] }), 1.5);
        Assert.Equal(Expected(frame, ClipGradeRecipe.For(controls), 45).Pixels.ToArray(), zoomed.Pixels.ToArray());
    }

    [Fact]
    public void GrainFollowsTheRenderedFrameAtTheClipsSpeed()
    {
        var frame = ClipGradeMediaTests.Gradient(320, 180);
        var controls = Controls(grade: new ClipColorGrade { Grain = 60 }, speed: 2);
        var snapshot = Snapshot(new(controls, null));
        // Edited second 1.0 renders at 0.5 s: frame 15 at 30 fps.
        Assert.Equal(15u, FrameComposer.RenderedFrameIndex(snapshot, 1.0));
        var found = Finished(frame, snapshot, 1.0);
        Assert.Equal(Expected(frame, ClipGradeRecipe.For(controls), 15).Pixels.ToArray(), found.Pixels.ToArray());
        Assert.NotEqual(Expected(frame, ClipGradeRecipe.For(controls), 30).Pixels.ToArray(), found.Pixels.ToArray());
        // A paused frame keeps its grain.
        Assert.Equal(found.Pixels.ToArray(), Finished(frame, snapshot, 1.0).Pixels.ToArray());
    }

    [Theory]
    [InlineData(1.0, false)]
    [InlineData(1.25, false)]
    [InlineData(0.5, false)]
    [InlineData(1.0, true)]
    public void TheExportsFrameIsTheRenderedFrameIndex(double speed, bool part)
    {
        var effects = part ? new ClipEffectsRenderInput([new("fx-speed", "c", "speedForPart", 1, 3) { Rate = 1.5 }], new Dictionary<string, string>()) : null;
        var snapshot = Snapshot(new(Controls(grade: new ClipColorGrade { Grain = 10 }, speed: speed), effects));
        foreach (var fps in new[] { 24.0, 30, 60 })
        {
            var timed = snapshot with { Output = snapshot.Output with { FrameRate = fps } };
            for (long index = 0; index < 4 * fps; index++)
                Assert.Equal((uint)index, FrameComposer.RenderedFrameIndex(timed, Exporter.EditedTime(timed, index, fps)));
        }
    }

    [Fact]
    public void ATimedColourLookReplacesOnlyTheBaseLook()
    {
        var frame = ClipGradeMediaTests.Gradient(320, 180);
        var grade = new ClipColorGrade { Amount = 70, Exposure = 30, Vibrance = 40, Vignette = 40, Grain = 20 };
        var controls = Controls(ClipLook.Warm, new(5, 10, 0, 0), grade);
        var effects = new ClipEffectsRenderInput([new("fx-look", "c", "colourLook", 1, 3) { Look = "bw" }], new Dictionary<string, string>());
        var found = Finished(frame, Snapshot(new(controls, effects)), 2);
        Assert.Equal(Expected(frame, new ClipGradeRecipe(ClipLook.Bw, controls.ColorAdjustments, grade), 60).Pixels.ToArray(), found.Pixels.ToArray());
    }

    [Fact]
    public void GrainStaysOutOfAContextDemoAndTheVignetteStillCoversIt()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/context-demo/v4-project.voxclip"));
        var plan = TestPlan.FromKept(Rate, 336_000, [new(0, 336_000)]);
        var layers = ContextDemoRendering.Resolve(project, null, new RenderTimeline.Legacy(plan), "/data");
        var times = Enumerable.Range(0, 70).Select(step => step / 10.0).ToArray();
        var demo = times.First(time => layers!.At(time) is not null);
        var plain = times.First(time => layers!.At(time) is null);
        var frame = ClipGradeMediaTests.Gradient(320, 180);
        var grained = Controls(grade: new ClipColorGrade { Vignette = 30, Grain = 80 });
        var snapshot = Snapshot(new(grained, null)) with { Plan = plan, ContextDemo = layers };
        var recipe = ClipGradeRecipe.For(grained);
        var vignetteOnly = ClipGradeRecipe.For(Controls(grade: new ClipColorGrade { Vignette = 30 }));
        var index = FrameComposer.RenderedFrameIndex(snapshot, demo);
        Assert.Equal(Expected(frame, vignetteOnly, index).Pixels.ToArray(), Finished(frame, snapshot, demo).Pixels.ToArray());
        Assert.Equal(Expected(frame, recipe, FrameComposer.RenderedFrameIndex(snapshot, plain)).Pixels.ToArray(),
            Finished(frame, snapshot, plain).Pixels.ToArray());
    }
}
