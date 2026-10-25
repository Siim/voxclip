using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Tests.Tracks.WinEditing;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCoreNative;

public sealed class TextOutputTests
{
    [Fact]
    public void FormattingOverridesExplicitWindowsLineEndingsWithoutChangingOtherOptions()
    {
        var original = new JsonSerializerOptions { NewLine = "\r\n", WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        var options = JsonFormatting.CreateOptions(original);
        Assert.Equal("\r\n", original.NewLine);
        Assert.Same(original.PropertyNamingPolicy, options.PropertyNamingPolicy);
        var value = new { Nested = new { Text = "one\r\ntwo" } };
        var json = JsonSerializer.Serialize(value, options);
        Assert.Contains("\n", json);
        Assert.DoesNotContain('\r', json);
        Assert.Contains("one\\r\\ntwo", json);
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, JsonFormatting.CreateWriterOptions(new() { NewLine = "\r\n", Indented = true })))
        {
            writer.WriteStartObject();
            writer.WriteString("text", "one\r\ntwo");
            writer.WriteEndObject();
        }
        Assert.Contains((byte)'\n', buffer.ToArray());
        Assert.DoesNotContain((byte)'\r', buffer.ToArray());
    }

    [Fact]
    public void EveryGeneratedCoreContextExplicitlyPinsLfEvenOnUnix()
    {
        var contexts = new JsonSerializerContext[] { ProjectJsonContext.Default, TranscriptJsonContext.Default, SettingsJsonContext.Default,
            ModelsJsonContext.Default, LlmJsonContext.Default, CacheJsonContext.Default };
        foreach (var context in contexts)
        {
            Assert.Equal("\n", context.Options.NewLine);
            Assert.Equal("\n", context.GetType().GetCustomAttribute<JsonSourceGenerationOptionsAttribute>()!.NewLine);
        }
    }

    [Fact]
    public async Task SettingsProjectsCacheMetadataAndSpeechDocumentsHaveOneFinalLf()
    {
        using var files = new TestStorage();
        var settingsPath = files.PathFor("settings.json");
        var settings = new SettingsStore(settingsPath);
        await settings.SaveAsync(await settings.LoadAsync(TestContext.Current.CancellationToken), TestContext.Current.CancellationToken);
        await settings.FlushAsync(TestContext.Current.CancellationToken);
        var projectPath = files.PathFor("project.voxclip");
        await new ProjectStore().SaveAsync(TestStorage.ProjectFixture(), projectPath, TestContext.Current.CancellationToken);
        var cacheRoot = files.PathFor("Cache");
        var contentKey = new string('a', 64);
        await new CacheIndex(cacheRoot).TouchAsync(contentKey, 1, new(48000, 0.01, 1), TestContext.Current.CancellationToken);
        foreach (var name in new[] { "installed.json", "model.partial.json", "raw-transcript.json" })
        {
            var path = files.PathFor(name);
            await SpeechTransport.AtomicWriteAsync(path, writer =>
            {
                writer.WriteStartObject();
                writer.WriteString("text", "one\r\ntwo");
                writer.WriteEndObject();
            }, TestContext.Current.CancellationToken);
            await AssertFileAsync(path);
        }
        await AssertFileAsync(settingsPath);
        await AssertFileAsync(projectPath);
        await AssertFileAsync(Path.Combine(cacheRoot, contentKey, "meta.json"));
        var preset = JsonSerializer.Serialize(TestStorage.ProjectFixture().Export, ProjectJsonContext.Default.ProjectExport);
        Assert.Contains('\n', preset);
        Assert.DoesNotContain('\r', preset);
    }

    internal static async Task AssertFileAsync(string path)
    {
        var bytes = await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken);
        Assert.NotEmpty(bytes);
        Assert.DoesNotContain((byte)'\r', bytes);
        Assert.Equal((byte)'\n', bytes[^1]);
        Assert.NotEqual((byte)'\n', bytes[^2]);
        Assert.False(bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble));
        using var document = JsonDocument.Parse(bytes);
    }
}
