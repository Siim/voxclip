using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>Replays shared/fixtures/clip-frames/clip-frames-wire-cases.json, as the Swift ClipFramesProjectWireTests do: a clip's
/// opening lead-in, its face-follow crop centre and its cover (ADR-R48 part 2) open, validate and save unchanged on Windows, and
/// the lead-in and the crop centre render as on the Mac.</summary>
public sealed class ClipFramesProjectWireTests
{
    private const string FixturePath = "fixtures/clip-frames/clip-frames-project.voxclip";
    private static JsonObject Fixture() => JsonNode.Parse(FixtureLoader.ReadText(FixturePath))!.AsObject();
    private static JsonObject Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-frames/clip-frames-wire-cases.json"))!.AsObject();

    private static JsonObject Applied(JsonNode item)
    {
        var document = Fixture();
        foreach (var patch in item["patches"]!.AsArray())
        {
            var parts = patch!["path"]!.GetValue<string>().Split('/', StringSplitOptions.RemoveEmptyEntries);
            JsonNode target = document;
            foreach (var part in parts[..^1]) target = target is JsonArray array ? array[int.Parse(part)]! : target[part]!;
            if (target is JsonArray values) values[int.Parse(parts[^1])] = patch["value"]?.DeepClone();
            else if (patch["remove"]?.GetValue<bool>() == true) target.AsObject().Remove(parts[^1]);
            else target[parts[^1]] = patch["value"]?.DeepClone();
        }
        return document;
    }

    [Fact]
    public void FormatIsItsOwnFile() => Assert.Equal("voxclip-clip-frames-wire-cases/1", Cases()["format"]!.GetValue<string>());

