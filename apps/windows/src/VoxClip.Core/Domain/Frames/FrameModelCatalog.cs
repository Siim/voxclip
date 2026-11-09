using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Domain.Frames;

/// <summary>One pinned file of the Windows face models (shared/catalog/frame-models.json), with the licence and notice the app's
/// notices list.</summary>
/// <param name="Role"><c>detector</c> (YuNet) or <c>landmarks</c> (Face Mesh V2).</param>
/// <param name="Name">The file name in the models folder.</param>
/// <param name="Url">Where it is fetched from, or null when it is only bundled.</param>
/// <param name="Bytes">Its exact size.</param>
/// <param name="Sha256">Its SHA-256, lower-case hex.</param>
/// <param name="License">Its licence, e.g. <c>MIT</c> or <c>Apache-2.0</c>.</param>
/// <param name="LicenseUrl">The licence text.</param>
/// <param name="Notice">The line the app's notices show for it.</param>
/// <param name="TrainingData">What it was trained on, and that data's terms.</param>
/// <param name="Bundled">Its path in the repository when the Windows app bundles it (<c>apps/windows/models/frames/&lt;name&gt;</c>,
/// copied beside the app as <c>models/frames/&lt;name&gt;</c>), or null. A file that is neither hosted nor bundled can't be enabled.</param>
public sealed record FrameModelFile(string Role, string Name, Uri? Url, long Bytes, string Sha256, string License, Uri LicenseUrl,
    string Notice, string TrainingData, string? Bundled);

/// <summary>A fitted straight line, <c>a·value + b</c>, from the catalogue's calibration.</summary>
/// <param name="A">The slope.</param>
/// <param name="B">The intercept.</param>
public readonly record struct FrameLinearMap(double A, double B)
{
    /// <summary>The mapped value.</summary>
    public double Apply(double value) => A * value + B;
}

/// <summary>The capture-quality gates: a face too small, too dark, too bright or too clipped scores 0.</summary>
/// <param name="MinimumFaceWidth">A face narrower than this (pixels, on the 1,280 px analysis frame) scores 0.</param>
/// <param name="LumaLow">A crop whose mean grey is below this (0–255) scores 0.</param>
/// <param name="LumaHigh">A crop whose mean grey is above this scores 0.</param>
/// <param name="ClippedBelow">A grey value below this counts as clipped.</param>
/// <param name="ClippedAbove">A grey value above this counts as clipped.</param>
/// <param name="ClippedFraction">A crop with more than this share of clipped pixels scores 0.</param>
public sealed record FrameQualityGates(double MinimumFaceWidth, double LumaLow, double LumaHigh, double ClippedBelow, double ClippedAbove,
    double ClippedFraction);

