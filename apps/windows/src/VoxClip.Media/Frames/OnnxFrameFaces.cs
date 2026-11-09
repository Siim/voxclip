using System.Buffers;
using System.Security.Cryptography;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Frames;

/// <summary>Faces in a frame on Windows (ADR-R48 Windows, W3): YuNet finds the faces on the frame scaled to a 640 px long side,
/// the speaker's (<see cref="SpeakerFace"/>; usually the largest) roll-aligned 256 px crop is cut from the frame itself, Face Mesh V2 reads it, and <see cref="FaceMeshFields"/>
/// turns the 478 landmarks into the Mac's <see cref="FrameFace"/> fields with the catalogue's calibration. The two bundled models
/// load only after <see cref="FrameModel.VerifiedFiles"/> has checked their sizes and hashes, and the bytes handed to ONNX Runtime
/// are hashed again, so a file swapped between the check and the load is refused too.</summary>
/// <remarks>One <see cref="InferenceSession"/> per model, made once with <see cref="IntraOpThreads"/> threads, serves every lane:
/// ONNX Runtime documents <c>Run</c> as safe to call concurrently on one session, and everything else a call touches is its own
/// (buffers are per call). <see cref="Dispose"/> waits for calls in flight; a call after it throws
/// <see cref="ObjectDisposedException"/>.</remarks>
public sealed class OnnxFrameFaces : IFrameFaces, IDisposable
{
    /// <summary>Set to <c>1</c>, it lets tests and developers (the W7 calibration run) use the bundled faces while the catalogue is
    /// still switched off. Shipping builds never set it, so faces stay unavailable until the catalogue is enabled.</summary>
    public const string OverrideVariable = "VOXCLIP_FRAME_FACES";
    /// <summary>ONNX Runtime's intra-op threads per session, as the speaker check uses.</summary>
    public const int IntraOpThreads = 2;
    /// <summary>The detector's input name.</summary>
    public const string DetectorInput = "input";
    /// <summary>The mesh's input name: 1 × 256 × 256 × 3 RGB in 0–1.</summary>
    public const string MeshInput = "input_12";
    /// <summary>The mesh's landmarks: 478 × (x, y, z) in crop pixels.</summary>
    public const string MeshLandmarks = "Identity";
    /// <summary>The mesh's face-presence logit.</summary>
    public const string MeshPresence = "Identity_1";

    private static readonly string[] DetectorOutputs = [.. new[] { "cls", "obj", "bbox", "kps" }
        .SelectMany(kind => YuNetDecoder.Strides.Select(stride => YuNetDecoder.OutputName(kind, stride)))];
    private static readonly string[] MeshOutputs = [MeshLandmarks, MeshPresence];

    private readonly InferenceSession detector;
    private readonly InferenceSession mesh;
    private readonly FrameFaceCalibration calibration;
    private readonly ReaderWriterLockSlim life = new(LockRecursionPolicy.NoRecursion);
    private bool disposed;

    private OnnxFrameFaces(InferenceSession detector, InferenceSession mesh, FrameFaceCalibration calibration)
    {
        this.detector = detector;
        this.mesh = mesh;
        this.calibration = calibration;
    }

    /// <summary>Where the app and the CLI have the bundled models: <c>models/frames</c> beside the executable.</summary>
    public static string BundledDirectory(string? executableDirectory = null) =>
        Path.Combine(executableDirectory ?? AppContext.BaseDirectory, "models", "frames");

    /// <summary>Whether <see cref="OverrideVariable"/> is set to <c>1</c>.</summary>
    public static bool Overridden() => Environment.GetEnvironmentVariable(OverrideVariable) == "1";

