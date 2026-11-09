// The Windows half of the face calibration (tools/frames/calibrate, ADR-R48 Windows, W7).
//
//   dotnet voxclip-face-calibration.dll <job.json>
//
// The job is JSON: {"out": path, "models": folder, "frames": [{"sha256", "path", "width", "height"}]}, each frame raw RGB24 rows
// as calibrate.py decoded and hashed them. A frame whose bytes no longer hash to its pin is refused (exit 2).
//
// For every frame it writes one JSON line with what the shipped path measured before the catalogue's maps: the face count, the
// speaker's face (SpeakerFace's reading order, W8) with its YuNet box, the raw mean eye ratio of each eye, the mesh's yaw and
// pitch, and the crop's sharpness, luma and clipped share, with the face's width at 1,280 px. It gets them by running the same public steps OnnxFrameFaces runs (YuNet
// on the 640 px input, YuNetDecoder, RotatedCrop, Face Mesh V2, FaceCropStats, FaceMeshFields.Measure), and checks every frame
// against OnnxFrameFaces.Faces itself: the face count and every FrameFace field must be the same, or the run stops (exit 3).
// It also writes every box YuNet kept (largest first, each with the mesh's numbers or null) and the frame's QuadFinder quads,
// which the speaker rule is fitted and checked from.
// So the numbers are the shipped path's, not a twin's. Needs VOXCLIP_SHARED_DIR (the catalogue) and runs two frames at a time,
// each session on two threads.
using System.Buffers;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Frames;
using VoxClip.Media.Frames;

if (args.Length != 1)
{
    Console.Error.WriteLine("usage: voxclip-face-calibration <job.json>");
    return 64;
}
var job = JsonNode.Parse(File.ReadAllText(args[0]))!;
var models = job["models"]!.GetValue<string>();
var output = job["out"]!.GetValue<string>();
var frames = job["frames"]!.AsArray().Select(frame => new Frame(frame!["sha256"]!.GetValue<string>(), frame["path"]!.GetValue<string>(),
    frame["width"]!.GetValue<int>(), frame["height"]!.GetValue<int>())).ToArray();

var catalog = new FrameModelCatalog();
using var production = OnnxFrameFaces.Load(catalog.Entry, models);
using var steps = new Steps(catalog.Entry, models);
var lines = new ConcurrentDictionary<int, string>();
var refused = new ConcurrentBag<string>();
var differing = new ConcurrentBag<string>();
Parallel.For(0, frames.Length, new ParallelOptions { MaxDegreeOfParallelism = 2 }, index =>
{
    var frame = frames[index];
    var rgb = File.ReadAllBytes(frame.Path);
    if (rgb.Length != frame.Width * frame.Height * 3 || Convert.ToHexStringLower(SHA256.HashData(rgb)) != frame.Sha256)
    {
        refused.Add(frame.Path);
        return;
    }
    var buffer = Bgra(rgb, frame.Width, frame.Height);
    var shipped = production.Faces(buffer);
    var measured = steps.Measure(buffer);
    var quads = new QuadFinder().Find(buffer);
    if (shipped.FaceCount != measured.FaceCount || !Equal(shipped.Largest, measured.Face?.Measure.Face))
        differing.Add(frame.Sha256);
    lines[index] = Line(frame.Sha256, measured, quads).ToJsonString();
});
if (!refused.IsEmpty)
{
    Console.Error.WriteLine($"{refused.Count} frame(s) are not the bytes the manifest pins, e.g. {refused.First()}");
    return 2;
}
if (!differing.IsEmpty)
{
    Console.Error.WriteLine($"{differing.Count} frame(s) measured differently from OnnxFrameFaces, e.g. {differing.First()}");
    return 3;
}
File.WriteAllLines(output, Enumerable.Range(0, frames.Length).Select(index => lines[index]));
Console.WriteLine($"{frames.Length} frames, all matching OnnxFrameFaces");
return 0;

static PixelBuffer Bgra(byte[] rgb, int width, int height)
{
    var pixels = new byte[width * height * 4];
    for (var index = 0; index < width * height; index++)
    {
        pixels[index * 4] = rgb[index * 3 + 2];
        pixels[index * 4 + 1] = rgb[index * 3 + 1];
        pixels[index * 4 + 2] = rgb[index * 3];
        pixels[index * 4 + 3] = 255;
    }
    return new PixelBuffer(pixels, width, height, width * 4);
}

static bool Equal(FrameFace? a, FrameFace? b) => a is null || b is null ? a is null && b is null :
    a.Rect.Equals(b.Rect) && a.CaptureQuality == b.CaptureQuality && a.LeftEyeAspect == b.LeftEyeAspect &&
    a.RightEyeAspect == b.RightEyeAspect && a.Yaw == b.Yaw && a.Pitch == b.Pitch && a.Eyes == b.Eyes;

