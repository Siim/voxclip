using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>The frame types in the Mac's JSON shape (Swift's synthesized Codable): the same keys, a nil optional left out, keys
/// written in sorted order as the Mac's <c>ProjectJSON</c> encoder writes them. A reader returns null for a value the Mac's
/// decoder would refuse: a missing required key or a value of the wrong type.</summary>
public static class FrameJson
{
    /// <summary>The raw value of <see cref="FrameEyes"/>, as the Mac writes it.</summary>
    public static string EyesName(FrameEyes eyes) => eyes switch
    {
        FrameEyes.Open => "open",
        FrameEyes.Closed => "closed",
        _ => "unknown",
    };

    // MARK: Writing

    /// <summary>A rect: <c>{height, width, x, y}</c>.</summary>
    public static JsonObject Write(ClipEffectRect rect) => new()
    {
        ["height"] = rect.Height, ["width"] = rect.Width, ["x"] = rect.X, ["y"] = rect.Y,
    };

    /// <summary>A face; unmeasured parts are left out.</summary>
    public static JsonObject Write(FrameFace face)
    {
        var value = new JsonObject();
        if (face.CaptureQuality is { } quality) value["captureQuality"] = quality;
        value["eyes"] = EyesName(face.Eyes);
        if (face.LeftEyeAspect is { } left) value["leftEyeAspect"] = left;
        if (face.Pitch is { } pitch) value["pitch"] = pitch;
        value["rect"] = Write(face.Rect);
        if (face.RightEyeAspect is { } right) value["rightEyeAspect"] = right;
        if (face.Yaw is { } yaw) value["yaw"] = yaw;
        return value;
    }

    /// <summary>A screen: <c>{framed, rect, textBoxes, textCoverage}</c>.</summary>
    public static JsonObject Write(FrameScreen screen) => new()
    {
        ["framed"] = screen.Framed, ["rect"] = Write(screen.Rect), ["textBoxes"] = screen.TextBoxes, ["textCoverage"] = screen.TextCoverage,
    };

    /// <summary>An observation; without a face, <c>face</c> is left out.</summary>
    public static JsonObject Write(FrameObservation frame)
    {
        var value = new JsonObject();
        if (frame.Face is { } face) value["face"] = Write(face);
        value["faceCount"] = frame.FaceCount;
        value["screens"] = new JsonArray([.. frame.Screens.Select(screen => (JsonNode)Write(screen))]);
        value["textRects"] = new JsonArray([.. frame.TextRects.Select(rect => (JsonNode)Write(rect))]);
        value["time"] = frame.Time;
        return value;
    }

    /// <summary>A clip's analysis, as <c>voxclip-cli analyze-frames</c> reports it.</summary>
    public static JsonObject Write(FrameAnalysis analysis) => new()
    {
        ["contentKey"] = analysis.ContentKey,
        ["opening"] = Array(analysis.Opening.Select(Write)),
        ["sentences"] = Array(analysis.Sentences.Select(Write)),
        ["timings"] = new JsonObject
        {
            ["analyzedFrames"] = analysis.Timings.AnalyzedFrames, ["cachedFrames"] = analysis.Timings.CachedFrames,
            ["openingSeconds"] = analysis.Timings.OpeningSeconds, ["sentenceSeconds"] = analysis.Timings.SentenceSeconds,
        },
        ["version"] = analysis.Version,
    };

    /// <summary>An opening choice: <c>{shift, time}</c>.</summary>
    public static JsonObject Write(OpeningFrameChoice choice) => new() { ["shift"] = choice.Shift, ["time"] = choice.Time };

    /// <summary>A face-follow plan: <c>{centerX, centerY, cropHeight, cropWidth, path: [{t, x, y}]}</c>.</summary>
    public static JsonObject Write(FaceFollowPlan plan) => new()
    {
        ["centerX"] = plan.CenterX, ["centerY"] = plan.CenterY, ["cropHeight"] = plan.CropHeight, ["cropWidth"] = plan.CropWidth,
        ["path"] = Array(plan.Path.Select(point => new JsonObject { ["t"] = point.T, ["x"] = point.X, ["y"] = point.Y })),
    };

    /// <summary>A cover choice: <c>{score, time}</c>.</summary>
    public static JsonObject Write(CoverFrameChoice choice) => new() { ["score"] = choice.Score, ["time"] = choice.Time };

    /// <summary>A blur span: <c>{end, frames, rect, start}</c>.</summary>
    public static JsonObject Write(FrameBlurSpan span) => new()
    {
        ["end"] = span.End, ["frames"] = span.Frames, ["rect"] = Write(span.Rect), ["start"] = span.Start,
    };

