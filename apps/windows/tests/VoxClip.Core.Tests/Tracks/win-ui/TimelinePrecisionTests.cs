#if WIN_UI_TESTS
using System.Text.RegularExpressions;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Issue #41 step 1 on Windows: frame and word-boundary steps, the exact range, I and O, the edit bar's range actions and
/// A1's word ticks. Twin of the Mac TimelinePrecisionTests, on the same 60-second, 30 fps take.</summary>
public sealed class TimelinePrecisionTests
{
    private const double Frame = 1.0 / 30;

    // MARK: Frame and word-boundary steps

    [Fact]
    public void CommaAndPeriodStepThePlayheadOneFrameWithNothingSelected()
    {
        var model = Model();
        Assert.Equal(30, model.TimelineFrameRate);
        Assert.Equal(TimelineShortcut.LaterFrame, TimelineKeys.Resolve(190, false, false, false));
        Assert.Equal(TimelineShortcut.EarlierWord, TimelineKeys.Resolve(188, false, true, false));
        var later = TimelinePrecision.FrameStep(12, model.TimelineFrameRate, 1);
        Assert.Equal(12 + Frame, later, 9);
        var back = TimelinePrecision.FrameStep(TimelinePrecision.FrameStep(later, 30, -1), 30, -1);
        Assert.Equal(12 - Frame, back, 9);
        // A playhead between frames steps onto the grid.
        Assert.Equal(361.0 / 30, TimelinePrecision.FrameStep(12.01, 30, 1), 9);
        Assert.Equal(12, TimelinePrecision.FrameStep(12.01, 30, -1), 9);
        Assert.Equal(29.97, new EditorViewModel(Fixture()).TimelineFrameRate);
    }

    [Fact]
    public void AHeldKeyStepsOnFromTheLastTargetUntilThePlayheadLeavesIt()
    {
        (double From, double To) last = (12, 12 + Frame);
        // The seek has not landed: the playhead still reads where the step began.
        Assert.Equal(12 + Frame, TimelinePrecision.StepOrigin(12, 30, last), 9);
        // It landed on a decoded frame time a little before the grid: the next step still starts from the target.
        Assert.Equal(12 + Frame, TimelinePrecision.StepOrigin(12 + Frame - 1e-4, 30, last), 9);
        Assert.Equal(12 + 2 * Frame, TimelinePrecision.FrameStep(TimelinePrecision.StepOrigin(12 + Frame - 1e-4, 30, last), 30, 1), 9);
        // A click elsewhere starts from the playhead.
        Assert.Equal(20, TimelinePrecision.StepOrigin(20, 30, last));
        Assert.Equal(20, TimelinePrecision.StepOrigin(20, 30, null));
    }

    [Fact]
    public void ShiftCommaAndPeriodJumpToWordBoundariesAndSkipFoldedWordsOnEdited()
    {
        var model = Model();
        static double Same(double time) => time;
        Assert.Equal(12.8, model.TimelineWordBoundary(12.5, 1, Same, false));
        Assert.Equal(13, model.TimelineWordBoundary(12.8, 1, Same, false));
        Assert.Equal(12.8, model.TimelineWordBoundary(13, -1, Same, false));
        var plan = TimelineLayout.Plan(model);
        var first = model.TimelineWordBoundary(13, 1, plan.MapTime, true);
        Assert.Equal(13.8, first);
        Assert.Equal(16, model.TimelineWordBoundary(first!.Value, 1, plan.MapTime, true));
        Assert.Null(model.TimelineWordBoundary(29.8, 1, Same, false));
        Assert.False(model.CanUndo);
    }

    // MARK: The exact range

    [Fact]
    public void SnapOffKeepsAFrameRoundedRangeAndSelectsTheWordsWhollyInside()
    {
        var model = Model();
        Assert.True(model.SetExactRange(17.06, 12.84, 17.06));
        var range = Assert.IsType<TimelineExactRange>(model.ExactRange);
        // 12.84 s and 17.06 s fall on frames 385.2 and 511.8 of 30 fps: the nearest frames are 385 and 512.
        Assert.Null(range.Recording);
        Assert.Equal(385, range.Start * 30, 6);
        Assert.Equal(512, range.End * 30, 6);
        Assert.Equal((model.Index("t13"), model.Index("t16")), (model.SelectionStart, model.SelectionEnd));
        Assert.Equal("4.23" + (char)0xA0 + "s · 0:12.83–0:17.07", model.ExactRangeReadout);
        Assert.Equal((385.0 / 30, 512.0 / 30), model.AskClaude.TimeRange);
        Assert.Equal("Exact range, 4 words inside", model.TimelineSelectionStatus);
        Assert.False(model.TimelineCanCut);
        Assert.False(model.CanUndo);
        Assert.False(model.IsDirty);
    }

