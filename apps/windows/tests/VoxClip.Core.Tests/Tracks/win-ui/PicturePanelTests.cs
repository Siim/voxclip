#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The Picture tab on Windows (looks spec §3.7, mockup frame 4): the twin of the Mac Picture panel's model. Looks, Amount,
/// Compare, the Fine-tune groups, their resets, Auto, Claude's pick and every disabled reason, on the 80-word editor with clip c1.
/// Stills and the measurement are stubs: nothing is decoded or sent.</summary>
public sealed class PicturePanelTests
{
    private static readonly ClipLookLibrary Looks = ClipLookLibrary.Load(MakeItPostableTests.Root);

    private sealed class Measurement
    {
        internal TaskCompletionSource<ClipColorFix?> Result { get; } = new();
        internal List<string> Clips { get; } = [];
        internal bool? Remembered { get; private set; }
        internal PicturePanelServices Services(bool open = false) => new(Looks)
        {
            Measure = (clip, ct) => { Clips.Add(clip); return Result.Task.WaitAsync(ct); },
            FineTuneOpen = open,
            RememberFineTune = value => Remembered = value,
        };
    }

    private static (EditorViewModel Editor, PicturePanelModel Picture, Measurement Measure) Open(bool open = false)
    {
        var editor = MakeItPostableTests.Editor();
        var measure = new Measurement();
        editor.Picture.Services = measure.Services(open);
        Assert.True(editor.SetScope("c1"));
        return (editor, editor.Picture, measure);
    }

    private static PictureSlider Slider(PicturePanelModel picture, PictureControl control) =>
        picture.Groups.SelectMany(group => group.Sliders).Single(slider => slider.Control == control);

    private static PictureGroup Group(PicturePanelModel picture, PictureGroupId id) => picture.Groups.Single(group => group.Id == id);

    private static List<string?> Undos(EditorViewModel editor)
    {
        var names = new List<string?>();
        while (editor.CanUndo) { names.Add(editor.UndoActionName); editor.Undo(); }
        return names;
    }

    [Fact]
    public void TheTabIsForAPictureAndTheSurfaceSaysWhyItCantChangeTheLook()
    {
        var editor = MakeItPostableTests.Editor();
        editor.Picture.Services = new(Looks);
        Assert.True(editor.Picture.IsAvailable);
        Assert.Equal("Open a clip to choose its look.", editor.Picture.Blocked);
        Assert.True(editor.SetScope("c1"));
        Assert.Null(editor.Picture.Blocked);
        editor.SetMediaUnavailable(true);
        Assert.Equal("Locate the video to change the look.", editor.Picture.Blocked);
        Assert.Equal("Locate the video to change the look.", editor.Picture.AmountReason);
        Assert.False(editor.Picture.Apply("warm") is PictureApplyOutcome.Applied);
        var audio = MakeItPostableTests.Editor();
        var project = audio.Project with { Media = audio.Project.Media with { Source = audio.Project.Media.Source with { Video = null } } };
        var listened = new EditorViewModel(project);
        listened.Picture.Services = new(Looks);
        Assert.False(listened.Picture.IsAvailable);
        Assert.True(listened.SetScope("c1"));
        Assert.Equal("This recording has no picture to color.", listened.Picture.Blocked);
    }

    [Fact]
    public void SuggestedHoldsAsFilmedClaudesPicksTheCurrentLookAndTheStarters()
    {
        var (editor, picture, _) = Open();
        Assert.Equal(PicturePanelModel.Suggested, picture.Category);
        Assert.Equal(["Suggested", "All", "Natural", "Bright", "Warm", "Film", "Cinematic", "B&W"], picture.Chips.Select(chip => chip.Label));
        Assert.Equal(["original", "naturalBoost", "softSkin", "warm", "goldenHour", "warmPrint", "softBW", "cleanPop"], picture.Tiles.Select(tile => tile.Look.Id));
        Assert.Equal(PictureApplyOutcome.Applied, picture.Apply("moody"));
        picture.NoteClaudePick("c1", new("tealAmber", 70, "Stakes in the story", ["matteFilm", "bw"]));
        Assert.Equal(["original", "tealAmber", "matteFilm", "bw", "moody", "naturalBoost", "softSkin", "warm"], picture.Tiles.Select(tile => tile.Look.Id));
        Assert.Equal([false, true, true, true, false, false, false, false], picture.Tiles.Select(tile => tile.Claude));
        Assert.Equal("Claude's pick", picture.Tiles[1].Status);
        Assert.Equal("Claude's alternative", picture.Tiles[2].Status);
        var counts = picture.Chips.Skip(1).Select(chip => { picture.SelectCategory(chip.Id); return picture.Tiles.Count; }).ToArray();
        Assert.Equal([24, 6, 4, 3, 5, 3, 3], counts);
        picture.SelectCategory("film");
        Assert.Equal(("Looks, Film", "5 looks"), (picture.TilesName, picture.TilesStatus));
        Assert.Equal("Warm Print, Film look", picture.Tiles.Single(tile => tile.Look.Id == "warmPrint").Name);
        Assert.True(picture.Chips.Single(chip => chip.Id == "film").Selected);
        // The chosen chip is view state: no undo step.
        Assert.Equal(["Change look"], Undos(editor));
    }

