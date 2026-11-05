using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>The limits of shared/prompts/clip-autopilot.json (ai.md §16.4): the same numbers fill the system prompts and bound
/// the validator. Twin of the Mac <c>ClipAutopilotLimits</c>.</summary>
public sealed record ClipAutopilotLimits
{
    internal ClipAutopilotLimits(JsonNode? value)
    {
        int Int(string key)
        {
            var number = AiJson.Number(AiJson.Get(value, key));
            if (number is not { } read || read != Math.Round(read) || read < 0 || read > 1_000_000) throw ClipAutopilotPrompt.Missing();
            return (int)read;
        }
        double Double(string key)
        {
            var number = AiJson.Number(AiJson.Get(value, key));
            if (number is not { } read || !double.IsFinite(read) || read < 0) throw ClipAutopilotPrompt.Missing();
            return read;
        }
        MaxTranscriptWords = Int("maxTranscriptWords"); MaxClips = Int("maxClips"); MaxCuts = Int("maxCuts"); MaxPauseCuts = Int("maxPauseCuts");
        MaxRewrites = Int("maxRewrites"); MaxRewriteWords = Int("maxRewriteWords"); MaxRewriteTextWords = Int("maxRewriteTextWords");
        MaxCorrections = Int("maxCorrections"); MaxCorrectionWords = Int("maxCorrectionWords"); MaxZooms = Int("maxZooms");
        MinWordsPerCaption = Int("minWordsPerCaption"); MaxWordsPerCaption = Int("maxWordsPerCaption"); MaxMusic = Int("maxMusic");
        MaxQuestions = Int("maxQuestions"); MaxOptions = Int("maxOptions"); MaxTitleScalars = Int("maxTitleScalars"); MaxHookScalars = Int("maxHookScalars");
        MaxPostScalars = Int("maxPostScalars"); MaxReasonScalars = Int("maxReasonScalars"); MaxMusicPromptScalars = Int("maxMusicPromptScalars");
        MaxNoteBytes = Int("maxNoteBytes"); MaxToneSummaryScalars = Int("maxToneSummaryScalars");
        MinClipSeconds = Double("minClipSeconds"); MaxClipSeconds = Double("maxClipSeconds"); MinTargetSeconds = Double("minTargetSeconds");
        MaxTargetSeconds = Double("maxTargetSeconds"); MaxReasonedSeconds = Double("maxReasonedSeconds"); MinSpeed = Double("minSpeed"); MaxSpeed = Double("maxSpeed");
        MaxZoomSeconds = Double("maxZoomSeconds"); MinZoomScale = Double("minZoomScale"); MaxZoomScale = Double("maxZoomScale");
        MinUnderVoiceDb = Double("minUnderVoiceDb"); MaxUnderVoiceDb = Double("maxUnderVoiceDb");
        if (!(MaxClips >= 1 && MaxRewriteWords >= 2 && MaxCorrectionWords >= 1 && MinWordsPerCaption >= 1 && MaxWordsPerCaption >= MinWordsPerCaption &&
              MinClipSeconds < MaxClipSeconds && MinTargetSeconds < MaxTargetSeconds && MaxTargetSeconds <= MaxReasonedSeconds &&
              MaxReasonedSeconds <= MaxClipSeconds && MinSpeed > 0 && MinSpeed < 1 && MaxSpeed > 1 && MinZoomScale >= 1 &&
              MaxZoomScale >= MinZoomScale && MaxZoomScale <= ClipAutopilotMapping.MaximumZoomScale && MaxUnderVoiceDb >= MinUnderVoiceDb && MaxMusic >= 1))
            throw ClipAutopilotPrompt.Missing();
    }

#pragma warning disable CS1591
    public int MaxTranscriptWords { get; } public int MaxClips { get; } public int MaxCuts { get; } public int MaxPauseCuts { get; }
    public int MaxRewrites { get; } public int MaxRewriteWords { get; } public int MaxRewriteTextWords { get; } public int MaxCorrections { get; }
    public int MaxCorrectionWords { get; } public int MaxZooms { get; } public int MinWordsPerCaption { get; } public int MaxWordsPerCaption { get; }
    public int MaxMusic { get; } public int MaxQuestions { get; } public int MaxOptions { get; } public int MaxTitleScalars { get; } public int MaxHookScalars { get; }
    public int MaxPostScalars { get; } public int MaxReasonScalars { get; } public int MaxMusicPromptScalars { get; } public int MaxNoteBytes { get; }
    public int MaxToneSummaryScalars { get; }
    public double MinClipSeconds { get; } public double MaxClipSeconds { get; } public double MinTargetSeconds { get; } public double MaxTargetSeconds { get; }
    public double MaxReasonedSeconds { get; } public double MinSpeed { get; } public double MaxSpeed { get; } public double MaxZoomSeconds { get; }
    public double MinZoomScale { get; } public double MaxZoomScale { get; } public double MinUnderVoiceDb { get; } public double MaxUnderVoiceDb { get; }
#pragma warning restore CS1591

