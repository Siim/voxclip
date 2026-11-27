using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;

namespace VoxClip.Tests.Support;

internal static class RecordingStoryFixture
{
    internal static async Task<(Project Project, string Path, MediaInfo Primary)> CreateAsync(string directory, CancellationToken ct)
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/plan-cases.json"))!;
        var row = vectors["cases"]!.AsArray().Single(row => row!["id"]!.GetValue<string>() == "five-part-a1-b1-b2-a2-b3")!;
        var document = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/" + row["project"]!.GetValue<string>()))!;
        var edits = row["edits"]!.DeepClone();
        edits["clips"] = new JsonArray(row["clip"]!.DeepClone());
        edits["activeClipId"] = row["clip"]!["id"]!.DeepClone();
        document["edits"] = edits;
        var project = ProjectSerialization.Deserialize(document.ToJsonString());
        var store = new ProjectStore();
        var original = project.Media.Source;
        var companions = project.Media.AdditionalSources!.ToArray();
        var primary = await CopyAsync(original, "A", "DJI_0007.MP4", new(320, 180, 30, 0), 48_000);
        var second = await CopyAsync(companions[0], "B", "DJI_0010.MP4", new(240, 320, 30, 0), 44_100);
        var spoken = project.Media.SpokenSources!.Select(source => source.SourceKey == companions[0].ContentKey ? source with { SourceKey = second.ContentKey } : source).ToArray();
        companions[0] = second;
        project = project with
        {
            Media = project.Media with { Source = primary, AdditionalSources = companions, SpokenSources = spoken },
            Export = project.Export with { Aspect = ExportAspect.Source, Srt = false }
        };
        var path = Path.Combine(directory, "story.voxclip");
        await File.WriteAllTextAsync(path, ProjectSerialization.Serialize(project), ct);
        return (project, path, new(primary.AbsolutePath, primary.DurationSeconds, primary.Video, primary.Audio,
            new(320, 180), "h264", "aac", false, 0, 1, 0));

        async Task<MediaReference> CopyAsync(MediaReference reference, string recording, string name, VideoTrackInfo video, int rate)
        {
            var input = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", $"t4-recording-{recording}.mp4");
            var output = Path.Combine(directory, name);
            File.Copy(input, output, overwrite: true);
            return reference with { AbsolutePath = output, RelativePath = name, SizeBytes = new FileInfo(output).Length,
                ContentKey = await store.ComputeContentKeyAsync(output, null, ct), Video = video, Audio = new(rate, 1) };
        }
    }
}