    /// <summary>Looks spec §3.0's reference task: Warm Print, 70%, vibrance +20, highlights −15, four undo steps, and the stored
    /// grade of §8.1.</summary>
    [Fact]
    public void TheReferenceTaskTakesFourStepsAndStoresTheExpandedGrade()
    {
        var (editor, picture, _) = Open();
        var announced = new List<string>();
        picture.Announced += (_, text) => announced.Add(text);
        Assert.Equal(PictureApplyOutcome.Applied, picture.Apply("warmPrint"));
        Assert.Equal(("Warm Print", "Change look"), (picture.LookText, editor.UndoActionName));
        // The applied, unedited tile again moves focus to Amount and changes nothing.
        Assert.Equal(PictureApplyOutcome.FocusAmount, picture.Apply("warmPrint"));
        Assert.True(picture.SetAmount(70));
        Assert.False(picture.SetAmount(70));
        Assert.Equal(("Warm Print · 70%", "Change look amount"), (picture.LookText, editor.UndoActionName));
        Assert.Equal(("70%", "70 percent"), (picture.AmountText, picture.AmountSpoken));
        Assert.Equal("Selected, amount 70 percent", picture.Tiles.Single(tile => tile.Look.Id == "warmPrint").Status);
        Assert.False(picture.FineTuneOpen);
        Assert.True(picture.SetValue(PictureControl.Vibrance, 20));
        Assert.Equal("Change vibrance", editor.UndoActionName);
        Assert.Equal("Warm Print, edited · 70%", picture.LookText);
        Assert.True(picture.FineTuneOpen);
        var highlights = Slider(picture, PictureControl.Highlights);
        Assert.Equal((-12, -12, "Warm Print's value: −12"), (highlights.Value, highlights.LookValue, highlights.Help));
        Assert.True(picture.SetValue(PictureControl.Highlights, -15));
        Assert.Equal(("−15", "minus 15"), (Slider(picture, PictureControl.Highlights).ValueText, Slider(picture, PictureControl.Highlights).Spoken));
        var tile = picture.Tiles.Single(item => item.Look.Id == "warmPrint");
        Assert.Equal((true, true, "Selected, edited", "Warm Print, edited"), (tile.Applied, tile.Edited, tile.Status, tile.Label(highContrast: true)));
        Assert.Equal("Warm Print", tile.Label(highContrast: false));
        Assert.Equal(["Look Warm Print", "Amount 70 percent", "Vibrance plus 20", "Highlights minus 15"], announced);
        var controls = ClipControlsProject.Controls("c1", editor.Project)!;
        Assert.Equal((ClipLook.Original, new ClipColorAdjustments(0, 0, -10, 26)), (controls.Look, controls.ColorAdjustments));
        var grade = controls.ColorGrade!;
        Assert.Equal(("warmPrint", 70, -15, 20, 20, 0, 20), (grade.Preset, grade.Amount, grade.Highlights, grade.Vibrance, grade.Fade, grade.Vignette, grade.Grain));
        Assert.Equal(new ClipCurveChannel(0, 245, 500, 760, 965), grade.Curve!.Master);
        Assert.Equal(new ClipSplitTone(200, 10, 38, 30, 0), grade.SplitTone);
        Assert.Equal(8, editor.Project.SchemaVersion);
        // Clicking the edited applied tile puts the look's values back and keeps Amount.
        Assert.Equal(PictureApplyOutcome.Applied, picture.Apply("warmPrint"));
        Assert.Equal("Warm Print · 70%", picture.LookText);
        Assert.Equal(["Change look", "Change highlights", "Change vibrance", "Change look amount", "Change look"], Undos(editor));
    }

