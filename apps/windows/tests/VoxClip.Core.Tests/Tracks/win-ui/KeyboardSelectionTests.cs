#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The transcript's arrow-key selection and what Narrator hears after a move (design §11.2, §15). The fixture's
/// words: So, um, (cut) today, we, ship (corrected to "shipped"), uh, (cut) the, clipper., Thanks.</summary>
public sealed class KeyboardSelectionTests
{
    [Fact]
    public void ControlShiftYUsesTheCaretOrTheTimelinePlayheadWithoutStealingTextKeys()
    {
        var model = ClipSemanticsTests.RecordingReference();
        Assert.True(model.StartFromRecording(model.RecordingRegions[0].Key));
        var opening = Assert.Single(model.RecordingClipLines, line => line.FirstId == "w1");
        var later = model.RecordingClipLines.First(line => line.Id != opening.Id && line.Alternatives.Count > 0);
        model.Select(model.Index(opening.FirstId));
        model.SourceTime = model.Words[model.Index(later.FirstId)].Start;
        Assert.Equal("Ctrl+Shift+Y", ShortcutPolicy.RecordingVersionsGesture);
        Assert.True(ShortcutPolicy.OpensRecordingVersions("Y", true, true, false, false, false));
        Assert.False(ShortcutPolicy.OpensRecordingVersions("Y", true, false, false, false, false));
        Assert.False(ShortcutPolicy.OpensRecordingVersions("Y", true, true, true, false, false));
        Assert.False(ShortcutPolicy.OpensRecordingVersions("Y", true, true, false, true, false));
        Assert.False(ShortcutPolicy.OpensRecordingVersions("Y", true, true, false, false, true));
        Assert.Equal(opening.Id, model.RecordingVersionTarget(fromTimeline: false)?.Id);
        Assert.Equal(later.Id, model.RecordingVersionTarget(fromTimeline: true)?.Id);
    }