    [Fact]
    public void MacProjectsWithTheNewFieldsSaveLosslessly()
    {
        var valid = Cases()["valid"]!.AsArray();
        Assert.Equal(8, valid.Count);
        foreach (var item in valid)
        {
            var id = item!["id"]!.GetValue<string>();
            var input = Applied(item);
            var project = ProjectSerialization.Deserialize(input.ToJsonString());
            var encoded = ProjectSerialization.Serialize(project);
            Assert.Equal(encoded, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(encoded)));
            var saved = JsonNode.Parse(encoded)!.AsObject();
            // Every field the case carries comes back as it was, and an absent one stays absent.
            Assert.True(JsonNode.DeepEquals(input["edits"]!["clips"], saved["edits"]!["clips"]), id + ": " + saved["edits"]!["clips"]!.ToJsonString());
            if (input["clipControls"] is null) Assert.False(saved.ContainsKey("clipControls"), id);
            else Assert.True(JsonNode.DeepEquals(input["clipControls"], saved["clipControls"]), id + ": " + saved["clipControls"]?.ToJsonString());
        }
    }

    [Fact]
    public void InvalidCorpusIsRejected()
    {
        var invalid = Cases()["invalid"]!.AsArray();
        Assert.Equal(14, invalid.Count);
        foreach (var item in invalid)
        {
            var exception = Record.Exception(() => ProjectSerialization.Deserialize(Applied(item!).ToJsonString()));
            Assert.True(exception is not null, item!["id"]!.GetValue<string>());
        }
    }

    [Fact]
    public void TheFixtureCarriesEachField()
    {
        var project = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        var controls = Assert.Single(project.ClipControls);
        Assert.Equal(0.25, project.Edits.Clips[0].LeadInSeconds);
        Assert.Equal(new ReframeSettings(ReframeSettings.FaceMode, 1, 0.42, 0.38), controls.Reframe);
        Assert.Equal(1.3, controls.CoverSeconds);
        Assert.Equal((0.42, 0.38), controls.CropCenter(9.0 / 16));
        Assert.Equal((0.42, 0.38), controls.CropCenter(1));
        Assert.Null(controls.CropCenter(16.0 / 9));
        // A cover alone, or a face alone, is a control worth storing.
        var bare = new ProjectClipControls("clip-main", 1, null, ClipLook.Original, 0, 0, 0, false, false, 0);
        Assert.True(bare.IsDefault);
        Assert.False((bare with { CoverSeconds = 1.3 }).IsDefault);
        Assert.False((bare with { Reframe = controls.Reframe }).IsDefault);
    }

    private static TimedWord Word(string id, string text, double start, double end) =>
        new(id, text, WordKind.Word, start, end, null, null, null, null, TimingSource.Native);

    [Fact]
    public void ALeadInOpensEarlierButNeverReachesTheWordBefore()
    {
        TimedWord[] words = [Word("a", "So.", 0.2, 0.5), Word("b", "Here", 1.5, 1.8), Word("c", "it", 1.9, 2.1), Word("d", "is.", 2.2, 2.5)];
        Assert.Equal(1.5 - 0.12, EditingAlgorithms.ClipTimes(words, 1, 3).Start, 9);
        Assert.Equal(1.1, EditingAlgorithms.ClipTimes(words, 1, 3, 0.4).Start, 9);
        // The floor is the word before plus its own cut margin (0.1 s): never a sound of "So.".
        Assert.Equal(0.6, EditingAlgorithms.ClipTimes(words, 1, 3, 5).Start, 9);
        Assert.Equal(0.6, EditingAlgorithms.ClipLeadInFloor(words, 1), 9);
        Assert.Equal(0, EditingAlgorithms.ClipTimes(words, 0, 3, 0.6).Start, 9);
    }

    [Fact]
    public void TheClipsSegmentsOpenAtTheLeadInAndANewFirstWordDropsIt()
    {
        var project = ProjectSerialization.Deserialize(Fixture().ToJsonString());
        var words = project.Transcript!.Words;
        var state = EditingEngine.FromProject(project)! with { ActiveClipId = "clip-main" };
        var withLead = state with { Clips = [state.Clips[0] with { StartWordId = words[3].Id, LeadInSeconds = 0.6 }] };
        var plain = state with { Clips = [state.Clips[0] with { StartWordId = words[3].Id, LeadInSeconds = null }] };
        double Head(EditState value) => EditingEngine.BuildSegments(value, 60).Single(segment => segment.Id == "clip-head").End;
        Assert.Equal(words[3].Start - 0.6, Head(withLead), 9);
        Assert.True(Head(plain) > Head(withLead));
        var moved = EditingEngine.Reduce(withLead, new EditOperation.UpdateClip("clip-main", 1, 8));
        Assert.Null(moved.Clips[0].LeadInSeconds);
        var kept = EditingEngine.Reduce(withLead, new EditOperation.UpdateClip("clip-main", 3, 7));
        Assert.Equal(0.6, kept.Clips[0].LeadInSeconds);
    }

    [Fact]
    public void TheFaceCentreMovesTheVerticalAndSquareCropsOnly()
    {
        var face = new ProjectClipControls("a", 1, null, ClipLook.Original, 0, 0, 0, false, false, 0, new ReframeSettings(ReframeSettings.FaceMode, 1, 0.3, 0.5));
        var portrait = ClipFaceCrop.Centered(ExportPresets.CenterCrop(new(1920, 1080), new(1080, 1920)), 1920, 1080, face, 1080.0 / 1920);
        Assert.Equal(607.5, portrait.Width, 6);
        Assert.Equal(576, portrait.X + portrait.Width / 2, 6);
        var square = ClipFaceCrop.Centered(ExportPresets.CenterCrop(new(1920, 1080), new(1080, 1080)), 1920, 1080, face, 1);
        Assert.Equal(36, square.X, 6);
        var edge = face with { Reframe = face.Reframe! with { CenterX = 0.98 } };
        var right = ClipFaceCrop.Centered(ExportPresets.CenterCrop(new(1920, 1080), new(1080, 1920)), 1920, 1080, edge, 1080.0 / 1920);
        Assert.Equal(1920, right.X + right.Width, 6);
        var flipped = face with { FlipHorizontal = true };
        var mirrored = ClipFaceCrop.Centered(ExportPresets.CenterCrop(new(1920, 1080), new(1080, 1920)), 1920, 1080, flipped, 1080.0 / 1920);
        Assert.Equal(1344, mirrored.X + mirrored.Width / 2, 6);
        var wide = ExportPresets.CenterCrop(new(1920, 1080), new(1920, 1080));
        Assert.Equal(wide, ClipFaceCrop.Centered(wide, 1920, 1080, face, 16.0 / 9));
        var centre = ExportPresets.CenterCrop(new(1920, 1080), new(1080, 1920));
        Assert.Equal(centre, ClipFaceCrop.Centered(centre, 1920, 1080, face with { Reframe = null }, 1080.0 / 1920));
        Assert.Equal(centre, ClipFaceCrop.Centered(centre, 1920, 1080, null, 1080.0 / 1920));
    }
}
