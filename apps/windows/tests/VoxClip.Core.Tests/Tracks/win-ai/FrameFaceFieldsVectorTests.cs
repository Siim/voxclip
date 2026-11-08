using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The pure steps from the two face models' outputs to a <see cref="FrameFace"/> (ADR-R48 Windows, package W2): every case of
/// shared/fixtures/clip-frames/frame-face-fields-cases.json, which tools/fixtures/clip-frames/generate_face_fields.py writes with
/// pure IEEE series for atan2, exp and ln, so numbers compare within 1e-9 relative. No Mac twin: the Mac reads Vision.</summary>
[Trait("Track", "win-ai")]
public sealed class FrameFaceFieldsVectorTests
{
    private const string Path = "fixtures/clip-frames/frame-face-fields-cases.json";
    private static readonly Lazy<JsonObject> Vectors = new(() => JsonNode.Parse(FixtureLoader.ReadText(Path))!.AsObject());
    private static readonly Lazy<FrameFaceCalibration> Calibration = new(() => new FrameModelCatalog(FixtureLoader.SharedRoot).Entry.Calibration);
    private static IEnumerable<JsonObject> Rows(string key) => Vectors.Value[key]!.AsArray().Select(row => row!.AsObject());
    private static string Id(JsonObject row) => row["id"]!.GetValue<string>();
    private static double Number(JsonNode? node) => node!.GetValue<double>();
    private static double? Optional(JsonNode? node) => node is null ? null : node.GetValue<double>();
    private static double[] Numbers(JsonNode? node) => node!.AsArray().Select(Number).ToArray();

    private static void Near(double expected, double actual, string where)
    {
        if (!(Math.Abs(actual - expected) <= 1e-9 * Math.Max(1, Math.Abs(expected))))
            Assert.Fail($"{where}: expected {expected:R}, got {actual:R}");
    }

    private static void Near(double? expected, double? actual, string where)
    {
        if (expected is null || actual is null) Assert.True(expected is null && actual is null, $"{where}: expected {expected}, got {actual}");
        else Near(expected.Value, actual.Value, where);
    }

    private static void SameJson(JsonNode? expected, JsonNode? actual, string where)
    {
        switch (expected)
        {
            case JsonObject value:
                var other = Assert.IsType<JsonObject>(actual);
                Assert.True(value.Select(pair => pair.Key).SequenceEqual(other.Select(pair => pair.Key)), $"{where}: keys {other.ToJsonString()}");
                foreach (var (key, item) in value) SameJson(item, other[key], where + "." + key);
                break;
            case JsonArray list:
                var items = Assert.IsType<JsonArray>(actual);
                Assert.True(list.Count == items.Count, where + ": count");
                for (var index = 0; index < list.Count; index++) SameJson(list[index], items[index], $"{where}[{index}]");
                break;
            case JsonValue scalar when scalar.TryGetValue<double>(out var number):
                Near(number, actual!.GetValue<double>(), where);
                break;
            default:
                Assert.True(JsonNode.DeepEquals(expected, actual), $"{where}: {expected?.ToJsonString()} vs {actual?.ToJsonString()}");
                break;
        }
    }

    private static YuNetFace Face(JsonNode? node) => new(Number(node!["x"]), Number(node["y"]), Number(node["width"]), Number(node["height"]),
        node["points"]!.AsArray().Select(point => new FramePoint(Number(point![0]), Number(point[1]))).ToArray(), Number(node["score"]));

    private static FaceCropStats Stats(JsonNode? node) =>
        new(Number(node!["sharpnessVariance"]), Number(node["meanLuma"]), Number(node["clippedFraction"]));

    private static ClipEffectRect Rect(JsonNode? node) => FrameJson.ReadRect(node) ?? throw new InvalidDataException("not a rect");

    private static void SameParts(JsonNode? expected, FaceQualityParts? actual, string where)
    {
        if (expected is null)
        {
            Assert.True(actual is null, where + ": expected no quality");
            return;
        }
        Assert.NotNull(actual);
        Near(Number(expected["eyesOpen"]), actual.EyesOpen, where + ".eyesOpen");
        Near(Number(expected["facing"]), actual.Facing, where + ".facing");
        Near(Number(expected["sharp"]), actual.Sharp, where + ".sharp");
        Assert.True(Number(expected["gate"]) == actual.Gate, where + ".gate");
        Near(Number(expected["score"]), actual.Score, where + ".score");
        Near(Number(expected["quality"]), actual.Quality, where + ".quality");
    }