/// <summary>Every fitted constant of the Windows face fields, read from the catalogue's <c>calibration</c> block so they live in one
/// place. Until the calibration package (W7) runs, <see cref="Status"/> is <c>provisional</c> and the numbers are the study's seed fit.</summary>
public sealed record FrameFaceCalibration
{
    /// <summary><c>provisional</c> (the seed fit) or <c>calibrated</c> (W7 passed).</summary>
    public required string Status { get; init; }
    /// <summary>Mesh eye ratio → Vision's eye ratio.</summary>
    public required FrameLinearMap EyeAspect { get; init; }
    /// <summary>Mesh yaw → Vision revision-3 yaw (radians).</summary>
    public required FrameLinearMap Yaw { get; init; }
    /// <summary>Mesh pitch → Vision revision-3 pitch (radians; negative with the head tipped back).</summary>
    public required FrameLinearMap Pitch { get; init; }
    /// <summary>The quality's constant weight.</summary>
    public required double W0 { get; init; }
    /// <summary>The weight of eyes-open × facing.</summary>
    public required double W1 { get; init; }
    /// <summary>The weight of sharpness.</summary>
    public required double W2 { get; init; }
    /// <summary>The Vision-scale mean eye ratio where eyes-open starts rising from 0.</summary>
    public required double EyesClosedAt { get; init; }
    /// <summary>The Vision-scale mean eye ratio where eyes-open reaches 1.</summary>
    public required double EyesOpenAt { get; init; }
    /// <summary>The pose angle (radians) at which facing falls to 0.</summary>
    public required double FacingSpan { get; init; }
    /// <summary>The camera-height pitch offset the facing term is measured from (Vision scale).</summary>
    public required double Pitch0 { get; init; }
    /// <summary>The Laplacian variance at which sharpness starts rising from 0.</summary>
    public required double SharpLow { get; init; }
    /// <summary>The Laplacian variance at which sharpness reaches 1.</summary>
    public required double SharpHigh { get; init; }
    /// <summary>The monotone remap of the score onto Vision's quantiles, as (Windows, Vision) points strictly increasing inside 0–1;
    /// empty for none.</summary>
    public required IReadOnlyList<(double Windows, double Vision)> QuantileMap { get; init; }
    /// <summary>The exposure and size gates.</summary>
    public required FrameQualityGates Gates { get; init; }
    /// <summary>The YuNet score from which a box counts as a confident detection when the face path picks the speaker
    /// (<see cref="SpeakerFace"/>), fitted below the calibration's speakers' lowest score (W8).</summary>
    public required double SpeakerScore { get; init; }
    /// <summary>The face width, pixels of the 1,280 px analysis frame, below which the eyes are reported unknown (null ratios):
    /// smaller faces read too unsteadily to call open or closed (W8). The capture quality still uses the measured eyes.</summary>
    public required double EyesFromWidth { get; init; }

    /// <summary>Whether the constants are still the seed fit.</summary>
    public bool Provisional => Status != "calibrated";

    /// <summary>The calibration from a catalogue <c>calibration</c> object; throws <see cref="InvalidDataException"/> when a number is
    /// missing, not finite or out of order.</summary>
    public static FrameFaceCalibration Read(JsonElement value)
    {
        try
        {
            var quality = value.GetProperty("quality");
            var gates = quality.GetProperty("gates");
            var eyes = Pair(quality.GetProperty("eyesOpen"));
            var sharp = Pair(quality.GetProperty("sharpness"));
            var luma = Pair(gates.GetProperty("luma"));
            var map = quality.GetProperty("quantileMap").EnumerateArray().Select(Pair).ToArray();
            var calibration = new FrameFaceCalibration
            {
                Status = value.GetProperty("status").GetString() ?? "",
                EyeAspect = Linear(value.GetProperty("eyeAspect")), Yaw = Linear(value.GetProperty("yaw")), Pitch = Linear(value.GetProperty("pitch")),
                W0 = Number(quality, "w0"), W1 = Number(quality, "w1"), W2 = Number(quality, "w2"),
                EyesClosedAt = eyes.Item1, EyesOpenAt = eyes.Item2, FacingSpan = Number(quality, "facingSpan"), Pitch0 = Number(quality, "pitch0"),
                SharpLow = sharp.Item1, SharpHigh = sharp.Item2, QuantileMap = Array.AsReadOnly(map),
                Gates = new FrameQualityGates(Number(gates, "minimumFaceWidth"), luma.Item1, luma.Item2, Number(gates, "clippedBelow"),
                    Number(gates, "clippedAbove"), Number(gates, "clippedFraction")),
                SpeakerScore = Number(value, "speakerScore"), EyesFromWidth = Number(value, "eyesFromWidth"),
            };
            var previous = (Windows: 0.0, Vision: 0.0);
            foreach (var point in map)
            {
                if (!(point.Item1 > previous.Windows && point.Item2 > previous.Vision && point.Item1 < 1 && point.Item2 < 1))
                    throw new InvalidDataException("The quantile map must rise strictly inside 0–1.");
                previous = point;
            }
            if (calibration.Status is not ("provisional" or "calibrated") || calibration.W0 < 0 || calibration.W1 < 0 || calibration.W2 < 0 ||
                !(calibration.EyesOpenAt > calibration.EyesClosedAt) || !(calibration.FacingSpan > 0) || !(calibration.SharpLow > 0) ||
                !(calibration.SharpHigh > calibration.SharpLow) || !(luma.Item2 >= luma.Item1) || calibration.Gates.MinimumFaceWidth < 0 ||
                calibration.Gates.ClippedFraction is < 0 or > 1 || calibration.SpeakerScore is < 0 or > 1 || calibration.EyesFromWidth < 0)
                throw new InvalidDataException("The face calibration is out of range.");
            return calibration;
        }
        catch (Exception error) when (error is KeyNotFoundException or InvalidOperationException or FormatException or IndexOutOfRangeException)
        {
            throw new InvalidDataException("The face calibration is incomplete.", error);
        }
    }

