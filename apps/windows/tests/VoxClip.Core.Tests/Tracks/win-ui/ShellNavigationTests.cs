#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The window's navigation decisions around the leave boundary (ADR-R29, design §2): what saves first, what only
/// shows Home, and what a refused leave shows.</summary>
public sealed class ShellNavigationTests
{
    [Theory]
    [InlineData(false, false, ShellRoute.Open)]
    [InlineData(false, true, ShellRoute.LeaveThenOpen)]
    [InlineData(true, false, ShellRoute.ShowHoldingWindow)]
    [InlineData(true, true, ShellRoute.ShowHoldingWindow)]
    public void OpeningSavesTheOpenProjectFirstUnlessAnotherWindowHoldsIt(bool heldByAWindow, bool projectOpen, ShellRoute expected) =>
        Assert.Equal(expected, ShellNavigation.Open(heldByAWindow, projectOpen));

    [Theory]
    [InlineData(false, ShellRoute.Close)]
    [InlineData(true, ShellRoute.LeaveThenClose)]
    public void ClosingSavesTheOpenProjectFirst(bool projectOpen, ShellRoute expected) => Assert.Equal(expected, ShellNavigation.Close(projectOpen));

    [Theory]
    [InlineData(@"C:\Takes\interview.MP4", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.mov", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.m4v", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.mkv", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.webm", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Projects\interview.voxclip", ShellRoute.LeaveThenOpen)]
    [InlineData(@"C:\Takes\interview.avi", ShellRoute.Unsupported)]
    [InlineData(@"C:\Takes\notes.txt", ShellRoute.Unsupported)]
    public void DropsOpenOnlyWhatVoxClipCanOpen(string path, ShellRoute expected) => Assert.Equal(expected, ShellNavigation.Drop(path, false, true));

    [Fact]
    public void AnUnsupportedDropIsExplainedWithTheDesignCopy()
    {
        Assert.Equal("VoxClip can't open AVI files on PC yet. Export the video as MP4 or MOV and try again.", ShellNavigation.UnsupportedDrop(@"C:\Takes\interview.avi"));
        Assert.Equal("VoxClip can't open TXT files on PC yet. Export the video as MP4 or MOV and try again.", ShellNavigation.UnsupportedDrop(@"C:\notes.Txt"));
        Assert.Null(ShellNavigation.UnsupportedDrop(@"C:\Takes\interview.Mp4"));
        // An unsupported drop never reaches the leave boundary, even with a project open in another window.
        Assert.Equal(ShellRoute.Unsupported, ShellNavigation.Drop(@"C:\Takes\interview.avi", true, true));
    }

    [Theory]
    [InlineData(true, true)]
    [InlineData(false, false)]
    public void ARefusedLeaveFromHomeBringsTheEditorBack(bool showingHome, bool expected) =>
        Assert.Equal(expected, ShellNavigation.ShowEditorAfterRefusedLeave(showingHome));
}
#endif
