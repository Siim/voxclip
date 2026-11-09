using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>What the capture quality reads from the upright face crop's inner half (the middle 128 × 128 of the 256 px crop):
/// the variance of its 4-neighbour Laplacian, its mean grey and its share of clipped pixels, all on a 0–255 grey scale.</summary>
/// <param name="SharpnessVariance">The Laplacian's variance (population).</param>
/// <param name="MeanLuma">The mean grey, 0–255.</param>
/// <param name="ClippedFraction">The share of grey values below the gates' <c>ClippedBelow</c> or above their <c>ClippedAbove</c>.</param>
public readonly record struct FaceCropStats(double SharpnessVariance, double MeanLuma, double ClippedFraction)
{
    /// <summary>The stats of a crop of <paramref name="size"/>² RGB values in 0–1 (NHWC, the mesh's input). Grey is
    /// 255·(0.299·r + 0.587·g + 0.114·b); the inner half runs from size/4 to size − size/4 on each axis (integer division).</summary>
    public static FaceCropStats Measure(ReadOnlySpan<float> rgb, int size, FrameQualityGates gates)
    {
        if (size < 4 || rgb.Length != size * size * 3) throw new ArgumentException("The crop is not size² RGB values.");
        var grey = new double[size * size];
        for (var index = 0; index < grey.Length; index++)
            grey[index] = 255.0 * (0.299 * rgb[index * 3] + 0.587 * rgb[index * 3 + 1] + 0.114 * rgb[index * 3 + 2]);
        var start = size / 4;
        var end = size - size / 4;
        var count = (end - start) * (end - start);
        var laplacians = new double[count];
        var luma = 0.0;
        var clipped = 0;
        var next = 0;
        for (var y = start; y < end; y++)
        {
            for (var x = start; x < end; x++)
            {
                var centre = grey[y * size + x];
                laplacians[next++] = grey[(y - 1) * size + x] + grey[(y + 1) * size + x] + grey[y * size + x - 1] + grey[y * size + x + 1] - 4.0 * centre;
                luma += centre;
                if (centre < gates.ClippedBelow || centre > gates.ClippedAbove) clipped++;
            }
        }
        var mean = 0.0;
        foreach (var value in laplacians) mean += value;
        mean /= count;
        var variance = 0.0;
        foreach (var value in laplacians) variance += (value - mean) * (value - mean);
        return new FaceCropStats(variance / count, luma / count, (double)clipped / count);
    }
}

/// <summary>The capture quality's parts (ADR-R48, Windows): each term, the gate, the weighted score and the remapped quality.</summary>
/// <param name="EyesOpen">clamp((mean Vision-scale eye ratio − closed) / (open − closed), 0, 1).</param>
/// <param name="Facing">clamp(1 − max(|yaw|, |pitch − pitch0|) / span, 0, 1), on Vision's scale.</param>
/// <param name="Sharp">clamp((ln variance − ln low) / (ln high − ln low), 0, 1); 0 for a flat crop.</param>
/// <param name="Gate">0 for a face too small, too dark, too bright or too clipped; else 1.</param>
/// <param name="Score">clamp(gate · (w0 + w1·eyesOpen·facing + w2·sharp), 0, 1).</param>
/// <param name="Quality">The score through the calibration's quantile remap, clamped to 0–1.</param>
public sealed record FaceQualityParts(double EyesOpen, double Facing, double Sharp, double Gate, double Score, double Quality);

/// <summary>Everything <see cref="FaceMeshFields.Measure"/> works out on the way to a <see cref="FrameFace"/>.</summary>
/// <param name="RawLeftEye">The subject's left eye's mesh ratio (<see cref="EyeAspect.Ratio"/> of its 16-point contour), or null.</param>
/// <param name="RawRightEye">The subject's right eye's mesh ratio, or null.</param>
/// <param name="MeshYaw">The mesh's yaw before the map, or null.</param>
/// <param name="MeshPitch">The mesh's pitch before the map, or null.</param>
/// <param name="Quality">The quality's parts, or null when the eyes or the pose could not be measured.</param>
/// <param name="Face">The face, on Vision's scales.</param>
public sealed record FaceMeshMeasure(double? RawLeftEye, double? RawRightEye, double? MeshYaw, double? MeshPitch, FaceQualityParts? Quality, FrameFace Face);

