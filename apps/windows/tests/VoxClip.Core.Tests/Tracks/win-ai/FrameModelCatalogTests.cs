using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Frames;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The Windows face models' catalogue (shared/catalog/frame-models.json, ADR-R48 Windows): pinned and hash-checked like the
/// speaker model's, licensed per file, bundled in the Windows app, and switched off until the calibration (W7). No download here.</summary>
[Trait("Track", "win-ai")]
public sealed class FrameModelCatalogTests
{
    private static JsonObject Shipped() => JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "catalog", "frame-models.json")))!.AsObject();
    private static JsonObject Model(JsonObject catalogue) => catalogue["models"]![0]!.AsObject();
    private static JsonObject File0(JsonObject catalogue, int index) => Model(catalogue)["files"]![index]!.AsObject();
    private static FrameModelCatalog Load(JsonObject catalogue) => new(Encoding.UTF8.GetBytes(catalogue.ToJsonString()));

    [Fact]
    public void TheShippedCatalogueIsPinnedAndOff()
    {
        var catalogue = new FrameModelCatalog(FixtureLoader.SharedRoot);
        Assert.False(catalogue.Enabled);
        Assert.Empty(catalogue.Installable);
        var model = catalogue.Entry;
        Assert.Equal("yunet2026may-facemeshv2-f16v1", model.Id);
        Assert.Equal("1.19.2", model.OrtVersion);
        Assert.Equal(("face_detection_yunet_2026may.onnx", 229738L, "ebafce4e3c118d6554634be5c27ab333b4c047a9a8c3faf1d7cf93101c22f0f0", "MIT"),
            (model.Detector.Name, model.Detector.Bytes, model.Detector.Sha256, model.Detector.License));
        Assert.Equal(("face_mesh_v2.onnx", 4921008L, "336896759881634ebf1121fe161e95abf1eaae697779d02a9eab04f53b1f0784", "Apache-2.0"),
            (model.Landmarks.Name, model.Landmarks.Bytes, model.Landmarks.Sha256, model.Landmarks.License));
        Assert.Contains("26cc381e4d2594bb9f47a26eb8fd96c94a13660d", model.Detector.Url!.AbsoluteUri);
        Assert.Null(model.Landmarks.Url);
        Assert.All(model.Files, file => Assert.Equal(FrameModel.BundledFolder + file.Name, file.Bundled));
        Assert.All(model.Files, file => Assert.False(string.IsNullOrWhiteSpace(file.Notice)));
        Assert.Contains("Google", model.Landmarks.Notice);
        Assert.Contains("WIDER FACE", model.Detector.TrainingData);
        var calibration = model.Calibration;
        Assert.True(calibration.Provisional);
        Assert.Equal((0.7446, 0.069), (calibration.EyeAspect.A, calibration.EyeAspect.B));
        Assert.Equal((1.1694, -0.0004), (calibration.Yaw.A, calibration.Yaw.B));
        Assert.Equal((-0.9019, 0.0263), (calibration.Pitch.A, calibration.Pitch.B));
        Assert.Equal((0.2739, 0.1218, 0.2468), (calibration.W0, calibration.W1, calibration.W2));
        Assert.Equal((0.12, 0.26, 0.6, 0.11, 30.0, 400.0), (calibration.EyesClosedAt, calibration.EyesOpenAt, calibration.FacingSpan, calibration.Pitch0,
            calibration.SharpLow, calibration.SharpHigh));
        Assert.Equal(new FrameQualityGates(40, 40, 220, 5, 250, 0.25), calibration.Gates);
        Assert.Equal([(0.372, 0.2759), (0.4416, 0.429), (0.5025, 0.5232), (0.558, 0.6069), (0.6088, 0.6543)], calibration.QuantileMap);
        Assert.Equal((0.85, 80.0), (calibration.SpeakerScore, calibration.EyesFromWidth));
    }

    [Fact]
    public void TheDisabledCatalogueInstallsNothing()
    {
        var catalogue = Shipped();
        Assert.Empty(Load(catalogue).Installable);
        catalogue["enabled"] = true;
        Assert.Throws<InvalidDataException>(() => Load(catalogue));
        Model(catalogue)["calibration"]!["status"] = "calibrated";
        var enabled = Load(catalogue);
        Assert.True(enabled.Enabled);
        Assert.Same(enabled.Entry, Assert.Single(enabled.Installable));
        // A file neither hosted nor bundled can't be enabled.
        File0(catalogue, 1).Remove("bundled");
        Assert.Throws<InvalidDataException>(() => Load(catalogue));
        File0(catalogue, 1)["url"] = "https://example.invalid/face_mesh_v2.onnx";
        Assert.True(Load(catalogue).Enabled);
    }

    [Theory]
    [InlineData(0, "license")]
    [InlineData(0, "licenseUrl")]
    [InlineData(0, "notice")]
    [InlineData(1, "license")]
    [InlineData(1, "notice")]
    [InlineData(1, "trainingData")]
    public void AFileWithoutItsLicenceIsRefused(int index, string key)
    {
        var catalogue = Shipped();
        File0(catalogue, index).Remove(key);
        Assert.Throws<InvalidDataException>(() => Load(catalogue));
        File0(catalogue, index)[key] = "";
        Assert.Throws<InvalidDataException>(() => Load(catalogue));
    }

    [Fact]
    public void ABrokenEntryIsRefused()
    {
        void Refused(Action<JsonObject> change)
        {
            var catalogue = Shipped();
            change(catalogue);
            Assert.Throws<InvalidDataException>(() => Load(catalogue));
        }
        Refused(catalogue => Model(catalogue).Remove("license"));
        Refused(catalogue => Model(catalogue)["totalBytes"] = 5150745);
        Refused(catalogue => File0(catalogue, 0)["sha256"] = "EBAFCE4E3C118D6554634BE5C27AB333B4C047A9A8C3FAF1D7CF93101C22F0F0");
        Refused(catalogue => File0(catalogue, 0)["name"] = "../face.onnx");
        Refused(catalogue => File0(catalogue, 0)["url"] = "http://github.com/face.onnx");
        Refused(catalogue => File0(catalogue, 0)["bundled"] = "apps/windows/models/frames/face_mesh_v2.onnx");
        Refused(catalogue => File0(catalogue, 1)["bundled"] = "models/face_mesh_v2.onnx");
        Refused(catalogue => File0(catalogue, 1)["role"] = "detector");
        Refused(catalogue => Model(catalogue)["ortVersion"] = "1.20.0");
        Refused(catalogue => catalogue["schema"] = "voxclip-frame-models/2");
        Refused(catalogue => Model(catalogue)["calibration"]!["quality"]!["quantileMap"] = new JsonArray(new JsonArray(0.5, 0.4), new JsonArray(0.4, 0.6)));
        Refused(catalogue => Model(catalogue)["calibration"]!["quality"]!["eyesOpen"] = new JsonArray(0.26, 0.12));
        Refused(catalogue => Model(catalogue)["calibration"]!["quality"]!.AsObject().Remove("gates"));
        Refused(catalogue => Model(catalogue)["calibration"]!["status"] = "guessed");
        Refused(catalogue => Model(catalogue)["calibration"]!.AsObject().Remove("speakerScore"));
        Refused(catalogue => Model(catalogue)["calibration"]!["speakerScore"] = 1.2);
        Refused(catalogue => Model(catalogue)["calibration"]!["eyesFromWidth"] = -1);
    }

    [Fact]
    public void AnInstalledFileIsHashChecked()
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-frame-models-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            byte[] detector = [1, 2, 3, 4, 5], landmarks = [6, 7, 8];
            var catalogue = Shipped();
            void Pin(int index, byte[] bytes)
            {
                File0(catalogue, index)["bytes"] = bytes.Length;
                File0(catalogue, index)["sha256"] = Convert.ToHexStringLower(SHA256.HashData(bytes));
            }
            Pin(0, detector);
            Pin(1, landmarks);
            Model(catalogue)["totalBytes"] = detector.Length + landmarks.Length;
            var model = Load(catalogue).Entry;
            Assert.Throws<InvalidDataException>(() => model.VerifiedFiles(directory));
            File.WriteAllBytes(Path.Combine(directory, "face_detection_yunet_2026may.onnx"), detector);
            File.WriteAllBytes(Path.Combine(directory, "face_mesh_v2.onnx"), landmarks);
            Assert.Equal((Path.Combine(directory, "face_detection_yunet_2026may.onnx"), Path.Combine(directory, "face_mesh_v2.onnx")), model.VerifiedFiles(directory));
            File.WriteAllBytes(Path.Combine(directory, "face_mesh_v2.onnx"), [6, 7, 9]);
            Assert.Throws<InvalidDataException>(() => model.VerifiedFiles(directory));
            File.WriteAllBytes(Path.Combine(directory, "face_mesh_v2.onnx"), [6, 7, 8, 9]);
            Assert.Throws<InvalidDataException>(() => model.VerifiedFiles(directory));
            Assert.Throws<InvalidDataException>(() => new FrameModelCatalog(FixtureLoader.SharedRoot).Entry.VerifiedFiles(directory));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
