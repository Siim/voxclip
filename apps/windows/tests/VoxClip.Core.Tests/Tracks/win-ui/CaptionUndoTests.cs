#if WIN_UI_TESTS
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Undo restores only what each step changed, as the Mac's one-step history does: a caption style, Fine tune or reset
/// change is its own step, so undoing an earlier cut never reverts later caption choices.</summary>
public sealed class CaptionUndoTests
{
    private static EditorViewModel Editor()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "clip-from-long-take.voxclip")));
        return new(project with
        {
            Edits = project.Edits with { Clips = [], CutWordIds = [], CutPauseIds = [], ActiveClipId = null },
            Captions = project.Captions with { StyleId = "vox-highlight" }
        });
    }

    private static string Raw(JsonElement value) => value.ValueKind == JsonValueKind.Undefined ? "" : value.GetRawText();

    [Fact]
    public void UndoingACutKeepsTheCaptionChangesMadeAfterIt()
    {
        var model = Editor();
        var original = Raw(model.Project.Captions.Overrides);
        model.Select(2); model.CutSelection(false);
        var cut = model.Project.Edits.CutWordIds.ToArray();
        Assert.NotEmpty(cut);
        model.SetCaptionStyle("karaoke");
        model.SetCaptionOverrides(CaptionFineTune.Change(model.Project.Captions, "font", ("sizeScale", JsonValue.Create(1.2))));
        var tuned = Raw(model.Project.Captions.Overrides);
        Assert.NotEqual(original, tuned);

        // Ctrl+Z steps back one change at a time, newest first; the cut stays until its own step.
        model.Undo();
        Assert.Equal(("karaoke", original), (model.Project.Captions.StyleId, Raw(model.Project.Captions.Overrides)));
        Assert.Equal(cut, model.Project.Edits.CutWordIds);
        model.Undo();
        Assert.Equal("vox-highlight", model.Project.Captions.StyleId);
        Assert.Equal(cut, model.Project.Edits.CutWordIds);
        model.Undo();
        Assert.Empty(model.Project.Edits.CutWordIds);
        Assert.Equal(("vox-highlight", original), (model.Project.Captions.StyleId, Raw(model.Project.Captions.Overrides)));
        Assert.False(model.CanUndo);

        // Redo replays the same steps in order.
        model.Redo();
        Assert.Equal(cut, model.Project.Edits.CutWordIds);
        Assert.Equal("vox-highlight", model.Project.Captions.StyleId);
        model.Redo();
        Assert.Equal("karaoke", model.Project.Captions.StyleId);
        model.Redo();
        Assert.Equal(tuned, Raw(model.Project.Captions.Overrides));
        Assert.False(model.CanRedo);
    }

    [Fact]
    public void ReselectingTheCurrentStyleRecordsNoStepAndResetIsOneStep()
    {
        var model = Editor();
        model.SetCaptionStyle("vox-highlight");
        Assert.False(model.CanUndo);
        model.SetCaptionOverrides(CaptionFineTune.Change(model.Project.Captions, "font", ("sizeScale", JsonValue.Create(1.45))));
        var tuned = model.Project.Captions;
        model.SetCaptions(CaptionFineTune.Reset(model.Project.Captions));
        model.Undo();
        Assert.Equal(Raw(tuned.Overrides), Raw(model.Project.Captions.Overrides));
        Assert.True(model.CanUndo);
        Assert.True(model.CanRedo);
    }
}
#endif
