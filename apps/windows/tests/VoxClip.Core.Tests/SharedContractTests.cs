using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;
namespace VoxClip.Core.Tests;

public sealed class SharedContractTests
{
    [Fact]
    public void UnicodeNormalizationUsesIcuRatherThanInvariantMode()
        => Assert.Equal("\u00F5", "o\u0303".Normalize(System.Text.NormalizationForm.FormC));

    [Fact]
    public void SettingsPreserveUnknownFlatKeysAndProviderModels()
    {
        const string source = """{"schema":"voxclip-settings/1","llm.model.ollama":"local-model","fork.example":true}""";
        var settings = JsonSerializer.Deserialize(source, SettingsJsonContext.Default.AppSettings);
        Assert.NotNull(settings);
        Assert.Equal("local-model", settings.Values["llm.model.ollama"].GetString());
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(source), JsonNode.Parse(JsonSerializer.Serialize(settings, SettingsJsonContext.Default.AppSettings))));
    }

    [Theory]
    [InlineData("1.2", "1.2.0", 0)]
    [InlineData("v1.2.3", "1.2.2", 1)]
    [InlineData("1.2.3-beta", "1.2.3", -1)]
    [InlineData("1.2.3+build", "1.2.3", 0)]
    [InlineData("999999999999999999999", "3", 1)]
    public void VersionOrdering(string left, string right, int expected)
        => Assert.Equal(expected, Math.Sign(VersionComparison.CompareVersions(left, right)));

    [Fact]
    public void VersionOrderingFollowsSharedFixture()
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "version", "compare.json")))!;
        Assert.Equal("voxclip-version-fixture/1", root["schema"]!.GetValue<string>());
        var cases = root["cases"]!.AsArray();
        Assert.Equal(9, cases.Count);
        foreach (var row in cases)
        {
            var (left, right) = (row![0]!.GetValue<string>(), row[1]!.GetValue<string>());
            Assert.Equal((left, right, row[2]!.GetValue<int>()), (left, right, Math.Sign(VersionComparison.CompareVersions(left, right))));
        }
    }

    [Theory]
    [InlineData("Authorization: Bearer eyJhbGciOi.J9.abc", "Authorization: Bearer [REDACTED]")]
    [InlineData("{\"client_secret\":\"s3cr3t-value-123\"}", "{\"client_secret\":\"[REDACTED]\"}")]
    [InlineData("GET https://example.com/?code=temporary-code&alt=json", "GET https://example.com/?code=[REDACTED]&alt=json")]
    [InlineData("/Users/alice/Movies/take.mov failed", "~/Movies/take.mov failed")]
    [InlineData("status 401 from api.elevenlabs.io", "status 401 from api.elevenlabs.io")]
    [InlineData("Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic [REDACTED]")]
    public void RedactsMetadata(string input, string expected)
        => Assert.Equal(expected, new Redactor(homeDirectory: "/Users/alice").Redact(input));

    [Fact]
    public void RedactsKnownValuesAndPreservesShortValues()
    {
        var redactor = new Redactor(["synthetic-value-for-tests", "short"]);
        Assert.Equal("[REDACTED] short", redactor.Redact("synthetic-value-for-tests short"));
    }

    [Fact]
    public void RedactorFollowsSharedFixture()
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "redaction", "cases.json")))!;
        Assert.Equal("voxclip-redaction-fixture/1", root["schema"]!.GetValue<string>());
        // Mac Core checks the same list, so both platforms run identical patterns in the same order.
        Assert.Equal(root["rules"]!.AsArray().Select(rule => (rule!["pattern"]!.GetValue<string>(), rule["template"]!.GetValue<string>())),
            Redactor.Rules.Select(rule => (rule.Pattern.ToString(), rule.Template)));
        var cases = root["cases"]!.AsArray();
        Assert.Equal(124, cases.Count);
        foreach (var row in cases)
        {
            var redactor = new Redactor(homeDirectory: row!["home"]?.GetValue<string>() ?? "");
            var input = row["input"]!.GetValue<string>();
            Assert.Equal(row["output"]!.GetValue<string>(), redactor.Redact(input));
        }
    }

    [Fact]
    public void ProviderKeysRedactWhetherOrNotRegistered()
    {
        const string fal = "6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5:0f1e2d3c4b5a69788796a5b4c3d2e1f0", sync = "3f9a1c0e-7b2d-4e8f-a6c5-1d2e3f4a5b6c";
        foreach (var redactor in new[] { new Redactor(), new Redactor([fal, sync]) })
        {
            Assert.Equal("Authorization: Key [REDACTED]", redactor.Redact("Authorization: Key " + fal));
            Assert.Equal("authorization: key [REDACTED] next", redactor.Redact("authorization: key " + fal + " next"));
            Assert.Equal("{\"authorization\":\"Key [REDACTED]\"}", redactor.Redact("{\"authorization\":\"Key " + fal + "\"}"));
            Assert.Equal("x-api-key: [REDACTED]", redactor.Redact("x-api-key: " + sync));
        }
    }

    [Fact]
    public void ProjectFixturesRoundTripWithoutChangingWordsOrJson()
    {
        var paths = Directory.GetFiles(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects"), "*.voxclip");
        Assert.NotEmpty(paths);
        foreach (var path in paths)
        {
            var source = File.ReadAllText(path);
            var project = ProjectSerialization.Deserialize(source);
            var roundTrip = ProjectSerialization.Serialize(project);
            // The examples store whole seconds, which a save writes once in canonical form (editing §10.1).
            Assert.True(JsonNode.DeepEquals(TimestampWireRuleTests.CanonicalTimestamps(JsonNode.Parse(source)), JsonNode.Parse(roundTrip)), Path.GetFileName(path));
        }
    }

    [Fact]
    public void EveryBundledStyleDeserializesWithSourceGeneration()
    {
        var paths = Directory.GetFiles(Path.Combine(FixtureLoader.SharedRoot, "caption-styles", "styles"), "*.json");
        Assert.NotEmpty(paths);
        foreach (var path in paths)
        {
            var style = JsonSerializer.Deserialize(File.ReadAllText(path), ProjectJsonContext.Default.CaptionStyle);
            Assert.NotNull(style);
            Assert.Equal(Path.GetFileNameWithoutExtension(path), style.Id);
            Assert.Equal(1, style.SchemaVersion);
            Assert.Equal(1, style.Font.SizeScale);
        }
    }

    [Fact]
    public void ExportPresetsUseTheArchitectureRules()
    {
        Assert.Equal(new PixelSize(1920, 1080), ExportPresets.OutputSize(new(2400, 1350), ExportAspect.Source));
        Assert.Equal(new PixelSize(1080, 1920), ExportPresets.OutputSize(new(1920, 1080), ExportAspect.Portrait));
        Assert.Equal(8_000_000, ExportPresets.VideoBitrate(new(1920, 1080), ExportAspect.Landscape, ExportQuality.Standard, 30));
        Assert.Equal(18_000_000, ExportPresets.VideoBitrate(new(1920, 1080), ExportAspect.Landscape, ExportQuality.High, 60));
    }

    [Fact]
    public void ExportPresetsFollowSharedFixture()
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "export", "presets.json")))!;
        Assert.Equal("voxclip-export-fixture/1", root["schema"]!.GetValue<string>());
        var cases = root["cases"]!.AsArray();
        Assert.Equal(15, cases.Count);
        foreach (var entry in cases)
        {
            var source = new PixelSize(entry!["source"]![0]!.GetValue<int>(), entry["source"]![1]!.GetValue<int>());
            var aspect = entry["aspect"]!.GetValue<string>() switch
            {
                "source" => ExportAspect.Source, "16:9" => ExportAspect.Landscape, "9:16" => ExportAspect.Portrait, "1:1" => ExportAspect.Square,
                var other => throw new InvalidDataException("Unknown export fixture aspect: " + other)
            };
            var quality = entry["quality"]!.GetValue<string>() switch
            {
                "standard" => ExportQuality.Standard, "high" => ExportQuality.High,
                var other => throw new InvalidDataException("Unknown export fixture quality: " + other)
            };
            var expected = entry["expected"]!;
            var output = ExportPresets.Output(source, entry["sourceFps"]!.GetValue<double>(), aspect, quality);
            Assert.Equal(new PixelSize(expected["size"]![0]!.GetValue<int>(), expected["size"]![1]!.GetValue<int>()), output.Size);
            Assert.Equal(expected["fps"]!.GetValue<double>(), output.FrameRate);
            Assert.Equal(expected["videoBitrate"]!.GetValue<long>(), output.VideoBitrate);
            var crop = ExportPresets.CenterCrop(source, output.Size);
            var actual = new[] { crop.X, crop.Y, crop.Width, crop.Height };
            for (var index = 0; index < actual.Length; index++)
                Assert.True(Math.Abs(actual[index] - expected["crop"]![index]!.GetValue<double>()) < 1e-9,
                    $"{source} {aspect}: crop {string.Join(", ", actual)}");
        }
    }

    [Fact]
    public void CenterCropKeepsAWholeSourceThatRoundsToTheOutputAspect()
    {
        Assert.Equal(new RectD(0, 0, 853, 480), ExportPresets.CenterCrop(new(853, 480), ExportPresets.OutputSize(new(853, 480), ExportAspect.Source)));
        Assert.Equal(new RectD(0, 0, 2560, 1441), ExportPresets.CenterCrop(new(2560, 1441), new(1920, 1080)));
        Assert.Equal(new RectD(656.25, 0, 607.5, 1080), ExportPresets.CenterCrop(new(1920, 1080), new(1080, 1920)));
    }
}

