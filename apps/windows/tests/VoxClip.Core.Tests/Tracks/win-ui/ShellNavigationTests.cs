#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Every window navigation path around the leave boundary (ADR-R29, design §2): what saves first, what only shows,
/// and what a refused leave shows. MainWindow names its path for each one; MainWindow itself runs only on Windows, where
/// run-native-flow.ps1's --shell-probe drives it.</summary>
public sealed class ShellNavigationTests
{
    private const string Video = @"C:\Takes\interview.mp4";

    /// <summary>Each path's route with no project open, with one open, and with the file already held by another window.</summary>
    private static readonly (ShellPath Via, ShellRoute None, ShellRoute Open, ShellRoute Held)[] Table =
    [
        (ShellPath.SidebarHome, ShellRoute.ShowHome, ShellRoute.ShowHome, ShellRoute.ShowHome),
        (ShellPath.HomeShortcut, ShellRoute.ShowHome, ShellRoute.ShowHome, ShellRoute.ShowHome),
        (ShellPath.Back, ShellRoute.ShowHome, ShellRoute.ShowHome, ShellRoute.ShowHome),
        (ShellPath.ScopeRow, ShellRoute.Stay, ShellRoute.ShowEditor, ShellRoute.ShowEditor),
        (ShellPath.EditorShortcut, ShellRoute.Stay, ShellRoute.ShowEditor, ShellRoute.ShowEditor),
        (ShellPath.RecentRow, ShellRoute.Open, ShellRoute.LeaveThenOpen, ShellRoute.ShowHoldingWindow),
        (ShellPath.HomeTile, ShellRoute.Open, ShellRoute.LeaveThenOpen, ShellRoute.ShowHoldingWindow),
        (ShellPath.HomeTileOpen, ShellRoute.Open, ShellRoute.LeaveThenOpen, ShellRoute.ShowHoldingWindow),
        (ShellPath.ImportVideo, ShellRoute.Open, ShellRoute.LeaveThenOpen, ShellRoute.ShowHoldingWindow),
        (ShellPath.OpenProject, ShellRoute.Open, ShellRoute.LeaveThenOpen, ShellRoute.ShowHoldingWindow),
        (ShellPath.Drop, ShellRoute.Open, ShellRoute.LeaveThenOpen, ShellRoute.ShowHoldingWindow),
        (ShellPath.FileActivation, ShellRoute.Open, ShellRoute.LeaveThenOpen, ShellRoute.ShowHoldingWindow),
        (ShellPath.Launch, ShellRoute.Open, ShellRoute.LeaveThenOpen, ShellRoute.ShowHoldingWindow),
        (ShellPath.CloseWindow, ShellRoute.Close, ShellRoute.LeaveThenClose, ShellRoute.LeaveThenClose),
        (ShellPath.CloseShortcut, ShellRoute.Close, ShellRoute.LeaveThenClose, ShellRoute.LeaveThenClose),
    ];

    public static IEnumerable<object[]> Routes => Table.Select(row => new object[] { row.Via, row.None, row.Open, row.Held });

    public static IEnumerable<object[]> Paths => Enum.GetValues<ShellPath>().Select(via => new object[] { via });

    [Fact]
    public void TheTableNamesEveryPathOnce() => Assert.Equal(Enum.GetValues<ShellPath>(), Table.Select(row => row.Via).Order());

    [Theory]
    [MemberData(nameof(Routes))]
    public void EveryPathHasItsRoute(ShellPath via, ShellRoute none, ShellRoute open, ShellRoute held)
    {
        Assert.Equal(none, ShellNavigation.Route(via, false, false, Video));
        Assert.Equal(open, ShellNavigation.Route(via, false, true, Video));
        Assert.Equal(held, ShellNavigation.Route(via, true, true, Video));
    }

    /// <summary>Every path with a project open, through the leave step with a stand-in for the editor's
    /// TrySaveBeforeLeavingAsync. Only the paths that open or close call it, once; the others never save. A refused save
    /// keeps the project; from Home the editor comes back so its explanation is seen.</summary>
    [Theory]
    [MemberData(nameof(Paths))]
    public async Task OnlyOpeningAndClosingRunTheLeaveBoundary(ShellPath via)
    {
        ShellPath[] leaving = [ShellPath.RecentRow, ShellPath.HomeTile, ShellPath.HomeTileOpen, ShellPath.ImportVideo, ShellPath.OpenProject,
            ShellPath.Drop, ShellPath.FileActivation, ShellPath.Launch, ShellPath.CloseWindow, ShellPath.CloseShortcut];
        foreach (var (saves, showingHome, expected) in new[]
        {
            (true, false, LeaveResult.Proceed), (true, true, LeaveResult.Proceed),
            (false, false, LeaveResult.Stay), (false, true, LeaveResult.ShowEditor),
        })
        {
            var calls = 0;
            var result = await ShellNavigation.LeaveAsync(ShellNavigation.Route(via, false, true, Video), showingHome, () => { calls++; return Task.FromResult(saves); });
            if (leaving.Contains(via)) Assert.Equal((1, expected), (calls, result));
            else Assert.Equal((0, LeaveResult.Proceed), (calls, result));
        }
    }

    /// <summary>Bringing forward the window that holds the file, an unsupported drop and a path with nothing open never save.</summary>
    [Theory]
    [MemberData(nameof(Paths))]
    public async Task HeldFilesUnsupportedDropsAndEmptyWindowsNeverSave(ShellPath via)
    {
        var calls = 0;
        Task<bool> Save() { calls++; return Task.FromResult(false); }
        Assert.Equal(LeaveResult.Proceed, await ShellNavigation.LeaveAsync(ShellNavigation.Route(via, false, false, Video), true, Save));
        var held = ShellNavigation.Route(via, true, true, Video);
        if (held != ShellRoute.LeaveThenClose) Assert.Equal(LeaveResult.Proceed, await ShellNavigation.LeaveAsync(held, true, Save));
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task AFailedSaveReachesTheWindow()
    {
        // MainWindow catches it and resumes the editor (ResumeAfterFailedLeave), so the project stays editable.
        await Assert.ThrowsAsync<IOException>(() => ShellNavigation.LeaveAsync(ShellRoute.LeaveThenClose, true, () => throw new IOException("disk full")));
    }

    [Theory]
    [InlineData(@"C:\Takes\interview.MP4", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.mov", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.m4v", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.mkv", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.webm", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Projects\interview.voxclip", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.avi", ShellRoute.Unsupported)]
    [InlineData(@"C:\Takes\notes.txt", ShellRoute.Unsupported)]
    public void DropsOpenOnlyWhatVoxClipCanOpen(string path, ShellRoute expected) => Assert.Equal(expected, ShellNavigation.Route(ShellPath.Drop, false, true, path));

    [Fact]
    public void AnUnsupportedDropIsExplainedWithTheDesignCopy()
    {
        Assert.Equal("VoxClip can't open AVI files on PC yet. Export the video as MP4 or MOV and try again.", ShellNavigation.UnsupportedDrop(@"C:\Takes\interview.avi"));
        Assert.Equal("VoxClip can't open TXT files on PC yet. Export the video as MP4 or MOV and try again.", ShellNavigation.UnsupportedDrop(@"C:\notes.Txt"));
        Assert.Null(ShellNavigation.UnsupportedDrop(@"C:\Takes\interview.Mp4"));
        // An unsupported drop never reaches the leave boundary, even with a project open in another window.
        Assert.Equal(ShellRoute.Unsupported, ShellNavigation.Route(ShellPath.Drop, true, true, @"C:\Takes\interview.avi"));
    }
}
#endif