    /// <summary>A blur candidate as the Mac encodes it: <c>{end, frames, id, rect, start}</c>, the rect an object.</summary>
    public static JsonObject Write(ClipAutopilotFrames.BlurCandidate candidate) => new()
    {
        ["end"] = candidate.End, ["frames"] = candidate.Frames, ["id"] = candidate.Id, ["rect"] = Write(candidate.Rect), ["start"] = candidate.Start,
    };

    /// <summary>A cover candidate: <c>{frame, id, score, time}</c>.</summary>
    public static JsonObject Write(ClipAutopilotFrames.CoverCandidate candidate) => new()
    {
        ["frame"] = candidate.Frame, ["id"] = candidate.Id, ["score"] = candidate.Score, ["time"] = candidate.Time,
    };

    /// <summary>A sentence sample: <c>{firstWord, lastWord, time}</c>.</summary>
    public static JsonObject Write(FrameSample sample) => new()
    {
        ["firstWord"] = sample.FirstWord, ["lastWord"] = sample.LastWord, ["time"] = sample.Time,
    };

    /// <summary>A JSON array of written values.</summary>
    public static JsonArray Array(IEnumerable<JsonNode> items) => new([.. items]);

    // MARK: The Mac CLI's text

    /// <summary><paramref name="node"/> as the Mac's <c>voxclip-cli</c> prints a JSON value: <c>JSONEncoder</c> with sorted keys
    /// (ordinal) and unescaped slashes, compact, numbers as <see cref="SwiftNumber"/> writes them. No final newline.
    /// shared/fixtures/clip-frames/analyze-frames-cli-cases.json pins it.</summary>
    public static string MacText(JsonNode? node)
    {
        var text = new System.Text.StringBuilder();
        WriteMac(text, node);
        return text.ToString();
    }

