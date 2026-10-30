using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Project;
#pragma warning disable CS1591

namespace VoxClip.Core.Services.VoiceLab;

public sealed class SpeakerModel
{
    private readonly JsonElement document;
    public string Id { get; }
    public string DisplayName { get; }
    public int Dimension { get; }
    public string Preprocessing { get; }
    public IReadOnlyList<ModelFile> Files { get; }
    public string Identity { get; }
    internal SpeakerModel(JsonElement value)
    {
        document = value.Clone();
        Id = value.GetProperty("id").GetString()!;
        DisplayName = value.GetProperty("displayName").GetString()!;
        Dimension = value.GetProperty("dimension").GetInt32();
        Preprocessing = value.GetProperty("preprocessing").GetString()!;
        Files = Array.AsReadOnly(value.GetProperty("files").EnumerateArray().Select(file => new ModelFile(
            file.GetProperty("role").GetString()!, file.GetProperty("name").GetString()!, new Uri(file.GetProperty("url").GetString()!),
            file.GetProperty("bytes").GetInt64(), file.GetProperty("sha256").GetString()!)).ToArray());
        if (Id.Length == 0 || Id.Any(character => character is not (>= 'a' and <= 'z' or >= '0' and <= '9' or '-')) ||
            Files.Any(file => file.Name != Path.GetFileName(file.Name) || file.Name.Contains('\\') || file.Name.StartsWith('.') ||
                file.Url.Scheme != "https" || file.Bytes <= 0 || !VoiceConsentRecord.HashValid(file.Sha256)) ||
            Files.Sum(file => file.Bytes) != value.GetProperty("totalBytes").GetInt64()) throw Unavailable();
        Identity = VoiceConsentStore.Hash(System.Text.Encoding.UTF8.GetBytes(value.GetRawText()));
    }
    public double? CalibratedThreshold(string language = "en")
    {
        try
        {
            var threshold = document.GetProperty("threshold").GetDouble();
            var calibration = document.GetProperty("calibration");
            var margin = calibration.GetProperty("margin");
            static double Number(JsonElement row, string name) => row.GetProperty(name).GetDouble();
            static bool Between(double value, double low, double high) => double.IsFinite(value) && value >= low && value <= high;
            var floor = Number(margin, "absoluteFloor");
            var drift = Number(margin, "crossRuntimeDrift");
            var percentile = Number(margin, "percentileCalibrationImpostorScore");
            var maximum = Number(margin, "maximumCalibrationImpostorScore");
            var far = Number(margin, "farLimit");
            var minimum = Number(margin, "sameSpeakerMinimum");
            var rounded = Math.Ceiling(Math.Max(0m, decimal.Parse(percentile.ToString("R", CultureInfo.InvariantCulture), CultureInfo.InvariantCulture) +
                decimal.Parse(Math.Max(floor, drift).ToString("R", CultureInfo.InvariantCulture), CultureInfo.InvariantCulture)) * 100m) / 100m;
            if (Dimension != 256 || Preprocessing != SpeakerAudio.Version || !Between(threshold, 0, 1) ||
                !document.GetProperty("languages").EnumerateArray().Any(item => item.GetString() == language) ||
                calibration.GetProperty("preprocessing").GetString() != Preprocessing || calibration.GetProperty("outcome").GetString() != "passed" ||
                calibration.GetProperty("modelSha256").GetString() != Files.Single(file => file.Role == "speaker").Sha256 ||
                calibration.GetProperty("vadSha256").GetString() != Files.Single(file => file.Role == "vad").Sha256 ||
                margin.GetProperty("policy").GetString() != "clean-p999-plus-margin-ceil-cent-production-v1" ||
                Number(margin, "percentileProbability") != 0.999 || margin.GetProperty("percentileMethod").GetString() != "linear-(n-1)" ||
                Number(margin, "roundingIncrement") != 0.01 || !Between(floor, 0.002, double.MaxValue) || !Between(drift, 0, double.MaxValue) ||
                !Between(maximum, -1, 1) || !Between(percentile, -1, maximum) || threshold != Number(margin, "candidateThreshold") ||
                threshold != (double)rounded || !Between(far, 0, 0.005) || !Between(minimum, 0.95, 1)) return null;
            var result = calibration.GetProperty("languages").EnumerateArray().Single(row => row.GetProperty("language").GetString() == language);
            var speakers = result.GetProperty("speakers").GetInt32();
            var calibrationSpeakers = result.GetProperty("calibrationSpeakers").GetInt32();
            var clips = result.GetProperty("independentClips").GetInt32();
            var conditions = result.GetProperty("conditions").EnumerateArray().ToArray();
            bool Pass(JsonElement row) => row.GetProperty("impostorPairs").GetInt32() >= 200 && row.GetProperty("sameSpeakerPairs").GetInt32() >= 50 &&
                Between(Number(row, "falseAcceptRate"), 0, far) && Between(Number(row, "sameSpeakerPassRate"), minimum, 1);
            if (calibrationSpeakers < 80 || speakers < calibrationSpeakers || clips < speakers * 3 || result.GetProperty("audioRenders").GetInt32() != clips * 2 ||
                conditions.Length < 4 || !conditions.Select(row => row.GetProperty("sampleRate").GetInt32()).ToHashSet().SetEquals([44100, 48000]) ||
                conditions.Any(row => row.GetProperty("speakers").GetInt32() < 2 || row.GetProperty("independentClips").GetInt32() < row.GetProperty("speakers").GetInt32() * 3 || !Pass(row)) || !Pass(result)) return null;
            return threshold;
        }
        catch (Exception error) when (error is KeyNotFoundException or InvalidOperationException or FormatException or OverflowException) { return null; }
    }
    public (string Model, string Vad) VerifiedFiles(string directory)
    {
        if (Dimension != 256 || Preprocessing != SpeakerAudio.Version || Files.Count != 2 ||
            Files.Count(file => file.Role == "speaker") != 1 || Files.Count(file => file.Role == "vad") != 1) throw Unavailable();
        foreach (var file in Files)
        {
            var path = Path.Combine(directory, file.Name);
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length != file.Bytes) throw Unavailable();
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (Convert.ToHexStringLower(SHA256.HashData(stream)) != file.Sha256) throw Unavailable();
        }
        return (Path.Combine(directory, Files.Single(file => file.Role == "speaker").Name), Path.Combine(directory, Files.Single(file => file.Role == "vad").Name));
    }
    private static VoiceConsentException Unavailable() => new(VoiceConsentError.SpeakerUnavailable);
}

public sealed class SpeakerModelCatalog
{
    public SpeakerModel Entry { get; }
    public SpeakerModelCatalog() : this(SharedResources.ResolveRoot()) { }
    internal SpeakerModelCatalog(string sharedRoot)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(sharedRoot, "catalog", "voice-lab-models.json")));
        var root = document.RootElement;
        if (root.GetProperty("schema").GetString() != "voxclip-voice-models/1" || root.GetProperty("models").GetArrayLength() != 1)
            throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        Entry = new(root.GetProperty("models")[0]);
    }
}