    /// <summary>The score after the quantile remap: piecewise linear through (0, 0), the map's points and (1, 1). Empty: unchanged.</summary>
    public double Remap(double score)
    {
        if (QuantileMap.Count == 0) return score;
        var (fromX, fromY) = (0.0, 0.0);
        foreach (var (x, y) in QuantileMap.Append((1.0, 1.0)))
        {
            if (score <= x) return fromY + (score - fromX) * (y - fromY) / (x - fromX);
            (fromX, fromY) = (x, y);
        }
        return 1;
    }

    private static double Number(JsonElement row, string name)
    {
        var value = row.GetProperty(name).GetDouble();
        return double.IsFinite(value) ? value : throw new InvalidDataException(name + " is not finite.");
    }
    private static FrameLinearMap Linear(JsonElement row) => new(Number(row, "a"), Number(row, "b"));
    private static (double, double) Pair(JsonElement row)
    {
        if (row.GetArrayLength() != 2) throw new InvalidDataException("Expected a pair.");
        var (low, high) = (row[0].GetDouble(), row[1].GetDouble());
        return double.IsFinite(low) && double.IsFinite(high) ? (low, high) : throw new InvalidDataException("A pair is not finite.");
    }
}

/// <summary>The face models' one catalogue entry: YuNet (the detector) and Face Mesh V2 (the landmarks), their licences and the
/// calibration.</summary>
public sealed class FrameModel
{
    /// <summary>The entry's stable id, also the models folder's name.</summary>
    public string Id { get; }
    /// <summary>The name shown in the app.</summary>
    public string DisplayName { get; }
    /// <summary>The ONNX Runtime version the files were checked on (the app's pin).</summary>
    public string OrtVersion { get; }
    /// <summary>Both files, in catalogue order.</summary>
    public IReadOnlyList<FrameModelFile> Files { get; }
    /// <summary>The detector (YuNet).</summary>
    public FrameModelFile Detector => Files.Single(file => file.Role == "detector");
    /// <summary>The landmark model (Face Mesh V2).</summary>
    public FrameModelFile Landmarks => Files.Single(file => file.Role == "landmarks");
    /// <summary>The combined licence line.</summary>
    public string License { get; }
    /// <summary>The attribution the notices show.</summary>
    public string Attribution { get; }
    /// <summary>The fitted constants of <see cref="FaceMeshFields"/>.</summary>
    public FrameFaceCalibration Calibration { get; }

    internal FrameModel(JsonElement value)
    {
        Id = Text(value, "id");
        DisplayName = Text(value, "displayName");
        OrtVersion = Text(value, "ortVersion");
        License = Text(value, "license");
        Attribution = Text(value, "attribution");
        Files = Array.AsReadOnly(value.GetProperty("files").EnumerateArray().Select(file => new FrameModelFile(Text(file, "role"), Text(file, "name"),
            file.GetProperty("url").ValueKind == JsonValueKind.Null ? null : new Uri(Text(file, "url")), file.GetProperty("bytes").GetInt64(),
            Text(file, "sha256"), Text(file, "license"), new Uri(Text(file, "licenseUrl")), Text(file, "notice"), Text(file, "trainingData"),
            file.TryGetProperty("bundled", out var bundled) ? bundled.GetString() : null)).ToArray());
        if (Id.Any(character => character is not (>= 'a' and <= 'z' or >= '0' and <= '9' or '-')) || OrtVersion != "1.19.2" ||
            Files.Count != 2 || Files.Count(file => file.Role == "detector") != 1 || Files.Count(file => file.Role == "landmarks") != 1 ||
            Files.Any(file => file.Name != Path.GetFileName(file.Name) || file.Name.Contains('\\') || file.Name.StartsWith('.') ||
                file.Url is { Scheme: not "https" } || file.LicenseUrl.Scheme != "https" || file.Bytes <= 0 || !HashValid(file.Sha256) ||
                (file.Bundled is not null && file.Bundled != BundledFolder + file.Name)) ||
            Files.Sum(file => file.Bytes) != value.GetProperty("totalBytes").GetInt64())
            throw new InvalidDataException("The face model entry is not valid.");
        Calibration = FrameFaceCalibration.Read(value.GetProperty("calibration"));
    }