    /// <summary>A whole number without a decimal point, else its shortest round-trip text (the Mac's <c>String(Double)</c>).</summary>
    internal static string Text(double value) => value == Math.Round(value) ? ((long)value).ToString(CultureInfo.InvariantCulture) : value.ToString("R", CultureInfo.InvariantCulture);

    /// <summary>The <c>{name}</c> values the system prompts name.</summary>
    internal Dictionary<string, string> TemplateValues() => new(StringComparer.Ordinal)
    {
        ["maxClips"] = Text(MaxClips), ["maxRewrites"] = Text(MaxRewrites), ["maxRewriteWords"] = Text(MaxRewriteWords),
        ["maxCorrectionWords"] = Text(MaxCorrectionWords), ["minTargetSeconds"] = Text(MinTargetSeconds), ["maxTargetSeconds"] = Text(MaxTargetSeconds),
        ["maxReasonedSeconds"] = Text(MaxReasonedSeconds), ["minSpeed"] = Text(MinSpeed), ["maxSpeed"] = Text(MaxSpeed),
        ["minWordsPerCaption"] = Text(MinWordsPerCaption), ["maxWordsPerCaption"] = Text(MaxWordsPerCaption), ["minUnderVoiceDb"] = Text(MinUnderVoiceDb),
        ["maxUnderVoiceDb"] = Text(MaxUnderVoiceDb), ["maxZoomSeconds"] = Text(MaxZoomSeconds), ["minZoomScale"] = Text(MinZoomScale),
        ["maxZoomScale"] = Text(MaxZoomScale), ["maxOptions"] = Text(MaxOptions)
    };
}

/// <summary>The fallbacks the validator uses for a value the reply leaves unreadable (ai.md §16.5).</summary>
public sealed record ClipAutopilotDefaults(string StyleId, ClipAutopilotFont Font, ClipAutopilotCaptionCase TextCase, int WordsPerCaption,
    double UnderVoiceDb, double ZoomScale, int Score);

/// <summary>shared/prompts/clip-autopilot.json, read whole: every string the planner sends comes from it (ai.md §16.4). Twin of the
/// Mac <c>ClipAutopilotPrompt</c>.</summary>
public sealed partial class ClipAutopilotPrompt
{
    /// <summary>The file, relative to the shared root.</summary>
    public const string Path = "prompts/clip-autopilot.json";

    private readonly JsonNode transcript;
    private readonly JsonNode request;

    /// <summary>The prompt's own version (6 adds the tone).</summary>
    public int PromptVersion { get; }
    /// <summary>SHA-256 of the file's bytes with CRLF read as LF.</summary>
    public string Sha256 { get; }
    /// <summary>The clip plan's system prompt, its sections joined and its limits filled in.</summary>
    public string System { get; }
    /// <summary>The series' first stage: picking the moments.</summary>
    public string MomentsSystem { get; }
    /// <summary>The limits.</summary>
    public ClipAutopilotLimits Limits { get; }
    /// <summary>The fallbacks.</summary>
    public ClipAutopilotDefaults Defaults { get; }
    /// <summary>The looks in the order the prompt lists them.</summary>
    public IReadOnlyList<ClipLook> Looks { get; }
    /// <summary>The clip plan's schema name.</summary>
    public string SchemaName { get; }
    /// <summary>The clip plan's schema.</summary>
    public JsonObject Schema { get; }
    /// <summary>The moments' schema name.</summary>
    public string MomentsSchemaName { get; }
    /// <summary>The moments' schema.</summary>
    public JsonObject MomentsSchema { get; }
    /// <summary>A clip plan's output cap.</summary>
    public int ClipOutputTokens { get; }
    /// <summary>The moments' output cap.</summary>
    public int MomentsOutputTokens { get; }
    /// <summary>The least a plan waits.</summary>
    public TimeSpan MinimumTimeout { get; }
    /// <summary>Appended to a music prompt that does not say "instrumental".</summary>
    public string InstrumentalSuffix { get; }