    /// <summary>The face source this PC has, or null when faces are unavailable: the catalogue is off (and not
    /// <paramref name="overridden"/>, by default <see cref="Overridden"/>), the catalogue or a file is missing or not the catalogued
    /// bytes, or ONNX Runtime can't load them. Never throws for those; the caller hides what needs faces.</summary>
    public static OnnxFrameFaces? Installed(FrameModelCatalog? catalog = null, string? directory = null, bool? overridden = null)
    {
        try
        {
            catalog ??= new FrameModelCatalog();
            if (!catalog.Enabled && !(overridden ?? Overridden())) return null;
            return Load(catalog.Entry, directory ?? BundledDirectory());
        }
        catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException or OnnxRuntimeException
            or VoxClipException)
        {
            return null;
        }
    }

    /// <summary>The faces from <paramref name="model"/>'s two files in <paramref name="directory"/>, whether or not the catalogue is
    /// enabled. Throws <see cref="InvalidDataException"/> when a file is missing, altered or not the expected graph.</summary>
    public static OnnxFrameFaces Load(FrameModel model, string directory)
    {
        ArgumentNullException.ThrowIfNull(model);
        var paths = model.VerifiedFiles(Path.GetFullPath(directory));
        var detectorBytes = Verified(paths.Detector, model.Detector);
        var meshBytes = Verified(paths.Landmarks, model.Landmarks);
        InferenceSession? detector = null;
        InferenceSession? mesh = null;
        try
        {
            using var options = new SessionOptions { IntraOpNumThreads = IntraOpThreads, GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL };
            detector = new InferenceSession(detectorBytes, options);
            mesh = new InferenceSession(meshBytes, options);
            if (!detector.InputMetadata.Keys.SequenceEqual([DetectorInput]) || !DetectorOutputs.All(detector.OutputMetadata.ContainsKey) ||
                !mesh.InputMetadata.Keys.SequenceEqual([MeshInput]) || !MeshOutputs.All(mesh.OutputMetadata.ContainsKey))
                throw new InvalidDataException("The face models don't have the expected inputs and outputs.");
            var faces = new OnnxFrameFaces(detector, mesh, model.Calibration);
            detector = mesh = null;
            return faces;
        }
        finally
        {
            detector?.Dispose();
            mesh?.Dispose();
        }
    }

    /// <inheritdoc/>
    public Task<FrameFaceFindings> FacesAsync(PixelBuffer frame, IReadOnlyList<ClipEffectRect> screens, CancellationToken ct)
    {
        try
        {
            return Task.FromResult(Faces(frame, screens, ct));
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return Task.FromCanceled<FrameFaceFindings>(ct);
        }
        catch (Exception error)
        {
            return Task.FromException<FrameFaceFindings>(error);
        }
    }

    /// <summary>The faces in a frame without a screen scan: <see cref="Faces(PixelBuffer, IReadOnlyList{ClipEffectRect}, CancellationToken)"/>
    /// with no screens.</summary>
    public FrameFaceFindings Faces(PixelBuffer frame, CancellationToken ct = default) => Faces(frame, [], ct);

    /// <summary>The faces in <paramref name="frame"/> (premultiplied BGRA, upright, as <c>CurrentFrames</c> decodes it): how many YuNet
    /// kept and the speaker's fields. The boxes are read in <see cref="SpeakerFace.ReadingOrder"/> (outside <paramref name="screens"/>
    /// first, then confident detections, then the larger); when the mesh finds no face in a box (presence below 0.5), that box is not
    /// a face: it is not counted and the next one is read instead. The count is <see cref="SpeakerFace.FaceCount"/>: the speaker and
    /// the confident boxes not read.</summary>
    public FrameFaceFindings Faces(PixelBuffer frame, IReadOnlyList<ClipEffectRect> screens, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(frame);
        ArgumentNullException.ThrowIfNull(screens);
        if (frame.Width <= 0 || frame.Height <= 0 || frame.Stride < frame.Width * 4 ||
            frame.Pixels.Length < (long)frame.Stride * (frame.Height - 1) + frame.Width * 4)
            throw new ArgumentException("The frame buffer is smaller than its size.", nameof(frame));
        life.EnterReadLock();
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            ct.ThrowIfCancellationRequested();
            var input = YuNetDecoder.Input(frame.Width, frame.Height);
            var found = Detect(frame, input);
            if (found.Count == 0) return new FrameFaceFindings(0, null);
            var rgbLength = frame.Width * frame.Height * 3;
            var rgb = ArrayPool<byte>.Shared.Rent(rgbLength);
            try
            {
                Rgb(frame, rgb);
                var order = SpeakerFace.ReadingOrder(found, input, screens, calibration.SpeakerScore);
                for (var index = 0; index < order.Count; index++)
                {
                    ct.ThrowIfCancellationRequested();
                    if (Measure(order[index], input, rgb.AsSpan(0, rgbLength), frame.Width, frame.Height) is { } measured)
                        return new FrameFaceFindings(SpeakerFace.FaceCount(order, index, calibration.SpeakerScore), measured);
                }
                return new FrameFaceFindings(0, null);
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(rgb);
            }
        }
        finally
        {
            life.ExitReadLock();
        }
    }

    /// <summary>Waits for calls in flight, then frees both sessions.</summary>
    public void Dispose()
    {
        life.EnterWriteLock();
        try
        {
            if (disposed) return;
            disposed = true;
            detector.Dispose();
            mesh.Dispose();
        }
        finally
        {
            life.ExitWriteLock();
        }
    }

    private static byte[] Verified(string path, FrameModelFile file)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.LongLength != file.Bytes || Convert.ToHexStringLower(SHA256.HashData(bytes)) != file.Sha256)
            throw new InvalidDataException(file.Name + " changed after it was checked.");
        return bytes;
    }

    /// <summary>YuNet on the frame scaled to the detector input (bilinear at pixel centres, as OpenCV's resize), BGR 0–255 NCHW, the
    /// padding black; decoded by <see cref="YuNetDecoder"/>.</summary>
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
            var value = NamedOnnxValue.CreateFromTensor(DetectorInput,
                new DenseTensor<float>(buffer.AsMemory(0, length), [1, 3, input.Height, input.Width]));
            using var results = detector.Run([value], DetectorOutputs);
            var outputs = results.ToDictionary(result => result.Name, Values);
            return YuNetDecoder.Decode(outputs, input.Width, input.Height);
        }
        finally
        {
            ArrayPool<float>.Shared.Return(buffer);
        }
    }

    /// <summary>The mesh on the face's crop, and its fields; null when the crop can't be made or the mesh finds no face.</summary>
    private FrameFace? Measure(YuNetFace face, YuNetInput input, ReadOnlySpan<byte> rgb, int width, int height)
    {
        if (RotatedCrop.FromFace(face, 1 / input.Scale) is not { } crop) return null;
        var sample = crop.Sample(rgb, width, height, width * 3);
        var value = NamedOnnxValue.CreateFromTensor(MeshInput, new DenseTensor<float>(sample, [1, crop.CropSize, crop.CropSize, 3]));
        using var results = mesh.Run([value], MeshOutputs);
        var landmarks = Values(results.Single(result => result.Name == MeshLandmarks));
        var presence = Values(results.Single(result => result.Name == MeshPresence));
        if (landmarks.Length != FaceMeshFields.LandmarkCount * 3 || presence.Length != 1)
            throw new InvalidDataException("Face Mesh V2 answered with the wrong shape.");
        if (!FaceMeshFields.Present(presence[0])) return null;
        var points = new MeshPoint[FaceMeshFields.LandmarkCount];
        for (var index = 0; index < points.Length; index++)
            points[index] = new MeshPoint(landmarks[index * 3], landmarks[index * 3 + 1], landmarks[index * 3 + 2]);
        var stats = FaceCropStats.Measure(sample, crop.CropSize, calibration.Gates);
        // The gate's width is on the 1,280 px analysis frame; the detector input is always 640 px on the long side.
        var widthAt1280 = face.Width * ((double)FrameAnalyzer.AnalysisEdge / YuNetDecoder.LongSide);
        return FaceMeshFields.Fields(face.PictureRect(input.ContentWidth, input.ContentHeight), widthAt1280, points, stats, calibration);
    }

    private static float[] Values(DisposableNamedOnnxValue result) =>
        result.AsTensor<float>() is DenseTensor<float> dense ? dense.Buffer.ToArray() : [.. result.AsTensor<float>()];

    /// <summary>The frame as RGB24 (the alpha dropped: decoded video is opaque, so premultiplied is straight).</summary>
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

    /// <summary>For each of <paramref name="target"/> output samples along an axis of <paramref name="source"/> pixels: the two source
    /// pixels and the weight of the second, sampling at pixel centres with the edges repeated.</summary>
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
