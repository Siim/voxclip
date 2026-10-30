#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The transcript's arrow-key selection and what Narrator hears after a move (design §11.2, §15). The fixture's
/// words: So, um, (cut) today, we, ship (corrected to "shipped"), uh, (cut) the, clipper., Thanks.</summary>
public sealed class KeyboardSelectionTests
{
    private static EditorViewModel Model() => new(HomeViewModelTests.Fixture("interview-take.voxclip"));

    [Fact]
    public void FirstArrowSelectsTheFirstWord()
    {
        var right = Model(); right.Step(1);
        Assert.Equal(0, right.SelectionStart); Assert.Equal(0, right.SelectionEnd);
        var left = Model(); left.Step(-1);
        Assert.Equal(0, left.SelectionStart); Assert.Equal(0, left.SelectionEnd);
        var shift = Model(); shift.Step(1, true);
        Assert.Equal(0, shift.SelectionStart); Assert.Equal(0, shift.SelectionEnd);
    }

    [Fact]
    public void ShiftArrowsExtendFromTheMovingEnd()
    {
        var model = Model(); model.Select(5);
        model.Step(-1, true); model.Step(-1, true); model.Step(-1, true);
        Assert.Equal(2, model.SelectionStart); Assert.Equal(5, model.SelectionEnd); Assert.Equal(2, model.SelectionCaret);
        model.Step(1, true);
        Assert.Equal(3, model.SelectionStart); Assert.Equal(5, model.SelectionEnd);
        model.Step(1, true); model.Step(1, true); model.Step(1, true);
        Assert.Equal(5, model.SelectionStart); Assert.Equal(6, model.SelectionEnd); Assert.Equal(6, model.SelectionCaret);
        model.Step(1);
        Assert.Equal(7, model.SelectionStart); Assert.Equal(7, model.SelectionEnd);
    }

    [Fact]
    public void PlainArrowsMoveFromTheCaretAndStopAtTheEnds()
    {
        var model = Model(); model.Select(6); model.Select(3, true);
        model.Step(-1);
        Assert.Equal(2, model.SelectionStart); Assert.Equal(2, model.SelectionEnd);
        model.Select(model.Words.Count - 1); model.Step(1);
        Assert.Equal(model.Words.Count - 1, model.SelectionStart);
        model.Select(0); model.Step(-1);
        Assert.Equal(0, model.SelectionEnd);
    }

    [Fact]
    public void AnnouncementNamesTheCaretWordAndTheSelectionSize()
    {
        var model = Model();
        Assert.Equal("", model.SelectionAnnouncement());
        model.Step(1);
        Assert.Equal("So, selected", model.SelectionAnnouncement());
        Assert.Equal(model.AccessibleWord(0), model.SelectionAnnouncement());
        model.Select(4);
        Assert.Equal("shipped, corrected, heard as: ship, selected", model.SelectionAnnouncement());
        model.Select(2); model.Select(4, true);
        Assert.Equal("shipped, corrected, heard as: ship, 3 words selected", model.SelectionAnnouncement());
        model.Select(4); model.Step(-1, true); model.Step(-1, true);
        Assert.Equal("today, 3 words selected", model.SelectionAnnouncement());
        model.Select(0); model.Select(model.Words.Count - 1, true);
        Assert.Equal($"All {model.Words.Count} words selected", model.SelectionAnnouncement());
    }
}
#endif
