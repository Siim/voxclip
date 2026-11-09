using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Frames;

/// <summary>The faces one frame shows, as the Mac's <c>AppleFrameVision.observe</c> makes them: how many faces were found and the
/// largest one (ADR-R48). A frame with no face is <c>(0, null)</c>; that is a measurement, which only an installed face source
/// makes (<see cref="FrameFaces"/>).</summary>
public sealed record FrameFaceFindings
{
    /// <summary>Findings of <paramref name="faceCount"/> faces, <paramref name="largest"/> the largest. A count of 0 has no face, and
    /// any other count has one.</summary>
    public FrameFaceFindings(int faceCount, FrameFace? largest)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(faceCount);
        if ((faceCount == 0) != (largest is null))
            throw new ArgumentException("A frame's largest face is there exactly when its face count is above 0.", nameof(largest));
        FaceCount = faceCount;
        Largest = largest;
    }

    /// <summary>How many faces were found.</summary>
    public int FaceCount { get; }
    /// <summary>The face the frame's observation carries, or null when there is none: the largest, as on the Mac, except that on
    /// Windows a face inside a screen or a weak detection gives way to the speaker's (<see cref="SpeakerFace"/>).</summary>
    public FrameFace? Largest { get; }

    /// <summary><paramref name="observation"/> with these faces (its text and screens are the screen scan's).</summary>
    public FrameObservation ApplyTo(FrameObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        return observation with { FaceCount = FaceCount, Face = Largest };
    }
}

/// <summary>Faces in a frame on Windows: the seam between the frame analyzer and the face models (ADR-R48 Windows). W3's
/// <c>OnnxFrameFaces</c> (YuNet and Face Mesh V2 on the pinned ONNX Runtime) implements it; tests stub it. The analyzer calls it
/// from several decoding lanes at once, so an implementation must take concurrent calls (an ONNX Runtime session does).</summary>
public interface IFrameFaces
{
    /// <summary>The faces in <paramref name="frame"/>: premultiplied BGRA as <c>CurrentFrames</c> decodes it, upright, at most
    /// 1,280 px on the long side. The speaker's face (<see cref="SpeakerFace"/>: the largest, unless it is inside one of
    /// <paramref name="screens"/> or a weak detection beside a confident one) has its rect in picture space (normalized, top-left
    /// origin), its yaw and pitch in radians as the post-fix Mac reports them. <paramref name="screens"/> are the frame's screen rects
    /// in picture space, empty when the frame had no screen scan.</summary>
    Task<FrameFaceFindings> FacesAsync(PixelBuffer frame, IReadOnlyList<ClipEffectRect> screens, CancellationToken ct);
}

/// <summary>Whether faces can be measured on this PC. The face source is nullable where the App and the CLI are put together:
/// null is <em>faces unavailable</em> (the models are not installed, or not yet released), and then nothing is analyzed. The
/// analyzer never makes an observation without a face source, so no caller ever reads an invented "no face" (<c>faceCount: 0</c>),
/// and the App hides what needs faces.</summary>
public static class FrameFaces
{
    /// <summary>The line a caller shows or prints when faces are unavailable.</summary>
    public const string UnavailableMessage = "The face models aren't installed on this PC, so faces in the video's frames can't be measured. Nothing was analyzed.";

    /// <summary><paramref name="faces"/>, or <see cref="FrameFacesUnavailableException"/> when it is null.</summary>
    public static IFrameFaces Require(IFrameFaces? faces) => faces ?? throw new FrameFacesUnavailableException();
}

/// <summary>Faces unavailable: no face source is installed. It is <see cref="VoxClipErrorCode.ModelMissing"/>, so the CLI exits 7 with
/// <c>modelMissing</c>, as the Mac does for a missing model.</summary>
public sealed class FrameFacesUnavailableException() : VoxClipException(VoxClipErrorCode.ModelMissing, FrameFaces.UnavailableMessage);
