using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests;

/// <summary>A manual clip's title, design §6.2, against the cases both platforms share.</summary>
public sealed class ManualClipTitleTests
{
    [Fact]
    public void EveryManualClipTitleCase()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/clips/manual-titles.json");
        var root = fixture.RootElement;
        Assert.Equal("voxclip-manual-clip-titles/1", root.GetProperty("fixture").GetString());
        Assert.Equal(EditingAlgorithms.ClipTitleWords, root.GetProperty("maxWords").GetInt32());
        Assert.Equal(EditingLimits.MaxClipTitleCodePoints, root.GetProperty("maxCodePoints").GetInt32());
        var cases = root.GetProperty("cases").EnumerateArray().ToArray();
        Assert.True(cases.Length >= 10);
        foreach (var item in cases)
        {
            var words = item.GetProperty("words").EnumerateArray().Select(word => word.GetString()!).ToArray();
            var expected = item.GetProperty("expected");
            var title = EditingAlgorithms.ClipTitle(words);
            Assert.True(expected.ValueKind == JsonValueKind.Null ? title is null : title == expected.GetString(), $"{item.GetProperty("id").GetString()}: {title}");
            // Whatever the helper returns, the reducer stores unchanged.
            Assert.True(title is null || EditingAlgorithms.JsTrim(title) == title && title.EnumerateRunes().Count() <= EditingLimits.MaxClipTitleCodePoints);
        }
    }
}