static JsonObject Rect(VoxClip.Core.Domain.Effects.ClipEffectRect rect) =>
    new() { ["x"] = rect.X, ["y"] = rect.Y, ["width"] = rect.Width, ["height"] = rect.Height };

static JsonObject Line(string sha256, Measured measured, IReadOnlyList<FrameQuad> quads)
{
    var line = new JsonObject { ["sha256"] = sha256, ["faceCount"] = measured.FaceCount };
    if (measured.Face is { } face) line["face"] = Candidate(face);
    // Every box YuNet kept, largest first, each with what the mesh measured (null: the mesh found no face in it), and the frame's
    // quads: what the speaker rule is fitted from.
    line["candidates"] = new JsonArray([.. measured.Candidates.Select(candidate => (JsonNode)new JsonObject
    {
        ["rect"] = Rect(candidate.Rect), ["detectorScore"] = candidate.DetectorScore, ["widthAt1280"] = candidate.WidthAt1280,
        ["measured"] = candidate.Face is { } found ? Candidate(found) : null,
    })]);
    line["quads"] = new JsonArray([.. quads.Select(quad => (JsonNode)new JsonObject { ["rect"] = Rect(quad.BoundingBox), ["confidence"] = quad.Confidence })]);
    return line;
}

static JsonObject Candidate(MeasuredFace face)
{
    var parts = face.Measure;
    return new JsonObject
    {
        ["rect"] = Rect(parts.Face.Rect),
        ["detectorScore"] = face.DetectorScore,
        ["presenceLogit"] = face.PresenceLogit,
        ["roll"] = face.Roll,
        ["faceWidthPixels"] = face.WidthAt1280,
        ["rawLeftEye"] = parts.RawLeftEye,
        ["rawRightEye"] = parts.RawRightEye,
        ["meshYaw"] = parts.MeshYaw,
        ["meshPitch"] = parts.MeshPitch,
        ["sharpnessVariance"] = face.Crop.SharpnessVariance,
        ["meanLuma"] = face.Crop.MeanLuma,
        ["clippedFraction"] = face.Crop.ClippedFraction,
    };
}

internal sealed record Frame(string Sha256, string Path, int Width, int Height);

internal sealed record MeasuredFace(FaceMeshMeasure Measure, FaceCropStats Crop, double WidthAt1280, double DetectorScore, double PresenceLogit,
    double Roll);

internal sealed record CandidateFace(VoxClip.Core.Domain.Effects.ClipEffectRect Rect, double DetectorScore, double WidthAt1280, MeasuredFace? Face);

internal sealed record Measured(int FaceCount, MeasuredFace? Face, IReadOnlyList<CandidateFace> Candidates);

/// <summary>OnnxFrameFaces' steps, kept open so the parts before the maps can be read; the same inputs, outputs and order.</summary>
internal sealed class Steps : IDisposable
{
    private static readonly string[] DetectorOutputs = [.. new[] { "cls", "obj", "bbox", "kps" }
        .SelectMany(kind => YuNetDecoder.Strides.Select(stride => YuNetDecoder.OutputName(kind, stride)))];
    private readonly InferenceSession detector;
    private readonly InferenceSession mesh;
    private readonly FrameFaceCalibration calibration;

    public Steps(FrameModel model, string directory)
    {
        var paths = model.VerifiedFiles(Path.GetFullPath(directory));
        using var options = new SessionOptions
        {
            IntraOpNumThreads = OnnxFrameFaces.IntraOpThreads, GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
        };
        detector = new InferenceSession(File.ReadAllBytes(paths.Detector), options);
        mesh = new InferenceSession(File.ReadAllBytes(paths.Landmarks), options);
        calibration = model.Calibration;
    }

    public Measured Measure(PixelBuffer frame)
    {
        var input = YuNetDecoder.Input(frame.Width, frame.Height);
        var found = Detect(frame, input);
        if (found.Count == 0) return new(0, null, []);
        var rgb = new byte[frame.Width * frame.Height * 3];
        Rgb(frame, rgb);
        // Every box, largest first, measured (the dump the speaker rule is fitted from); then the shipped choice: the boxes in
        // SpeakerFace's reading order (no screens: the calibration has no OCR), the first the mesh confirms.
        var measured = found.ToDictionary(face => face, face => Face(face, input, rgb, frame.Width, frame.Height));
        var candidates = found.OrderByDescending(face => face.Area).Select(face => new CandidateFace(
            face.PictureRect(input.ContentWidth, input.ContentHeight), face.Score,
            face.Width * ((double)FrameAnalyzer.AnalysisEdge / YuNetDecoder.LongSide), measured[face])).ToArray();
        var order = SpeakerFace.ReadingOrder(found, input, [], calibration.SpeakerScore);
        for (var index = 0; index < order.Count; index++)
            if (measured[order[index]] is { } speaker) return new(SpeakerFace.FaceCount(order, index, calibration.SpeakerScore), speaker, candidates);
        return new(0, null, candidates);
    }

