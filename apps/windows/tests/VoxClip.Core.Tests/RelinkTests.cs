using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests;

public sealed class RelinkTests
{
    [Fact]
    public async Task AcceptedRelinkUpdatesOnlyIdentityAndTracksAndWriterRecomputesRelativePath()
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-relink-" + Guid.NewGuid());
        Directory.CreateDirectory(directory);
        try
        {
            var selected = Path.Combine(directory, "selected.mp4");
            await File.WriteAllTextAsync(selected, "local synthetic relink input", TestContext.Current.CancellationToken);
            var store = new ProjectStore();
            using var fixture = FixtureLoader.ReadJson("fixtures/projects/interview-take.voxclip");
            var original = ProjectSerialization.Deserialize(fixture.RootElement.GetRawText());
            var probe = new MediaInfo(selected, original.Media.Source.DurationSeconds + 0.04, new(1280, 720, 30, 0), new(48000, 1), new(1280, 720), null, null, false, 0, 0, 0);
            var result = await store.RelinkAsync(original, selected, probe, true, TestContext.Current.CancellationToken);
            Assert.Equal(RelinkDecision.Different, result.Decision);
            var relinked = Assert.IsType<Project>(result.Project);
            Assert.Same(original.Transcript, relinked.Transcript);
            Assert.Same(original.Edits, relinked.Edits);
            Assert.Equal(original.Media.Source.DurationSeconds, relinked.Media.Source.DurationSeconds);
            Assert.Equal(new FileInfo(selected).Length, relinked.Media.Source.SizeBytes);
            Assert.Equal(await store.ComputeContentKeyAsync(selected, null, TestContext.Current.CancellationToken), relinked.Media.Source.ContentKey);
            Assert.Equal(probe.Video, relinked.Media.Source.Video);
            Assert.Equal(probe.Audio, relinked.Media.Source.Audio);
            Assert.Equal(original.Media.Source.RelativePath, relinked.Media.Source.RelativePath);
            var match = await store.RelinkAsync(relinked, selected, probe with { DurationSeconds = 999, Video = null, Audio = null }, false, TestContext.Current.CancellationToken);
            Assert.Equal(RelinkDecision.Match, match.Decision);
            Assert.Equal(relinked, match.Project);
            var destination = Path.Combine(directory, "take.voxclip");
            await store.SaveAsync(relinked, destination, TestContext.Current.CancellationToken);
            var saved = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(destination, TestContext.Current.CancellationToken));
            Assert.Equal("selected.mp4", saved.Media.Source.RelativePath);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void SharedDecisions()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/projects/relink-cases.json");
        var root = fixture.RootElement;
        foreach (var item in root.GetProperty("cases").EnumerateArray())
        {
            var actual = Relinking.Decide(root.GetProperty("storedSize").GetInt64(), root.GetProperty("storedKey").GetString()!,
                item.TryGetProperty("storedDuration", out var stored) ? stored.GetDouble() : root.GetProperty("storedDuration").GetDouble(), item.GetProperty("size").GetInt64(), item.GetProperty("key").GetString()!,
                item.GetProperty("duration").GetDouble(), item.GetProperty("confirmed").GetBoolean());
            Assert.Equal(item.GetProperty("expected").GetString(), System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(actual.ToString()));
        }
    }
}