    [Fact]
    public void AsFilmedHasNothingToBlendCompareOrClearAndAFixStaysAsFilmed()
    {
        var (editor, picture, _) = Open();
        Assert.Equal("As filmed", picture.LookText);
        Assert.Equal("As filmed has no look to blend", picture.AmountReason);
        Assert.Equal("Nothing to compare: the clip is as filmed", picture.CompareReason);
        Assert.Equal("Nothing to clear", picture.ClearReason);
        Assert.Null(picture.BackToLabel);
        Assert.Null(picture.ToningText);
        Assert.False(picture.BeginCompare());
        Assert.Equal("0.00 EV", Slider(picture, PictureControl.Exposure).ValueText);
        Assert.True(picture.SetValue(PictureControl.Exposure, 20));
        Assert.Equal(("+0.40 EV", "plus 0.4"), (Slider(picture, PictureControl.Exposure).ValueText, Slider(picture, PictureControl.Exposure).Spoken));
        Assert.Equal(("As filmed", "Change exposure"), (picture.LookText, editor.UndoActionName));
        Assert.Equal("As filmed has no look to blend", picture.AmountReason);
        Assert.Null(picture.CompareReason);
        Assert.Null(picture.ClearReason);
        var grade = ClipControlsProject.Controls("c1", editor.Project)!.ColorGrade!;
        Assert.Equal((null, 20, 100), (grade.Preset, grade.Exposure, grade.Amount));
        // Another look keeps the Fix; the As filmed tile goes back without it changing.
        Assert.Equal(PictureApplyOutcome.Applied, picture.Apply("goldenHour"));
        Assert.Equal(20, Slider(picture, PictureControl.Exposure).Value);
        Assert.Equal(PictureApplyOutcome.Applied, picture.Apply("original"));
        Assert.Equal(("As filmed", 20), (picture.LookText, Slider(picture, PictureControl.Exposure).Value));
        Assert.Equal(PictureApplyOutcome.None, picture.Apply("original"));
        Assert.Equal(["Change look", "Change look", "Change exposure"], Undos(editor));
    }

    [Fact]
    public void BlackAndWhiteLooksDisableVibranceAndSaturationOnly()
    {
        var (_, picture, _) = Open();
        Assert.Equal(PictureApplyOutcome.Applied, picture.Apply("softBW"));
        Assert.Equal("No effect on black and white", Slider(picture, PictureControl.Vibrance).Reason);
        Assert.Equal("No effect on black and white", Slider(picture, PictureControl.Saturation).Reason);
        Assert.False(picture.SetValue(PictureControl.Vibrance, 30));
        foreach (var control in new[] { PictureControl.Warmth, PictureControl.Temperature, PictureControl.Tint, PictureControl.Contrast })
            Assert.Null(Slider(picture, control).Reason);
        Assert.Equal(("Soft B&W", "Soft B&W's value: −15"), (picture.LookText, Slider(picture, PictureControl.Contrast).Help));
    }

    [Fact]
    public void ResetsBackToRemoveToningAndClearEachTakeOneNamedStep()
    {
        var (editor, picture, _) = Open();
        picture.Apply("warmPrint");
        Assert.Equal(("Back to Warm Print", "Matches Warm Print"), (picture.BackToLabel, picture.BackToReason));
        Assert.Equal(["Nothing to reset"], picture.Groups.Select(group => group.ResetReason).Distinct());
        picture.SetValue(PictureControl.Contrast, 10);
        picture.SetValue(PictureControl.Vibrance, 20);
        picture.SetValue(PictureControl.Grain, 5);
        picture.SetValue(PictureControl.Exposure, 25);
        Assert.Null(picture.BackToReason);
        Assert.Equal("Toning from Warm Print", picture.ToningText);
        Assert.True(picture.ResetGroup(PictureGroupId.Light));
        Assert.Equal((0, "Nothing to reset"), (Slider(picture, PictureControl.Contrast).Value, Group(picture, PictureGroupId.Light).ResetReason));
        Assert.True(picture.ResetGroup(PictureGroupId.Effects));
        Assert.Equal(20, Slider(picture, PictureControl.Grain).Value);
        Assert.True(picture.BackTo());
        Assert.Equal((0, 25, "Warm Print"), (Slider(picture, PictureControl.Vibrance).Value, Slider(picture, PictureControl.Exposure).Value, picture.LookText));
        Assert.True(picture.RemoveToning());
        Assert.Null(picture.ToningText);
        Assert.Equal("Warm Print, edited", picture.LookText);
        Assert.True(picture.ResetGroup(PictureGroupId.Fix));
        Assert.Equal((0, "Nothing to reset"), (Slider(picture, PictureControl.Exposure).Value, Group(picture, PictureGroupId.Fix).ResetReason));
        Assert.True(picture.Clear());
        Assert.Equal(("As filmed", "Nothing to clear"), (picture.LookText, picture.ClearReason));
        Assert.Null(ClipControlsProject.Controls("c1", editor.Project)!.ColorGrade);
        Assert.Equal(["Clear color", "Reset fix", "Remove toning", "Back to Warm Print", "Reset effects", "Reset light", "Change exposure", "Change grain",
            "Change vibrance", "Change contrast", "Change look"], Undos(editor));
    }