    public void Dispose()
    {
        detector.Dispose();
        mesh.Dispose();
    }

    private IReadOnlyList<YuNetFace> Detect(PixelBuffer frame, YuNetInput input)
    {
        var plane = input.Width * input.Height;
        var length = plane * 3;
        var buffer = ArrayPool<float>.Shared.Rent(length);
        try
        {
            var tensor = buffer.AsSpan(0, length);
            tensor.Clear();
            var columns = Taps(frame.Width, input.ContentWidth);
            var rows = Taps(frame.Height, input.ContentHeight);
            var pixels = frame.Pixels.Span;
            for (var y = 0; y < input.ContentHeight; y++)
            {
                var (top, bottom, fy) = rows[y];
                var upper = top * frame.Stride;
                var lower = bottom * frame.Stride;
                for (var x = 0; x < input.ContentWidth; x++)
                {
                    var (left, right, fx) = columns[x];
                    for (var channel = 0; channel < 3; channel++)
                    {
                        double topLeft = pixels[upper + left * 4 + channel], topRight = pixels[upper + right * 4 + channel];
                        double bottomLeft = pixels[lower + left * 4 + channel], bottomRight = pixels[lower + right * 4 + channel];
                        var high = topLeft + (topRight - topLeft) * fx;
                        var low = bottomLeft + (bottomRight - bottomLeft) * fx;
                        tensor[channel * plane + y * input.Width + x] = (float)(high + (low - high) * fy);
                    }
                }
            }
            var value = NamedOnnxValue.CreateFromTensor(OnnxFrameFaces.DetectorInput,
                new DenseTensor<float>(buffer.AsMemory(0, length), [1, 3, input.Height, input.Width]));
            using var results = detector.Run([value], DetectorOutputs);
            return YuNetDecoder.Decode(results.ToDictionary(result => result.Name, Values), input.Width, input.Height);
        }
        finally
        {
            ArrayPool<float>.Shared.Return(buffer);
        }
    }

    private MeasuredFace? Face(YuNetFace face, YuNetInput input, byte[] rgb, int width, int height)
    {
        if (RotatedCrop.FromFace(face, 1 / input.Scale) is not { } crop) return null;
        var sample = crop.Sample(rgb, width, height, width * 3);
        var value = NamedOnnxValue.CreateFromTensor(OnnxFrameFaces.MeshInput, new DenseTensor<float>(sample, [1, crop.CropSize, crop.CropSize, 3]));
        using var results = mesh.Run([value], [OnnxFrameFaces.MeshLandmarks, OnnxFrameFaces.MeshPresence]);
        var landmarks = Values(results.Single(result => result.Name == OnnxFrameFaces.MeshLandmarks));
        var presence = Values(results.Single(result => result.Name == OnnxFrameFaces.MeshPresence))[0];
        if (!FaceMeshFields.Present(presence)) return null;
        var points = new MeshPoint[FaceMeshFields.LandmarkCount];
        for (var index = 0; index < points.Length; index++)
            points[index] = new MeshPoint(landmarks[index * 3], landmarks[index * 3 + 1], landmarks[index * 3 + 2]);
        var stats = FaceCropStats.Measure(sample, crop.CropSize, calibration.Gates);
        var widthAt1280 = face.Width * ((double)FrameAnalyzer.AnalysisEdge / YuNetDecoder.LongSide);
        var measure = FaceMeshFields.Measure(face.PictureRect(input.ContentWidth, input.ContentHeight), widthAt1280, points, stats, calibration);
        return new(measure, stats, widthAt1280, face.Score, presence, crop.Roll);
    }

    private static float[] Values(DisposableNamedOnnxValue result) =>
        result.AsTensor<float>() is DenseTensor<float> dense ? dense.Buffer.ToArray() : [.. result.AsTensor<float>()];

    private static void Rgb(PixelBuffer frame, Span<byte> rgb)
    {
        var pixels = frame.Pixels.Span;
        for (var y = 0; y < frame.Height; y++)
        {
            var source = y * frame.Stride;
            var target = y * frame.Width * 3;
            for (var x = 0; x < frame.Width; x++)
            {
                rgb[target + x * 3] = pixels[source + x * 4 + 2];
                rgb[target + x * 3 + 1] = pixels[source + x * 4 + 1];
                rgb[target + x * 3 + 2] = pixels[source + x * 4];
            }
        }
    }

    private static (int Low, int High, double Weight)[] Taps(int source, int target)
    {
        var taps = new (int, int, double)[target];
        var ratio = (double)source / target;
        for (var index = 0; index < target; index++)
        {
            var position = Math.Max(0, (index + 0.5) * ratio - 0.5);
            var low = Math.Min((int)Math.Floor(position), source - 1);
            var high = Math.Min(low + 1, source - 1);
            taps[index] = (low, high, position - low);
        }
        return taps;
    }
}