    internal static VoxClipException Missing() => new(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");

    /// <summary>Reads the file under <paramref name="sharedRoot"/>.</summary>
    public static ClipAutopilotPrompt Load(string sharedRoot)
    {
        var (document, sha) = ReadShared(sharedRoot, Path);
        return new(document, sha);
    }

    /// <summary>A shared JSON file and the SHA-256 of its bytes with CRLF read as LF, as the Voice Lab prompts are hashed.</summary>
    internal static (JsonObject Document, string Sha256) ReadShared(string sharedRoot, string relative)
    {
        try
        {
            var bytes = File.ReadAllBytes(global::System.IO.Path.Combine(sharedRoot, relative));
            var normal = new List<byte>(bytes.Length);
            for (var index = 0; index < bytes.Length; index++)
                if (bytes[index] != 0x0D || index + 1 == bytes.Length || bytes[index + 1] != 0x0A) normal.Add(bytes[index]);
            using var reader = new StreamReader(new MemoryStream(bytes), Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            var document = JsonNode.Parse(reader.ReadToEnd())!.AsObject();
            return (document, Convert.ToHexStringLower(global::System.Security.Cryptography.SHA256.HashData(normal.ToArray())));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            throw Missing();
        }
    }

    internal ClipAutopilotPrompt(JsonObject document, string sha256)
    {
        int? Int(JsonNode? node) => AiJson.Number(node) is { } number && number == Math.Round(number) && Math.Abs(number) < int.MaxValue ? (int)number : null;
        if (Int(document["schemaVersion"]) != 2 || Int(document["promptVersion"]) is not { } version || version < 1 ||
            AiJson.String(document["schemaName"]) is not { } name || AiJson.String(document["momentsSchemaName"]) is not { } momentsName ||
            !IsSchema(document["schema"]) || !IsSchema(document["momentsSchema"]) ||
            AiJson.String(document["momentsSchema"]?["properties"]?["clips"]?["items"]?["type"]) != "object" ||
            Int(document["maxOutputTokens"]?["clip"]) is not { } clipTokens || clipTokens <= 0 ||
            Int(document["maxOutputTokens"]?["moments"]) is not { } momentsTokens || momentsTokens <= 0 ||
            Int(document["minimumTimeoutSeconds"]) is not { } timeout || timeout <= 0 ||
            AiJson.String(document["music"]?["instrumentalSuffix"]) is not { } suffix) throw Missing();
        var limits = new ClipAutopilotLimits(document["limits"]);
        var values = document["defaults"];
        if (AiJson.String(values?["styleId"]) is not { } style || AiJson.String(values?["fontFamily"]) is not { } family ||
            Int(values?["fontWeight"]) is not { } weight || ClipAutopilotWire.CaptionCase(AiJson.String(values?["case"])) is not { } textCase ||
            Int(values?["wordsPerCaption"]) is not { } words || words < limits.MinWordsPerCaption || words > limits.MaxWordsPerCaption ||
            AiJson.Number(values?["underVoiceDb"]) is not { } under || under < limits.MinUnderVoiceDb || under > limits.MaxUnderVoiceDb ||
            AiJson.Number(values?["zoomScale"]) is not { } scale || scale < limits.MinZoomScale || scale > limits.MaxZoomScale ||
            Int(values?["score"]) is not { } score || score is < 1 or > 10) throw Missing();
        // The looks the prompt offers are exactly the ones the contract knows, each with a description.
        var looks = new List<ClipLook>();
        var lookLines = new List<string>();
        foreach (var item in AiJson.Array(document["looks"]))
        {
            if (ClipAutopilotWire.Look(AiJson.String(item?["id"])) is not { } id || looks.Contains(id) ||
                AiJson.String(item?["description"]) is not { Length: > 0 } description) throw Missing();
            looks.Add(id);
            lookLines.Add("- " + id.Name() + ": " + description);
        }
        if (!looks.ToHashSet().SetEquals(Enum.GetValues<ClipLook>())) throw Missing();
        var templateValues = limits.TemplateValues();
        templateValues["looks"] = string.Join("\n", lookLines);
        PromptVersion = version;
        Sha256 = sha256;
        System = SystemPrompt(document, "plan", templateValues);
        MomentsSystem = SystemPrompt(document, "moments", templateValues);
        Limits = limits;
        Defaults = new(style, new(family, weight), textCase, words, under, scale, score);
        Looks = looks;
        SchemaName = name;
        Schema = document["schema"]!.DeepClone().AsObject();
        MomentsSchemaName = momentsName;
        MomentsSchema = document["momentsSchema"]!.DeepClone().AsObject();
        ClipOutputTokens = clipTokens;
        MomentsOutputTokens = momentsTokens;
        MinimumTimeout = TimeSpan.FromSeconds(timeout);
        InstrumentalSuffix = suffix;
        transcript = document["transcriptBlock"]?.DeepClone() ?? throw Missing();
        request = document["request"]?.DeepClone() ?? throw Missing();
    }

    /// <summary>An object schema whose properties are objects and whose required keys are properties.</summary>
    private static bool IsSchema(JsonNode? node) =>
        node is JsonObject schema && AiJson.String(schema["type"]) == "object" && schema["properties"] is JsonObject properties &&
        properties.All(item => item.Value is JsonObject) &&
        AiJson.Array(schema["required"]).All(key => AiJson.String(key) is { } text && properties.ContainsKey(text));

    private static string SystemPrompt(JsonObject document, string key, IReadOnlyDictionary<string, string> values)
    {
        var names = AiJson.Array(document["system"]?[key]).Select(AiJson.String).OfType<string>().ToArray();
        if (names.Length == 0) throw Missing();
        var parts = names.Select(name => AiJson.String(document["sections"]?[name]) is { Length: > 0 } text ? text : throw Missing());
        return Fill(string.Join("\n\n", parts), values);
    }

    /// <summary>One <c>request</c> template with its <c>{name}</c> values filled in one pass.</summary>
    internal string Request(string key, IReadOnlyDictionary<string, string> values) =>
        Fill(AiJson.String(request[key]) ?? throw Missing(), values);

    internal string TranscriptTemplate(string key) => AiJson.String(transcript[key]) ?? throw Missing();

    internal int LineWords => Math.Max(1, AiJson.Number(transcript["lineWords"]) is { } words ? (int)words : 16);

    /// <summary>Fills <c>{name}</c> placeholders; a placeholder without a value is a defect of the shared file.</summary>
    internal static string Fill(string template, IReadOnlyDictionary<string, string> values)
    {
        var missing = false;
        var result = Placeholder().Replace(template, match =>
        {
            if (values.TryGetValue(match.Groups[1].Value, out var value)) return value;
            missing = true;
            return match.Value;
        });
        if (missing) throw Missing();
        return result;
    }

    [GeneratedRegex("\\{([A-Za-z][A-Za-z0-9]*)\\}", RegexOptions.CultureInvariant)]
    private static partial Regex Placeholder();
}

/// <summary>Reads planner JSON as the Mac's <c>JSONValue</c> accessors do: a key of a non-object is null, a string is only a JSON
/// string, a number only a JSON number, and an array of anything else is empty.</summary>
internal static class AiJson
{
    internal static JsonNode? Get(JsonNode? node, string key) => node is JsonObject json ? json[key] : null;
    internal static string? String(JsonNode? node) => node is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : null;
    internal static double? Number(JsonNode? node) => node is JsonValue value && value.GetValueKind() == JsonValueKind.Number
        ? value.TryGetValue<double>(out var number) ? number : double.Parse(value.ToJsonString(), CultureInfo.InvariantCulture)
        : null;
    internal static IReadOnlyList<JsonNode?> Array(JsonNode? node) => node is JsonArray array ? array.ToArray() : [];
    /// <summary>A finite whole number within ±10⁹.</summary>
    internal static int? Integer(JsonNode? node) =>
        Number(node) is { } number && double.IsFinite(number) && number == Math.Round(number) && Math.Abs(number) <= 1e9 ? (int)number : null;
}
