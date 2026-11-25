#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class FootageUndoTests
{
    [Fact]
    public void UndoAndRedoRestoreTheFootagePlacement()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(),
            "fixtures", "projects", "clip-from-long-take.voxclip")));
        var original = new ProjectFootage("b-roll", project.Edits.Clips.First().Id, "bRoll", 6, 7, new("companion", 0));
        var moved = original with { Start = 7, End = 8, FadeOutSeconds = 0.25 };
        project = project with { Media = project.Media with { Footage = [original] } };
        var model = new EditorViewModel(project);

        Assert.True(model.ReplaceProject(project with { Media = project.Media with { Footage = [moved] } }, "Adjust B-roll"));
        Assert.Equal(moved, Assert.Single(model.Project.Media.Footage!));
        model.Undo();
        Assert.Equal(original, Assert.Single(model.Project.Media.Footage!));
        model.Redo();
        Assert.Equal(moved, Assert.Single(model.Project.Media.Footage!));
    }
}
#endif