    [Fact]
    public void SlidersStepTypeAndGoBackToTheLooksValue()
    {
        var (editor, picture, _) = Open();
        picture.Apply("goldenHour");
        Assert.Equal((25, 25), (Slider(picture, PictureControl.Vibrance).Value, Slider(picture, PictureControl.Vibrance).LookValue));
        Assert.Equal(("+25", "plus 25"), (Slider(picture, PictureControl.Vibrance).ValueText, Slider(picture, PictureControl.Vibrance).Spoken));
        Assert.Equal("20", Slider(picture, PictureControl.Vignette).ValueText);
        Assert.Equal((0, 100), (Slider(picture, PictureControl.Fade).Minimum, Slider(picture, PictureControl.Fade).Maximum));
        Assert.True(picture.SetValue(PictureControl.Vibrance, 140));
        Assert.Equal(100, Slider(picture, PictureControl.Vibrance).Value);
        Assert.True(picture.ResetValue(PictureControl.Vibrance));
        Assert.Equal(25, Slider(picture, PictureControl.Vibrance).Value);
        Assert.False(picture.ResetValue(PictureControl.Vibrance));
        Assert.Equal(20, PicturePanelModel.Parse(PictureControl.Vibrance, "+20"));
        Assert.Equal(-15, PicturePanelModel.Parse(PictureControl.Highlights, "−15"));
        Assert.Equal(-15, PicturePanelModel.Parse(PictureControl.Highlights, "-15"));
        Assert.Equal(20, PicturePanelModel.Parse(PictureControl.Exposure, "+0.40 EV"));
        Assert.Equal(-25, PicturePanelModel.Parse(PictureControl.Exposure, "-0.5"));
        Assert.Null(PicturePanelModel.Parse(PictureControl.Fade, "lots"));
        Assert.Equal(70, PicturePanelModel.ParseAmount("70%"));
        Assert.Null(PicturePanelModel.ParseAmount("half"));
        Assert.Equal(["Change vibrance", "Change vibrance", "Change look"], Undos(editor));
    }

    [Fact]
    public async Task AutoSetsTheMeasuredFixAsOneStepAndSaysWhyWhenItCant()
    {
        var (editor, picture, measure) = Open();
        var announced = new List<string>();
        picture.Announced += (_, text) => announced.Add(text);
        picture.Opened();
        Assert.Equal(["c1"], measure.Clips);
        Assert.Equal("Measuring the picture…", picture.AutoReason);
        Assert.False(picture.Auto());
        measure.Result.SetResult(new ClipColorFix(20, -18, 0));
        await picture.Measuring;
        Assert.Null(picture.AutoReason);
        Assert.True(picture.Auto());
        Assert.Equal(("Fix light and color", "Fix matches the measurement"), (editor.UndoActionName, picture.AutoReason));
        Assert.Equal(["Fix light and color: exposure plus 0.4, temperature minus 18"], announced);
        Assert.Equal((20, -18), (Slider(picture, PictureControl.Exposure).Value, Slider(picture, PictureControl.Temperature).Value));
        picture.Opened();
        Assert.Equal(["c1"], measure.Clips);

        var (_, even, evenMeasure) = Open();
        even.Opened();
        evenMeasure.Result.SetResult(new ClipColorFix(0, 0, 0));
        await even.Measuring;
        Assert.Equal("The light and color already look even", even.AutoReason);
        var (_, failed, failedMeasure) = Open();
        failed.Opened();
        failedMeasure.Result.SetResult(null);
        await failed.Measuring;
        Assert.Equal("VoxClip couldn't read this video's frames", failed.AutoReason);
    }

    /// <summary>A measurement that comes back empty during playback (no frame pass, so the paused frame is needed) or with the source
    /// gone is tried again at the next paused, readable render; only an empty result then reads as a failure.</summary>
    [Fact]
    public async Task AutoMeasuresAgainWhenItCameBackEmptyDuringPlaybackOrOffline()
    {
        var editor = MakeItPostableTests.Editor();
        var calls = 0;
        var results = new Queue<ClipColorFix?>([null, null, new ClipColorFix(20, 0, 0), null]);
        editor.Picture.Services = new(Looks)
        {
            Measure = (_, _) => { if (++calls == 2) editor.SetMediaUnavailable(true); return Task.FromResult(results.Dequeue()); },
        };
        Assert.True(editor.SetScope("c1"));
        var picture = editor.Picture;
        picture.SetPlaying(true);
        picture.Opened();
        await picture.Measuring;
        Assert.Equal((1, "Measuring the picture…"), (calls, picture.AutoReason));
        // Still playing: renders don't measure again.
        picture.Opened();
        Assert.Equal(1, calls);
        picture.SetPlaying(false);
        picture.Opened();
        await picture.Measuring;
        Assert.Equal(2, calls);
        Assert.Equal("Locate the video to change the look.", picture.AutoReason);
        picture.Opened();
        Assert.Equal(2, calls);
        editor.SetMediaUnavailable(false);
        Assert.Equal("Measuring the picture…", picture.AutoReason);
        picture.Opened();
        await picture.Measuring;
        Assert.Equal((3, null), (calls, picture.AutoReason));
        Assert.True(picture.Auto());
    }

