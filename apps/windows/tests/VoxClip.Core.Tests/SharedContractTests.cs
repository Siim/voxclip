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
    public void ProjectFixturesRoundTripWithoutChangingWordsOrJson()
    {
        var paths = Directory.GetFiles(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects"), "*.voxclip");
        Assert.NotEmpty(paths);
        foreach (var path in paths)
        {
            var source = File.ReadAllText(path);
            var project = ProjectSerialization.Deserialize(source);
            var roundTrip = ProjectSerialization.Serialize(project);
            Assert.True(JsonNode.DeepEquals(JsonNode.Parse(source), JsonNode.Parse(roundTrip)), Path.GetFileName(path));
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
}
