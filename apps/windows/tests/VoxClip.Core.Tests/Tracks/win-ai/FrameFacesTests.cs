using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The face seam (ADR-R48 Windows, W5): findings as the Mac's <c>observe</c> makes them, and faces unavailable as its own
/// state, never an invented "no face".</summary>
[Trait("Track", "win-ai")]
public sealed class FrameFacesTests
{
    [Fact]
    public void FindingsCarryTheCountAndTheLargestFaceOntoAnObservation()
    {
        var face = new FrameFace(new ClipEffectRect(0.4, 0.2, 0.2, 0.3), 0.6, 0.3, 0.32, 0.05, -0.1);
        var observation = new FrameObservation(1.25) { TextRects = [new(0.1, 0.1, 0.2, 0.05)] };
        var applied = new FrameFaceFindings(2, face).ApplyTo(observation);
        Assert.Equal((2, face, 1.25), (applied.FaceCount, applied.Face, applied.Time));
        Assert.Single(applied.TextRects);
        Assert.Equal((0, (FrameFace?)null), (new FrameFaceFindings(0, null).ApplyTo(observation).FaceCount, new FrameFaceFindings(0, null).Largest));
    }

    [Fact]
    public void ACountWithoutAFaceOrAFaceWithoutACountIsRefused()
    {
        var face = new FrameFace(new ClipEffectRect(0.4, 0.2, 0.2, 0.3));
        Assert.Throws<ArgumentException>(() => new FrameFaceFindings(1, null));
        Assert.Throws<ArgumentException>(() => new FrameFaceFindings(0, face));
        Assert.Throws<ArgumentOutOfRangeException>(() => new FrameFaceFindings(-1, null));
    }

    /// <summary>No face source is its own state: <c>modelMissing</c>, exit 7 in the CLI, with the line that says the models aren't
    /// installed.</summary>
    [Fact]
    public void NoFaceSourceIsFacesUnavailableNotNoFace()
    {
        var error = Assert.Throws<FrameFacesUnavailableException>(() => FrameFaces.Require(null));
        Assert.Equal((VoxClipErrorCode.ModelMissing, "modelMissing", 7), (error.Code, error.WireCode, error.ExitCode));
        Assert.Equal(FrameFaces.UnavailableMessage, error.Message);
        Assert.StartsWith("The face models aren't installed on this PC", error.Message, StringComparison.Ordinal);
    }
}