/// <summary>The <see cref="FrameFace"/> fields from Face Mesh V2's 478 landmarks on the upright crop (ADR-R48, Windows; the study's
/// "How the chosen pair produces each FrameFace field"). They mean what the post-fix Mac's mean: the rect is the detector box,
/// the eye ratios are the Mac's bounding-box height over width mapped onto Vision's scale (null on a face narrower than
/// <see cref="FrameFaceCalibration.EyesFromWidth"/>), yaw and pitch are mapped onto
/// Vision revision 3's (pitch negative with the head tipped back), and the capture quality is the catalogued formula. Every
/// fitted constant comes from <see cref="FrameFaceCalibration"/>. Pure.</summary>
public static class FaceMeshFields
{
    /// <summary>The mesh's landmark count.</summary>
    public const int LandmarkCount = 478;
    /// <summary>The subject's right eye's contour (on the picture's left): outer corner 33 to inner corner 133 and round.</summary>
    public static readonly IReadOnlyList<int> RightEyeContour = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246];
    /// <summary>The subject's left eye's contour: outer corner 263 to inner corner 362 and round.</summary>
    public static readonly IReadOnlyList<int> LeftEyeContour = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466];
    /// <summary>The subject's right eye's outer corner.</summary>
    public const int RightEyeOuter = 33;
    /// <summary>The subject's left eye's outer corner.</summary>
    public const int LeftEyeOuter = 263;
    /// <summary>The top of the forehead.</summary>
    public const int Forehead = 10;
    /// <summary>The chin.</summary>
    public const int Chin = 152;

    /// <summary>Whether the mesh found a face: its presence logit is at least 0 (sigmoid ≥ 0.5).</summary>
    public static bool Present(double presenceLogit) => presenceLogit >= 0;

    /// <summary>The face from the detector's picture-space <paramref name="rect"/>, its width in pixels of the 1,280 px analysis frame,
    /// the mesh landmarks in upright crop pixels and the crop's stats.</summary>
    public static FrameFace Fields(ClipEffectRect rect, double faceWidthPixels, IReadOnlyList<MeshPoint> mesh, FaceCropStats crop,
        FrameFaceCalibration calibration) => Measure(rect, faceWidthPixels, mesh, crop, calibration).Face;

    /// <summary><see cref="Fields"/> with its parts. Throws <see cref="ArgumentException"/> unless there are 478 landmarks.</summary>
    public static FaceMeshMeasure Measure(ClipEffectRect rect, double faceWidthPixels, IReadOnlyList<MeshPoint> mesh, FaceCropStats crop,
        FrameFaceCalibration calibration)
    {
        if (mesh.Count != LandmarkCount) throw new ArgumentException($"Face Mesh V2 gives {LandmarkCount} landmarks, not {mesh.Count}.");
        var rawLeft = EyeAspect.Ratio(LeftEyeContour.Select(index => (mesh[index].X, mesh[index].Y)).ToArray());
        var rawRight = EyeAspect.Ratio(RightEyeContour.Select(index => (mesh[index].X, mesh[index].Y)).ToArray());
        double? left = rawLeft is { } leftRatio ? calibration.EyeAspect.Apply(leftRatio) : null;
        double? right = rawRight is { } rightRatio ? calibration.EyeAspect.Apply(rightRatio) : null;
        var pose = Pose(mesh);
        double? yaw = pose is { } angles ? calibration.Yaw.Apply(angles.Yaw) : null;
        double? pitch = pose is { } tilt ? calibration.Pitch.Apply(tilt.Pitch) : null;
        var parts = Quality(Mean(left, right), yaw, pitch, faceWidthPixels, crop, calibration);
        // A face narrower than EyesFromWidth reads its eyes too unsteadily to call: the face reports them unknown (null ratios), as the
        // Mac reports a face without eye landmarks. The quality above still uses the measured ratios.
        var readable = faceWidthPixels >= calibration.EyesFromWidth;
        return new FaceMeshMeasure(rawLeft, rawRight, pose?.Yaw, pose?.Pitch, parts,
            new FrameFace(rect, parts?.Quality, readable ? left : null, readable ? right : null, yaw, pitch));
    }

    /// <summary>The mesh's yaw and pitch, radians, from its face axes: x̂ = p263 − p33 (eye corners), ŷ = p152 − p10 (forehead to chin)
    /// made orthogonal to x̂; yaw = atan2(x̂.z, x̂.x), pitch = atan2(−ŷ.z, ŷ.y). Null when an axis has no length.</summary>
    public static (double Yaw, double Pitch)? Pose(IReadOnlyList<MeshPoint> mesh)
    {
        if (mesh.Count != LandmarkCount) return null;
        var across = Minus(mesh[LeftEyeOuter], mesh[RightEyeOuter]);
        var down = Minus(mesh[Chin], mesh[Forehead]);
        var length = Dot(across, across);
        if (!(length > 0) || !double.IsFinite(length)) return null;
        var along = Dot(down, across) / length;
        var upright = new MeshPoint(down.X - along * across.X, down.Y - along * across.Y, down.Z - along * across.Z);
        var height = Dot(upright, upright);
        if (!(height > 0) || !double.IsFinite(height)) return null;
        return (Math.Atan2(across.Z, across.X), Math.Atan2(-upright.Z, upright.Y));
    }

    /// <summary>The capture quality's parts from the mean Vision-scale eye ratio, Vision-scale yaw and pitch, the face's width at
    /// 1,280 px and the crop's stats; null when the eyes or the pose were not measured.</summary>
    public static FaceQualityParts? Quality(double? eyeAspect, double? yaw, double? pitch, double faceWidthPixels, FaceCropStats crop,
        FrameFaceCalibration calibration)
    {
        if (eyeAspect is not { } eyes || yaw is not { } turn || pitch is not { } tilt || !double.IsFinite(eyes) || !double.IsFinite(turn) ||
            !double.IsFinite(tilt)) return null;
        var c = calibration;
        var eyesOpen = Math.Clamp((eyes - c.EyesClosedAt) / (c.EyesOpenAt - c.EyesClosedAt), 0, 1);
        var facing = Math.Clamp(1 - Math.Max(Math.Abs(turn), Math.Abs(tilt - c.Pitch0)) / c.FacingSpan, 0, 1);
        var sharp = Sharpness(crop.SharpnessVariance, c);
        var gates = c.Gates;
        var gate = faceWidthPixels >= gates.MinimumFaceWidth && crop.MeanLuma >= gates.LumaLow && crop.MeanLuma <= gates.LumaHigh &&
            crop.ClippedFraction <= gates.ClippedFraction ? 1.0 : 0.0;
        var score = Math.Clamp(gate * (c.W0 + c.W1 * eyesOpen * facing + c.W2 * sharp), 0, 1);
        return new FaceQualityParts(eyesOpen, facing, sharp, gate, score, Math.Clamp(c.Remap(score), 0, 1));
    }

    /// <summary>The sharpness term from the crop's Laplacian variance: 0 at or below the calibration's low variance, 1 at or above
    /// its high one, linear in ln variance between.</summary>
    public static double Sharpness(double variance, FrameFaceCalibration calibration)
    {
        if (!(variance > 0) || !double.IsFinite(variance)) return variance == double.PositiveInfinity ? 1 : 0;
        var low = Math.Log(calibration.SharpLow);
        return Math.Clamp((Math.Log(variance) - low) / (Math.Log(calibration.SharpHigh) - low), 0, 1);
    }

    private static double? Mean(double? left, double? right)
    {
        var count = 0;
        var total = 0.0;
        foreach (var value in new[] { left, right })
        {
            if (value is not { } ratio || !double.IsFinite(ratio)) continue;
            total += ratio;
            count++;
        }
        return count == 0 ? null : total / count;
    }

    private static MeshPoint Minus(MeshPoint a, MeshPoint b) => new(a.X - b.X, a.Y - b.Y, a.Z - b.Z);
    private static double Dot(MeshPoint a, MeshPoint b) => a.X * b.X + a.Y * b.Y + a.Z * b.Z;
}
