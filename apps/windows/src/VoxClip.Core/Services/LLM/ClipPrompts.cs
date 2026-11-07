using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Services.LLM;

internal sealed record PromptWindowPlan(int Context, int OutputReserve, int Overhead, int Budget, int? MaxClips, IReadOnlyList<ClipWindow> Windows);

internal sealed class ClipPrompts(LlmCatalog catalog)
{
    internal JsonObject Clips { get; } = catalog.ReadAsset("prompts/clip-finder.json");
    internal JsonObject Tighten { get; } = catalog.ReadAsset("prompts/ai-tighten.json");
    internal JsonObject Preset(ClipPreset preset) => Clips["presets"]!.AsArray().OfType<JsonObject>().Single(item => item["id"]!.GetValue<string>() == preset.ToString().ToLowerInvariant());
    internal ClipPresetRules Rules(ClipPreset preset)
    {
        var settings = Preset(preset);
        return new(settings["minSeconds"]!.GetValue<double>(), settings["maxSeconds"]!.GetValue<double>(), settings["maxClips"]!.GetValue<int>(), settings["noOverlap"]!.GetValue<bool>());
    }
    internal string Instructions(string? text) => ClipText.Limit(ClipText.Trim(text ?? ""), Clips["request"]!["maxInstructionsLength"]!.GetValue<int>());
    internal ClipValidationLimits ValidationLimits
    {
        get
        {
            var limits = Clips["limits"]!;
            return new(limits["titleMaxLength"]!.GetValue<int>(), limits["reasonMaxLength"]!.GetValue<int>(), limits["scoreMin"]!.GetValue<int>(), limits["scoreMax"]!.GetValue<int>(),
                limits["minLengthFloorSeconds"]!.GetValue<double>(), limits["minLengthFactor"]!.GetValue<double>(), limits["maxLengthFactor"]!.GetValue<double>(),
                limits["snapRadiusWords"]!.GetValue<int>(), limits["mostlyCutFraction"]!.GetValue<double>(), limits["nearDuplicateOverlap"]!.GetValue<double>());
        }
    }
    internal string Block(IReadOnlyList<NumberedLine> lines, bool tighten = false)
    {
        var prompt = tighten ? Tighten : Clips;
        return prompt["transcriptBlock"]!["prefix"]!.GetValue<string>() + ClipText.Render(lines) + prompt["transcriptBlock"]!["suffix"]!.GetValue<string>();
    }
    /// <summary>The clip finder's transcript block (AI §11.3, <c>voxclip-sentence-lines-v1</c>): <paramref name="window"/>, lines of
    /// <paramref name="all"/>, each as its number over the whole transcript (from 1), its start time and its words, with no word range
    /// and no pause line.</summary>
    internal string SentenceBlock(IReadOnlyList<ClipWord> entries, IReadOnlyList<NumberedLine> all, IReadOnlyList<NumberedLine> window)
    {
        var block = Clips["transcriptBlock"]!;
        var template = block["line"]!.GetValue<string>();
        var numbers = new Dictionary<int, int>();
        for (var position = 0; position < all.Count; position++) numbers.TryAdd(all[position].Line.FirstIndex, position);
        var rendered = window.Where(line => numbers.ContainsKey(line.Line.FirstIndex)).Select(line =>
        {
            var position = numbers[line.Line.FirstIndex];
            var own = all[position];
            var text = string.Join(" ", entries.Skip(own.FirstPosition).Take(own.LastPosition - own.FirstPosition + 1).Select(entry => entry.Text));
            return System.Text.RegularExpressions.Regex.Replace(template, "\\{(line|time|text)\\}", match => match.Groups[1].Value switch
            {
                "line" => (position + 1).ToString(CultureInfo.InvariantCulture),
                "time" => ClipText.Time(own.Line.Start),
                _ => text
            }, System.Text.RegularExpressions.RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
        });
        return block["prefix"]!.GetValue<string>() + string.Join("\n", rendered) + block["suffix"]!.GetValue<string>();
    }
    /// <summary>The inclusive word range of a reply's inclusive 1-based line range over <paramref name="all"/>: the first line's first word
    /// to the last line's last word; (-1, -1), which finalization drops, when the range names no lines or names them backwards.</summary>
    internal static (double Start, double End) WordRange(double startLine, double endLine, IReadOnlyList<NumberedLine> all)
    {
        if (!double.IsFinite(startLine) || !double.IsFinite(endLine) || startLine != Math.Floor(startLine) || endLine != Math.Floor(endLine) ||
            startLine < 1 || startLine > endLine || endLine > all.Count) return (-1, -1);
        return (all[(int)startLine - 1].Line.FirstIndex, all[(int)endLine - 1].Line.LastIndex);
    }
    /// <summary>The 1-based number of the line of <paramref name="all"/> that holds word <paramref name="index"/>; the last line past the end.</summary>
    internal static int LineNumber(int index, IReadOnlyList<NumberedLine> all)
    {
        for (var position = 0; position < all.Count; position++) if (all[position].Line.LastIndex >= index) return position + 1;
        return all.Count;
    }
    internal string Instruction(ClipPreset preset, string instructions, double duration, ClipWindow? window = null, int count = 1, int maxClips = 0, int? lastEnd = null, IReadOnlyList<NumberedLine>? all = null)
    {
        var request = Clips["request"]!;
        var parts = new List<string> { request["durationLine"]!.GetValue<string>().Replace("{duration}", ClipText.Time(duration), StringComparison.Ordinal) };
        var presetInstruction = Preset(preset)["instruction"]!.GetValue<string>();
        if (presetInstruction.Length > 0) parts.Add(presetInstruction);
        if (instructions.Length > 0) parts.Add((presetInstruction.Length > 0 ? request["alsoPrefix"]!.GetValue<string>() : "") + instructions);
        if (count > 1 && window is not null)
        {
            foreach (var template in request["windowLines"]!.AsArray()) parts.Add(template!.GetValue<string>()
                .Replace("{windowStart}", ClipText.Time(window.Lines[0].Line.Start), StringComparison.Ordinal)
                .Replace("{windowEnd}", ClipText.Time(window.Lines[^1].Line.End), StringComparison.Ordinal)
                .Replace("{maxClips}", maxClips.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal));
            if (preset == ClipPreset.Topics && lastEnd is not null)
            {
                var lastLine = LineNumber(lastEnd.Value, all ?? []);
                parts.Add(request["topicsContinuationLine"]!.GetValue<string>()
                    .Replace("{lastLine}", lastLine.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
                    .Replace("{nextLine}", (lastLine + 1).ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal));
            }
        }
        return string.Join("\n", parts);
    }
    internal IReadOnlyList<ClipWindow> Windows(IReadOnlyList<NumberedLine> lines, ClipPreset preset, string instructions, double duration, int context, int outputCap)
        => Plan(lines, preset.ToString().ToLowerInvariant(), instructions, duration, context, outputCap).Windows;

    internal PromptWindowPlan Plan(IReadOnlyList<NumberedLine> lines, string choice, string instructions, double duration, int context, int outputCap, bool tighten = false, bool localServer = false, string model = "")
    {
        var prompt = tighten ? Tighten : Clips;
        if (lines.Count == 0) return new(context, 0, 0, 0, null, []);
        var longestStart = lines.MaxBy(line => System.Text.Encoding.UTF8.GetByteCount(ClipText.Time(line.Line.Start)))!;
        var longestEnd = lines.MaxBy(line => System.Text.Encoding.UTF8.GetByteCount(ClipText.Time(line.Line.End)))!;
        var longest = new ClipWindow(new[] { longestStart with { Line = longestStart.Line with { End = longestEnd.Line.End } } }, 0, 0, 0);
        var preset = tighten ? ClipPreset.Best : Enum.Parse<ClipPreset>(choice, true);
        var instruction = tighten ? TightenInstruction(choice, instructions, longest, 2) :
            Instruction(preset, instructions, duration, longest, 2, 99, preset == ClipPreset.Topics ? lines[^1].Line.LastIndex : null, lines);
        var overhead = catalog.Estimate(prompt["system"]!.GetValue<string>()) + catalog.Estimate(instruction) + catalog.Estimate(prompt["output"]!["schema"]!.ToJsonString()) + 64;
        var reserve = Math.Min(prompt["generation"]!["maxOutputTokens"]!.GetValue<int>(), outputCap);
        if (localServer) reserve = Math.Min(reserve, Math.Max(1024, context / 4));
        var budget = (int)Math.Floor((context - overhead - reserve) * catalog.Data["policy"]!["tokenEstimate"]!["contextSafetyFactor"]!.GetValue<double>());
        if (budget < 600) throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", model, feature: tighten ? LlmFeature.AiTighten : LlmFeature.ClipFinder);
        var windows = ClipWindowing.Pack(lines, budget, prompt["limits"]!["maxWordsPerRequest"]!.GetValue<int>(), tighten ? 0 : Math.Min(Rules(preset).MaxSeconds, Clips["limits"]!["windowOverlapMaxSeconds"]!.GetValue<double>()), catalog.BytesPerToken);
        return new(context, reserve, overhead, budget, tighten ? null : WindowClips(preset, windows.Count), windows);
    }

    internal string TightenInstruction(string strength, string instructions, ClipWindow? window = null, int count = 1)
    {
        var settings = Tighten["request"]!;
        var parts = new List<string> { settings["strengths"]!.AsArray().Single(item => item!["id"]!.GetValue<string>() == strength)!["instruction"]!.GetValue<string>() };
        var text = ClipText.Limit(ClipText.Trim(instructions), settings["maxInstructionsLength"]!.GetValue<int>());
        if (text.Length > 0) parts.Add(settings["alsoPrefix"]!.GetValue<string>() + text);
        if (count > 1 && window is not null) parts.Add(settings["windowLine"]!.GetValue<string>()
            .Replace("{windowStart}", ClipText.Time(window.Lines[0].Line.Start), StringComparison.Ordinal)
            .Replace("{windowEnd}", ClipText.Time(window.Lines[^1].Line.End), StringComparison.Ordinal));
        return string.Join("\n", parts);
    }

    /// <summary>The prompt's <c>generation.effort</c>, else the AI decision level (AI §2.1).</summary>
    private static Effort GenerationEffort(JsonNode prompt) =>
        prompt["generation"]?["effort"]?.GetValue<string>() is { } name ? Enum.Parse<Effort>(name, true) : EffortLevel.Decision;
    internal LlmRequest TightenRequest(IReadOnlyList<NumberedLine> lines, string instruction, string? language, int? outputReserve = null) =>
        new(LlmFeature.AiTighten, Tighten["system"]!.GetValue<string>(), Block(lines, true), instruction, Tighten["output"]!["name"]!.GetValue<string>(),
            Tighten["output"]!["schema"]!.DeepClone().AsObject(), outputReserve ?? Tighten["generation"]!["maxOutputTokens"]!.GetValue<int>(), GenerationEffort(Tighten),
            catalog.Timeout("cloud"), language, "tighten");
    internal int WindowClips(ClipPreset preset, int count) => Math.Max(Clips["limits"]!["windowMinClips"]!.GetValue<int>(),
        (int)Math.Ceiling(Rules(preset).MaxClips * Clips["limits"]!["windowClipFactor"]!.GetValue<double>() / count));
    internal LlmRequest Request(ClipFinderRequest input, IReadOnlyList<NumberedLine> lines, string instruction, int part, int count, int? outputReserve = null)
    {
        var timeout = catalog.Timeout(input.Connector switch { ConnectorId.ClaudeCode or ConnectorId.Codex => "cli", ConnectorId.Ollama or ConnectorId.LmStudio => "localServer", ConnectorId.AppleFoundation => "appleFoundation", _ => "cloud" });
        var entries = ClipText.Entries(input.Words, input.Corrections, Clips["limits"]!["maxWordTextLength"]!.GetValue<int>());
        return new(LlmFeature.ClipFinder, Clips["system"]!.GetValue<string>(), SentenceBlock(entries, ClipText.Lines(entries), lines), instruction, Clips["output"]!["name"]!.GetValue<string>(), Clips["output"]!["schema"]!.DeepClone().AsObject(),
            outputReserve ?? Clips["generation"]!["maxOutputTokens"]!.GetValue<int>(), GenerationEffort(Clips), timeout, input.Language, $"clips/{input.Preset.ToString().ToLowerInvariant()} part {part} of {count}");
    }
}
