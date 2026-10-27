using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class ProjectNormalizationTests
{
    [Fact]
    public async Task LegacyProjectNormalizesBeforeValidationAndWritesCanonicalText()
    {
        var path = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "normalization", "legacy-nfc.voxclip");
        var expectedJson = File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "normalization", "legacy-nfc.expected.json"));
        var expected = ProjectSerialization.Deserialize(expectedJson);
        var opened = await new ProjectStore().LoadAsync(path, TestContext.Current.CancellationToken);
        Assert.Empty(opened.Warnings);
        var encoded = ProjectSerialization.Serialize(opened.Project);
        Assert.Equal(ProjectSerialization.Serialize(expected), encoded);
        ProjectValidation.Validate(encoded);
        var saved = ProjectSerialization.Deserialize(encoded);
        Assert.Equal(new[] { 0xAC01 }, saved.Transcript!.Words[0].Text.EnumerateRunes().Select(rune => rune.Value));
        Assert.Equal(new[] { 0xAC04 }, saved.Edits.Corrections["w5"].EnumerateRunes().Select(rune => rune.Value));
        Assert.Equal(expected.Transcript!.Words.Select(word => (word.Id, word.Start, word.End)), saved.Transcript.Words.Select(word => (word.Id, word.Start, word.End)));
    }
}