/// <summary>Runs alone, after the parallel collections: under full-suite load, the Redactor's 1 s timeout per rule could
/// otherwise fire on these 1 MB inputs and fail them closed.</summary>
[CollectionDefinition("redaction timing", DisableParallelization = true)]
public sealed class RedactionTimingCollection;

[Collection("redaction timing")]
public sealed class RedactionLongInputTests
{
    /// <summary>Rule 5 tries a JWT only at the start of a base64url run, so 1 MB of "eyJ" is scanned once; the bound is
    /// generous. An unchanged result also shows that no rule hit its 1 s timeout, which would return "[REDACTED]".</summary>
    [Fact]
    public void RedactionStaysLinearOnDenseJwtPrefixes()
    {
        var input = string.Concat(Enumerable.Repeat("eyJ", 350_000));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var output = new Redactor().Redact(input);
        watch.Stop();
        Assert.True(output == input, "the dense eyJ text changed");
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), watch.Elapsed.ToString());
    }

    /// <summary>Label chains, nested labels, scheme repeats and quoted values full of labels are scanned in linear time; the
    /// bound is generous. At 256 KB no rule may hit the 1 s timeout, which would return "[REDACTED]". At 1 MB a loaded CI host
    /// may hit it, and failing closed hides everything, so only the time bound applies there.</summary>
    [Fact]
    public void RedactionStaysLinearOnLabelRuns()
    {
        foreach (var (head, unit) in new[] { ("", "token:"), ("", "password: token: secret: "), ("token: ", "Bearer "), ("", "token=a=\""), ("token: a=\"", "password x ") })
            foreach (var size in new[] { 256_000, 1_000_000 })
            {
                var input = head + string.Concat(Enumerable.Repeat(unit, size / unit.Length));
                var watch = System.Diagnostics.Stopwatch.StartNew();
                var output = new Redactor().Redact(input);
                watch.Stop();
                if (size < 1_000_000) Assert.True(output != "[REDACTED]", unit + " failed closed at " + size);
                Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), unit + " " + watch.Elapsed);
            }
    }

    /// <summary>Rule 5's open-ended key shapes are a bounded lookahead and a + loop, so a 1,000,000-character key does not stop
    /// ICU and the key after it is still redacted. Mac Core runs the same inputs.</summary>
    [Fact]
    public void KeyShapesRedactMillionCharacterRuns()
    {
        // At 256 KB the output is exact. At 1 MB a loaded CI host may hit the 1 s rule timeout and fail closed, which also
        // hides both keys.
        foreach (var prefix in new[] { "sk-ant-", "sk-", "sk-proj-", "xai-", "sk_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_" })
            foreach (var size in new[] { 256_000, 1_000_000 })
            {
                var output = new Redactor().Redact(prefix + new string('a', size) + " " + prefix + new string('b', 40));
                Assert.True(output == "[REDACTED] [REDACTED]" || (size == 1_000_000 && output == "[REDACTED]"), prefix + " " + size);
            }
        // A JWT segment holds at most 8,192 characters: a longer header is no JWT, and a longer signature is replaced up
        // to its first 8,192 characters.
        const string jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl";
        var header256 = "eyJ" + new string('a', 256_000) + ".x.y";
        Assert.True(new Redactor().Redact(header256 + " " + jwt) == header256 + " [REDACTED]");
        var longHeader = "eyJ" + new string('a', 1_000_000) + ".x.y";
        var longOutput = new Redactor().Redact(longHeader + " " + jwt);
        Assert.True(longOutput == longHeader + " [REDACTED]" || longOutput == "[REDACTED]");
        Assert.Equal("[REDACTED]" + new string('s', 1_808), new Redactor().Redact("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0." + new string('s', 10_000)));
        // Rule 6 replaces a JWT glued after a signature that filled its 8,192 characters.
        Assert.Equal("[REDACTED][REDACTED]", new Redactor().Redact("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0." + new string('s', 8_192) + jwt));
    }
}