    [Fact]
    public void RangesWordsAndItemsReplaceEachOtherAndEscapeClearsTheRange()
    {
        var model = Model();
        var changes = 0;
        model.SelectionChanged += (_, _) => changes++;
        model.SetExactRange(11.5, 13.9, 11.5);
        Assert.Equal((model.Index("t12"), model.Index("t13")), (model.SelectionStart, model.SelectionEnd));
        Assert.True(changes > 0);
        // An item selection clears the words through ClearSelection; it clears the range too.
        model.ClearSelection();
        Assert.Null(model.ExactRange);
        Assert.False(model.HasSelection);
        Assert.Null(model.AskClaude.TimeRange);
        model.SetExactRange(11.5, 13.9, 11.5);
        model.Select(model.Index("t20"));
        Assert.Null(model.ExactRange);
        Assert.Equal(model.Index("t20"), model.SelectionStart);
        model.SetExactRange(11.5, 13.9, 11.5);
        Assert.True(model.ClearExactRange());
        Assert.Null(model.ExactRange);
        Assert.False(model.HasSelection);
        Assert.Null(model.AskClaude.TimeRange);
        Assert.False(model.ClearExactRange());
        // A range of no words, as a drag inside a gap leaves, is still a range an item selection replaces.
        model.SetExactRange(12.85, 12.95, 12.85);
        Assert.NotNull(model.ExactRange);
        Assert.False(model.HasSelection);
        Assert.Equal("Exact range", model.TimelineSelectionStatus);
        model.ClearSelection();
        Assert.Null(model.ExactRange);
        Assert.False(model.CanUndo);
    }

    [Fact]
    public void ShiftClickExtendsByFrameWithSnapOffAndByWordWithItOn()
    {
        var model = Model();
        model.SetExactRange(12.4, 13.5, 12.4);
        Assert.True(model.ExtendTimelineSelection(16.42, exact: true));
        var range = Assert.IsType<TimelineExactRange>(model.ExactRange);
        Assert.Equal(12.4, range.Start, 6);
        Assert.Equal(493, range.End * 30, 6);
        Assert.Equal((model.Index("t13"), model.Index("t15")), (model.SelectionStart, model.SelectionEnd));
        Assert.True(model.ExtendTimelineSelection(18.7, exact: false));
        Assert.Null(model.ExactRange);
        // Word grain: In snaps to word 12's start, Out to word 18's end.
        Assert.Equal((model.Index("t12"), model.Index("t18")), (model.SelectionStart, model.SelectionEnd));
        Assert.Equal("7 words", model.TimelineSelectionStatus);
        Assert.False(model.CanUndo);
    }

    [Fact]
    public void AShiftPressExtendsOnReleaseAndCtrlNStaysWithTheTimelineDuringACtrlDrag()
    {
        // TimelineView needs WinUI, so its pointer wiring is checked in the source (CI's Windows run drives it).
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/TimelineView.cs"));
        string Body(string name)
        {
            var start = source.IndexOf($"private void {name}(", StringComparison.Ordinal);
            Assert.True(start >= 0, name);
            var end = source.IndexOf("\n    private ", start + 1, StringComparison.Ordinal);
            return source[start..end];
        }
        // The press only marks a pending extend; the release extends unless the pointer moved 3 epx, which keeps the Shift+drag scrub.
        Assert.DoesNotContain("ExtendTimelineSelection", Body("ScrubPressed"));
        Assert.Contains("extendPending = shift && !control && !ruler", Body("ScrubPressed"));
        Assert.Matches(@"if \(extendPending\)\s*\{\s*if \(Math\.Abs\(args\.GetCurrentPoint\(track\)\.Position\.X - selectOrigin\.X\) < 3\) return;", Body("Scrub"));
        Assert.Matches(@"if \(extendPending && model is not null\) \{ extendPending = false; model\.ExtendTimelineSelection", Body("ScrubReleased"));
        // Ctrl+N would open a window in the middle of a Ctrl+drag.
        Assert.Matches(@"slider\.ProcessKeyboardAccelerators \+= \(_, args\) => \{ if \(\(selecting \|\| ranging\) && args\.Key == VirtualKey\.N\) args\.Handled = true; \};", source);
        var design = File.ReadAllText(Path.Combine(root, "doc/design.md"));
        Assert.DoesNotContain("Ctrl+drag with Snap off, or Alt or N held", design);
    }