    [Fact]
    public void TheFileHasItsSchemaKeysAndCount()
    {
        var root = Vectors.Value;
        string[] sections = ["inputSizes", "decodes", "crops", "samples", "cropStats", "meshes", "qualities"];
        Assert.Equal(new[] { "schema", "description", "constants", "calibration", "caseCount", "counts" }.Concat(sections), root.Select(pair => pair.Key));
        Assert.Equal("voxclip-frame-face-fields-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(81, root["caseCount"]!.GetValue<int>());
        Assert.Equal(sections, root["counts"]!.AsObject().Select(pair => pair.Key));
        Assert.Equal(new[] { 8, 13, 8, 3, 8, 16, 25 }, sections.Select(key => root[key]!.AsArray().Count));
        Assert.All(sections, key => Assert.Equal(root[key]!.AsArray().Count, root["counts"]![key]!.GetValue<int>()));
        Assert.All(sections, key => Assert.Equal(root[key]!.AsArray().Count, Rows(key).Select(Id).Distinct().Count()));
    }

    [Fact]
    public void TheConstantsAreTheCores()
    {
        var constants = Vectors.Value["constants"]!.AsObject();
        Assert.Equal(YuNetDecoder.Strides, constants["strides"]!.AsArray().Select(item => item!.GetValue<int>()));
        Assert.Equal(YuNetDecoder.ScoreThreshold, Number(constants["scoreThreshold"]));
        Assert.Equal(YuNetDecoder.NmsThreshold, Number(constants["nmsThreshold"]));
        Assert.Equal(YuNetDecoder.LongSide, constants["longSide"]!.GetValue<int>());
        Assert.Equal(YuNetDecoder.Alignment, constants["alignment"]!.GetValue<int>());
        Assert.Equal(RotatedCrop.Size, constants["cropSize"]!.GetValue<int>());
        Assert.Equal(RotatedCrop.Expansion, Number(constants["expansion"]));
        Assert.Equal(FaceMeshFields.LandmarkCount, constants["landmarkCount"]!.GetValue<int>());
        Assert.Equal(FaceMeshFields.RightEyeContour, constants["rightEyeContour"]!.AsArray().Select(item => item!.GetValue<int>()));
        Assert.Equal(FaceMeshFields.LeftEyeContour, constants["leftEyeContour"]!.AsArray().Select(item => item!.GetValue<int>()));
        Assert.Equal((FaceMeshFields.RightEyeOuter, FaceMeshFields.LeftEyeOuter, FaceMeshFields.Forehead, FaceMeshFields.Chin),
            (constants["rightEyeOuter"]!.GetValue<int>(), constants["leftEyeOuter"]!.GetValue<int>(), constants["forehead"]!.GetValue<int>(),
                constants["chin"]!.GetValue<int>()));
    }

    [Fact]
    public void TheVectorsUseTheCataloguesCalibration()
    {
        var catalogue = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(FixtureLoader.SharedRoot, "catalog", "frame-models.json")))!;
        Assert.True(JsonNode.DeepEquals(catalogue["models"]![0]!["calibration"], Vectors.Value["calibration"]),
            "Regenerate frame-face-fields-cases.json after changing the catalogue's calibration.");
        Assert.True(Calibration.Value.Provisional);
    }

    [Fact]
    public void InputSizesReplay()
    {
        foreach (var row in Rows("inputSizes"))
        {
            var input = YuNetDecoder.Input(row["frameWidth"]!.GetValue<int>(), row["frameHeight"]!.GetValue<int>());
            var expect = row["expect"]!;
            Assert.True((expect["width"]!.GetValue<int>(), expect["height"]!.GetValue<int>(), expect["contentWidth"]!.GetValue<int>(),
                expect["contentHeight"]!.GetValue<int>()) == (input.Width, input.Height, input.ContentWidth, input.ContentHeight), Id(row));
            Near(Number(expect["scale"]), input.Scale, Id(row));
            Assert.Equal(0, input.Width % 32);
            Assert.Equal(0, input.Height % 32);
        }
    }

    private static Dictionary<string, float[]> Outputs(JsonObject row)
    {
        var (width, height) = (row["inputWidth"]!.GetValue<int>(), row["inputHeight"]!.GetValue<int>());
        var outputs = new Dictionary<string, float[]>();
        foreach (var stride in YuNetDecoder.Strides)
        {
            var cells = width / stride * (height / stride);
            outputs[YuNetDecoder.OutputName("cls", stride)] = new float[cells];
            outputs[YuNetDecoder.OutputName("obj", stride)] = new float[cells];
            outputs[YuNetDecoder.OutputName("bbox", stride)] = new float[cells * 4];
            outputs[YuNetDecoder.OutputName("kps", stride)] = new float[cells * 10];
        }
        foreach (var cell in row["cells"]!.AsArray())
        {
            var stride = cell!["stride"]!.GetValue<int>();
            var index = cell["row"]!.GetValue<int>() * (width / stride) + cell["column"]!.GetValue<int>();
            outputs[YuNetDecoder.OutputName("cls", stride)][index] = (float)Number(cell["cls"]);
            outputs[YuNetDecoder.OutputName("obj", stride)][index] = (float)Number(cell["obj"]);
            var bbox = Numbers(cell["bbox"]);
            for (var item = 0; item < 4; item++) outputs[YuNetDecoder.OutputName("bbox", stride)][index * 4 + item] = (float)bbox[item];
            var kps = Numbers(cell["kps"]);
            for (var item = 0; item < 10; item++) outputs[YuNetDecoder.OutputName("kps", stride)][index * 10 + item] = (float)kps[item];
        }
        if (row["truncate"]?.GetValue<string>() is { } name) outputs[name] = outputs[name][..^1];
        return outputs;
    }

    [Fact]
    public void DecodesReplay()
    {
        foreach (var row in Rows("decodes"))
        {
            var id = Id(row);
            var expect = row["expect"]!;
            var decode = () => YuNetDecoder.Decode(Outputs(row), row["inputWidth"]!.GetValue<int>(), row["inputHeight"]!.GetValue<int>());
            if (expect["error"]!.GetValue<bool>())
            {
                Assert.Throws<ArgumentException>(decode);
                continue;
            }
            var faces = decode();
            var expected = expect["faces"]!.AsArray().Select(Face).ToArray();
            Assert.True(expected.Length == faces.Count, $"{id}: {faces.Count} faces");
            for (var index = 0; index < faces.Count; index++)
            {
                var (want, got) = (expected[index], faces[index]);
                foreach (var (name, a, b) in new[] { ("x", want.X, got.X), ("y", want.Y, got.Y), ("width", want.Width, got.Width),
                             ("height", want.Height, got.Height), ("score", want.Score, got.Score) })
                    Near(a, b, $"{id}.faces[{index}].{name}");
                for (var point = 0; point < 5; point++)
                {
                    Near(want.Points[point].X, got.Points[point].X, $"{id}.faces[{index}].points[{point}].x");
                    Near(want.Points[point].Y, got.Points[point].Y, $"{id}.faces[{index}].points[{point}].y");
                }
            }
            var largest = YuNetDecoder.Largest(faces);
            if (expect["largest"] is null)
            {
                Assert.Null(largest);
                continue;
            }
            Assert.Same(faces[expect["largest"]!.GetValue<int>()], largest);
            SameJson(expect["largestRect"], FrameJson.Write(largest!.PictureRect(Number(row["contentWidth"]), Number(row["contentHeight"]))), id + ".largestRect");
        }
    }

    [Fact]
    public void NmsKeepsTheBestOfAnOverlapAndTheLargestFaceIsPickedAfterIt()
    {
        var overlap = Rows("decodes").Single(row => Id(row) == "nms-drops-the-overlap");
        Assert.Single(YuNetDecoder.Decode(Outputs(overlap), 64, 64));
        var after = Rows("decodes").Single(row => Id(row) == "nms-before-largest");
        var faces = YuNetDecoder.Decode(Outputs(after), 64, 64);
        Assert.Equal(2, faces.Count);
        Assert.Same(faces[0], YuNetDecoder.Largest(faces));
        Assert.Single(YuNetDecoder.Decode(Outputs(after), 64, 64, nmsThreshold: 0.9), face => face.Area > faces[0].Area);
        var largest = Rows("decodes").Single(row => Id(row) == "largest-is-not-the-best-score");
        var two = YuNetDecoder.Decode(Outputs(largest), 64, 64);
        Assert.True(two[0].Score > two[1].Score && two[1].Area > two[0].Area);
        Assert.Same(two[1], YuNetDecoder.Largest(two));
    }

    [Fact]
    public void CropsReplayAndRoundTrip()
    {
        foreach (var row in Rows("crops"))
        {
            var id = Id(row);
            var crop = RotatedCrop.FromFace(Face(row["face"]), Number(row["scale"]));
            var expect = row["expect"];
            if (expect is null)
            {
                Assert.Null(crop);
                continue;
            }
            Assert.NotNull(crop);
            Near(Number(expect["roll"]), crop.Roll, id + ".roll");
            Near(Number(expect["centre"]![0]), crop.Centre.X, id + ".centre.x");
            Near(Number(expect["centre"]![1]), crop.Centre.Y, id + ".centre.y");
            Near(Number(expect["side"]), crop.Side, id + ".side");
            Assert.Equal(expect["cropSize"]!.GetValue<int>(), crop.CropSize);
            Near(Number(expect["cos"]), crop.Cos, id + ".cos");
            Near(Number(expect["sin"]), crop.Sin, id + ".sin");
            var forward = crop.CropToFrame;
            var inverse = crop.FrameToCrop;
            var matrices = new[] { (expect["cropToFrame"], new[] { forward.A, forward.B, forward.C, forward.D, forward.E, forward.F }),
                (expect["frameToCrop"], new[] { inverse.A, inverse.B, inverse.C, inverse.D, inverse.E, inverse.F }) };
            foreach (var (node, actual) in matrices)
            {
                var wanted = Numbers(node);
                for (var index = 0; index < 6; index++) Near(wanted[index], actual[index], $"{id}.matrix[{index}]");
            }
            var cropPoints = expect["cropPoints"]!.AsArray().Select(point => (Number(point![0]), Number(point[1]))).ToArray();
            var framePoints = expect["framePoints"]!.AsArray().Select(point => (Number(point![0]), Number(point[1]))).ToArray();
            for (var index = 0; index < cropPoints.Length; index++)
            {
                var frame = crop.ToFrame(cropPoints[index].Item1, cropPoints[index].Item2);
                Near(framePoints[index].Item1, frame.X, $"{id}.framePoints[{index}].x");
                Near(framePoints[index].Item2, frame.Y, $"{id}.framePoints[{index}].y");
                var (u, v) = (forward.A * cropPoints[index].Item1 + forward.B * cropPoints[index].Item2 + forward.C,
                    forward.D * cropPoints[index].Item1 + forward.E * cropPoints[index].Item2 + forward.F);
                Assert.True(Math.Abs(u - frame.X) <= 1e-9 && Math.Abs(v - frame.Y) <= 1e-9, $"{id}: the affine is ToFrame");
                var back = crop.ToCrop(frame.X, frame.Y);
                Assert.True(Math.Abs(back.X - cropPoints[index].Item1) <= 1e-9 && Math.Abs(back.Y - cropPoints[index].Item2) <= 1e-9,
                    $"{id}: crop → frame → crop moved {cropPoints[index]} to {back}");
                var again = crop.ToFrame(back.X, back.Y);
                Assert.True(Math.Abs(again.X - frame.X) <= 1e-9 && Math.Abs(again.Y - frame.Y) <= 1e-9, $"{id}: frame → crop → frame");
            }
            var meshPoints = expect["meshPoints"]!.AsArray().Select(point => new MeshPoint(Number(point![0]), Number(point[1]), Number(point[2]))).ToArray();
            var meshInFrame = expect["meshInFrame"]!.AsArray().Select(point => Numbers(point)).ToArray();
            for (var index = 0; index < meshPoints.Length; index++)
            {
                var mapped = crop.ToFrame(meshPoints[index]);
                Near(meshInFrame[index][0], mapped.X, $"{id}.meshInFrame[{index}].x");
                Near(meshInFrame[index][1], mapped.Y, $"{id}.meshInFrame[{index}].y");
                Near(meshInFrame[index][2], mapped.Z, $"{id}.meshInFrame[{index}].z");
            }
            var eyes = expect["eyesInCrop"]!.AsArray().Select(point => Numbers(point)).ToArray();
            var face = Face(row["face"]);
            var scale = Number(row["scale"]);
            for (var index = 0; index < 2; index++)
            {
                var inCrop = crop.ToCrop(face.Points[index].X * scale, face.Points[index].Y * scale);
                Near(eyes[index][0], inCrop.X, $"{id}.eyesInCrop[{index}].x");
                Near(eyes[index][1], inCrop.Y, $"{id}.eyesInCrop[{index}].y");
            }
            Assert.True(Math.Abs(eyes[0][1] - eyes[1][1]) <= 1e-9 && eyes[0][0] < eyes[1][0], $"{id}: the eye line is level in the crop");
        }
    }

    [Fact]
    public void TheRollFollowsTheEyeLine()
    {
        double Roll(string id) => RotatedCrop.FromFace(Face(Rows("crops").Single(row => Id(row) == id)["face"]), 2)!.Roll;
        Assert.Equal(0, Roll("level"));
        Near(Math.Atan2(30, 60), Roll("second-eye-lower"), "second-eye-lower");
        Assert.True(Roll("second-eye-higher") < 0);
        Assert.True(Math.Abs(Roll("upside-down")) > 3);
    }

    [Fact]
    public void SamplesReplay()
    {
        foreach (var row in Rows("samples"))
        {
            var id = Id(row);
            var crop = RotatedCrop.FromFace(Face(row["face"]), Number(row["scale"]), row["cropSize"]!.GetValue<int>(), Number(row["expansion"]))!;
            var image = row["image"]!;
            var bytes = image["bytes"]!.AsArray().Select(item => (byte)item!.GetValue<int>()).ToArray();
            var output = crop.Sample(bytes, image["width"]!.GetValue<int>(), image["height"]!.GetValue<int>(), image["rowBytes"]!.GetValue<int>());
            var expected = Numbers(row["expect"]);
            Assert.Equal(expected.Length, output.Length);
            for (var index = 0; index < output.Length; index++) Near(expected[index], output[index], $"{id}[{index}]");
        }
        var first = Rows("samples").First();
        var small = RotatedCrop.FromFace(Face(first["face"]), 1, 4, 1)!;
        Assert.Throws<ArgumentException>(() => small.Sample(new byte[10], 7, 5, 24));
    }

    [Fact]
    public void CropStatsReplay()
    {
        var gates = Calibration.Value.Gates;
        foreach (var row in Rows("cropStats"))
        {
            var id = Id(row);
            var rgb = Numbers(row["rgb"]).Select(value => (float)value).ToArray();
            var size = row["size"]!.GetValue<int>();
            if (row["expect"] is null)
            {
                Assert.Throws<ArgumentException>(() => FaceCropStats.Measure(rgb, size, gates));
                continue;
            }
            var stats = FaceCropStats.Measure(rgb, size, gates);
            var expect = Stats(row["expect"]);
            Near(expect.SharpnessVariance, stats.SharpnessVariance, id + ".sharpnessVariance");
            Near(expect.MeanLuma, stats.MeanLuma, id + ".meanLuma");
            Near(expect.ClippedFraction, stats.ClippedFraction, id + ".clippedFraction");
        }
    }

    private static MeshPoint[] Mesh(JsonObject row)
    {
        var fill = Numbers(row["fill"]);
        var mesh = Enumerable.Repeat(new MeshPoint(fill[0], fill[1], fill[2]), row["count"]!.GetValue<int>()).ToArray();
        foreach (var (index, point) in row["points"]!.AsObject())
        {
            var values = Numbers(point);
            mesh[int.Parse(index, System.Globalization.CultureInfo.InvariantCulture)] = new MeshPoint(values[0], values[1], values[2]);
        }
        return mesh;
    }

    private static FaceMeshMeasure Measure(JsonObject row) =>
        FaceMeshFields.Measure(Rect(row["rect"]), Number(row["faceWidthPixels"]), Mesh(row), Stats(row["crop"]), Calibration.Value);

    [Fact]
    public void MeshesReplay()
    {
        foreach (var row in Rows("meshes"))
        {
            var id = Id(row);
            var expect = row["expect"];
            if (expect is null)
            {
                Assert.Throws<ArgumentException>(() => Measure(row));
                continue;
            }
            var measure = Measure(row);
            Near(Optional(expect["rawLeftEye"]), measure.RawLeftEye, id + ".rawLeftEye");
            Near(Optional(expect["rawRightEye"]), measure.RawRightEye, id + ".rawRightEye");
            Near(Optional(expect["meshYaw"]), measure.MeshYaw, id + ".meshYaw");
            Near(Optional(expect["meshPitch"]), measure.MeshPitch, id + ".meshPitch");
            SameParts(expect["quality"], measure.Quality, id + ".quality");
            SameJson(expect["face"], FrameJson.Write(measure.Face), id + ".face");
            Assert.True(expect["facesCamera"]?.GetValue<bool>() == measure.Face.FacesCamera(null), id + ".facesCamera");
            Assert.Equal(measure.Face, FaceMeshFields.Fields(Rect(row["rect"]), Number(row["faceWidthPixels"]), Mesh(row), Stats(row["crop"]), Calibration.Value));
        }
    }

    [Fact]
    public void EyesAndPoseReadAsTheMacs()
    {
        FrameFace Read(string id) => Measure(Rows("meshes").Single(row => Id(row) == id)).Face;
        Assert.Equal(FrameEyes.Open, Read("level-open").Eyes);
        Assert.Equal(FrameEyes.Closed, Read("closed").Eyes);
        Assert.Equal(FrameEyes.Closed, Read("half-closed").Eyes);
        Assert.Equal(FrameEyes.Closed, Read("one-eye-closed").Eyes);
        Assert.Equal(FrameEyes.Open, Read("one-eye-unmeasured").Eyes);
        Assert.Null(Read("one-eye-unmeasured").LeftEyeAspect);
        Assert.True(Read("level-open").FacesCamera(null));
        Assert.True(Read("slightly-turned").FacesCamera(null));
        Assert.True(Read("slightly-tipped").FacesCamera(null));
        Assert.False(Read("turned-yaw-negative").FacesCamera(null));
        Assert.False(Read("turned-yaw-positive").FacesCamera(null));
        Assert.True(Read("turned-yaw-negative").Yaw < -FrameFace.YawLimit && Read("turned-yaw-positive").Yaw > FrameFace.YawLimit);
        Assert.True(Read("tipped-back").Pitch < -FrameFace.PitchLimit, "the head tipped back reads negative, as the Mac's");
        Assert.True(Read("tipped-down").Pitch > FrameFace.PitchLimit);
        Assert.True(Read("tipped-back").FacesCamera(Read("tipped-back").Pitch));
        Assert.Null(Read("no-pose").Yaw);
        Assert.Null(Read("no-pose").CaptureQuality);
        Assert.True(Read("small-face-gated").CaptureQuality == 0);
        Assert.True(Read("level-open").CaptureQuality >= FrameFace.GoodQuality && Read("closed").CaptureQuality < FrameFace.GoodQuality);
        Assert.False(FaceMeshFields.Present(-0.01));
        Assert.True(FaceMeshFields.Present(0));
    }

    [Fact]
    public void QualitiesReplay()
    {
        foreach (var row in Rows("qualities"))
        {
            var id = Id(row);
            var calibration = Calibration.Value;
            if (row["quantileMap"] is JsonArray map)
                calibration = calibration with { QuantileMap = map.Select(point => (Number(point![0]), Number(point[1]))).ToArray() };
            var parts = FaceMeshFields.Quality(Optional(row["eyeAspect"]), Optional(row["yaw"]), Optional(row["pitch"]),
                Number(row["faceWidthPixels"]), Stats(row["crop"]), calibration);
            SameParts(row["expect"], parts, id);
        }
    }

    [Fact]
    public void EachQualityGateZeroesTheScore()
    {
        FaceQualityParts Parts(string id) => FaceMeshFields.Quality(Optional(Rows("qualities").Single(row => Id(row) == id)["eyeAspect"]),
            Optional(Rows("qualities").Single(row => Id(row) == id)["yaw"]), Optional(Rows("qualities").Single(row => Id(row) == id)["pitch"]),
            Number(Rows("qualities").Single(row => Id(row) == id)["faceWidthPixels"]), Stats(Rows("qualities").Single(row => Id(row) == id)["crop"]),
            Calibration.Value)!;
        foreach (var (closed, open) in new[] { ("small-face", "size-at-the-gate"), ("too-dark", "dark-at-the-gate"), ("too-bright", "bright-at-the-gate"),
                     ("too-clipped", "clipped-at-the-gate") })
        {
            Assert.Equal(0, Parts(closed).Quality);
            Assert.Equal(1, Parts(open).Gate);
            Assert.True(Parts(open).Quality > 0.5, open);
        }
        Assert.Equal(0, Parts("sharpness-floor").Sharp);
        Assert.Equal(1, Parts("sharpness-ceiling").Sharp);
        Assert.Equal(0, Parts("flat-crop").Sharp);
        Assert.Equal(0, Parts("closed").EyesOpen);
        Assert.Equal(0, Parts("turned-past-the-span").Facing);
    }
}
