using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Cli;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>A project the Windows CLI makes from a media file carries a schema-valid id (a dashed lowercase UUID,
/// shared/schemas/project.schema.json $defs/uuid) and writer ("VoxClip"), so it saves, upgrades to v3 and v4 and can take clip
/// controls and effects. A dashless id failed those upgrades with UnsafePath; "voxclip-cli" failed validation on save.</summary>
public sealed class CliNewProjectTests
{
    [Fact]
    public void ACliMadeProjectHasASchemaValidIdAndUpgradesToV4()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-new-project-").FullName;
        try
        {
            var path = Path.Combine(directory, "source.mp4");
            File.WriteAllText(path, "offline media stand-in");
            var media = new MediaInfo(path, 12, new(640, 360, 30, 0), new(48_000, 1), new(640, 360), "h264", "aac", false, 0, 1, 0);
            var transcript = JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/media/joins-tone.transcript.json"), CliDataJson.Default.Transcript)!;
            var project = CliOperations.NewProject(media, transcript, new string('a', 64));
            using var schema = FixtureLoader.ReadJson("schemas/project.schema.json");
            var root = schema.RootElement;
            Assert.Equal("#/$defs/uuid", root.GetProperty("properties").GetProperty("id").GetProperty("$ref").GetString());
            var pattern = root.GetProperty("$defs").GetProperty("uuid").GetProperty("pattern").GetString()!;
            Assert.Matches(new Regex(pattern, RegexOptions.CultureInvariant), project.Id);
            Assert.Equal(root.GetProperty("properties").GetProperty("savedBy").GetProperty("properties").GetProperty("app").GetProperty("const").GetString(),
                project.SavedBy.App);
            // It saves and reopens, then upgrades through v3 to v4 and takes a clip's controls.
            project = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project));
            var upgraded = ContextDemoProject.UpgradeToV4(project);
            Assert.Equal(4, upgraded.SchemaVersion);
            var clipped = project with { Edits = project.Edits with { Clips = [new("clip-1", "w21", "w80", "Clip", ClipOrigin.Manual, null, null, true)] } };
            var controlled = ClipControlsProject.Setting(new("clip-1", 1.25, null, ClipLook.Muted, 0, 0, 0, false, false, 0), clipped);
            Assert.Equal(4, controlled.SchemaVersion);
            // The native CLI E2E's project: the clip at 1.25× and Muted, with one bleep, saved and reopened.
            using var bleep = JsonDocument.Parse("""{"id":"fx-bleep-1","clipId":"clip-1","kind":"bleep","start":5.01,"end":5.39,"wordIds":["w51","w52","w53","w54"]}""");
            var effected = VoxClip.Core.Domain.Effects.ClipEffects.Adding([bleep.RootElement.Clone()], controlled);
            var reopened = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(effected));
            Assert.Equal(project.Id, reopened.Id);
            Assert.Single(reopened.ClipEffects);
            Assert.Equal(1.25, Assert.Single(reopened.ClipControls).Speed);
        }
        finally { Directory.Delete(directory, true); }
    }
}
