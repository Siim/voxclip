#if WIN_UI_TESTS
using VoxClip.App.Services;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class RedirectedLaunchSelectionTests
{
    private const string Exe = @"C:\Program Files\VoxClip\VoxClip.exe";
    private const string Project = @"C:\Video Projects\first take.voxclip";
    private const string Video = @"C:\Raw Video\first take.mp4";

    [Fact]
    public void RedirectedLaunchWithoutOneFileDoesNotOpen()
    {
        string[][] cases =
        [
            [], [" "], [Exe], ["--self-check"], ["/?"],
            [Exe, "--self-check"], [Exe, Project, Video], [Project, Video],
            [@"C:\Other App\Other.exe"]
        ];
        foreach (var tokens in cases) Assert.Null(RedirectedLaunchSelection.FilePath(tokens, Exe));
    }

    [Fact]
    public void ExecutableAndFileSelectOnlyTheFile()
    {
        Assert.Equal(Project, RedirectedLaunchSelection.FilePath([Exe, Project], Exe));
        Assert.Equal(Video, RedirectedLaunchSelection.FilePath([Exe, Video], Exe));
    }

    [Fact]
    public void FileOnlyActivationPreservesParsedPathWithSpaces() =>
        Assert.Equal(Video, RedirectedLaunchSelection.FilePath([Video], Exe));

    [Fact]
    public void ExecutableMatchIgnoresWindowsPathCase() =>
        Assert.Null(RedirectedLaunchSelection.FilePath([Exe.ToUpperInvariant()], Exe));
}
#endif
