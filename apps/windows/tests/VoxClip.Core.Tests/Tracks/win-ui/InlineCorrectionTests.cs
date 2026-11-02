#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The inline correction field (design §4.2) ends like an inline rename: leaving it any way but Esc keeps valid typed
/// text, and Esc or text that can't be saved keeps the word. Headless: the model and the Play/Pause controller, no window.</summary>
public sealed class InlineCorrectionTests
{
    /// <summary>"So um, today we ship uh the clipper." with w5 already corrected to "shipped".</summary>
    private static EditorViewModel Editor() => new(RoundThreeTests.Fixture());

    private static void Correcting(EditorViewModel model, int index, string text)
    {
        model.Select(index);
        Assert.True(model.BeginCorrection());
        Assert.Equal(model.Words[index].Id, model.CorrectionWordId);
        model.CorrectionText = text;
    }

    /// <summary>Like PreviewEngine.UpdateSnapshotAsync: playback reads as paused while the new plan is swapped in, then resumes.</summary>
    private sealed class Preview
    {
        private TaskCompletionSource? swap;
        internal bool Playing { get; set; }
        internal Task RefreshAsync()
        {
            var resume = Playing;
            Playing = false;
            swap = new TaskCompletionSource();
            return ResumeAsync(swap.Task, resume);
        }
        private async Task ResumeAsync(Task swapped, bool resume) { await swapped; Playing = resume; }
        internal void Settle() => swap?.TrySetResult();
    }

    /// <summary>The page's wiring: every edit refreshes the preview, and Play/Pause waits for that refresh.</summary>
    private static (EditorViewModel Model, Preview Preview, PlaybackToggle Toggle) Playback()
    {
        var model = Editor();
        var preview = new Preview();
        var toggle = new PlaybackToggle();
        model.Changed += (_, _) => toggle.Refreshing(preview.RefreshAsync());
        return (model, preview, toggle);
    }

    // The page dispatches the actual transport command only after the controller returns.
    private static async Task ToggleAsync(EditorViewModel model, Preview preview, PlaybackToggle toggle) =>
        preview.Playing = !await toggle.PausesAsync(model, () => preview.Playing);

    [Fact]
    public void OpeningShowsTheWordsTextAndAnnouncesTheChange()
    {
        var model = Editor();
        var changes = 0;
        model.CorrectionChanged += (_, _) => changes++;
        Assert.False(model.BeginCorrection());
        Assert.Equal(0, changes);
        model.Select(4);
        Assert.True(model.BeginCorrection());
        Assert.Equal(("w5", "shipped", 1), (model.CorrectionWordId, model.CorrectionText, changes));
    }

    [Fact]
    public void SelectingAnotherWordSavesTheOpenCorrection()
    {
        var model = Editor();
        Correcting(model, 2, "Today");
        model.Select(4);
        Assert.Null(model.CorrectionWordId);
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
        Assert.Equal((4, 4), (model.SelectionStart, model.SelectionEnd));
        // Extending the selection ends the correction even when its word remains selected.
        Correcting(model, 2, "TODAY");
        model.Select(3, true);
        Assert.Null(model.CorrectionWordId);
        Assert.Equal("TODAY", model.Project.Edits.Corrections["w3"]);
    }