    [Fact]
    public void RecordingFoldKeysChooseAuditionCloseAndUseOnlyOutsideTextFields()
    {
        var model = ClipSemanticsTests.RecordingReference();
        Assert.True(model.StartFromRecording(model.RecordingRegions[0].Key));
        var line = Assert.Single(model.RecordingClipLines, line => line.FirstId == "w1");
        var alternate = Assert.Single(line.Alternatives);
        model.Select(model.Index("w23"));
        Assert.True(model.OpenRecordingVersions(line));
        var project = model.Project;
        RecordingAudition? audition = null;
        var stopped = false;
        void Press(string key)
        {
            Assert.Null(ShortcutPolicy.RecordingFoldKey(key, true, false, false));
            Assert.Null(ShortcutPolicy.RecordingFoldKey(key, false, true, false));
            Assert.Null(ShortcutPolicy.RecordingFoldKey(key, false, false, true));
            var command = Assert.IsType<RecordingVersionKey>(ShortcutPolicy.RecordingFoldKey(key, false, false, false));
            Assert.True(model.HandleRecordingVersionKey(command, value => audition = value, () => stopped = true));
        }

        Press("Up");
        Assert.Equal(line.Take.Key, model.SelectedRecordingVersionKey);
        Press("Down");
        Assert.Equal(alternate.Key, model.SelectedRecordingVersionKey);
        Press("Space");
        Assert.Equal(line.Span(alternate.Key)?.StartWordId, audition?.FirstId);
        Assert.Same(project, model.Project);
        Press("Escape");
        Assert.True(stopped);
        Assert.Null(model.OpenRecordingLine);
        Assert.Equal(model.Index(line.FirstId), model.SelectionCaret);
        Assert.True(model.OpenRecordingVersions(line));
        Press("Enter");
        Assert.Equal("Use version", model.UndoActionName);
        Assert.Null(model.OpenRecordingLine);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    [InlineData(5)]
    [InlineData(6)]
    public void ControlAltSelectsAllOrTheRecordingInClockOrder(int number)
    {
        var model = ClipSemanticsTests.RecordingStory();
        var source = model.Project.Media.AdditionalSources![0];
        var transcript = model.Project.Media.SpokenSources![0].Transcript;
        for (var slot = 3; slot <= 6; slot++)
            Assert.True(model.AddSpokenRecording(source with { ContentKey = new string((char)('0' + slot), 64),
                AbsolutePath = $"/synthetic/DJI_001{slot}.MOV", RelativePath = $"DJI_001{slot}.MOV" }, transcript), model.Notice);
        var before = model.Project;
        Assert.True(ShortcutPolicy.PaneForwards(ShortcutPolicy.Gesture($"Number{number}", true, false, alt: true)));
        Assert.False(ShortcutPolicy.PaneForwards(ShortcutPolicy.Gesture($"Number{number}", true, true, alt: true)));
        Assert.True(model.ChooseRecordingShortcut(number));
        Assert.Equal(number == 0 ? new RecordingView(RecordingViewKind.All) : new(RecordingViewKind.Recording, model.RecordingRegions[number - 1].Key), model.TranscriptRecordingView);
        Assert.Same(before, model.Project);
    }

    [Fact]
    public void TimelineShortcutsReserveOnlyTheirExactModifiers()
    {
        (int Key, bool Ctrl, bool Shift, TimelineShortcut Command)[] bindings =
        [
            (13, false, false, TimelineShortcut.Select), (9, false, false, TimelineShortcut.Next), (9, false, true, TimelineShortcut.Previous),
            (188, false, false, TimelineShortcut.EarlierFrame), (190, false, false, TimelineShortcut.LaterFrame),
            (188, false, true, TimelineShortcut.EarlierWord), (190, false, true, TimelineShortcut.LaterWord),
            (219, true, true, TimelineShortcut.TrimStart), (221, true, true, TimelineShortcut.TrimEnd),
            ('B', false, false, TimelineShortcut.Split), ('B', true, true, TimelineShortcut.SplitAll), ('B', true, false, TimelineShortcut.None),
            ('D', true, false, TimelineShortcut.Duplicate), ('D', false, false, TimelineShortcut.None), ('D', true, true, TimelineShortcut.None),
            (46, false, false, TimelineShortcut.Delete), (8, false, false, TimelineShortcut.Delete),
            (187, true, true, TimelineShortcut.VolumeUp), (189, true, true, TimelineShortcut.VolumeDown),
            ('N', false, false, TimelineShortcut.Snapping), ('N', true, false, TimelineShortcut.None),
            (187, true, false, TimelineShortcut.ZoomIn), (189, true, false, TimelineShortcut.ZoomOut),
            ('Z', false, true, TimelineShortcut.Fit), (27, false, false, TimelineShortcut.Escape)
        ];
        foreach (var (key, ctrl, shift, command) in bindings)
        {
            Assert.Equal(command, TimelineKeys.Resolve(key, ctrl, shift, false));
            Assert.Equal(TimelineShortcut.None, TimelineKeys.Resolve(key, ctrl, shift, true));
        }
    }

    [Fact]
    public void DuplicateDoesNotShadowWindowAccelerators()
    {
        var app = Path.Combine(Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!, "apps/windows/src/VoxClip.App");
        var window = File.ReadAllText(Path.Combine(app, "MainWindow.xaml.cs"));
        var editor = File.ReadAllText(Path.Combine(app, "Pages/EditorPage.xaml.cs"));
        Assert.DoesNotContain("VirtualKey.D, VirtualKeyModifiers.Control", window + editor);
        Assert.Contains("VirtualKey.B, VirtualKeyModifiers.Control, ToggleExplorer", window);
        Assert.Contains("VirtualKey.N, VirtualKeyModifiers.Control, () => App.NewWindow()", window);
        Assert.Contains("ZoomFocusedEditor", editor);
        Assert.Contains("DescendsFrom(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject, Timeline)", editor);
    }

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
