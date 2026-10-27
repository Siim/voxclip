using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;
namespace VoxClip.Core.Tests;

/// <summary>The persisted timestamp rule (editing §10.1) against shared/fixtures/projects/timestamps.json. The macOS Core
/// replays the same cases, so both platforms read and write the same text for the same instant.</summary>
public sealed class TimestampWireRuleTests
{
    /// <summary>The example projects keep the whole-second timestamps that writers produced before the three-digit rule, so
    /// their first save writes the same instants in canonical form. An example not listed here must already be canonical.</summary>
    private static readonly HashSet<string> NonCanonicalExamples = new(StringComparer.Ordinal)
    {
        "projects/clip-from-long-take", "projects/interview-take", "voice-lab/clipped-seam-render-v3", "voice-lab/disclosure-above-30-render-v3", "voice-lab/disclosure-at-30-render-v3",
        "voice-lab/full-take-project", "voice-lab/full-take-render-v3", "voice-lab/one-sample-gap-render-v3",
        "voice-lab/passage-project", "voice-lab/passage-render-v3", "voice-lab/touching-render-v3", "voice-lab/voice-changer-half-render-v3",
    };

    private static JsonNode Cases() => JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "timestamps.json")))!;

    /// <summary>One timestamp through the project converter.</summary>
    private static string ProjectRoundTrip(string text)
    {
        var converter = new UtcTimestampConverter();
        using var input = new MemoryStream();
        using (var writer = new Utf8JsonWriter(input)) writer.WriteStringValue(text);
        var reader = new Utf8JsonReader(input.ToArray());
        reader.Read();
        var value = converter.Read(ref reader, typeof(DateTimeOffset), JsonSerializerOptions.Default);
        using var output = new MemoryStream();
        using (var writer = new Utf8JsonWriter(output)) converter.Write(writer, value, JsonSerializerOptions.Default);
        return JsonNode.Parse(output.ToArray())!.GetValue<string>();
    }

    /// <summary>A copy of a stored document with every timestamp under a key ending in At written as a save writes it, for
    /// comparing a save with an example project that predates the three-digit rule.</summary>
    internal static JsonNode? CanonicalTimestamps(JsonNode? node)
    {
        var copy = node?.DeepClone();
        Rewrite(copy);
        return copy;
        static void Rewrite(JsonNode? value)
        {
            if (value is JsonObject json)
                foreach (var key in json.Select(pair => pair.Key).ToArray())
                {
                    if (key.EndsWith("At", StringComparison.Ordinal) && json[key] is JsonValue text && text.GetValueKind() == JsonValueKind.String
                        && UtcTimestamp.TryParse(text.GetValue<string>(), out var instant)) json[key] = UtcTimestamp.Format(instant);
                    else Rewrite(json[key]);
                }
            else if (value is JsonArray array)
                foreach (var item in array) Rewrite(item);
        }
    }

    /// <summary>Every string under a key ending in At, by JSON path.</summary>
    private static Dictionary<string, string> Timestamps(JsonNode? node, string path = "")
    {
        var found = new Dictionary<string, string>(StringComparer.Ordinal);
        if (node is JsonObject json)
            foreach (var (key, value) in json)
            {
                if (key.EndsWith("At", StringComparison.Ordinal) && value is JsonValue text && text.GetValueKind() == JsonValueKind.String) found[path + "/" + key] = text.GetValue<string>();
                else foreach (var pair in Timestamps(value, path + "/" + key)) found[pair.Key] = pair.Value;
            }
        else if (node is JsonArray array)
            for (var index = 0; index < array.Count; index++)
                foreach (var pair in Timestamps(array[index], path + "/" + index)) found[pair.Key] = pair.Value;
        return found;
    }

    [Fact]
    public void AcceptedTextsLoadAndSaveInCanonicalForm()
    {
        var texts = Cases()["texts"]!.AsArray();
        Assert.Equal(317, texts.Count);
        foreach (var item in texts)
        {
            var input = item!["input"]!.GetValue<string>();
            var canonical = item["canonical"]!.GetValue<string>();
            Assert.True(UtcTimestamp.TryParse(input, out var value), input);
            Assert.Equal(canonical, UtcTimestamp.Format(value));
            Assert.Equal(0, value.UtcTicks % TimeSpan.TicksPerMillisecond);
            Assert.Equal(canonical, ProjectRoundTrip(input));
            Assert.Equal(canonical, ProjectRoundTrip(canonical));
        }
    }

    [Fact]
    public void RefusedTextsFailEveryReader()
    {
        var rejected = Cases()["rejected"]!.AsArray();
        Assert.Equal(53, rejected.Count);
        var project = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "interview-take.voxclip")))!;
        foreach (var item in rejected)
        {
            var input = item!["input"]!.GetValue<string>();
            var reason = item["reason"]!.GetValue<string>();
            Assert.False(UtcTimestamp.TryParse(input, out _), reason + ": " + input);
            Assert.Throws<JsonException>(() => ProjectRoundTrip(input));
            project["createdAt"] = input;
            var json = project.ToJsonString();
            Assert.Throws<JsonException>(() => ProjectValidation.Validate(json));
            Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(json));
        }
    }

    [Fact]
    public void InstantsWriteTheSharedText()
    {
        var instants = Cases()["instants"]!.AsArray();
        Assert.Equal(232, instants.Count);
        foreach (var item in instants)
        {
            var value = new DateTimeOffset(long.Parse(item!["ticks"]!.GetValue<string>(), System.Globalization.CultureInfo.InvariantCulture), TimeSpan.Zero);
            if (item["canonical"]?.GetValue<string>() is { } canonical) Assert.Equal(canonical, UtcTimestamp.Format(value));
            else Assert.Throws<ArgumentOutOfRangeException>(() => UtcTimestamp.Format(value));
        }
    }

    /// <summary>Seeded instants, never the clock: the same SHA-256 as the generator and the macOS suite, each text stable
    /// through load and save, and each loaded value its instant rounded to the millisecond.</summary>
    [Fact]
    public void SeededInstantsMatchTheSharedDigest()
    {
        var property = Cases()["property"]!;
        var state = property["seed"]!.GetValue<ulong>();
        ulong Next()
        {
            state += 0x9E37_79B9_7F4A_7C15;
            var z = state;
            z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9;
            z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB;
            return z ^ (z >> 31);
        }
        var lines = new List<string>();
        for (var index = 0; index < property["count"]!.GetValue<int>(); index++)
        {
            var milliseconds = (long)(Next() % 315_537_897_599_999UL);
            var offset = (long)(Next() % 9_000UL);
            var ticks = milliseconds * 10_000 + (offset < 4_500 ? offset : offset + 1_000);
            var text = UtcTimestamp.Format(new DateTimeOffset(ticks, TimeSpan.Zero));
            Assert.True(UtcTimestamp.TryParse(text, out var loaded));
            Assert.Equal(text, UtcTimestamp.Format(loaded));
            Assert.Equal((ticks + 5_000) / 10_000 * 10_000, loaded.UtcTicks);
            Assert.True(text.Length == 24 && text.EndsWith('Z'));
            lines.Add(text);
        }
        Assert.Equal(property["first"]!.GetValue<string>(), lines[0]);
        Assert.Equal(property["last"]!.GetValue<string>(), lines[^1]);
        var digest = Convert.ToHexStringLower(SHA256.HashData(Encoding.ASCII.GetBytes(string.Concat(lines.Select(line => line + "\n")))));
        Assert.Equal(property["sha256"]!.GetValue<string>(), digest);
    }

    [Fact]
    public void ExampleProjectsKeepTheirTimestamps()
    {
        var fixtures = Path.Combine(FixtureLoader.SharedRoot, "fixtures");
        var names = new[] { "projects", "voice-lab" }.SelectMany(folder => Directory.GetFiles(Path.Combine(fixtures, folder), "*.voxclip")
            .Select(path => folder + "/" + Path.GetFileNameWithoutExtension(path))).Order(StringComparer.Ordinal).ToArray();
        Assert.Contains("projects/interview-take", names);
        Assert.Contains("projects/clip-from-long-take", names);
        foreach (var name in names)
        {
            var source = File.ReadAllText(Path.Combine(fixtures, name + ".voxclip"));
            var saved = ProjectSerialization.Serialize(ProjectSerialization.Deserialize(source));
            Assert.Equal(saved, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(saved)));
            var before = Timestamps(JsonNode.Parse(source));
            var after = Timestamps(JsonNode.Parse(saved));
            Assert.NotEmpty(before);
            Assert.Equal(before.Keys.Order(StringComparer.Ordinal), after.Keys.Order(StringComparer.Ordinal));
            var canonical = true;
            foreach (var (path, text) in before)
            {
                Assert.True(UtcTimestamp.TryParse(text, out var value), name + " " + path);
                Assert.Equal(UtcTimestamp.Format(value), after[path]);
                canonical &= after[path] == text;
            }
            Assert.True(canonical == !NonCanonicalExamples.Contains(name), name);
        }
    }
}
