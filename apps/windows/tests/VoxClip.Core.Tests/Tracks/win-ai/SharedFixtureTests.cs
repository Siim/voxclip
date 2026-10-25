using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed partial class SharedFixtureTests
{
    private static readonly ConcurrentDictionary<string, JsonObject> Files = new(StringComparer.Ordinal);
    private static string DirectoryPath => Path.Combine(FixtureLoader.SharedRoot, "fixtures", "llm");
    private static JsonObject Load(string file) => Files.GetOrAdd(file, name => Fixture(name).AsObject());

    public static IEnumerable<object[]> Cases()
    {
        if (!Directory.Exists(DirectoryPath)) { yield return new object[] { "missing", "missing" }; yield break; }
        foreach (var path in Directory.EnumerateFiles(DirectoryPath, "*.json").Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileNameWithoutExtension(path);
            foreach (var item in Load(name)["cases"]!.AsArray()) yield return new object[] { name, item!["id"]!.GetValue<string>() };
        }
    }

    [Fact]
    public void EnvelopesAndSourceHashes()
    {
        RequireFixtures(Directory.Exists(DirectoryPath));
        foreach (var path in Directory.EnumerateFiles(DirectoryPath, "*.json").Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileNameWithoutExtension(path);
            var data = Load(name);
            Assert.Equal("voxclip-llm-fixtures/1", Text(data, "schema"));
            Assert.Equal(name, Text(data, "id"));
            Assert.Equal("voxclip", Text(data, "origin"));
            var ids = data["cases"]!.AsArray().Select(item => Text(item!, "id")).ToArray();
            Assert.Equal(ids.Length, ids.Distinct(StringComparer.Ordinal).Count());
            foreach (var source in data["sources"]!.AsObject())
            {
                var sourceText = File.ReadAllText(Path.Combine(Path.GetDirectoryName(FixtureLoader.SharedRoot)!, source.Key)).Replace("\r\n", "\n", StringComparison.Ordinal);
                Assert.Equal(source.Value!.GetValue<string>(), Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(sourceText))));
            }
        }
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public async Task GoldenCase(string file, string id)
    {
        RequireFixtures(file != "missing");
        var item = Load(file)["cases"]!.AsArray().Single(item => Text(item!, "id") == id)!;
        var input = item["input"]!;
        var expected = item["expected"];
        var prompts = new ClipPrompts(Catalog());
        JsonNode? actual;
        switch (Text(item, "kind"))
        {
            case "format-transcript":
                var formatted = ClipText.Lines(Entries(input["entries"]!));
                actual = new JsonObject { ["lines"] = Array(formatted.Select(LineJson)), ["rendered"] = ClipText.Render(formatted) };
                break;
            case "to-fixed-1": actual = JsonValue.Create(EditingFormat.ToFixed1(Number(input["value"]!))); break;
            case "format-time": actual = JsonValue.Create(ClipText.Time(Number(input["seconds"]!))); break;
            case "to-fixed-random":
                Assert.Equal("lcg32-scaled-binary64-v1", Text(input, "generator"));
                var state = input["seed"]!.GetValue<uint>();
                var values = expected!.AsArray();
                Assert.Equal(Integer(input, "count"), values.Count);
                for (var sample = 0; sample < values.Count; sample++)
                {
                    state = unchecked(1664525 * state + 1013904223);
                    var value = ((double)state / 4294967296) * Number(input["scale"]!);
                    Assert.Equal(values[sample]!.GetValue<string>(), EditingFormat.ToFixed1(value));
                }
                return;
            case "finalize-clips":
                var words = WordsFrom(input["words"]!);
                var preset = Enum.Parse<ClipPreset>(Text(input, "preset"), true);
                var candidates = input["candidates"]!.AsArray().Select(candidate => new RawClip(Text(candidate!, "title"), Text(candidate!, "reason"), Number(candidate!["score"]!), Number(candidate["start_word"]!), Number(candidate["end_word"]!))).ToArray();
                var lines = input["lines"] is { } supplied ? supplied.AsArray().Select(line => ReadLine(line!).Line).ToArray() : ClipText.Lines(ClipText.Entries(words, new Dictionary<string, string>())).Select(line => line.Line).ToArray();
                var result = ClipValidation.FinalizeClips(new(candidates, words, prompts.Rules(preset), lines, Strings(input["cutWordIds"]), Integer(input, "windowCount", 1), input["snap"]?.GetValue<bool>() ?? false));
                actual = Array(result.Clips.Select(clip => (JsonNode)new JsonObject { ["title"] = clip.Title, ["reason"] = clip.Reason, ["score"] = clip.Score, ["startWord"] = clip.Start, ["endWord"] = clip.End }));
                break;
            case "snap-pair":
                var pair = input["pair"]!.AsArray();
                var snapped = ClipText.Snap(pair[0]!.GetValue<int>(), pair[1]!.GetValue<int>(), input["lines"]!.AsArray().Select(line => ReadLine(line!).Line).ToArray());
                actual = new JsonArray(snapped.Start, snapped.End);
                break;
            case "prepare-entries":
                var items = input["items"]!.AsArray();
                var preparedWords = WordsFrom(items);
                var corrections = items.Where(item => item?["correction"] is not null).ToDictionary(item => Text(item!, "id"), item => Text(item!, "correction"));
                var options = input["options"]!;
                var prepared = Text(options, "feature") == "clipFinder" ? ClipText.Entries(preparedWords, corrections) :
                    TightenVerifier.Entries(preparedWords, corrections, Strings(options["cutWordIds"]), options["scope"]?[0]?.GetValue<int>() ?? 0, options["scope"]?[1]?.GetValue<int>() ?? preparedWords.Length - 1);
                actual = Array(prepared.Select(entry => (JsonNode)new JsonObject { ["id"] = preparedWords[entry.Index].Id, ["index"] = entry.Index, ["text"] = entry.Text, ["start"] = entry.Start, ["end"] = entry.End }));
                break;
            case "string-helpers": actual = JsonValue.Create(ClipText.Limit(ClipText.Trim(Text(input, "text")), Integer(input, "maxLength"))); break;
            case "windows":
                var windowWords = WordsFrom(input["words"]!);
                var windowLines = ClipText.Lines(ClipText.Entries(windowWords, new Dictionary<string, string>()));
                var plan = prompts.Plan(windowLines, Text(input, "choice"), input["instructions"]?.GetValue<string>() ?? "", windowWords[^1].End, Integer(input, "context"), Integer(input, "maxOutputTokensCap", 16000), Text(input, "feature") == "aiTighten", input["localServer"]?.GetValue<bool>() == true);
                actual = new JsonObject { ["context"] = plan.Context, ["outputReserve"] = plan.OutputReserve, ["overhead"] = plan.Overhead, ["budget"] = plan.Budget, ["maxClips"] = plan.MaxClips, ["windows"] = WindowJson(plan.Windows, windowLines, true) };
                break;
            case "pack-lines":
                var packingLines = input["lines"]!.AsArray().Select(line => ReadLine(line!)).ToArray();
                if (expected is JsonObject error)
                {
                    Assert.Equal("contextTooLong", Text(error, "error"));
                    Assert.Throws<ArgumentOutOfRangeException>(() => ClipWindowing.Pack(packingLines, Integer(input, "budget"), Integer(input, "maxWords"), Number(input["overlapSeconds"]!)));
                    return;
                }
                actual = WindowJson(ClipWindowing.Pack(packingLines, Integer(input, "budget"), Integer(input, "maxWords"), Number(input["overlapSeconds"]!)), packingLines, false);
                break;
            case "tighten-verifier":
                var entries = Entries(input["entries"]!);
                var indexedWords = Enumerable.Range(0, entries.Count == 0 ? 0 : entries.Max(entry => entry.Index) + 1).Select(index => Word(index)).ToArray();
                foreach (var entry in input["entries"]!.AsArray()) indexedWords[Integer(entry!, "index")] = indexedWords[Integer(entry!, "index")] with { Id = Text(entry!, "id") };
                var verified = TightenVerifier.Verify(input["edits"]!.DeepClone().AsArray(), entries, indexedWords, prompts.Tighten);
                actual = new JsonObject { ["proposals"] = Array(verified.Proposals.Select(proposal => (JsonNode)new JsonObject { ["lineLabel"] = proposal.LineLabel, ["kind"] = proposal.Kind, ["cutWordIds"] = Array(proposal.CutWordIds.Select(value => (JsonNode)JsonValue.Create(value)!)), ["preselected"] = proposal.Preselected })), ["rejectedCount"] = verified.RejectedCount, ["rejected"] = Array(verified.Rejected.Select(rejection => (JsonNode)new JsonObject { ["editIndex"] = rejection.EditIndex, ["reason"] = rejection.Reason })) };
                break;
            case "render-request": await RenderCase(file, input, expected!); return;
            case "connector-request": await ConnectorCase(ReadRequest(input["request"]!), Text(input, "connector"), input["options"]!.AsObject(), expected!); return;
            default: Assert.Fail($"Unknown shared LLM fixture kind '{Text(item, "kind")}' in {file}/{id}."); return;
        }
        EqualJson(expected, actual);
    }

    private static string Text(JsonNode node, string key) => node[key]!.GetValue<string>();
    private static int Integer(JsonNode node, string key, int fallback = 0) => node[key]?.GetValue<int>() ?? fallback;
    private static double Number(JsonNode node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text switch { "NaN" => double.NaN, "Infinity" => double.PositiveInfinity, "-Infinity" => double.NegativeInfinity, "-0" => -0.0, _ => throw new InvalidDataException("Unknown numeric sentinel: " + text) } : node.GetValue<double>();
    private static HashSet<string> Strings(JsonNode? node) => node?.AsArray().Select(value => value!.GetValue<string>()).ToHashSet(StringComparer.Ordinal) ?? [];
    private static JsonArray Array(IEnumerable<JsonNode> values) => new(values.ToArray());
    private static IReadOnlyList<ClipWord> Entries(JsonNode node) => node.AsArray().Select(entry => new ClipWord(Integer(entry!, "index"), Text(entry!, "text"), Number(entry!["start"]!), Number(entry["end"]!))).ToArray();
    private static TimedWord[] WordsFrom(JsonNode node)
    {
        if (node is JsonObject recipe)
        {
            var generator = Text(recipe, "generator");
            Assert.Contains(generator, new[] { "U100", "W1" });
            return generator == "U100" ? Words(100) : Enumerable.Range(0, 20000).Select(index => Word(index, "w" + index + (index % 15 == 14 ? "." : ""), 0.3 * index, 0.3 * index + 0.25)).ToArray();
        }
        return node.AsArray().Select((item, index) => Word(index, Text(item!, "text"), Number(item!["start"]!), Number(item["end"]!), item["kind"]?.GetValue<string>() switch { "event" => WordKind.Event, "unlabeledSpeech" => WordKind.UnlabeledSpeech, _ => WordKind.Word }) with { Id = item["id"]?.GetValue<string>() ?? "w" + index }).ToArray();
    }
    private static NumberedLine ReadLine(JsonNode node) => new(new(Integer(node, "firstIndex"), Integer(node, "lastIndex"), Number(node["start"]!), Number(node["end"]!), Text(node, "text")), Integer(node, "firstPos"), Integer(node, "lastPos"), node["pauseAfter"]?.GetValue<string>());
    private static JsonNode LineJson(NumberedLine line) => new JsonObject { ["firstPos"] = line.FirstPosition, ["lastPos"] = line.LastPosition, ["firstIndex"] = line.Line.FirstIndex, ["lastIndex"] = line.Line.LastIndex, ["start"] = line.Line.Start, ["end"] = line.Line.End, ["text"] = line.Line.Text, ["pauseAfter"] = line.PauseAfter };
    private static JsonArray WindowJson(IReadOnlyList<ClipWindow> windows, IReadOnlyList<NumberedLine> lines, bool labels) => Array(windows.Select(window =>
    {
        var first = Enumerable.Range(0, lines.Count).First(index => ReferenceEquals(lines[index], window.Lines[0]));
        var value = new JsonObject { ["firstLine"] = first, ["lastLine"] = first + window.Lines.Count - 1, ["firstIndex"] = window.Lines[0].Line.FirstIndex, ["lastIndex"] = window.Lines[^1].Line.LastIndex, ["entryCount"] = window.WordCount, ["estimatedCost"] = window.EstimatedTokens };
        if (labels) value["lineLabels"] = Array(window.Lines.Select(line => (JsonNode)JsonValue.Create(line.Line.Text.Split(' ')[0])!));
        return (JsonNode)value;
    }));
}
