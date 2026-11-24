using System.Text.Json;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class ClaudeTranscriptionChoiceTests
{
    public static IEnumerable<object[]> WindowsChoices()
    {
        using var fixture = FixtureLoader.ReadJson(Path.Combine("fixtures", "transcription", "claude-mode-choice.json"));
        foreach (var row in fixture.RootElement.EnumerateArray())
        {
            if (row.GetProperty("apple").GetString() != "unavailable") continue;
            yield return [row.GetProperty("mode").GetString()!, row.GetProperty("confirmation").GetString()!, row.GetProperty("label").GetString()!];
        }
    }

    [Theory]
    [MemberData(nameof(WindowsChoices))]
    public void ClipStyleShowsTheConfirmationChoiceWithoutApple(string mode, string confirmation, string label)
    {
        var choice = ClaudeTranscriptionChoice.ForWindows(mode);
        Assert.Equal(confirmation, choice.Confirmation);
        Assert.Equal(label, choice.Label);
    }
}
