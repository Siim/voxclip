using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>The Mac's tone match (voice-lab §8.7 item 2b): a segment's optional <c>audio.tiltDbPerOctave</c> is read,
/// validated and saved unchanged. Windows renders without it for now (owed in apps/macos/CONTRACTS.md).</summary>
public sealed class VoiceLabToneMatchWireTests
{
    private static JsonNode WithTilt(JsonNode? value)
    {
        var json = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"))!;
        var segment = json["voiceLab"]!["segments"]![0]!;
        segment["audio"]!["tiltDbPerOctave"] = value?.DeepClone();
        segment["candidates"]![0]!["recipe"]!["audio"]!["tiltDbPerOctave"] = value?.DeepClone();
        return json;
    }

    [Fact]
    public void AMacTiltIsReadValidatedAndSavedUnchanged()
    {
        var plain = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        Assert.Null(plain.VoiceLab.Segments[0].Audio.TiltDbPerOctave);
        Assert.DoesNotContain("tiltDbPerOctave", ProjectSerialization.Serialize(plain));
        var project = ProjectSerialization.Deserialize(WithTilt(JsonValue.Create(1.2)).ToJsonString());
        Assert.Equal(1.2, project.VoiceLab.Segments[0].Audio.TiltDbPerOctave);
        Assert.Equal(1.2, project.VoiceLab.Segments[0].Candidates[0].Recipe!.Audio.TiltDbPerOctave);
        VoiceLabProject.Validate(project); VoiceLabRenderValidation.Validate(project);
        var saved = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project));
        Assert.Equal(1.2, saved.VoiceLab.Segments[0].Audio.TiltDbPerOctave);
        Assert.Equal(1.2, saved.VoiceLab.Segments[0].Candidates[0].Recipe!.Audio.TiltDbPerOctave);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("2.1")]
    [InlineData("-2.5")]
    [InlineData("\"1\"")]
    public void AnInvalidTiltRefusesTheProject(string value)
    {
        Assert.Throws<VoxClipException>(() => ProjectSerialization.Deserialize(WithTilt(JsonNode.Parse(value)).ToJsonString()));
    }

    [Fact]
    public void ATiltIsFiniteNonZeroAndWithinTwoDecibelsPerOctave()
    {
        Assert.True(new VoiceLabAudio("a", 0, 1, 1, 0).TiltIsValid);
        Assert.True(new VoiceLabAudio("a", 0, 1, 1, 0, -2).TiltIsValid);
        Assert.False(new VoiceLabAudio("a", 0, 1, 1, 0, 0).TiltIsValid);
        Assert.False(new VoiceLabAudio("a", 0, 1, 1, 0, double.NaN).TiltIsValid);
        Assert.False(new VoiceLabAudio("a", 0, 1, 1, 0, 2.01).TiltIsValid);
    }
}
