using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabAudioTagTests
{
    [Fact]
    public void OptionalAnnotationsDecodeValidateAndPreserveWithoutChangingWords()
    {
        using var fixture = JsonDocument.Parse(FixtureLoader.ReadText("fixtures/voice-lab/audio-tag-cases.json"));
        var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        foreach (var row in fixture.RootElement.GetProperty("roundTrips").EnumerateArray())
        {
            var text = JsonSerializer.Deserialize<VoiceLabText>(row.GetRawText(), options)!;
            Assert.True(VoiceLabProject.ValidAudioTags(text));
            using var encoded = JsonDocument.Parse(JsonSerializer.Serialize(text, options));
            Assert.Equal(row.GetProperty("new").GetString(), encoded.RootElement.GetProperty("new").GetString());
            Assert.Equal(row.TryGetProperty("audioTags", out _), encoded.RootElement.TryGetProperty("audioTags", out _));
            if (text.AudioTags is not null)
                Assert.Equal(text.AudioTags, JsonSerializer.Deserialize<VoiceLabText>(encoded.RootElement.GetRawText(), options)!.AudioTags);
        }
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var segments = project.VoiceLab.Segments.ToArray();
        segments[0] = segments[0] with { Text = segments[0].Text! with { AudioTags = [new(1, "laughs")] } };
        var changed = project with { VoiceLab = project.VoiceLab with { Segments = segments } };
        VoiceLabProject.Validate(changed);
        var saved = ProjectSerialization.Serialize(changed);
        var restored = ProjectSerialization.Deserialize(saved);
        Assert.Equal("laughs", restored.VoiceLab.Segments[0].Text!.AudioTags![0].Tag);
        Assert.Equal(project.VoiceLab.Segments[0].Words, restored.VoiceLab.Segments[0].Words);
    }

    [Theory]
    [InlineData(-1, "laughs")]
    [InlineData(3, "laughs")]
    [InlineData(1, "shouts")]
    public void InvalidAnnotationsAreRejected(int boundary, string tag)
        => Assert.False(VoiceLabProject.ValidAudioTags(new("Old words", "Hello there") { AudioTags = [new(boundary, tag)] }));
}
