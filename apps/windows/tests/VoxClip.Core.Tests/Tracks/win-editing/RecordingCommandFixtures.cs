using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class RecordingCommandFixtures
{
    [Fact]
    public void StartsFromTheWholeRecordingExceptRestarts()
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/command-cases.json"))!;
        var original = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/recordings/" + vectors["project"]!.GetValue<string>()));
        var started = Assert.IsType<RecordingEditResult.Applied>(RecordingEdits.Apply(new RecordingEdit.StartFromRecording(original.Media.Source.ContentKey), original));
        var clip = Assert.Single(started.Project.Edits.Clips);
        Assert.Equal("Start from recording", started.UndoName);
        Assert.Equal(clip.Id, started.Project.Edits.ActiveClipId);
        Assert.Equal("I started Superscribe as a dictation tool.", clip.Title);
        Assert.Equal(new[] { "w1", "w18" }, clip.PlayParts.Select(part => part.StartWordId));
        Assert.Equal(new[] { "w13", "w27" }, clip.PlayParts.Select(part => part.EndWordId));
        Assert.Equal("w14", Assert.Single(started.Details!.LeftOut).StartWordId);
    }
}