    [Fact]
    public void SeveralRecordingsKeepTheRangeInTheRecordingItBeganIn()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/recordings/two-recordings.voxclip"));
        var model = new EditorViewModel(project with { Edits = project.Edits with { Clips = [], ActiveClipId = null } });
        var clock = Assert.IsType<ProjectClock>(model.RecordingClock);
        var second = clock.Regions[^1];
        var offset = (double)second.OffsetSamples / clock.SampleRate;
        Assert.True(model.SetExactRange(offset + 0.2, offset - 2, offset + 0.2));
        var range = Assert.IsType<TimelineExactRange>(model.ExactRange);
        Assert.Equal(second.Key, range.Recording);
        Assert.Equal(0, range.Start);
        Assert.Equal(0.2, range.End, 6);
        var source = Assert.IsType<TimeRange>(model.ExactRangeSource);
        Assert.Equal(offset, source.Start, 6);
        Assert.Equal(offset + 0.2, source.End, 6);
    }

    [Fact]
    public void BandAndWashDrawTheRangeNotTheWords()
    {
        var model = Model();
        model.SetExactRange(12.84, 17.06, 12.84);
        var scene = new TimelineScene();
        scene.Build(model, TimelineLayout.Plan(model), new(10, 20), [], 1000, false);
        var band = Assert.Single(scene.Layers[8]);
        Assert.Equal((385.0 / 30 - 10) * 100, band.X, 6);
        Assert.Equal(127.0 / 30 * 100, band.Width, 6);
        model.ClearExactRange();
        model.Select(model.Index("t13")); model.Select(model.Index("t16"), true);
        scene.Build(model, TimelineLayout.Plan(model), new(10, 20), [], 1000, false);
        Assert.Equal(300, Assert.Single(scene.Layers[8]).X, 6);
    }

    // MARK: I and O

    [Fact]
    public void IAndOOnTheTimelineSetTheRangeAtThePlayheadAndTheTranscriptKeepsClipEdges()
    {
        var model = Model();
        Assert.Equal(TimelineShortcut.RangeIn, TimelineKeys.Resolve('I', false, false, false));
        Assert.Equal(TimelineShortcut.RangeOut, TimelineKeys.Resolve('O', false, false, false));
        var clip = model.ActiveClip;
        model.SourceTime = 12.34;
        Assert.True(model.SetExactRangeEdge(true));
        var range = Assert.IsType<TimelineExactRange>(model.ExactRange);
        var scopeEnd = EditingAlgorithms.ClipTimes(model.Words, model.Index("t10"), model.Index("t29")).End;
        Assert.Equal(370, range.Start * 30, 6);
        Assert.Equal(Math.Round(scopeEnd * 30, MidpointRounding.AwayFromZero), range.End * 30, 6);
        model.SourceTime = 15.5;
        Assert.True(model.SetExactRangeEdge(false));
        range = Assert.IsType<TimelineExactRange>(model.ExactRange);
        Assert.Equal(15.5, range.End, 6);
        Assert.Equal(370, range.Start * 30, 6);
        Assert.Equal(clip, model.ActiveClip);
        Assert.False(model.CanUndo);
        // In the transcript I still sets the clip's start at the caret.
        model.Select(model.Index("t12"));
        Assert.Null(model.ExactRange);
        model.SetClipEdgeAtCaret(true);
        Assert.Equal("t12", model.ActiveClip?.StartWordId);
    }

    // MARK: Range actions

    [Fact]
    public void RangeActionsPlayTheRangeAndAddATitleTrimAnItemOrMakeAClipAsOrdinaryUndoSteps()
    {
        var model = Model();
        const string hint = EditorViewModel.TimelineRangeHint;
        Assert.Equal(hint, model.TimelinePlayRangeReason);
        Assert.Equal(hint, model.TimelineAddTitleReason);
        Assert.Equal(hint, model.TimelineTrimToRangeReason);
        Assert.Equal(hint, model.TimelineMakeClipReason);
        Assert.Equal(hint, model.TimelineSelectionStatus);
        model.SetExactRange(12.4, 17.06, 12.4);
        var outPoint = 512.0 / 30;
        // Play range asks the page to play from In and stop at Out.
        TimeRange? played = null;
        model.TimelineRangePlayRequested += (_, range) => played = range;
        Assert.True(model.PlayTimelineRange());
        Assert.Equal(12.4, played!.Value.Start, 6);
        Assert.Equal(outPoint, played.Value.End, 6);
        // Cut range is shown but cuts nothing yet.
        Assert.False(model.TimelineCanCut);
        string? announced = null;
        model.Announcement += (_, text) => announced = text;
        model.CutSelection();
        Assert.Equal(EditorViewModel.TimelineCutRangeReason, announced);
        Assert.Equal(["t14", "t15"], model.State!.CutWordIds.Order());
        Assert.False(model.CanUndo);
        Assert.NotNull(model.TimelineAskClaudeReason);
        // Add title over the range, one "Add title" step.
        var firstId = Assert.IsType<string>(model.AddTimelineTitleOverRange());
        var title = Effect(model, firstId);
        Assert.Equal(("title", "Title", "clip-1"), (title.Kind, title.Text, title.ClipId));
        Assert.Equal(12.4, title.Start, 6);
        Assert.Equal(outPoint, title.End, 6);
        Assert.Equal("Add title", model.UndoActionName);
        // Trim item to range: a second title over 18.5–20.5, trimmed to 19–20 s in one "Trim to range" step.
        model.SetExactRange(18.5, 20.5, 18.5);
        var secondId = Assert.IsType<string>(model.AddTimelineTitleOverRange());
        model.SetExactRange(19, 20, 19);
        Assert.Equal(new TimelineItemId(TimelineItemType.Effect, secondId), model.TimelineRangeTrimTarget?.Id);
        Assert.Null(model.TimelineTrimToRangeReason);
        Assert.True(model.TrimTimelineItemToRange());
        var trimmed = Effect(model, secondId);
        Assert.Equal(19, trimmed.Start, 3);
        Assert.Equal(20, trimmed.End, 3);
        Assert.Equal("Trim to range", model.UndoActionName);
        Assert.Equal("The title already fits inside the range.", model.TimelineTrimToRangeReason);
        model.Undo();
        Assert.Equal((18.5, 20.5), (Effect(model, secondId).Start, Effect(model, secondId).End));
        Assert.Equal("Add title", model.UndoActionName);
        // Make clip: In snaps to word 12's start and Out to word 16's end.
        model.SetExactRange(12.4, 17.06, 12.4);
        Assert.Null(model.TimelineMakeClipReason);
        Assert.NotNull(model.MakeClip());
        Assert.Equal(("t12", "t16"), (model.ActiveClip?.StartWordId, model.ActiveClip?.EndWordId));
        Assert.Equal("Make clip", model.UndoActionName);
        Assert.Null(model.ExactRange);
    }

    [Fact]
    public void ARangeInAGapMakesAClipOnlyFromAWordItReachesAndCannotTrimWithoutAnItem()
    {
        var model = Model();
        model.SetExactRange(12.84, 13.02, 12.84);
        Assert.False(model.HasSelection);
        // The range reaches into word 13. In snaps to word 13's start and Out to word 12's end; crossed, the clip is the word
        // nearest the middle.
        Assert.Equal((model.Index("t13"), model.Index("t13")), model.TimelineRangeClipWords);
        Assert.Null(model.TimelineMakeClipReason);
        Assert.Equal("Put the range over a title, picture, sound or song to trim it.", model.TimelineTrimToRangeReason);
        Assert.Null(model.TimelinePlayRangeReason);
        Assert.Null(model.TimelineAddTitleReason);
        // A range wholly inside the pause covers no word, so Make clip says why instead of reaching for a neighbour.
        model.SetExactRange(12.82, 12.98, 12.82);
        Assert.Null(model.TimelineRangeClipWords);
        Assert.Equal("There are no words in this range to make a clip from.", model.TimelineMakeClipReason);
        var clips = model.Project.Edits.Clips.Count;
        Assert.Null(model.MakeClip());
        Assert.Equal(clips, model.Project.Edits.Clips.Count);
        Assert.Null(model.TimelinePlayRangeReason);
    }

    [Fact]
    public void MakeClipFromARangeSnapsOnlyToWordsTheRangeOverlaps()
    {
        // Word 13 is short (12.85–12.95), just after word 12's tail. A range over that tail makes a clip of word 12, never of the
        // short word beside it that the range doesn't reach.
        var model = Model(("t13", 12.85, 12.95));
        model.SetExactRange(12.6, 12.8, 12.6);
        Assert.False(model.HasSelection);
        Assert.Equal((model.Index("t12"), model.Index("t12")), model.TimelineRangeClipWords);
        Assert.Null(model.TimelineMakeClipReason);
        Assert.NotNull(model.MakeClip());
        Assert.Equal(("t12", "t12"), (model.ActiveClip?.StartWordId, model.ActiveClip?.EndWordId));
    }

    [Fact]
    public void EveryMakeClipEntryPointGatesOnTheTimelineReason()
    {
        // A range that reaches a word without holding it whole selects no word, yet makes a clip: the ClipBar, the command palette
        // and the edit bar all ask TimelineMakeClipReason, never HasSelection.
        var pages = string.Concat(Directory.EnumerateFiles(Path.Combine(AppRoot, "Pages"), "EditorPage*.cs").Select(File.ReadAllText));
        Assert.DoesNotMatch(@"MakeClipCommand\.IsEnabled\s*=[^;]*HasSelection", pages);
        Assert.Equal(2, Regex.Matches(pages, @"MakeClipCommand\.IsEnabled\s*=[^;]*ViewModel\.TimelineMakeClipReason is null").Count);
        Assert.Matches(@"Command\(""clip\.make"",[^\n]*ViewModel\.TimelineMakeClipReason is null", pages);
        Assert.DoesNotMatch(@"Command\(""clip\.make"",[^\n]*HasSelection", pages);
        Assert.Contains("model => model.TimelineMakeClipReason is null", EditBarSource, StringComparison.Ordinal);
    }

    [Fact]
    public void PlayRangeStopsAtOutOnTheEditedClockOfTheTimelineItSeeksOn()
    {
        // A story that plays words 20–24, then words 10–12: after part 1 the source clock runs back before Out, so a stop on the
        // source clock never comes.
        var model = Model();
        var story = model.Project.Edits.Clips[0] with { StartWordId = "t10", EndWordId = "t24", Parts = [new("p1", "t20", "t24"), new("p2", "t10", "t12")] };
        model = new(model.Project with { Edits = model.Project.Edits with { Clips = [story], CutWordIds = [] } });
        Assert.True(model.IsStoryClip);
        model.SetExactRange(23, 40, 23);
        var range = Assert.IsType<TimeRange>(model.TimelineActionRange);
        var timeline = new RenderTimeline.Legacy(TimelineLayout.Plan(model));
        var play = Assert.IsType<(double Start, double Stop)>(EditorViewModel.TimelineRangePlayback(timeline, range));
        Assert.Equal(timeline.MapTime(range.Start), play.Start, 9);
        Assert.Equal(timeline.MapEndTime(range.End), play.Stop, 9);
        Assert.True(play.Stop > play.Start);
        Assert.True(play.Stop <= timeline.MapTime(model.Words[model.Index("t10")].Start) + 1e-9);
        // The page seeks and stops on that one render timeline, on the edited clock.
        var page = File.ReadAllText(Path.Combine(AppRoot, "Pages", "EditorPage.xaml.cs"));
        var start = page.IndexOf("private async Task PlayTimelineRangeAsync(", StringComparison.Ordinal);
        var body = page[start..page.IndexOf("    private ", start + 1, StringComparison.Ordinal)];
        Assert.Contains("EditorViewModel.TimelineRangePlayback(snapshot.Timeline, range)", body, StringComparison.Ordinal);
        Assert.Contains("previewStop = (play.Stop, true);", body, StringComparison.Ordinal);
        Assert.DoesNotContain("range.End", body, StringComparison.Ordinal);
    }

    [Fact]
    public void ADisabledCutSelectionSaysWhy()
    {
        var model = Model();
        Assert.Equal(EditorViewModel.TimelineRangeHint, model.TimelineCutReason);
        // Word 14 is already cut.
        model.Select(model.Index("t14"));
        Assert.Equal(EditorViewModel.TimelineAlreadyCutReason, model.TimelineCutReason);
        Assert.False(model.TimelineCanCut);
        model.Select(model.Index("t16"));
        Assert.Null(model.TimelineCutReason);
        Assert.True(model.TimelineCanCut);
        model.SetExactRange(12.4, 17.06, 12.4);
        Assert.Equal(EditorViewModel.TimelineCutRangeReason, model.TimelineCutReason);
        Assert.False(model.TimelineCanCut);
        var readOnly = Model();
        readOnly.Select(readOnly.Index("t16"));
        readOnly.Busy = true;
        Assert.NotNull(readOnly.TimelineCutReason);
        Assert.False(readOnly.TimelineCanCut);
        // The edit bar's disabled Cut selection shows that reason as its tooltip and accessibility help.
        Assert.Contains("model => model.TimelineCutReason is null", EditBarSource, StringComparison.Ordinal);
        Assert.Contains("model => model.TimelineCutReason ?? CutHelp", EditBarSource, StringComparison.Ordinal);
    }

    // MARK: Word ticks

    [Fact]
    public void A1TicksWordEdgesOfTheScopeAndOnEditedOnlyTheWordsThatPlay()
    {
        var model = Model();
        static double Same(double time) => time;
        var (starts, ends) = model.TimelineWordEdges(12.5, 18.3, Same, Same, false);
        Assert.Equal([13, 14, 15, 16, 17, 18], starts);
        Assert.Equal(12.8, ends[0], 9);
        Assert.Equal(6, ends.Count);
        var plan = TimelineLayout.Plan(model);
        var edited = model.TimelineWordEdges(plan.MapTime(12.5), plan.MapTime(18.3), plan.MapTime, plan.SourceTime, true).Starts;
        Assert.Contains(plan.MapTime(16), edited);
        Assert.DoesNotContain(edited, time => Math.Abs(time - plan.MapTime(14)) < 1e-9);
        // Words outside the open clip get no ticks.
        Assert.Empty(model.TimelineWordEdges(0, 9.9, Same, Same, false).Starts);
    }

    private static string AppRoot => Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps", "windows", "src", "VoxClip.App");
    private static string EditBarSource => File.ReadAllText(Path.Combine(AppRoot, "Controls", "TimelineView.EditBar.cs"));

    private static ClipEffect Effect(EditorViewModel model, string id) =>
        ClipEffect.Parse(model.Project.ClipEffects.Single(effect => effect.GetProperty("id").GetString() == id));

    private static Project Fixture() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip"));

    /// <summary>A 60-second, 30 fps take of 0.8-second words a second apart, with Clip 1 on words 10–29 and words 14 and 15 cut;
    /// <paramref name="timing"/> moves the words it names.</summary>
    private static EditorViewModel Model(params (string Id, double Start, double End)[] timing)
    {
        var project = Fixture();
        var words = Enumerable.Range(0, 60).Select(index => project.Transcript!.Words[0] with
            { Id = $"t{index}", Text = index % 10 == 9 ? "word." : "word", Start = index, End = index + 0.8, RawStart = index, RawEnd = index + 0.8 })
            .Select(word => timing.FirstOrDefault(entry => entry.Id == word.Id) is { Id: not null } moved
                ? word with { Start = moved.Start, End = moved.End, RawStart = moved.Start, RawEnd = moved.End } : word).ToArray();
        var source = project.Media.Source with { DurationSeconds = 60, Video = project.Media.Source.Video! with { FrameRate = 30 } };
        var clip = new ClipRange("clip-1", "t10", "t29", null, ClipOrigin.Manual, null, null, true);
        return new(project with
        {
            Media = project.Media with { Source = source },
            Transcript = project.Transcript! with { Words = words, DurationSeconds = 60 },
            Edits = project.Edits with { CutWordIds = ["t14", "t15"], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [clip], ActiveClipId = clip.Id },
            Ai = project.Ai with { Results = [] }
        });
    }
}
#endif