    /// <summary>A number as Swift's <c>JSONEncoder</c> writes it: the Double's <c>description</c> (the shortest round-trip digits; an
    /// exponent of two digits at least below 1e-4 and above 2^53, as <c>1.234e-05</c>) without a trailing <c>.0</c>, so 1 is "1"
    /// and −0 is "-0".</summary>
    public static string SwiftNumber(double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value), "JSON has no infinities or NaN.");
        if (value == 0) return double.IsNegative(value) ? "-0" : "0";
        var sign = value < 0 ? "-" : "";
        var shortest = Math.Abs(value).ToString("R", System.Globalization.CultureInfo.InvariantCulture);
        var marker = shortest.IndexOfAny(['E', 'e']);
        var mantissa = marker < 0 ? shortest : shortest[..marker];
        var exponent = marker < 0 ? 0 : int.Parse(shortest[(marker + 1)..], System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture);
        var point = mantissa.IndexOf('.');
        var whole = point < 0 ? mantissa : mantissa[..point];
        var every = point < 0 ? mantissa : whole + mantissa[(point + 1)..];
        var lead = every.Length - every.TrimStart('0').Length;
        var digits = every.Trim('0');
        if (digits.Length == 0) digits = "0";
        var scientific = whole.Length - lead - 1 + exponent;
        if (scientific < -4 || Math.Abs(value) > 9007199254740992.0)
        {
            var rest = digits.Length > 1 ? "." + digits[1..] : "";
            return sign + digits[0] + rest + "e" + (scientific < 0 ? "-" : "+")
                + Math.Abs(scientific).ToString("00", System.Globalization.CultureInfo.InvariantCulture);
        }
        if (scientific < 0) return sign + "0." + new string('0', -scientific - 1) + digits;
        var integer = digits.Length > scientific + 1 ? digits[..(scientific + 1)] : digits.PadRight(scientific + 1, '0');
        return sign + integer + (digits.Length > scientific + 1 ? "." + digits[(scientific + 1)..] : "");
    }

    private static void WriteMac(System.Text.StringBuilder text, JsonNode? node)
    {
        switch (node)
        {
            case null:
                text.Append("null");
                return;
            case JsonObject value:
                text.Append('{');
                var first = true;
                foreach (var key in value.Select(pair => pair.Key).Order(StringComparer.Ordinal))
                {
                    if (!first) text.Append(',');
                    first = false;
                    WriteMacString(text, key);
                    text.Append(':');
                    WriteMac(text, value[key]);
                }
                text.Append('}');
                return;
            case JsonArray items:
                text.Append('[');
                for (var index = 0; index < items.Count; index++)
                {
                    if (index > 0) text.Append(',');
                    WriteMac(text, items[index]);
                }
                text.Append(']');
                return;
            case JsonValue value:
                switch (value.GetValueKind())
                {
                    case JsonValueKind.String: WriteMacString(text, value.GetValue<string>()); return;
                    case JsonValueKind.True: text.Append("true"); return;
                    case JsonValueKind.False: text.Append("false"); return;
                    case JsonValueKind.Null: text.Append("null"); return;
                    case JsonValueKind.Number:
                        // The Mac's JSONValue holds every number as a Double, integers too.
                        text.Append(SwiftNumber(AsDouble(value) ?? throw new ArgumentException("A JSON number could not be read.", nameof(node))));
                        return;
                }
                break;
        }
        throw new ArgumentException("Not a JSON value.", nameof(node));
    }

    /// <summary>A string as Swift's JSONWriter escapes it: quote, backslash and control characters; slashes and non-ASCII as they are.</summary>
    private static void WriteMacString(System.Text.StringBuilder text, string value)
    {
        text.Append('"');
        foreach (var character in value)
        {
            switch (character)
            {
                case '"': text.Append("\\\""); break;
                case '\\': text.Append("\\\\"); break;
                case '\n': text.Append("\\n"); break;
                case '\r': text.Append("\\r"); break;
                case '\t': text.Append("\\t"); break;
                case '\b': text.Append("\\b"); break;
                case '\f': text.Append("\\f"); break;
                default:
                    if (character < 0x20) text.Append("\\u").Append(((int)character).ToString("x4", System.Globalization.CultureInfo.InvariantCulture));
                    else text.Append(character);
                    break;
            }
        }
        text.Append('"');
    }

    // MARK: Reading

    /// <summary>A rect, or null when a side is missing or not a number.</summary>
    public static ClipEffectRect? ReadRect(JsonNode? node) =>
        node is JsonObject value && Number(value, "x") is { } x && Number(value, "y") is { } y && Number(value, "width") is { } width
        && Number(value, "height") is { } height ? new ClipEffectRect(x, y, width, height) : null;

    /// <summary>A face with its stored <c>eyes</c>, or null when it is not one.</summary>
    public static FrameFace? ReadFace(JsonNode? node)
    {
        if (node is not JsonObject value || ReadRect(value["rect"]) is not { } rect || Eyes(value["eyes"]) is not { } eyes) return null;
        if (!Optional(value, "captureQuality", out var quality) || !Optional(value, "leftEyeAspect", out var left)
            || !Optional(value, "rightEyeAspect", out var right) || !Optional(value, "yaw", out var yaw) || !Optional(value, "pitch", out var pitch)) return null;
        return new FrameFace(rect, quality, left, right, yaw, pitch) { Eyes = eyes };
    }

    /// <summary>A screen, or null when it is not one.</summary>
    public static FrameScreen? ReadScreen(JsonNode? node) =>
        node is JsonObject value && ReadRect(value["rect"]) is { } rect && Integer(value["textBoxes"]) is { } boxes
        && Number(value, "textCoverage") is { } coverage && value["framed"] is JsonValue framed && framed.GetValueKind() is JsonValueKind.True or JsonValueKind.False
            ? new FrameScreen(rect, boxes, coverage, framed.GetValue<bool>()) : null;

    /// <summary>An observation, or null when it is not one.</summary>
    public static FrameObservation? ReadObservation(JsonNode? node)
    {
        if (node is not JsonObject value || Number(value, "time") is not { } time || Integer(value["faceCount"]) is not { } faceCount) return null;
        FrameFace? face = null;
        if (value["face"] is { } faceNode && (face = ReadFace(faceNode)) is null) return null;
        if (ReadRects(value["textRects"]) is not { } texts || ReadList(value["screens"], ReadScreen) is not { } screens) return null;
        return new FrameObservation(time) { FaceCount = faceCount, Face = face, TextRects = texts, Screens = screens };
    }

    /// <summary>A clip's analysis, or null when it is not one.</summary>
    public static FrameAnalysis? ReadAnalysis(JsonNode? node)
    {
        if (node is not JsonObject value || value["contentKey"] is not JsonValue key || key.GetValueKind() != JsonValueKind.String
            || Integer(value["version"]) is not { } version || value["timings"] is not JsonObject timings
            || ReadList(value["sentences"], ReadObservation) is not { } sentences || ReadList(value["opening"], ReadObservation) is not { } opening
            || Number(timings, "sentenceSeconds") is not { } sentenceSeconds || Number(timings, "openingSeconds") is not { } openingSeconds
            || Integer(timings["cachedFrames"]) is not { } cached || Integer(timings["analyzedFrames"]) is not { } analyzed) return null;
        return new FrameAnalysis(key.GetValue<string>(), sentences, opening, new(sentenceSeconds, openingSeconds, cached, analyzed)) { Version = version };
    }

    private static FrameEyes? Eyes(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() switch
        {
            "open" => FrameEyes.Open,
            "closed" => FrameEyes.Closed,
            "unknown" => FrameEyes.Unknown,
            _ => null,
        } : null;

    private static double? Number(JsonObject value, string key) => value[key] is JsonValue number ? AsDouble(number) : null;

    /// <summary>A number node's value, parsed or built in memory as any numeric type.</summary>
    internal static double? AsDouble(JsonValue value)
    {
        if (value.GetValueKind() != JsonValueKind.Number) return null;
        if (value.TryGetValue<double>(out var number)) return number;
        if (value.TryGetValue<long>(out var whole)) return whole;
        if (value.TryGetValue<int>(out var small)) return small;
        return value.TryGetValue<float>(out var single) ? single : null;
    }

    /// <summary>An optional number: absent and null are fine (nil); anything else must be a number.</summary>
    private static bool Optional(JsonObject value, string key, out double? result)
    {
        result = null;
        if (value[key] is null) return true;
        result = Number(value, key);
        return result is not null;
    }

    private static int? Integer(JsonNode? node)
    {
        if (node is not JsonValue value || value.GetValueKind() != JsonValueKind.Number) return null;
        if (value.TryGetValue<int>(out var whole)) return whole;
        return AsDouble(value) is { } number && number == Math.Floor(number) && number is >= int.MinValue and <= int.MaxValue ? (int)number : null;
    }

    private static IReadOnlyList<T>? ReadList<T>(JsonNode? node, Func<JsonNode?, T?> read) where T : class
    {
        if (node is not JsonArray array) return null;
        var result = new List<T>(array.Count);
        foreach (var item in array)
        {
            if (read(item) is not { } value) return null;
            result.Add(value);
        }
        return result;
    }

    private static IReadOnlyList<ClipEffectRect>? ReadRects(JsonNode? node)
    {
        if (node is not JsonArray array) return null;
        var result = new List<ClipEffectRect>(array.Count);
        foreach (var item in array)
        {
            if (ReadRect(item) is not { } value) return null;
            result.Add(value);
        }
        return result;
    }
}