    [Fact]
    public void ReturnAndFocusLeavingTheFieldSaveTheTypedTextOnTheWordItWasOpenedFor()
    {
        var model = Editor();
        Correcting(model, 2, "  Today ");
        Assert.True(model.EndCorrection());
        Assert.Null(model.CorrectionWordId);
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
        Assert.False(model.EndCorrection());
        model.Undo();
        Assert.False(model.Project.Edits.Corrections.ContainsKey("w3"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("to\nday")]
    [InlineData("to\r\nday")]
    [InlineData("Today\n")]
    [InlineData("\rToday")]
    public void TextThatCannotBeSavedClosesTheFieldAndKeepsTheWord(string text)
    {
        var model = Editor();
        var undo = model.CanUndo;
        Correcting(model, 2, text);
        model.Select(4);
        Assert.Null(model.CorrectionWordId);
        Assert.False(model.Project.Edits.Corrections.ContainsKey("w3"));
        Assert.Equal("today", model.DisplayText(model.Words[2]));
        Assert.Equal(undo, model.CanUndo);
    }

    [Fact]
    public void TextLongerThanTheProjectLimitIsDroppedAndTheLimitItselfIsSaved()
    {
        var longest = new string('a', EditingLimits.MaxCorrectionCodePoints);
        Assert.Equal(longest, EditorViewModel.SavableCorrection(longest));
        Assert.Null(EditorViewModel.SavableCorrection(longest + "a"));
        Assert.Null(EditorViewModel.SavableCorrection("to" + (char)0x2028 + "day"));
        var model = Editor();
        Correcting(model, 2, longest + "a");
        model.EndCorrection();
        Assert.False(model.Project.Edits.Corrections.ContainsKey("w3"));
        Correcting(model, 2, longest);
        model.EndCorrection();
        Assert.Equal(longest, model.Project.Edits.Corrections["w3"]);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void ReturnAndTabKeepUnsavableDraftsOpen(bool advance, bool tooLong)
    {
        var model = Editor();
        var draft = tooLong ? new string('a', EditingLimits.MaxCorrectionCodePoints + 1) : "";
        Correcting(model, 2, draft);
        Assert.False(model.SaveCorrection(advance));
        Assert.Equal("w3", model.CorrectionWordId);
        Assert.Equal(draft, model.CorrectionText);
        Assert.Equal(2, model.SelectionEnd);
        Assert.False(model.CanUndo);
    }

    [Fact]
    public void TabSavesAndOpensTheNextWordButStopsAtTheLastWord()
    {
        var model = Editor();
        Correcting(model, 2, "Today");
        Assert.True(model.SaveCorrection(advance: true));
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
        Assert.Equal(3, model.SelectionEnd);
        Assert.Equal(model.Words[3].Id, model.CorrectionWordId);
        Assert.Equal(model.DisplayText(model.Words[3]), model.CorrectionText);
        Correcting(model, model.Words.Count - 1, "last");
        Assert.True(model.SaveCorrection(advance: true));
        Assert.Null(model.CorrectionWordId);
    }

    [Fact]
    public void NextLineIsCountedAtTheCorrectionLimit()
    {
        var model = Editor();
        var draft = new string('a', EditingLimits.MaxCorrectionCodePoints) + (char)0x0085;
        Correcting(model, 2, draft);
        Assert.False(model.SaveCorrection());
        Assert.Equal(draft, model.CorrectionText);
        Assert.Equal("w3", model.CorrectionWordId);
        model.EndCorrection();
        Assert.False(model.Project.Edits.Corrections.ContainsKey("w3"));
    }

    [Fact]
    public void ReturnSavesAndClosesWithoutMovingSelection()
    {
        var model = Editor();
        Correcting(model, 2, "Today");
        Assert.True(model.SaveCorrection());
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
        Assert.Null(model.CorrectionWordId);
        Assert.Equal(2, model.SelectionEnd);
    }

    [Fact]
    public void EscapeKeepsTheWord()
    {
        var model = Editor();
        Correcting(model, 4, "shipping");
        Assert.True(model.EndCorrection(keep: false));
        Assert.Null(model.CorrectionWordId);
        Assert.Equal("shipped", model.Project.Edits.Corrections["w5"]);
        Assert.False(model.CanUndo);
    }

    [Fact]
    public void OpeningAnotherCorrectionSavesTheFirst()
    {
        var model = Editor();
        Correcting(model, 2, "Today");
        model.Select(2);
        Correcting(model, 2, "Today!");
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
        model.EndCorrection();
        Assert.Equal("Today!", model.Project.Edits.Corrections["w3"]);
    }

    [Fact]
    public void LeavingTheProjectSavesTheOpenCorrectionBeforeEditingPauses()
    {
        var model = Editor();
        Correcting(model, 2, "Today");
        model.BeginLeaving();
        Assert.Null(model.CorrectionWordId);
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
        Assert.True(model.IsDirty);
    }

    /// <summary>Narrator's Invoke on Pause leaves the focus in the field: the toggle ends the correction itself, from the state
    /// before the save. Reading it after the save would see the refresh's pause and play again.</summary>
    [Fact]
    public async Task PauseWithTheFieldOpenDuringPlaybackSavesItAndStaysPaused()
    {
        var (model, preview, toggle) = Playback();
        preview.Playing = true;
        Correcting(model, 2, "Today");
        var pause = ToggleAsync(model, preview, toggle);
        Assert.False(pause.IsCompleted);
        Assert.Null(model.CorrectionWordId);
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
        Assert.False(preview.Playing);
        preview.Settle();
        await pause;
        Assert.False(preview.Playing);
    }

    /// <summary>A click on Pause moves the focus first, so the field's focus loss saves before the click: the toggle waits for
    /// the refresh that save started, then reads that playback is still running, and pauses.</summary>
    [Fact]
    public async Task PauseAfterTheFocusLeftTheFieldWaitsForTheSavesRefreshAndPauses()
    {
        var (model, preview, toggle) = Playback();
        preview.Playing = true;
        Correcting(model, 2, "Today");
        Assert.True(model.EndCorrection());
        Assert.False(preview.Playing);
        var pause = ToggleAsync(model, preview, toggle);
        Assert.False(pause.IsCompleted);
        preview.Settle();
        await pause;
        Assert.False(preview.Playing);
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
    }

    [Fact]
    public async Task PlayWithTheFieldOpenWhilePausedSavesItAndPlays()
    {
        var (model, preview, toggle) = Playback();
        Correcting(model, 2, "Today");
        var play = ToggleAsync(model, preview, toggle);
        Assert.False(play.IsCompleted);
        Assert.Null(model.CorrectionWordId);
        Assert.Equal("Today", model.Project.Edits.Corrections["w3"]);
        // With no edit in flight, the toggle reads the state at once.
        preview.Settle();
        await play;
        Assert.True(preview.Playing);
        Assert.True(toggle.PausesAsync(model, () => preview.Playing).IsCompletedSuccessfully);
    }

    /// <summary>The view no longer light-dismisses the field, which dropped the typed text on a click elsewhere: focus loss and
    /// a press outside it end the correction in the model, and every transport action ends it first.</summary>
    [Fact]
    public void TheFieldEndsOnFocusLossAndTransportActionsEndItFirst()
    {
        var view = AppSource("Controls/TranscriptView.cs");
        Assert.DoesNotContain("IsLightDismissEnabled", view);
        var editing = AppSource("Controls/TranscriptView.InlineEditing.cs");
        Assert.DoesNotContain("new Popup", view + editing);
        Ordered(editing, "text.TextChanged += (_, _) =>", "model.CorrectionText = text.Text;",
            "text.LostFocus += (_, _) =>", "model?.EndCorrection();");
        Ordered(editing, "void Commit(bool next)", "model.CorrectionText = entered;",
            "model?.SaveCorrection(advance: next)", "if (!applied)",
            "if (model?.CorrectionWordId is null) Focus(FocusState.Keyboard);");
        Assert.Contains("model.EndCorrection(keep: false);", editing);
        Assert.Contains("root.AddHandler(PointerPressedEvent, inlinePressHandler, true);", editing);
        Assert.Contains("root.RemoveHandler(PointerPressedEvent, handler);", editing);
        Assert.Contains("model.CorrectionChanged += CorrectionChanged;", view);
        var page = AppSource("Pages/EditorPage.xaml.cs");
        Assert.Contains("playback.Refreshing(RunAsync(UpdatePreviewAsync, \"Preview\"));", page);
        Ordered(page, "private async Task SeekSourceAsync(double source)", "await playback.EndCorrectionAsync(ViewModel);", "previewStop = null;");
        Ordered(page, "private async Task TogglePlaybackAsync()", "await playback.PausesAsync(ViewModel, () => preview?.Position.IsPlaying == true);",
            "if (pause) await preview.PauseAsync(token); else await preview.PlayAsync(token);");
        Assert.DoesNotContain("if (preview.Position.IsPlaying) await preview.PauseAsync", page);
    }

    private static void Ordered(string text, params string[] markers)
    {
        var at = 0;
        foreach (var marker in markers)
        {
            var next = text.IndexOf(marker, at, StringComparison.Ordinal);
            Assert.True(next >= 0, "Missing or out of order: " + marker);
            at = next + marker.Length;
        }
    }

    private static string AppSource(string path) =>
        File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App", path));
}
#endif
