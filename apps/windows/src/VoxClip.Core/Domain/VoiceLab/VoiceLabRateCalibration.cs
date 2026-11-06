#pragma warning disable CS1591
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>How real takes of one voice and model run against <see cref="VoiceLabRewriteFit.Estimate"/> (voice-lab §8.2.2, ADR-R43;
/// Mac <c>VoiceLabRateCalibration</c>): the measured ÷ estimated ratios, robust to the odd failed take, and the spread that gives an
/// estimate its p80. A voice's calibration travels across projects (<c>VoiceLab/calibration/&lt;recordId&gt;.json</c>,
/// <see cref="VoxClip.Core.Services.VoiceLab.VoiceLabRateCalibrationStore"/>); a project's own samples (<c>voiceLab.speakingRateSamples</c> under
/// <see cref="ProjectKey"/>) refine it. Ratios under the model's bare ID describe the 1.8 prior and are never read.
/// Vectors: <c>shared/fixtures/voice-lab/tts-estimator-cases.json</c>.</summary>
public static class VoiceLabRateCalibration
{
    /// <summary>The ratio p80 ÷ p50 observed on 78 real Eleven v4 takes against the current prior, rounded.</summary>
    public const double PriorSpread = 1.15;
    /// <summary>A ratio outside these bounds is a failed measurement (a cut-off take, a missed word check), never a voice's pace.</summary>
    public const double MinimumRatio = 0.25, MaximumRatio = 4;
    /// <summary>Spreads measured from five or more samples are kept within these bounds.</summary>
    public const double MinimumSpread = 1.05, MaximumSpread = 1.6;
    /// <summary>A voice keeps its last 30 ratios per model.</summary>
    public const int VoiceSampleLimit = 30;
    /// <summary>How many project samples it takes to outweigh the voice's calibration: the voice counts as this many samples.</summary>
    public const int VoiceWeight = 3;

    /// <summary>Whether a ratio is a pace rather than a failed measurement.</summary>
    public static bool InBounds(double ratio) => double.IsFinite(ratio) && ratio >= MinimumRatio && ratio <= MaximumRatio;

    /// <summary>The <c>speakingRateSamples</c> key for samples measured against the current prior: <c>"&lt;model&gt;@prior2"</c>.</summary>
    public static string ProjectKey(string modelId) => modelId + "@prior" + VoiceLabRewriteFit.PriorVersion;

    /// <summary>The ratios a calibration reads: within bounds, the last <paramref name="limit"/>, then with outliers trimmed (more than
    /// three scaled median absolute deviations from the median, once there are five or more).</summary>
    public static IReadOnlyList<double> RobustRatios(IReadOnlyList<VoiceLabRateSample>? samples, int limit)
    {
        var bounded = (samples ?? []).Where(sample => sample is not null).Select(sample => sample.Ratio).Where(InBounds).ToArray();
        var ratios = bounded.Skip(Math.Max(0, bounded.Length - Math.Max(0, limit))).ToArray();
        if (ratios.Length < 5) return ratios;
        var center = Median(ratios);
        var deviation = Median(ratios.Select(ratio => Math.Abs(ratio - center)).ToArray()) * 1.4826;
        if (deviation <= 0) return ratios;
        return ratios.Where(ratio => Math.Abs(ratio - center) <= 3 * deviation).ToArray();
    }

    /// <summary>The median of the robust ratios; 1 below two samples.</summary>
    public static double Multiplier(IReadOnlyList<VoiceLabRateSample>? samples, int limit)
    {
        var ratios = RobustRatios(samples, limit);
        return ratios.Count >= 2 ? Median(ratios) : 1;
    }

    /// <summary>p80 ÷ p50 of the robust ratios once there are five or more, within the spread bounds; the prior's spread before.</summary>
    public static double Spread(IReadOnlyList<VoiceLabRateSample>? samples, int limit = VoiceSampleLimit)
    {
        var ratios = RobustRatios(samples, limit);
        if (ratios.Count < 5) return PriorSpread;
        var center = Median(ratios);
        if (!(center > 0)) return PriorSpread;
        return Math.Min(MaximumSpread, Math.Max(MinimumSpread, Quantile(ratios, 0.8) / center));
    }

    /// <summary>The samples <see cref="VoiceLabWordingFit.Multiplier"/> reads for a phrase: the voice's calibration, weighted as
    /// <see cref="VoiceWeight"/> samples of its median, then the project's own samples, newest last. A new project therefore starts from
    /// the voice; its own takes outweigh the voice once there are four of them.</summary>
    public static IReadOnlyList<VoiceLabRateSample> Samples(IReadOnlyList<VoiceLabRateSample>? project, IReadOnlyList<VoiceLabRateSample>? voice)
    {
        var ratios = RobustRatios(voice, VoiceSampleLimit);
        if (ratios.Count < 2) return project ?? [];
        var center = Median(ratios);
        return Enumerable.Range(1, VoiceWeight).Select(index => new VoiceLabRateSample("voice-" + index, center)).Concat(project ?? []).ToArray();
    }

    /// <summary>A project's samples for <paramref name="modelId"/> against the current prior, after its voice's calibration.</summary>
    public static IReadOnlyList<VoiceLabRateSample> Samples(Project project, string modelId, VoiceLabVoiceCalibration? voice) =>
        Samples(ProjectSamples(project, modelId), voice?.Samples(modelId));

    /// <summary>The spread for a project's phrase with <paramref name="modelId"/>.</summary>
    public static double Spread(Project project, string modelId, VoiceLabVoiceCalibration? voice) =>
        Spread(ProjectSamples(project, modelId), voice?.Samples(modelId));

    /// <summary>The spread for a phrase: the project's own once it has five samples, else the voice's, else the prior's.</summary>
    public static double Spread(IReadOnlyList<VoiceLabRateSample>? project, IReadOnlyList<VoiceLabRateSample>? voice) =>
        RobustRatios(project, VoiceLabWordingFit.ProjectSampleLimit).Count >= 5
            ? Spread(project, VoiceLabWordingFit.ProjectSampleLimit) : Spread(voice);

    /// <summary>The duration four takes in five stay within, from a median estimate.</summary>
    public static double P80(double seconds, double spread = PriorSpread) => seconds * spread;

    /// <summary>The project's samples under the current prior's key; samples under the bare model ID are the old prior's.</summary>
    public static IReadOnlyList<VoiceLabRateSample> ProjectSamples(Project project, string modelId) =>
        project.VoiceLab.SpeakingRateSamples?.GetValueOrDefault(ProjectKey(modelId)) ?? [];

    internal static double Median(IReadOnlyList<double> values) => Quantile(values, 0.5);

    /// <summary>Linear interpolation between order statistics (the "type 7" quantile).</summary>
    internal static double Quantile(IReadOnlyList<double> values, double p)
    {
        var sorted = values.Order().ToArray();
        if (sorted.Length == 0) return double.NaN;
        if (sorted.Length == 1) return sorted[0];
        var position = (sorted.Length - 1) * p;
        int lower = (int)Math.Floor(position), upper = (int)Math.Ceiling(position);
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
    }
}

/// <summary>One voice's calibration across projects (Mac <c>VoiceLabVoiceCalibration</c>): per model, its last 30 measured ÷ estimated
/// ratios against the current prior, stored as <c>VoiceLab/calibration/&lt;recordId&gt;.json</c> with the schema
/// <c>voxclip-voice-rate-calibration/1</c>. Ratios against another prior are dropped when read.</summary>
public sealed record VoiceLabVoiceCalibration
{
    public const string SchemaId = "voxclip-voice-rate-calibration/1";
    public string Schema { get; init; } = SchemaId;
    public string RecordId { get; init; }
    public int Prior { get; init; } = VoiceLabRewriteFit.PriorVersion;
    public IReadOnlyDictionary<string, IReadOnlyList<VoiceLabRateSample>> Models { get; init; }
    /// <summary>Set once the takes the app already had were measured (or found to need no measuring).</summary>
    public bool Seeded { get; init; }

    public VoiceLabVoiceCalibration(string recordId, IReadOnlyDictionary<string, IReadOnlyList<VoiceLabRateSample>>? models = null, bool seeded = false)
    {
        RecordId = recordId;
        Models = models ?? new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>(StringComparer.Ordinal);
        Seeded = seeded;
    }

    public IReadOnlyList<VoiceLabRateSample> Samples(string modelId) => Models.GetValueOrDefault(modelId) ?? [];

    /// <summary>Adds one take's ratio for <paramref name="modelId"/>. A take counts once; an invalid or out-of-bounds ratio is not kept.</summary>
    public VoiceLabVoiceCalibration Recording(string modelId, string id, double measured, double estimated)
    {
        if (string.IsNullOrEmpty(modelId) || string.IsNullOrEmpty(id) || !double.IsFinite(measured) || !double.IsFinite(estimated) ||
            measured <= 0 || estimated <= 0) return this;
        var ratio = measured / estimated;
        var previous = Samples(modelId);
        if (!VoiceLabRateCalibration.InBounds(ratio) || previous.Any(sample => sample.Id == id)) return this;
        var next = previous.Append(new VoiceLabRateSample(id, ratio)).ToArray();
        var models = new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>(Models, StringComparer.Ordinal)
        {
            [modelId] = next.Skip(Math.Max(0, next.Length - VoiceLabRateCalibration.VoiceSampleLimit)).ToArray()
        };
        return this with { Models = models };
    }

    public bool Equals(VoiceLabVoiceCalibration? other) => other is not null && Schema == other.Schema && RecordId == other.RecordId &&
        Prior == other.Prior && Seeded == other.Seeded && Models.Count == other.Models.Count &&
        Models.All(pair => other.Models.TryGetValue(pair.Key, out var samples) && samples.SequenceEqual(pair.Value));
    public override int GetHashCode() => HashCode.Combine(Schema, RecordId, Prior, Seeded, Models.Count);

    /// <summary>A stored calibration as this build reads it: the right schema and record, and only ratios against this prior. A wrong
    /// schema or record, or a malformed document, throws <see cref="VoiceLabLengthBudgetException"/>.</summary>
    public static VoiceLabVoiceCalibration Decode(string json, string recordId)
    {
        JsonObject root;
        try { root = JsonNode.Parse(json) as JsonObject ?? throw Invalid(); }
        catch (JsonException) { throw Invalid(); }
        string Text(string key) => root[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : throw Invalid();
        var schema = Text("schema");
        var record = Text("recordId");
        if (root["prior"] is not JsonValue priorValue || !priorValue.TryGetValue<int>(out var prior)) throw Invalid();
        if (root["seeded"] is not JsonValue seededValue || !seededValue.TryGetValue<bool>(out var seeded)) throw Invalid();
        if (root["models"] is not JsonObject models) throw Invalid();
        if (schema != SchemaId || record != recordId) throw Invalid();
        var parsed = new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>(StringComparer.Ordinal);
        foreach (var (model, node) in models)
        {
            if (node is not JsonArray rows) throw Invalid();
            var samples = rows.Select(row => row is JsonObject sample && sample["id"] is JsonValue id && id.TryGetValue<string>(out var text) &&
                sample["ratio"] is JsonValue ratio && ratio.TryGetValue<double>(out var number) ? new VoiceLabRateSample(text, number) : throw Invalid()).ToArray();
            parsed[model] = samples;
        }
        if (prior != VoiceLabRewriteFit.PriorVersion) return new(recordId);
        var clean = parsed.Where(pair => pair.Key.Length > 0).ToDictionary(pair => pair.Key, pair =>
        {
            var kept = pair.Value.Where(sample => sample.Id.Length > 0 && VoiceLabRateCalibration.InBounds(sample.Ratio)).ToArray();
            return (IReadOnlyList<VoiceLabRateSample>)kept.Skip(Math.Max(0, kept.Length - VoiceLabRateCalibration.VoiceSampleLimit)).ToArray();
        }, StringComparer.Ordinal);
        return new(recordId, clean, seeded);
    }

    /// <summary>The stored form: sorted keys, indented, as the Mac writes it.</summary>
    public string Encoded()
    {
        var models = new JsonObject();
        foreach (var (model, samples) in Models.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            models[model] = new JsonArray(samples.Select(sample => (JsonNode)new JsonObject { ["id"] = sample.Id, ["ratio"] = sample.Ratio }).ToArray());
        var root = new JsonObject { ["models"] = models, ["prior"] = Prior, ["recordId"] = RecordId, ["schema"] = Schema, ["seeded"] = Seeded };
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    private static VoiceLabLengthBudgetException Invalid() => new(VoiceLabLengthBudgetErrorCode.InvalidInput);
}
