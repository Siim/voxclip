using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class ProjectPatternTests
{
    public static IEnumerable<TheoryDataRow<string, string, bool>> SchemaPatterns()
    {
        static IEnumerable<TheoryDataRow<string, string, bool>> Cases(string path, string[] accepted, string[] rejected) =>
            accepted.Select(value => new TheoryDataRow<string, string, bool>(path, value, true))
                .Concat(rejected.Select(value => new TheoryDataRow<string, string, bool>(path, value, false)));
        return Cases("id", ["00000000-0000-0000-0000-000000000000", "abcdef01-2345-6789-abcd-ef0123456789"],
                ["ABCDEF01-2345-6789-abcd-ef0123456789", "00000000-0000-0000-0000-00000000000", "00000000-0000-0000-0000-000000000000\n"])
            .Concat(Cases("savedBy/version", ["0.0.0", "001.02.003", "1.2.3-A.-9"], ["1.2", "1.2.3-", "v1.2.3", "1.2.3\n", "1.2.3+meta"]))
            .Concat(Cases("captions/styleId", ["a", "0", "a-0", "abc-123-def"], ["", "-a", "a-", "a--b", "A", "a\n"]))
            .Concat(Cases("media/source/contentKey", [new string('0', 64), new string('f', 64)],
                [new string('0', 63), new string('0', 65), new string('F', 64), new string('0', 64) + "\n"]))
            .Concat(Cases("transcript/words/0/id", ["a", "0", "Z._:-", new string('a', 64)],
                ["", "_a", new string('a', 65), "a/b", "é", "a\n"]))
            .Concat(Cases("transcript/language", ["en", "est", "en-US", "en-12345678", "en-Ab-01234567"],
                ["e", "engl", "EN", "en-a", "en-123456789", "en_Us", "en\n"]))
            .Concat(Cases("extensions", ["a.b", "0.0", "a.-", "a.b-c", "a.b.c"], ["a", ".a", "a.", "a..b", "A.b", "a.b\n"]))
            .Concat(Cases("edits/cutPauseIds", ["pause-after-a", "pause-after-" + new string('a', 64)],
                ["pause-after-", "pause-after-" + new string('a', 65), "pause-after-_a", "pause-after-a\n"]))
            .Concat(Cases("share/captions", ["full", "a", new string('a', 64)], ["", "_a", new string('a', 65), "full\n"]));
    }

    [Theory]
    [MemberData(nameof(SchemaPatterns))]
    public void SchemaPatternBoundariesKeepTheirLanguage(string path, string value, bool accepted)
    {
        var project = TestStorage.ProjectJson();
        Set(project, path, value);
        if (accepted) ProjectValidation.Validate(project.ToJsonString());
        else Assert.Throws<JsonException>(() => ProjectValidation.Validate(project.ToJsonString()));
    }

    [Theory]
    [InlineData("captions/styleId")]
    [InlineData("extensions")]
    [InlineData("savedBy/version")]
    public async Task UnboundedValidPatternsLoadWithoutAClockLimit(string path)
    {
        using var storage = new TestStorage();
        var project = TestStorage.ProjectJson();
        var text = string.Concat(Enumerable.Repeat("a-", 20_000)) + "a";
        Set(project, path, path == "extensions" ? "a." + text : path == "savedBy/version" ? "1.2.3-" + text : text);
        var file = storage.PathFor("long-valid.voxclip");
        await File.WriteAllTextAsync(file, project.ToJsonString(), TestContext.Current.CancellationToken);
        var result = await new ProjectStore().LoadAsync(file, TestContext.Current.CancellationToken);
        Assert.Equal(project["id"]!.GetValue<string>(), result.Project.Id);
    }

    [Theory]
    [InlineData("a", true)]
    [InlineData("a_0-9", true)]
    [InlineData("com0", true)]
    [InlineData("com10", true)]
    [InlineData("con", false)]
    [InlineData("lpt9", false)]
    [InlineData("_a", false)]
    [InlineData("a\n", false)]
    public void PaidAssetPatternsKeepReservedNameBoundaries(string asset, bool accepted)
    {
        const string project = "00000000-0000-0000-0000-000000000000";
        if (accepted) Assert.Equal(project + "/" + asset + ".wav", VoiceLabAssetNaming.File(project, asset, "wav"));
        else Assert.Throws<VoiceLabProjectException>(() => VoiceLabAssetNaming.File(project, asset, "wav"));
    }

    [Fact]
    public async Task MissingRequiredFieldLoadsAsProjectUnreadable()
    {
        using var storage = new TestStorage();
        var project = TestStorage.ProjectJson();
        project["media"]!.AsObject().Remove("source");
        var file = storage.PathFor("damaged.voxclip");
        var json = project.ToJsonString();
        await File.WriteAllTextAsync(file, json, TestContext.Current.CancellationToken);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => new ProjectStore().LoadAsync(file, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, error.Code);
        Assert.Equal(json, await File.ReadAllTextAsync(file, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task MissingCandidateDiscriminatorMapsTheRawLookupFailure()
    {
        using var storage = new TestStorage();
        var fixture = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-render-v3.voxclip");
        var project = JsonNode.Parse(await File.ReadAllTextAsync(fixture, TestContext.Current.CancellationToken))!;
        project["voiceLab"]!["segments"]![0]!["candidates"]![0]!.AsObject().Remove("rejected");
        var file = storage.PathFor("missing-discriminator.voxclip");
        var json = project.ToJsonString();
        await File.WriteAllTextAsync(file, json, TestContext.Current.CancellationToken);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => new ProjectStore().LoadAsync(file, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, error.Code);
        Assert.IsType<KeyNotFoundException>(error.InnerException);
        Assert.Equal(json, await File.ReadAllTextAsync(file, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task CancelledLoadRemainsCancellation()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new ProjectStore().LoadAsync(TestStorage.ProjectPath(), cancelled.Token));
    }

    private static void Set(JsonObject project, string path, string value)
    {
        var parts = path.Split('/');
        JsonNode parent = project;
        foreach (var part in parts[..^1]) parent = parent is JsonArray array ? array[int.Parse(part)]! : parent[part]!;
        parent[parts[^1]] = path switch
        {
            "extensions" => new JsonObject { [value] = null },
            "edits/cutPauseIds" => new JsonArray(value),
            "share/captions" => new JsonObject { [value] = "caption" },
            _ => JsonValue.Create(value)
        };
    }
}