    [Fact]
    public void HoverAndComparePreviewOnThePausedViewerWithoutAStep()
    {
        var (editor, picture, _) = Open();
        picture.SetValue(PictureControl.Exposure, 20);
        picture.Apply("warmPrint");
        var changes = 0;
        picture.PreviewChanged += (_, _) => changes++;
        Assert.True(picture.PreviewLook("goldenHour"));
        Assert.Equal("Preview · Golden Hour", picture.Preview!.Badge);
        Assert.Equal(new ClipLookMatch(Looks.Look("goldenHour")!, false), Looks.Match(picture.Preview.Colour));
        Assert.Equal(20, picture.Preview.Colour.ColorGrade!.Exposure);
        picture.EndPreview();
        Assert.Null(picture.Preview);
        Assert.Equal("Showing Warm Print", picture.CompareStatus);
        Assert.True(picture.BeginCompare());
        Assert.Equal(("As filmed", "Showing as filmed", true), (picture.Preview!.Badge, picture.CompareStatus, picture.Comparing));
        Assert.Equal(new ClipColorState(), ClipColorState.Of(picture.Preview.Colour));
        Assert.False(picture.PreviewLook("moody"));
        picture.EndCompare();
        Assert.Null(picture.Preview);
        // A drag previews its value; the release commits once.
        Assert.True(picture.PreviewValue(PictureControl.Vibrance, 40));
        Assert.Equal(40, picture.Preview!.Colour.ColorGrade!.Vibrance);
        Assert.True(picture.PreviewAmount(30));
        Assert.Equal(30, picture.Preview!.Colour.ColorGrade!.Amount);
        Assert.True(picture.SetAmount(30));
        Assert.Null(picture.Preview);
        picture.SetPlaying(true);
        Assert.Equal("Pause to preview on the viewer", picture.HoverReason);
        Assert.False(picture.PreviewLook("goldenHour"));
        Assert.Null(picture.Preview);
        picture.SetPlaying(false);
        editor.SetMediaUnavailable(true);
        picture.SetStillState(PictureStillState.Offline);
        Assert.Equal("Previews need the source video. Looks still apply when it's back.", picture.PreviewNote);
        Assert.Equal(picture.PreviewNote, picture.CompareReason);
        Assert.False(picture.PreviewLook("goldenHour"));
        editor.SetMediaUnavailable(false);
        picture.SetStillState(PictureStillState.Unreadable);
        Assert.Equal("Showing looks on a sample picture: this frame couldn't be read.", picture.PreviewNote);
        Assert.Null(picture.CompareReason);
        Assert.Equal(["Change look amount", "Change look", "Change exposure"], Undos(editor));
        Assert.True(changes >= 6);
    }

    /// <summary>Looks spec §3.3 and §3.5: one Shift+arrow press is ten points and one undo step, clamped at the end of the range; the
    /// panel handles it before the slider's own one-point step.</summary>
    [Fact]
    public void ShiftArrowsStepTenPointsAsOneUndoStep()
    {
        var (editor, picture, _) = Open();
        picture.Apply("warmPrint");
        var vibrance = Slider(picture, PictureControl.Vibrance).Value;
        Assert.True(picture.StepValue(PictureControl.Vibrance, 10));
        Assert.Equal(vibrance + 10, Slider(picture, PictureControl.Vibrance).Value);
        Assert.True(picture.StepAmount(-10));
        Assert.Equal(90, picture.Amount);
        Assert.True(picture.StepAmount(10));
        Assert.False(picture.StepAmount(10));
        Assert.True(picture.SetValue(PictureControl.Grain, 4));
        Assert.True(picture.StepValue(PictureControl.Grain, -10));
        Assert.Equal(0, Slider(picture, PictureControl.Grain).Value);
        Assert.False(picture.StepValue(PictureControl.Grain, -10));
        Assert.Equal(["Change grain", "Change grain", "Change look amount", "Change look amount", "Change vibrance", "Change look"], Undos(editor));
        var panel = File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps", "windows", "src", "VoxClip.App", "Controls", "PicturePanel.cs"));
        Assert.Contains("amount.PreviewKeyDown +=", panel);
        Assert.Contains("row.Slider.PreviewKeyDown +=", panel);
        Assert.DoesNotContain("AddHandler(KeyDownEvent, new KeyEventHandler((_, args) => SliderKey", panel);
    }

