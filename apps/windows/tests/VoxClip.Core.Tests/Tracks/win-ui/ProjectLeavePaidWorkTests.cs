#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Mac <c>RewritePaidWorkGuardTests.closingTheProjectAsksFirstAndACancelledCloseKeepsTheWork</c>: a leave over an open Rewrite's
/// unused paid takes never starts, so nothing freezes, saves or disposes the Rewrite; with none, the leave goes on as before.</summary>
public sealed class ProjectLeavePaidWorkTests
{
    private static Project Fixture()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, "shared", "fixtures", "projects", "interview-take.voxclip");
            if (File.Exists(path)) return ProjectSerialization.Deserialize(File.ReadAllText(path));
        }
        throw new FileNotFoundException("Shared project fixture not found.");
    }

    [Fact]
    public async Task ALeaveOverPaidTakesNeverStarts()
    {
        var model = new EditorViewModel(Fixture());
        var held = true;
        var boundary = new ProjectLeaveBoundary(model) { HoldsPaidWork = () => held };
        var saves = 0;
        var refused = await Assert.ThrowsAsync<ProjectLeaveHeldException>(() => boundary.BeginAsync(() => { saves++; return Task.CompletedTask; }));
        Assert.Equal(ProjectLeaveHeldException.Copy, refused.Message);
        Assert.False(boundary.IsLeaving);
        Assert.False(model.IsLeaving);
        Assert.Equal(0, saves);
        // Editing goes on: nothing was frozen.
        model.Select(1); model.Select(3, true);
        Assert.NotNull(model.MakeClip());
        held = false;
        await boundary.BeginAsync(() => { saves++; return Task.CompletedTask; });
        Assert.True(boundary.IsLeaving && model.IsLeaving);
        Assert.Equal(1, saves);
        boundary.Resume();
    }
}
#endif
