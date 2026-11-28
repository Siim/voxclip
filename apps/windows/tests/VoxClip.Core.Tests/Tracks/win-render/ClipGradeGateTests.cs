using VoxClip.Core.Domain.Clips;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>The picture gates (looks spec 2026-11-28, section 5.8): a Fix at any amount, or above amount 0 a look, an adjustment
/// or any grade value grades the picture; at amount 0 without a Fix nothing does, so the frame is left as it is.</summary>
public sealed class ClipGradeGateTests
{
    private static readonly ProjectClipControls Basis = new("c", 1, null, ClipLook.Original, 0, 0, 0, false, false, 0);

    public static TheoryData<string, ProjectClipControls, bool> Cases => new()
    {
        { "defaults", Basis, false },
        { "a base look", Basis with { Look = ClipLook.Bw }, true },
        { "adjustments", Basis with { ColorAdjustments = new(0, 0, 0, 5) }, true },
        { "a Fix", Basis with { ColorGrade = new() { Tint = 3 } }, true },
        { "a Fix at amount 0", Basis with { Look = ClipLook.Warm, ColorGrade = new() { Amount = 0, Exposure = -10 } }, true },
        { "highlights", Basis with { ColorGrade = new() { Highlights = -20 } }, true },
        { "a preset curve", Basis with { ColorGrade = new() { Curve = new(new ClipCurveChannel(0, 260, 500, 740, 1000)) } }, true },
        { "a vignette alone", Basis with { ColorGrade = new() { Vignette = 10 } }, true },
        { "grain alone", Basis with { ColorGrade = new() { Grain = 10 } }, true },
        { "a look at 40%", Basis with { Look = ClipLook.Muted, ColorGrade = new() { Amount = 40, Preset = "muted" } }, true },
        { "everything at amount 0", Basis with { Look = ClipLook.Warm, ColorAdjustments = new(10, 10, 10, 10),
            ColorGrade = new() { Amount = 0, Highlights = 30, Vibrance = 20, Fade = 10, Vignette = 80, Grain = 40 } }, false },
        { "an amount with nothing to blend", Basis with { ColorGrade = new() { Amount = 50, Preset = "original" } }, false },
    };

    [Theory]
    [MemberData(nameof(Cases))]
    public void TheGradeGateFollowsWhatChangesThePicture(string name, ProjectClipControls controls, bool grades)
    {
        Assert.True(grades == controls.HasColorGrade(), name);
        Assert.True(grades == controls.ChangesPicture(), name);
        var recipe = ClipGradeRecipe.For(controls);
        Assert.True(grades == (recipe.ChangesColor || recipe.HasFinish), name);
    }

    [Fact]
    public void AFlipOrTurnStillChangesThePictureAtAmountZero()
    {
        var silent = Basis with { Look = ClipLook.Warm, ColorGrade = new() { Amount = 0 } };
        Assert.False(silent.HasColorGrade());
        Assert.True((silent with { FlipHorizontal = true }).ChangesPicture());
        Assert.True((silent with { RotationDegrees = 90 }).ChangesPicture());
        Assert.False((Basis with { GainDb = 3 }).ChangesPicture());
    }
}