    /// <summary>Looks spec §7.6: the tiles are drawn again when the Fix or the source changes (Auto, a Fix slider, Reset fix, a relink),
    /// never for choosing a look, its amount or a look value.</summary>
    [Fact]
    public async Task TheTilesFollowTheFixAndTheSourceButNotTheLook()
    {
        var (editor, picture, measure) = Open();
        var start = picture.ThumbnailSource;
        Assert.NotNull(start);
        picture.Apply("warmPrint");
        picture.SetAmount(70);
        picture.SetValue(PictureControl.Vibrance, 20);
        Assert.Equal(start, picture.ThumbnailSource);
        picture.SetValue(PictureControl.Exposure, 20);
        var exposed = picture.ThumbnailSource;
        Assert.NotEqual(start, exposed);
        Assert.True(picture.ResetGroup(PictureGroupId.Fix));
        Assert.Equal(start, picture.ThumbnailSource);
        picture.Opened();
        measure.Result.SetResult(new ClipColorFix(10, -6, 0));
        await picture.Measuring;
        Assert.True(picture.Auto());
        Assert.NotEqual(start, picture.ThumbnailSource);
        var fixedUp = picture.ThumbnailSource;
        editor.SetMediaUnavailable(true);
        Assert.NotEqual(fixedUp, picture.ThumbnailSource);
        editor.SetMediaUnavailable(false);
        Assert.Equal(fixedUp, picture.ThumbnailSource);
        Assert.StartsWith("c1|", fixedUp, StringComparison.Ordinal);
    }

    /// <summary>A frame read while the source was offline leaves Offline behind; once the video is relinked, hover, Compare and the
    /// note follow the editor at once, before the tiles read the frame again.</summary>
    [Fact]
    public void PreviewsComeBackWhenTheVideoIsRelinked()
    {
        var (editor, picture, _) = Open();
        picture.Apply("warmPrint");
        editor.SetMediaUnavailable(true);
        picture.SetStillState(PictureStillState.Offline);
        Assert.Equal("Previews need the source video. Looks still apply when it's back.", picture.HoverReason);
        editor.SetMediaUnavailable(false);
        Assert.Equal(PictureStillState.Offline, picture.StillState);
        Assert.Equal((null, null, null), (picture.PreviewNote, picture.CompareReason, picture.HoverReason));
        Assert.True(picture.PreviewLook("goldenHour"));
        Assert.True(picture.BeginCompare());
    }

    /// <summary>Looks spec §3.2: the current look follows As filmed and Claude's looks in Suggested, so choosing a later starter moves its
    /// tile up. The panel keeps each look's item and gives the tile that had focus its focus back.</summary>
    [Fact]
    public void ChoosingAStarterMovesItsTileUpInSuggested()
    {
        var (_, picture, _) = Open();
        Assert.Equal(3, picture.Tiles.ToList().FindIndex(tile => tile.Look.Id == "warm"));
        Assert.Equal(PictureApplyOutcome.Applied, picture.Apply("warm"));
        Assert.Equal(["original", "warm", "naturalBoost", "softSkin", "goldenHour", "warmPrint", "softBW", "cleanPop"], picture.Tiles.Select(tile => tile.Look.Id));
        var panel = File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps", "windows", "src", "VoxClip.App", "Controls", "PicturePanel.cs"));
        Assert.Contains("kept.GetValueOrDefault(tile.Look.Id) ?? NewTile(", panel);
        Assert.Contains("Refocus(again,", panel);
    }

