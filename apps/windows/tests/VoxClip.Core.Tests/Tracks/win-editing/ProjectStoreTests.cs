using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinEditing.EditingFixtureTests;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class ProjectStoreTests
{
    [Theory]
    [InlineData(@"\??\UNC\server\share\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"\??\UNC\server\share\video.mp4", @"\\server\share\project.voxclip", false)]
    [InlineData(@"\??\C:\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"\\?\C:\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"\\.\C:\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"\\.\pipe\x", @"C:\project.voxclip", false)]
    [InlineData(@"\\?\UNC\server\share\video.mp4", @"\\server\share\project.voxclip", false)]
    [InlineData(@"/??\UNC/server\share/video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"/??\UNC/server\share/video.mp4", @"\\server\share\project.voxclip", false)]
    [InlineData(@"\??/C:\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"/\?/C:\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"\/.\pipe/x", @"C:\project.voxclip", false)]
    [InlineData(@"\\server\share\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"\\server\share\video.mp4", @"\\other\share\project.voxclip", false)]
    [InlineData(@"\\server\share\video.mp4", @"\\server\other\project.voxclip", false)]
    [InlineData(@"\\server\share\video.mp4", @"\\server\share-extra\project.voxclip", false)]
    [InlineData(@"\\server\share\video.mp4", @"\\?\UNC\server\share\project.voxclip", false)]
    [InlineData(@"\\server\share\video.mp4", @"\??\UNC\server\share\project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"\??\C:\project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"\\?\C:\project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"\\.\pipe\project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"/??\C:/project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"/\?/C:\project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"\/.\pipe/project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"relative.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"C:project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"\project.voxclip", false)]
    [InlineData(@"C:\video.mp4", @"C:\project.voxclip", true)]
    [InlineData(@"z:/Videos/video.mp4", @"D:\Projects\project.voxclip", true)]
    [InlineData(@"C:\video.mp4", @"\\server\share\project.voxclip", true)]
    [InlineData("video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"C:video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"1:\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"é:\video.mp4", @"C:\project.voxclip", false)]
    [InlineData(@"\\server\share", @"\\server\share\project.voxclip", false)]
    [InlineData(@"\\server\\video.mp4", @"\\server\share\project.voxclip", false)]
    [InlineData(@"\\\server\share\video.mp4", @"\\server\share\project.voxclip", false)]
    [InlineData("/tmp/video.mp4", "/tmp/project.voxclip", false)]
    [InlineData(@"\\server\share\video.mp4", @"\\server\share\project.voxclip", true)]
    [InlineData(@"\\server\share\Videos\video.mp4", @"\\SERVER\SHARE\Projects\project.voxclip", true)]
    [InlineData("//server/share/video.mp4", @"\\SERVER\SHARE\project.voxclip", true)]
    public void WindowsAutoProbeAllowsOnlyDrivePathsAndTheProjectsOwnUncShare(string candidate, string projectPath, bool allowed)
        => Assert.Equal(allowed, ProjectStore.CanAutoProbeMediaPath(candidate, projectPath));

    [Fact]
    public async Task InvalidUtf8IsRejectedWithoutChangingTheProject()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("damaged.voxclip");
        var json = TestStorage.ProjectJson();
        json["title"] = "invalid-utf8-marker";
        var bytes = Encoding.UTF8.GetBytes(json.ToJsonString());
        bytes[bytes.AsSpan().IndexOf("invalid-utf8-marker"u8)] = 0xFF;
        await File.WriteAllBytesAsync(path, bytes, TestContext.Current.CancellationToken);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => new ProjectStore().LoadAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, error.Code);
        Assert.IsType<DecoderFallbackException>(error.InnerException);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken));
    }

    public static IEnumerable<TheoryDataRow<string>> Projects()
        => Directory.GetFiles(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects"), "*.voxclip").Order(StringComparer.Ordinal)
            .Select(path => new TheoryDataRow<string>(Path.GetFileName(path)));

    [Theory]
    [MemberData(nameof(Projects))]
    public async Task EveryProjectRoundTripsSourceTimesExtensionsAndStableEditKeys(string name)
    {
        using var storage = new TestStorage();
        var store = new ProjectStore();
        var source = await store.LoadAsync(TestStorage.ProjectPath(name), TestContext.Current.CancellationToken);
        Assert.True(source.IsReadOnly);
        Assert.Null(source.ResolvedMediaPath);
        Assert.Empty(source.Warnings);
        var path = storage.PathFor("Projects/" + name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (source.Project.Media.Source.RelativePath is { } relative)
            source = source with { Project = source.Project with { Media = new(source.Project.Media.Source with {
                AbsolutePath = Path.GetFullPath(Path.Join(Path.GetDirectoryName(path)!, relative)) }) } };
        await store.SaveAsync(source.Project, path, TestContext.Current.CancellationToken);
        var first = await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken);
        Assert.False(first.AsSpan().StartsWith(Encoding.UTF8.Preamble));
        Assert.Equal((byte)'\n', first[^1]);
        var loaded = await store.LoadAsync(path, TestContext.Current.CancellationToken);
        Assert.Empty(loaded.Warnings);
        // The examples store whole seconds, which a save writes once in canonical form (editing §10.1).
        var original = TimestampWireRuleTests.CanonicalTimestamps(JsonNode.Parse(await File.ReadAllBytesAsync(TestStorage.ProjectPath(name), TestContext.Current.CancellationToken)))!;
        original["media"]!["source"]!["absolutePath"] = source.Project.Media.Source.AbsolutePath;
        using var originalDocument = JsonDocument.Parse(original.ToJsonString());
        using var savedDocument = JsonDocument.Parse(first);
        CompareRoundTrip(originalDocument.RootElement, savedDocument.RootElement, "");
        Assert.Equal(source.Project.Extensions?.Keys, loaded.Project.Extensions?.Keys);
        Assert.Equal(source.Project.Media.Source.ContentKey, loaded.Project.Media.Source.ContentKey);
        var orderedCuts = source.Project.Transcript!.Words.Where(word => source.Project.Edits.CutWordIds.Contains(word.Id)).Select(word => word.Id);
        Assert.Equal(orderedCuts, loaded.Project.Edits.CutWordIds);
        var orderedCorrections = source.Project.Transcript.Words.Where(word => source.Project.Edits.Corrections.ContainsKey(word.Id)).Select(word => word.Id);
        Assert.Equal(orderedCorrections, loaded.Project.Edits.Corrections.Keys);
        await store.SaveAsync(loaded.Project, path, TestContext.Current.CancellationToken);
        var before = JsonNode.Parse(first)!.AsObject();
        var after = JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!.AsObject();
        before.Remove("modifiedAt"); after.Remove("modifiedAt");
        Assert.Equal(before.ToJsonString(), after.ToJsonString());
        Assert.Empty(Directory.GetFiles(storage.Root, "*.tmp"));
    }

    [Fact]
    public async Task MediaResolutionChecksSizeHashAndAbsoluteBeforeRelative()
    {
        using var storage = new TestStorage();
        var store = new ProjectStore();
        var projectPath = storage.PathFor("project.voxclip");
        var absolute = storage.PathFor("absolute.bin");
        var relative = storage.PathFor(Path.Combine("media", "source.bin"));
        Directory.CreateDirectory(Path.GetDirectoryName(relative)!);
        await File.WriteAllBytesAsync(absolute, [1, 2, 3], TestContext.Current.CancellationToken);
        await File.WriteAllBytesAsync(relative, [1, 2, 3], TestContext.Current.CancellationToken);
        var source = TestStorage.ProjectFixture().Media.Source with { AbsolutePath = absolute, RelativePath = "media/source.bin", SizeBytes = 3,
            ContentKey = await store.ComputeContentKeyAsync(absolute, null, TestContext.Current.CancellationToken) };
        Assert.Equal(absolute, await store.ResolveMediaAsync(source, projectPath, TestContext.Current.CancellationToken));
        await File.WriteAllBytesAsync(absolute, [4, 5, 6], TestContext.Current.CancellationToken);
        Assert.Equal(relative, await store.ResolveMediaAsync(source, projectPath, TestContext.Current.CancellationToken));
        var project = TestStorage.ProjectFixture() with { Media = new(source) };
        await File.WriteAllTextAsync(projectPath, ProjectSerialization.Serialize(project), TestContext.Current.CancellationToken);
        var loaded = await store.LoadAsync(projectPath, TestContext.Current.CancellationToken);
        Assert.False(loaded.IsReadOnly);
        Assert.Equal(relative, loaded.Project.Media.Source.AbsolutePath);
        await store.SaveAsync(loaded.Project, projectPath, TestContext.Current.CancellationToken);
        Assert.Equal("media/source.bin", ProjectSerialization.Deserialize(await File.ReadAllTextAsync(projectPath, TestContext.Current.CancellationToken)).Media.Source.RelativePath);
        await File.WriteAllBytesAsync(relative, [1, 2], TestContext.Current.CancellationToken);
        Assert.Null(await store.ResolveMediaAsync(source, projectPath, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task LoadDropsEveryStaleReferenceButNeverMovesSourceWords()
    {
        using var storage = new TestStorage();
        var original = TestStorage.ProjectFixture();
        var words = new[] { Word("a", "um", 0, 0.2), Word("b", "(laughs)", 2, 2.2, WordKind.Event), Word("c", "end", 4, 4.2) };
        var project = original with { Transcript = original.Transcript! with { Words = words },
            Edits = new(0.8, 0.15, ["ghost", "a"], ["pause-after-ghost", "pause-after-a"],
                new Dictionary<string, string> { ["a"] = "um", ["b"] = "ignore", ["c"] = "corrected", ["ghost"] = "unknown" },
                [new("invalid", "ghost", "c", null, ClipOrigin.Manual, null, null, true), new("reversed", "c", "a", null, ClipOrigin.Manual, null, null, true),
                 new("valid", "a", "c", null, ClipOrigin.Ai, "missing", 0, true)], "invalid"),
            Share = new(new Dictionary<string, string> { ["full"] = "full caption", ["valid"] = "kept caption", ["invalid"] = "removed" }) };
        var path = storage.PathFor("references.voxclip");
        await File.WriteAllTextAsync(path, ProjectSerialization.Serialize(project), TestContext.Current.CancellationToken);
        var opened = await new ProjectStore().LoadAsync(path, TestContext.Current.CancellationToken);
        Assert.Equal(words, opened.Project.Transcript!.Words);
        Assert.Equal(["a"], opened.Project.Edits.CutWordIds);
        Assert.Equal(["pause-after-a"], opened.Project.Edits.CutPauseIds);
        Assert.Equal("corrected", Assert.Single(opened.Project.Edits.Corrections).Value);
        Assert.Null(Assert.Single(opened.Project.Edits.Clips).AiResultId);
        Assert.Null(opened.Project.Edits.Clips[0].AiClipIndex);
        Assert.Null(opened.Project.Edits.ActiveClipId);
        Assert.Equal(["full", "valid"], opened.Project.Share.Captions.Keys);
        Assert.Equal(10, opened.Warnings.Count);
    }

    [Theory]
    [InlineData(null)]
    [InlineData(0)]
    [InlineData(100)]
    public async Task ResolvedAiResultLinksSurviveMissingOrOutOfRangeClipIndices(int? index)
    {
        using var storage = new TestStorage();
        var project = TestStorage.ProjectFixture();
        var result = Assert.Single(project.Ai.Results);
        var clip = project.Edits.Clips[0] with { AiResultId = result.Id, AiClipIndex = index };
        project = project with { Edits = project.Edits with { Clips = [clip], ActiveClipId = clip.Id }, Share = new(new Dictionary<string, string>()) };
        var path = storage.PathFor("ai-reference.voxclip");
        await File.WriteAllTextAsync(path, ProjectSerialization.Serialize(project), TestContext.Current.CancellationToken);
        var store = new ProjectStore();
        var opened = await store.LoadAsync(path, TestContext.Current.CancellationToken);
        Assert.Empty(opened.Warnings);
        Assert.Equal(clip, Assert.Single(opened.Project.Edits.Clips));
        await store.SaveAsync(opened.Project, path, TestContext.Current.CancellationToken);
        var saved = await store.LoadAsync(path, TestContext.Current.CancellationToken);
        Assert.Empty(saved.Warnings);
        Assert.Equal(clip, Assert.Single(saved.Project.Edits.Clips));
    }

    [Fact]
    public async Task SavePrunesUnreferencedAiResultsAndRemovedShareCaptions()
    {
        using var storage = new TestStorage();
        var original = TestStorage.ProjectFixture();
        var result = original.Ai.Results[0];
        var results = Enumerable.Range(0, 15).Select(index => result with { Id = "r" + index, CreatedAt = DateTimeOffset.UnixEpoch.AddSeconds(index) }).ToArray();
        var clip = original.Edits.Clips[0] with { AiResultId = "r0", AiClipIndex = 0 };
        var project = original with { Ai = new(results), Edits = original.Edits with { Clips = [clip] },
            Share = new(new Dictionary<string, string> { ["full"] = "full", [clip.Id] = "clip", ["removed"] = "obsolete" }) };
        var path = storage.PathFor("pruned.voxclip");
        var store = new ProjectStore();
        await store.SaveAsync(project, path, TestContext.Current.CancellationToken);
        var loaded = (await store.LoadAsync(path, TestContext.Current.CancellationToken)).Project;
        Assert.Equal(new[] { "r0" }.Concat(Enumerable.Range(5, 10).Select(index => "r" + index)), loaded.Ai.Results.Select(item => item.Id));
        Assert.DoesNotContain("removed", loaded.Share.Captions.Keys);
        Assert.Equal(15, project.Ai.Results.Count);
        Assert.Equal(3, project.Share.Captions.Count);
    }

    [Fact]
    public async Task ReferencedRecentResultsStillCountTowardsTheNewestTenOverall()
    {
        using var storage = new TestStorage();
        var project = TestStorage.ProjectFixture();
        var result = project.Ai.Results[0];
        var results = Enumerable.Range(0, 15).Select(index => result with { Id = "r" + index, CreatedAt = DateTimeOffset.UnixEpoch.AddSeconds(index) }).ToArray();
        project = project with { Ai = new(results), Edits = project.Edits with { Clips = [project.Edits.Clips[0] with { AiResultId = "r14", AiClipIndex = 0 }] } };
        var path = storage.PathFor("recent-reference.voxclip");
        var store = new ProjectStore();
        await store.SaveAsync(project, path, TestContext.Current.CancellationToken);
        var loaded = (await store.LoadAsync(path, TestContext.Current.CancellationToken)).Project;
        Assert.Equal(Enumerable.Range(5, 10).Select(index => "r" + index), loaded.Ai.Results.Select(item => item.Id));
    }

    public static IEnumerable<TheoryDataRow<string>> InvalidProjects()
    {
        yield return new("null");
        yield return new("[]");
        yield return new("{}");
        foreach (var mutation in new Action<JsonObject>[]
        {
            root => root.Remove("share"),
            root => root["media"]!["source"]!.AsObject().Remove("relativePath"),
            root => root["savedBy"]!["extra"] = true,
            root => root["transcript"]!["words"]!.AsArray()[0] = null,
            root => root["edits"]!["clips"]!.AsArray()[0] = null,
            root => root["transcript"]!["words"]![0]!.AsObject().Remove("rawStart"),
            root => root["transcript"]!["words"]![0]!["start"] = "NaN",
            root => root["transcript"]!["words"]![0]!["kind"] = 0,
            root => root["transcript"]!["words"]![0]!["text"] = " o\u0303",
            root => root["transcript"]!["words"]![0]!["text"] = " um",
            root => root["transcript"]!["words"]![0]!["end"] = root["transcript"]!["words"]![0]!["start"]!.DeepClone(),
            root => root["transcript"]!["words"]![1]!["start"] = -1,
            root => root["transcript"]!["words"]![1]!["id"] = root["transcript"]!["words"]![0]!["id"]!.DeepClone(),
            root => root["transcript"]!["words"]![0]!["conf"] = 1.1,
            root => root["edits"]!["pauseKeepSeconds"] = 1.1,
            root => root["edits"]!["cutWordIds"] = new JsonArray("w1", "w1"),
            root => root["voiceLab"]!["segments"] = new JsonArray(1),
            root => root["captions"]!["position"] = new JsonObject { ["x"] = 2, ["y"] = 0 },
            root => root["export"]!["quality"] = "unknown"
        })
        {
            var root = TestStorage.ProjectJson();
            mutation(root);
            yield return new(root.ToJsonString());
        }
        var duplicate = TestStorage.ProjectJson().ToJsonString().Replace("\"format\":", "\"format\":\"voxclip-project\",\"format\":", StringComparison.Ordinal);
        yield return new(duplicate);
    }

    [Theory]
    [MemberData(nameof(InvalidProjects))]
    public async Task StrictTypedProjectDecodingRejectsDamagedDocuments(string json)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("damaged.voxclip");
        await File.WriteAllTextAsync(path, json, TestContext.Current.CancellationToken);
        var exception = await Assert.ThrowsAsync<VoxClipException>(() => new ProjectStore().LoadAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProjectUnreadable, exception.Code);
        Assert.Equal(json, await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task NewerSchemaIsNeverEditedAndCancellationPreservesTheSavedFile()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "{\"schemaVersion\":4}", TestContext.Current.CancellationToken);
        var store = new ProjectStore();
        var exception = await Assert.ThrowsAsync<VoxClipException>(() => store.LoadAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProjectTooNew, exception.Code);
        var cancelled = new CancellationToken(true);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.SaveAsync(TestStorage.ProjectFixture(), path, cancelled));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.LoadAsync(path, cancelled));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.ComputeContentKeyAsync(path, null, cancelled));
        Assert.Equal("{\"schemaVersion\":4}", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        Assert.Empty(Directory.GetFiles(storage.Root, "*.tmp"));
    }

    [Fact]
    public async Task UnicodeSchemaLengthsCountScalarsWhileTimesRoundTripAsBinary64()
    {
        using var storage = new TestStorage();
        var project = TestStorage.ProjectFixture();
        var word = Word("unicode", string.Concat(Enumerable.Repeat("😀", 200)), 0.49999999999999994, Math.BitIncrement(1.25));
        project = project with { Transcript = project.Transcript! with { Words = [word] } };
        var path = storage.PathFor("unicode.voxclip");
        var store = new ProjectStore();
        await store.SaveAsync(project, path, TestContext.Current.CancellationToken);
        var loaded = (await store.LoadAsync(path, TestContext.Current.CancellationToken)).Project.Transcript!.Words[0];
        Assert.Equal(400, loaded.Text.Length);
        Assert.Equal(BitConverter.DoubleToInt64Bits(word.Start), BitConverter.DoubleToInt64Bits(loaded.Start));
        Assert.Equal(BitConverter.DoubleToInt64Bits(word.End), BitConverter.DoubleToInt64Bits(loaded.End));
    }

    [Fact]
    public async Task ConcurrentSavesFromOneDocumentNeverLetAnOlderSnapshotWin()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("concurrent.voxclip");
        var store = new ProjectStore();
        var project = TestStorage.ProjectFixture();
        var writes = Enumerable.Range(0, 25).Select(index => store.SaveAsync(project with { Title = "Revision " + index }, path, TestContext.Current.CancellationToken)).ToArray();
        await Task.WhenAll(writes);
        var opened = await store.LoadAsync(path, TestContext.Current.CancellationToken);
        Assert.Equal("Revision 24", opened.Project.Title);
        Assert.Equal(project.Transcript!.Words, opened.Project.Transcript!.Words);
        Assert.Empty(Directory.GetFiles(storage.Root, "*.tmp"));
    }

    [Fact]
    public async Task OptionalProjectTitleMayBeEmptyAsTheSchemaAllows()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("empty-title.voxclip");
        var store = new ProjectStore();
        await store.SaveAsync(TestStorage.ProjectFixture() with { Title = "" }, path, TestContext.Current.CancellationToken);
        Assert.Equal("", (await store.LoadAsync(path, TestContext.Current.CancellationToken)).Project.Title);
    }

    [Theory]
    [InlineData("//host/share/x.mp4")]
    [InlineData("//?/UNC/host/share/x.mp4")]
    [InlineData("/abs/x.mp4")]
    [InlineData("C:/x.mp4")]
    [InlineData("C:x.mp4")]
    [InlineData("actual-absolute")]
    public async Task RootedRelativeMediaPathsAreNeverResolved(string relative)
    {
        using var storage = new TestStorage();
        var outside = storage.PathFor("outside.bin");
        var directory = storage.PathFor("project");
        Directory.CreateDirectory(directory);
        await File.WriteAllBytesAsync(outside, [1, 2, 3], TestContext.Current.CancellationToken);
        var store = new ProjectStore();
        var source = TestStorage.ProjectFixture().Media.Source with { AbsolutePath = storage.PathFor("missing.bin"),
            RelativePath = relative == "actual-absolute" ? outside : relative, SizeBytes = 3,
            ContentKey = await store.ComputeContentKeyAsync(outside, null, TestContext.Current.CancellationToken) };
        Assert.Null(await store.ResolveMediaAsync(source, Path.Combine(directory, "test.voxclip"), TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("../outside.bin")]
    [InlineData("media/../../outside.bin")]
    public async Task ParentRelativeMediaPathsResolveAndSurviveSave(string relative)
    {
        using var storage = new TestStorage();
        var outside = storage.PathFor("outside.bin");
        var directory = storage.PathFor("project");
        Directory.CreateDirectory(directory);
        await File.WriteAllBytesAsync(outside, [1, 2, 3], TestContext.Current.CancellationToken);
        var store = new ProjectStore();
        var source = TestStorage.ProjectFixture().Media.Source with { AbsolutePath = storage.PathFor("missing.bin"),
            RelativePath = relative, SizeBytes = 3,
            ContentKey = await store.ComputeContentKeyAsync(outside, null, TestContext.Current.CancellationToken) };
        var path = Path.Combine(directory, "test.voxclip");
        Assert.Equal(outside, await store.ResolveMediaAsync(source, path, TestContext.Current.CancellationToken));
        await store.SaveAsync(TestStorage.ProjectFixture() with { Media = new(source with { AbsolutePath = outside }) }, path, TestContext.Current.CancellationToken);
        Assert.Equal("../outside.bin", ProjectSerialization.Deserialize(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken)).Media.Source.RelativePath);
        await File.WriteAllBytesAsync(outside, [3, 2, 1], TestContext.Current.CancellationToken);
        Assert.Null(await store.ResolveMediaAsync(source, path, TestContext.Current.CancellationToken));
    }

    private static void CompareRoundTrip(JsonElement expected, JsonElement actual, string path)
    {
        Assert.Equal(expected.ValueKind, actual.ValueKind);
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                Assert.Equal(expected.EnumerateObject().Select(property => property.Name).Order(), actual.EnumerateObject().Select(property => property.Name).Order());
                foreach (var property in expected.EnumerateObject())
                {
                    var child = path + "/" + property.Name;
                    if (child is "/modifiedAt" or "/savedBy") continue;
                    CompareRoundTrip(property.Value, actual.GetProperty(property.Name), child);
                }
                break;
            case JsonValueKind.Array:
                Assert.Equal(expected.GetArrayLength(), actual.GetArrayLength());
                for (var index = 0; index < expected.GetArrayLength(); index++) CompareRoundTrip(expected[index], actual[index], path + "/" + index);
                break;
            case JsonValueKind.Number:
                Assert.Equal(BitConverter.DoubleToInt64Bits(expected.GetDouble()), BitConverter.DoubleToInt64Bits(actual.GetDouble()));
                break;
            default: Assert.True(JsonElement.DeepEquals(expected, actual), path); break;
        }
    }
}