    /// <summary>The detector's and the landmark model's paths in <paramref name="directory"/>, after checking each file's size and
    /// SHA-256 against the catalogue. Throws <see cref="InvalidDataException"/> when a file is missing, a link, or not the
    /// catalogued bytes.</summary>
    public (string Detector, string Landmarks) VerifiedFiles(string directory)
    {
        foreach (var file in Files)
        {
            var path = Path.Combine(directory, file.Name);
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length != file.Bytes)
                throw new InvalidDataException(file.Name + " is missing or has the wrong size.");
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (Convert.ToHexStringLower(SHA256.HashData(stream)) != file.Sha256) throw new InvalidDataException(file.Name + " does not match the catalogue.");
        }
        return (Path.Combine(directory, Detector.Name), Path.Combine(directory, Landmarks.Name));
    }

    /// <summary>The repository folder of the bundled files; the app has them in <c>models/frames</c> beside its executable.</summary>
    public const string BundledFolder = "apps/windows/models/frames/";

    private static bool HashValid(string value) => value.Length == 64 && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static string Text(JsonElement row, string name) =>
        row.GetProperty(name).GetString() is { Length: > 0 } text ? text : throw new InvalidDataException(name + " is empty.");
}

/// <summary>The Windows face models' catalogue (<c>shared/catalog/frame-models.json</c>, <c>voxclip-frame-models/1</c>), mirroring
/// <c>SpeakerModelCatalog</c>: read, validated and hash-checked, never downloaded here. Both files are bundled in the Windows app
/// (the user's decision, 2026-11-09). It ships switched off: while <see cref="Enabled"/> is false nothing is installable, until the
/// calibration (W7) passes.</summary>
public sealed class FrameModelCatalog
{
    /// <summary>The catalogue's schema id.</summary>
    public const string Schema = "voxclip-frame-models/1";

    /// <summary>Whether the lead has switched the face models on.</summary>
    public bool Enabled { get; }
    /// <summary>The one entry.</summary>
    public FrameModel Entry { get; }
    /// <summary>The entries the app may install or load: none while the catalogue is off.</summary>
    public IReadOnlyList<FrameModel> Installable => Enabled ? [Entry] : [];

    /// <summary>The installed catalogue.</summary>
    public FrameModelCatalog() : this(SharedResources.ResolveRoot()) { }

    internal FrameModelCatalog(string sharedRoot) : this(File.ReadAllBytes(Path.Combine(sharedRoot, "catalog", "frame-models.json"))) { }

    internal FrameModelCatalog(byte[] json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.GetProperty("schema").GetString() != Schema || root.GetProperty("models").GetArrayLength() != 1)
                throw new InvalidDataException("Not a face model catalogue.");
            Enabled = root.GetProperty("enabled").GetBoolean();
            Entry = new FrameModel(root.GetProperty("models")[0]);
            if (Enabled && (Entry.Files.Any(file => file.Url is null && file.Bundled is null) || Entry.Calibration.Provisional))
                throw new InvalidDataException("The face models can't be enabled before every file is hosted or bundled and the calibration has passed.");
        }
        catch (Exception error) when (error is KeyNotFoundException or InvalidOperationException or FormatException or JsonException or UriFormatException)
        {
            throw new InvalidDataException("The face model catalogue is not valid.", error);
        }
    }
}