    [Fact]
    public void ClaudesPickStaysFindableAfterAHandChange()
    {
        var (editor, picture, _) = Open();
        Assert.Null(picture.ClaudeLine);
        picture.NoteClaudePick("c1", new("warmPrint", 70, "Warm lamp light suits a travel memory", ["goldenHour", "softBW"], new(0, -12, 0)));
        Assert.Equal(("Claude's pick: Warm Print · 70%", true), (picture.ClaudeLine!.Text, picture.ClaudeLine.CanUse));
        // With the video missing, Use it stays in view, disabled with the reason.
        editor.SetMediaUnavailable(true);
        Assert.Equal((true, false, "Locate the video to change the look."), (picture.ClaudeLine!.ShowsUseIt, picture.ClaudeLine.CanUse, picture.ClaudeLine.UseItReason));
        Assert.False(picture.UseClaudeLook());
        editor.SetMediaUnavailable(false);
        Assert.True(picture.UseClaudeLook());
        Assert.Equal("Use Claude's look", editor.UndoActionName);
        Assert.Equal(("Claude chose Warm Print · 70%", "Warm lamp light suits a travel memory · Fix: temperature −12", false),
            (picture.ClaudeLine!.Text, picture.ClaudeLine.Detail, picture.ClaudeLine.ShowsUseIt));
        Assert.Equal(-12, Slider(picture, PictureControl.Temperature).Value);
        picture.Apply("moody");
        Assert.Equal(("Claude's pick: Warm Print · 70%", true), (picture.ClaudeLine!.Text, picture.ClaudeLine.CanUse));
        Assert.True(picture.UseClaudeLook());
        Assert.Equal("Warm Print · 70%", picture.LookText);
        Assert.False(picture.UseClaudeLook());
    }

    [Fact]
    public async Task MakeItHandsClaudesPickToPictureAndOffersAllLooks()
    {
        var editor = MakeItPostableTests.Editor();
        editor.Picture.Services = new(Looks);
        var stub = new MakeItPostableTests.Stub
        {
            PictureTab = true,
            Series = _ => new([MakeItPostableTests.Plan() with
            {
                ClipLookChoice = new("warmPrint", "Soft window light suits a memory") { Amount = 70, Alternatives = ["goldenHour", "bw"] },
            }], [], []),
        };
        var run = await MakeItPostableTests.RunAsync(editor, stub);
        editor.SetScope("c1");
        Assert.Equal(("Claude chose Warm Print · 70%", "Soft window light suits a memory"), (editor.Picture.ClaudeLine!.Text, editor.Picture.ClaudeLine.Detail));
        Assert.Equal(["original", "warmPrint", "goldenHour", "bw"], editor.Picture.Tiles.Take(4).Select(tile => tile.Look.Id));
        var row = run.Rows.Single(item => item.Change == MakeItChange.Look);
        Assert.Equal(MakeItController.AllLooks, row.Options[^1]);
        string? shown = null;
        editor.MakeItShowPictureRequested += (_, clip) => shown = clip;
        Assert.True(editor.MakeItChoose(MakeItController.AllLooks, row.Id, run));
        Assert.Equal("c1", shown);
    }

    [Fact]
    public void TheFineTuneFoldIsRememberedAndOpensItselfForAnEditedLook()
    {
        var (_, picture, measure) = Open();
        Assert.False(picture.FineTuneOpen);
        picture.ToggleFineTune();
        Assert.Equal((true, true), (picture.FineTuneOpen, measure.Remembered));
        picture.ToggleFineTune();
        Assert.Equal((false, false), (picture.FineTuneOpen, measure.Remembered));
        picture.Apply("warm");
        picture.SetValue(PictureControl.Brightness, 10);
        Assert.Equal("Custom", picture.LookText);
        Assert.True(picture.FineTuneOpen);
        Assert.False(measure.Remembered);
        picture.ToggleFineTune();
        Assert.False(picture.FineTuneOpen);
        var (_, remembered, _) = Open(open: true);
        Assert.True(remembered.FineTuneOpen);
    }

    [Fact]
    public void TheAccessibleNamesFollowTheSpec()
    {
        var (_, picture, _) = Open();
        Assert.Equal(("Look amount", "Blends the look over the clip; the fix stays"), (PicturePanelModel.AmountName, PicturePanelModel.AmountHelp));
        Assert.Equal("Compare with as filmed", PicturePanelModel.CompareName);
        Assert.Equal(("Fix", "stays when you change look", "Fix, stays when you change look"),
            (Group(picture, PictureGroupId.Fix).Heading, Group(picture, PictureGroupId.Fix).Note, Group(picture, PictureGroupId.Fix).SpokenHeading));
        Assert.Equal(["Fix", "Light", "Color", "Effects"], picture.Groups.Select(group => group.Heading));
        Assert.Equal([["Exposure", "Temperature", "Tint"], ["Brightness", "Contrast", "Highlights", "Shadows"], ["Vibrance", "Saturation", "Warmth"], ["Fade", "Vignette", "Grain"]],
            picture.Groups.Select(group => group.Sliders.Select(slider => slider.Label).ToArray()));
        Assert.Equal(["Reset fix", "Reset light", "Reset color", "Reset effects"], picture.Groups.Select(group => group.ResetName));
        Assert.Equal("Natural Boost, Natural look", picture.Tiles.Single(tile => tile.Look.Id == "naturalBoost").Name);
        Assert.Equal(Looks.Look("naturalBoost")!.Line, picture.Tiles.Single(tile => tile.Look.Id == "naturalBoost").Help);
        Assert.Equal("Selected", picture.Tiles.Single(tile => tile.Look.Id == "original").Status);
        Assert.Equal("", picture.Tiles.Single(tile => tile.Look.Id == "warm").Status);
    }