/// <summary>The frame analyzer's cache file, <c>Cache/&lt;contentKey&gt;/frames/analysis-v2.json</c> (architecture §8.2, ADR-R48),
/// in the Mac's shape: <c>{"frames": {"&lt;pass&gt;:&lt;millisecond&gt;": observation}, "schema": "voxclip-frames/2"}</c>. A pass is
/// a decode tolerance with three decimals (<c>"0.250"</c>).</summary>
public static class FrameAnalysisFile
{
    /// <summary>The file's schema id; a file of another version is never read.</summary>
    public const string SchemaId = "voxclip-frames/2";
    /// <summary>The file's name in the cache entry's <c>frames</c> folder.</summary>
    public const string FileName = "analysis-v2.json";

    /// <summary>The cached observations by key; empty when the text is not this version's file or any observation is unreadable, as
    /// on the Mac.</summary>
    public static IReadOnlyDictionary<string, FrameObservation> Read(string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject file || file["schema"] is not JsonValue schema || schema.GetValueKind() != JsonValueKind.String
                || schema.GetValue<string>() != SchemaId || file["frames"] is not JsonObject frames) return new Dictionary<string, FrameObservation>();
            var result = new Dictionary<string, FrameObservation>(StringComparer.Ordinal);
            foreach (var (key, value) in frames)
            {
                if (FrameJson.ReadObservation(value) is not { } observation) return new Dictionary<string, FrameObservation>();
                result[key] = observation;
            }
            return result;
        }
        catch (JsonException)
        {
            return new Dictionary<string, FrameObservation>();
        }
    }

    /// <summary>The file's JSON for <paramref name="frames"/>, keys in ordinal order, indented, ending in a newline.</summary>
    public static string Write(IReadOnlyDictionary<string, FrameObservation> frames)
    {
        var map = new JsonObject();
        foreach (var key in frames.Keys.Order(StringComparer.Ordinal)) map[key] = FrameJson.Write(frames[key]);
        var file = new JsonObject { ["frames"] = map, ["schema"] = SchemaId };
        return file.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n";
    }

    /// <summary>The key a frame is cached under: its pass and the millisecond asked for, rounded half away from zero.</summary>
    public static string Key(string pass, double time) =>
        pass + ":" + ((long)Math.Round(time * 1000, MidpointRounding.AwayFromZero)).ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>The pass name of a decode tolerance: its seconds with three decimals.</summary>
    public static string Pass(double tolerance) => FrameSheetFrame.Fixed(tolerance, 3);
}