    [Fact]
    public void ATimedLookFromAskClaudeShowsWhereItReplacesThisLookAndCanBeRemoved()
    {
        var editor = MakeItPostableTests.Editor();
        var effect = System.Text.Json.JsonDocument.Parse("""{"id":"fx1","kind":"colourLook","clipId":"c1","start":13,"end":16,"look":"bw"}""").RootElement.Clone();
        var project = ContextDemoProject.UpgradeToV4(editor.Project) with { ClipEffects = [effect] };
        editor = new(project, now: () => new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero));
        editor.Picture.Services = new(Looks);
        Assert.True(editor.SetScope("c1"));
        var timed = Assert.Single(editor.Picture.TimedLooks);
        Assert.Equal("A timed B&W from Ask Claude replaces this look at 0:02–0:05", timed.Text);
        double? played = null;
        editor.Picture.PlayRequested += (_, time) => played = time;
        editor.Picture.PlayTimedLook(timed);
        Assert.Equal(13, played);
        Assert.True(editor.Picture.RemoveTimedLook(timed));
        Assert.Empty(editor.Picture.TimedLooks);
        Assert.Equal("Remove timed look", editor.UndoActionName);
    }

    [Fact]
    public void TheWindowsAppWiresThePictureTabCommandsAndMakeItsChip()
    {
        static string App(string path) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps", "windows", "src", "VoxClip.App", path));
        var column = App("Controls/RightColumn.cs");
        Assert.Contains("Compact(pictureTab, \"Picture\", \"\\uE790\")", column);
        Assert.Contains("PictureTab = true", App("Pages/EditorPage.MakeIt.cs"));
        var page = App("Pages/EditorPage.Picture.cs");
        Assert.Contains("MakeItShowPictureRequested", page);
        Assert.Contains("StillBeforeGradeAsync", page);
        Assert.Contains("StillAsync(shown.Colour", page);
        Assert.Contains("KeyUp=\"EditorKeyUp\"", App("Pages/EditorPage.xaml"));
        var shell = App("Pages/EditorPage.Shell.cs");
        Assert.Contains("\"picture.open\"", shell);
        Assert.Contains("\"picture.compare\"", shell);
        var panel = App("Controls/PicturePanel.cs");
        foreach (var needle in new[] { "ItemsWrapGrid", "HyperlinkButton", "AutomationProperties.SetHelpText", "SetHeadingLevel", "SystemColorHighlightColor", "RaiseNotificationEvent" })
            Assert.True(panel.Contains(needle, StringComparison.Ordinal) || App("Controls/Ui.cs").Contains(needle, StringComparison.Ordinal), needle);
        // The static effects event holds the panel only while it's loaded, so a closed editor isn't kept alive by it.
        Assert.Contains("Loaded += (_, _) => { Subscribe(true);", panel);
        Assert.Contains("Subscribe(false);", panel);
        Assert.Equal(1, panel.Split("Ui.EffectsChanged +=").Length - 1);
        Assert.Contains("Ui.EffectsChanged -= EffectsChanged", panel);
        // The bubbled PointerExited of a tile doesn't end the hover preview; leaving the grid's bounds does.
        Assert.Contains("args.GetCurrentPoint(tiles).Position", panel);
        // Looks spec §3.1 and §3.8: the header is pinned while the panel is at least 300 epx tall; below that it scrolls and the
        // column's header carries the look and Compare.
        Assert.Contains("internal const double PinnedHeaderMinimum = 300;", panel);
        Assert.Contains("SizeChanged += (_, args) => Pin(args.NewSize.Height >= PinnedHeaderMinimum);", panel);
        Assert.Contains("WireCompare(titleCompare);", panel);
        Assert.Contains("titleAccessory.Child = panel.TitleCompare;", column);
        Assert.Contains("picture!.TitleLook", column);
        // A blocked tab's tiles and Use it stay in view, disabled with the reason.
        Assert.Contains("tiles.IsEnabled = model.Blocked is null;", panel);
        Assert.Contains("useIt.IsEnabled = line.CanUse;", panel);
        Assert.DoesNotContain("Flyout", panel);
        Assert.DoesNotContain("ContentDialog", panel);
        Assert.DoesNotContain("App.Services", App("ViewModels/PicturePanelModel.cs"));
    }
}
#endif
