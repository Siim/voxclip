#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The Rewrite thread on Windows (design.md §6.3 "Talk back to Claude" and "Your own words", ADR-R50; Mac RewriteThreadTests),
/// and the per-phrase keep (Mac track/v2-seam-fade-cut <c>keepUnplaceable</c>). Stub backends only: nothing is sent anywhere.</summary>
public sealed class RewriteThreadTests
{
    const string Proposed = "word10 better word12 word13 word14 word15 nicer word17 word18 word19 word20";

    sealed class Backend
    {
        internal List<RewriteFollowupRequest> Requests { get; } = [];
        internal Func<RewriteFollowupRequest, CancellationToken, Task<RewriteFollowupReply>> Answer { get; set; } =
            (_, _) => Task.FromResult(new RewriteFollowupReply(["much better"], "Says it more warmly.", ["Name the buyer"]));
        internal Task<RewriteFollowupReply> SendAsync(RewriteFollowupRequest request, CancellationToken ct) { Requests.Add(request); return Answer(request, ct); }
    }

    static (RewriteSession Session, Backend Backend, EditorViewModel Editor) Open(string words = Proposed)
    {
        var editor = RewriteAutoFixTests.Editor();
        var session = new RewriteSession(editor, 10, 20, RewriteAutoFixTests.Envelope(), null);
        var backend = new Backend();
        session.ThreadBackend = backend.SendAsync;
        session.Edit(words);
        session.FocusChange(1);
        return (session, backend, editor);
    }
    static string Words(RewriteSession session, int ordinal) => string.Join(" ", session.Review!.Diff.Hunks[ordinal - 1].NewTokens);

    [Fact]
    public void TheThreadShowsUnderTheFocusedWaitingChangeWithItsBubblesAndNoTurnsYet()
    {
        var (session, _, _) = Open();
        using var _session = session;
        var display = Assert.IsType<RewriteThreadDisplay>(session.ThreadDisplay);
        Assert.Equal((1, 1, 1), (display.Ordinal, display.Version, display.Versions));
        Assert.Empty(display.Turns);
        Assert.Empty(display.Steps);
        Assert.Equal("✓ That's it, keep it", display.Keep);
        Assert.Equal(["Shorter", "Closer to my words", "3 more versions"], display.Steady);
        Assert.Equal("· 1 phrase to voice at Keep", display.PhrasesLine);
        Assert.Equal("1 of 1", display.VersionLine);
        Assert.Equal(("Talk to Claude about change 1", "Tell Claude what to change about change 1"), (display.Label, display.InputLabel));
        Assert.False(display.OwnWords);
        Assert.Equal("Tell Claude what to change…", display.Placeholder);
        // Only the focused, waiting change has a thread: one left out has none.
        Assert.True(session.SetChangeIncluded(1, false));
        Assert.Null(session.ThreadDisplay);
        session.FocusChange(2);
        Assert.Equal(2, session.ThreadDisplay!.Ordinal);
    }

    [Fact]
    public async Task AReplyGoesInThroughTheLocalRediffAsTheChangesWordsSoKeepPricesAndVoicesItAndNothingChangesInTheProject()
    {
        var (session, backend, editor) = Open();
        using var _session = session;
        var before = ProjectSerialization.Serialize(editor.Project);
        session.SetThreadText("Make it warmer");
        Assert.True(session.ThreadInputKey(RewriteThreadInputKey.Enter));
        await session.Thread.Running;
        var request = Assert.Single(backend.Requests);
        Assert.Equal((RewriteFollowupKind.Reply, "passage", 1, "word11"), (request.Kind, request.Scope, request.Ordinal, request.Recorded));
        Assert.Equal(["better"], request.Versions);
        Assert.Equal(["Make it warmer"], request.Messages);
        Assert.StartsWith("word10 word11 word12", request.Source);
        Assert.Equal("much better", Words(session, 1));
        Assert.Equal("nicer", Words(session, 2));
        var display = session.ThreadDisplay!;
        Assert.Equal((2, 2), (display.Version, display.Versions));
        Assert.Equal([new RewriteThreadTurn(RewriteThreadSpeaker.You, "Make it warmer"), new RewriteThreadTurn(RewriteThreadSpeaker.Claude, "Says it more warmly.")], display.Turns);
        Assert.Equal(["Name the buyer"], display.Steps);
        Assert.Equal("", display.Input);
        // The version is the Rewrite's own words for the change: its voice phrase is made from them.
        var phrase = Assert.Single(session.Review!.VoiceHunks, hunk => hunk.Ordinals.Contains(1));
        Assert.Contains("much better", phrase.PatchText);
        Assert.Equal(TranscriptChangeState.Pending, session.ChangeStates.GetValueOrDefault(1));
        Assert.Equal(before, ProjectSerialization.Serialize(editor.Project));
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public async Task SwitchingVersionsSendsNothingAddsNoUndoStepAndEveryLaterRequestCarriesEveryVersionAndMessageInOrder()
    {
        var (session, backend, editor) = Open();
        using var _session = session;
        await session.SendThreadAsync("Make it warmer");
        Assert.True(session.ThreadInputKey(RewriteThreadInputKey.PreviousVersion));
        Assert.Equal("better", Words(session, 1));
        Assert.Equal((1, 2), (session.ThreadDisplay!.Version, session.ThreadDisplay.Versions));
        Assert.True(session.SwitchThreadVersion(1));
        Assert.Equal("much better", Words(session, 1));
        Assert.False(session.SwitchThreadVersion(1));
        Assert.Single(backend.Requests);
        Assert.False(editor.CanUndo);
        // While the input holds text, the version keys are left to the text box.
        session.SetThreadText("x");
        Assert.False(session.ThreadInputKey(RewriteThreadInputKey.PreviousVersion));
        backend.Answer = (_, _) => Task.FromResult(new RewriteFollowupReply(["far better"], "", []));
        await session.SendThreadAsync("Shorter");
        Assert.Equal(["better", "much better"], backend.Requests[1].Versions);
        Assert.Equal(["Make it warmer", "Shorter"], backend.Requests[1].Messages);
        Assert.Equal("far better", Words(session, 1));
        // The ✦ bubbles come from the last reply only, and an empty note says what happened.
        Assert.Empty(session.ThreadDisplay!.Steps);
        Assert.Equal(new RewriteThreadTurn(RewriteThreadSpeaker.Claude, "Changed the words."), session.ThreadDisplay.Turns[^1]);
        Assert.Equal(2, session.ThreadDisplay.Turns.Count);
    }

    [Fact]
    public async Task ThreeMoreVersionsIsOneRequestForAlternativesAndTheFirstNewOneShowsAndTheSameWordsAddNoVersion()
    {
        var (session, backend, _) = Open();
        using var _session = session;
        backend.Answer = (request, _) => Task.FromResult(request.Kind == RewriteFollowupKind.Versions
            ? new RewriteFollowupReply(["one better", "two better", "three better"], "", ["Say it slower", "Add a pause", "A third"])
            : new RewriteFollowupReply(["Better."], "It already says that.", []));
        await session.PressThreadBubbleAsync("3 more versions");
        Assert.Equal(RewriteFollowupKind.Versions, backend.Requests[0].Kind);
        Assert.Equal(["3 more versions"], backend.Requests[0].Messages);
        Assert.Equal((2, 4), (session.ThreadDisplay!.Version, session.ThreadDisplay.Versions));
        Assert.Equal("one better", Words(session, 1));
        Assert.Equal("3 more versions.", session.ThreadDisplay.Turns[^1].Text);
        Assert.Equal(["Say it slower", "Add a pause"], session.ThreadDisplay.Steps);
        Assert.True(session.SwitchThreadVersion(-1));
        await session.PressThreadBubbleAsync("Closer to my words");
        Assert.Equal(RewriteFollowupKind.Reply, backend.Requests[1].Kind);
        Assert.Equal((1, 4), (session.ThreadDisplay!.Version, session.ThreadDisplay.Versions));
        Assert.Equal("Kept the words as they are. It already says that.", session.ThreadDisplay.Turns[^1].Text);
    }

    [Fact]
    public async Task TheKeepBubbleIsExactlyKeepAndUndoLeavesTheChangeOutWithNoThread()
    {
        var (session, backend, _) = Open();
        using var _session = session;
        await session.PressThreadBubbleAsync("✓ That's it, keep it");
        Assert.Empty(backend.Requests);
        Assert.Equal(TranscriptChangeState.Pending, session.ChangeStates[1]);
        Assert.Null(session.ThreadDisplay);
        Assert.True(session.OpenThreadInput());
        Assert.True(session.ThreadInputKey(RewriteThreadInputKey.Undo));
        Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[1]);
        Assert.Null(session.ThreadDisplay);
        Assert.Empty(backend.Requests);
    }

    [Fact]
    public async Task EscFoldsTheThreadAndKeepsTheVersionAndFocusingTheChangeAgainOpensIt()
    {
        var (session, _, _) = Open();
        using var _session = session;
        await session.SendThreadAsync("Make it warmer");
        Assert.True(session.ThreadInputKey(RewriteThreadInputKey.Escape));
        Assert.Null(session.ThreadDisplay);
        Assert.Equal("much better", Words(session, 1));
        session.FocusChange(2);
        Assert.Equal(2, session.ThreadDisplay!.Ordinal);
        session.FocusChange(1);
        Assert.Equal((2, 2), (session.ThreadDisplay!.Version, session.ThreadDisplay.Versions));
        Assert.True(session.FoldThread());
        var requests = session.Thread.FocusRequest;
        Assert.True(session.OpenThreadInput());
        Assert.NotNull(session.ThreadDisplay);
        Assert.Equal(requests + 1, session.Thread.FocusRequest);
    }

    [Fact]
    public async Task AnErrorShowsInPlaceKeepsTheInputAndTryAgainSendsTheSameMessage()
    {
        var (session, backend, editor) = Open();
        using var _session = session;
        backend.Answer = (_, _) => throw new InvalidOperationException("Claude Code isn't signed in. Sign in, then Try Again.");
        session.SetThreadText("Make it warmer");
        session.ThreadInputKey(RewriteThreadInputKey.Enter);
        await session.Thread.Running;
        var display = session.ThreadDisplay!;
        Assert.Equal("Claude Code isn't signed in. Sign in, then Try Again.", display.Error);
        Assert.True(display.Retry);
        Assert.Equal("Make it warmer", display.Input);
        Assert.Equal("better", Words(session, 1));
        backend.Answer = (_, _) => Task.FromResult(new RewriteFollowupReply(["much better"], "Warmer.", []));
        await session.RetryThreadAsync();
        Assert.Equal(["Make it warmer"], backend.Requests[1].Messages);
        Assert.Null(session.ThreadDisplay!.Error);
        Assert.Equal("", session.ThreadDisplay.Input);
        Assert.Equal("much better", Words(session, 1));
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public async Task StopCancelsTheRequestAndNothingChanges()
    {
        var (session, backend, _) = Open();
        using var _session = session;
        var reply = new TaskCompletionSource<RewriteFollowupReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        backend.Answer = (_, ct) => { ct.Register(() => reply.TrySetCanceled(ct)); return reply.Task; };
        session.SetThreadText("Make it warmer");
        var running = session.SendThreadAsync("Make it warmer", fromInput: true);
        Assert.True(session.ThreadDisplay!.Sending);
        Assert.Equal("Claude is working on it".Replace("Claude", session.AiName), session.ThreadDisplay.WorkingLine);
        // A second message waits for the first.
        await session.SendThreadAsync("Again");
        Assert.Single(backend.Requests);
        Assert.True(session.ThreadInputKey(RewriteThreadInputKey.Escape));
        await running;
        var display = session.ThreadDisplay!;
        Assert.False(display.Sending);
        Assert.Null(display.Error);
        Assert.Equal("Make it warmer", display.Input);
        Assert.Equal("better", Words(session, 1));
        Assert.Equal(1, display.Versions);
    }

    [Fact]
    public async Task MyOwnWordsFillTheInputAndEnterPutsThemInPlaceAsYourVersionWithNoRequestAndLaterRequestsCarryThemAsAVersion()
    {
        var (session, backend, editor) = Open();
        using var _session = session;
        await session.SendThreadAsync("Make it warmer");
        session.SetThreadText("a draft for Claude");
        await session.PressThreadBubbleAsync(RewriteThreadDisplay.OwnWordsBubble);
        var display = session.ThreadDisplay!;
        Assert.True(display.OwnWords);
        Assert.Equal("much better", display.Input);
        Assert.Equal((RewriteThreadDisplay.OwnWordsPlaceholder, RewriteThreadDisplay.OwnWordsCostLine), (display.Placeholder, display.InputCostLine));
        Assert.Equal("Your own words for change 1", display.InputLabel);
        session.SetThreadText("truly better");
        // The version keys are left to the text while your own words are typed.
        Assert.False(session.ThreadInputKey(RewriteThreadInputKey.PreviousVersion));
        Assert.True(session.ThreadInputKey(RewriteThreadInputKey.Enter));
        Assert.Single(backend.Requests);
        Assert.Equal("truly better", Words(session, 1));
        display = session.ThreadDisplay!;
        Assert.Equal((3, 3, true, "· your words"), (display.Version, display.Versions, display.Yours, display.YoursLine));
        Assert.Equal(new RewriteThreadTurn(RewriteThreadSpeaker.Yours, "truly better"), display.Turns[^1]);
        Assert.Empty(display.Steps);
        Assert.False(display.OwnWords);
        Assert.Equal("a draft for Claude", display.Input);
        // Your words are the change's words for Keep: its voice phrase is made from your text.
        Assert.Contains("truly better", Assert.Single(session.Review!.VoiceHunks, hunk => hunk.Ordinals.Contains(1)).PatchText);
        Assert.False(editor.CanUndo);
        await session.SendThreadAsync("Shorter");
        Assert.Equal(["better", "much better", "truly better"], backend.Requests[1].Versions);
        Assert.Equal(["Make it warmer", "Shorter"], backend.Requests[1].Messages);
    }

    [Fact]
    public void EscOrTheBubbleAgainLeavesYourOwnWordsWithNothingChangedAndASecondEscFolds()
    {
        var (session, backend, _) = Open();
        using var _session = session;
        session.SetThreadText("for Claude");
        Assert.True(session.OpenThreadOwnWords());
        session.SetThreadText("changed my mind");
        Assert.True(session.ThreadInputKey(RewriteThreadInputKey.Escape));
        Assert.False(session.ThreadDisplay!.OwnWords);
        Assert.Equal("for Claude", session.ThreadDisplay.Input);
        Assert.Equal("better", Words(session, 1));
        session.ToggleThreadOwnWords();
        Assert.True(session.ThreadDisplay!.OwnWords);
        session.ToggleThreadOwnWords();
        Assert.False(session.ThreadDisplay!.OwnWords);
        Assert.Equal(1, session.ThreadDisplay.Versions);
        Assert.True(session.ThreadInputKey(RewriteThreadInputKey.Escape));
        Assert.Null(session.ThreadDisplay);
        Assert.Empty(backend.Requests);
    }

    [Fact]
    public async Task ABubbleThatTalksToClaudeLeavesYourOwnWordsFirst()
    {
        var (session, backend, _) = Open();
        using var _session = session;
        session.SetThreadText("for Claude");
        session.OpenThreadOwnWords();
        session.SetThreadText("unfinished words");
        await session.PressThreadBubbleAsync("Shorter");
        Assert.Equal(["Shorter"], Assert.Single(backend.Requests).Messages);
        Assert.False(session.ThreadDisplay!.OwnWords);
        Assert.Equal("much better", Words(session, 1));
    }

    [Fact]
    public void EmptyWordsMakeACutAndTheWordsInTheTextChangeNothingAndAVersionsExactWordsShowThatVersion()
    {
        var (session, backend, editor) = Open();
        using var _session = session;
        session.OpenThreadOwnWords();
        Assert.True(session.ApplyThreadOwnWords("better"));
        Assert.Equal(1, session.ThreadDisplay!.Versions);
        Assert.False(session.ThreadDisplay.OwnWords);
        session.OpenThreadOwnWords();
        Assert.True(session.ApplyThreadOwnWords("fine"));
        session.OpenThreadOwnWords();
        Assert.True(session.ApplyThreadOwnWords("better"));
        Assert.Equal((1, 2), (session.ThreadDisplay!.Version, session.ThreadDisplay.Versions));
        Assert.False(session.ThreadDisplay.Yours);
        session.OpenThreadOwnWords();
        Assert.True(session.ApplyThreadOwnWords("   "));
        Assert.Equal(VoiceLabDiffHunkKind.Cut, session.Review!.Diff.Hunks[0].Kind);
        Assert.Equal(["w11"], session.Review.Diff.Hunks[0].SourceWordIds);
        Assert.Equal((3, 3, "· text only, free"), (session.ThreadDisplay!.Version, session.ThreadDisplay.Versions, session.ThreadDisplay.PhrasesLine));
        Assert.Empty(backend.Requests);
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public async Task TheRecordedWordsLeaveTheChangeOutAndTheLaterChangesKeepTheirThreads()
    {
        var (session, backend, _) = Open();
        using var _session = session;
        session.FocusChange(2);
        await session.SendThreadAsync("Make it warmer");
        Assert.Equal("much better", Words(session, 2));
        session.FocusChange(1);
        session.OpenThreadOwnWords();
        Assert.True(session.ApplyThreadOwnWords("word11"));
        var hunk = Assert.Single(session.Review!.Diff.Hunks);
        Assert.Equal("much better", string.Join(" ", hunk.NewTokens));
        session.FocusChange(1);
        var display = session.ThreadDisplay!;
        Assert.Equal((2, 2), (display.Version, display.Versions));
        Assert.Equal("Make it warmer", display.Turns[0].Text);
        Assert.Single(backend.Requests);
    }

    [Fact]
    public void AVersionThatDiffersInSeveralPlacesStaysOneChangeVoicedFromItsWholeText()
    {
        var (session, _, _) = Open("word10 alpha beta gamma delta epsilon word16 word17 word18 word19 word20");
        using var _session = session;
        string[] span = ["w11", "w12", "w13", "w14", "w15"];
        Assert.Equal(span, session.Review!.Diff.Hunks[0].SourceWordIds);
        // A plain edit outside the thread is the local rediff as before: here, two changes.
        Assert.True(session.EditChange(1, "zeta word12 word13 word14 eta"));
        Assert.Equal(2, session.Review!.Diff.Hunks.Count);
        session.Edit("word10 alpha beta gamma delta epsilon word16 word17 word18 word19 word20");
        session.FocusChange(2);
        session.FocusChange(1);
        session.OpenThreadOwnWords();
        Assert.True(session.ApplyThreadOwnWords("zeta word12 word13 word14 eta"));
        var hunk = Assert.Single(session.Review!.Diff.Hunks);
        Assert.Equal((VoiceLabDiffHunkKind.Voice, "zeta word12 word13 word14 eta"), (hunk.Kind, string.Join(" ", hunk.NewTokens)));
        Assert.Equal(span, hunk.SourceWordIds);
        Assert.Equal((2, 2, true), (session.ThreadDisplay!.Version, session.ThreadDisplay.Versions, session.ThreadDisplay.Yours));
        Assert.Contains("zeta word12 word13 word14 eta", Assert.Single(session.Review.VoiceHunks).PatchText);
    }

    [Fact]
    public void AChangeThatCantBeJoinedToTheRecordingKeepsItsOriginalWordsWithTheNoteAndTheOthersArePriced()
    {
        // "extra" adds words where the speaker said nothing: placing every change together refuses it on geometry.
        var (session, _, _) = Open("word10 better word12 word13 word14 word15 word16 word17 extra word18 word19 word20");
        using var _session = session;
        var review = session.Review!;
        Assert.Equal(2, review.Diff.Hunks.Count);
        Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[2]);
        Assert.Contains("Change 2 keeps your original words: it adds words where you said nothing, and the video has no time for them.", session.AutoFix.Notes);
        Assert.Equal(session.AutoFix.Notes[^1], session.AutoFix.Announcement);
        var priced = Assert.Single(review.VoiceHunks);
        Assert.Equal([1], priced.Ordinals);
        Assert.NotNull(priced.Window);
        Assert.Null(priced.Refusal);
        Assert.Single(session.IncludedHunks);
        session.FocusChange(2);
        Assert.Null(session.ThreadDisplay);
    }

    [Fact]
    public void WithoutTheRecordingsEnvelopeNothingIsLeftOutAndTheReasonsReadAsOnTheMac()
    {
        using var session = new RewriteSession(RewriteAutoFixTests.Editor(), 10, 20, null, null);
        session.Edit("word10 better word12 word13 word14 word15 word16 word17 extra word18 word19 word20");
        Assert.Empty(session.ChangeStates);
        Assert.Empty(session.AutoFix.Notes);
        Assert.Equal("it is too close to the start of the take to blend in.",
            RewriteSession.UnplaceableReason(new(VoiceLabGeometryErrorCode.SeamFadeOutsideTake) { TakeEdgeIsStart = true }));
        Assert.Equal("it is too close to the end of the take to blend in.",
            RewriteSession.UnplaceableReason(new(VoiceLabGeometryErrorCode.SeamFadeOutsideTake) { TakeEdgeIsStart = false }));
        Assert.Equal("it can't be joined to the recording there.", RewriteSession.UnplaceableReason(new(VoiceLabGeometryErrorCode.SeamFadeCrossesCut)));
    }

    [Fact]
    public void NarratorNamesTheThreadItsTurnsBubblesAndActions()
    {
        Assert.Equal("Claude: Warmer.", RewriteThreadDisplay.TurnLabel(new(RewriteThreadSpeaker.Claude, "Warmer.")));
        Assert.Equal("You: Shorter", RewriteThreadDisplay.TurnLabel(new(RewriteThreadSpeaker.You, "Shorter")));
        Assert.Equal("More suspense, suggested by Claude", RewriteThreadDisplay.StepLabel("More suspense"));
        Assert.Equal("Type your own words for change 3", RewriteThreadDisplay.OwnWordsAction(3));
        Assert.Equal("Talk to Claude about change 3", RewriteThreadDisplay.TalkAction(3));
        Assert.Equal(("Free on your Claude plan", "Billed to your Anthropic key", "Free on this PC"),
            (RewriteThreadDisplay.CostLineFor(ConnectorId.ClaudeCode), RewriteThreadDisplay.CostLineFor(ConnectorId.Anthropic), RewriteThreadDisplay.CostLineFor(ConnectorId.Ollama)));
        var view = AppSource("Controls", "TranscriptView.Thread.cs");
        foreach (var name in new[] { "display.Label", "display.InputLabel", "\"Previous version\"", "\"Next version\"", "display.VersionLabel",
                     "RewriteThreadDisplay.StepLabel", "RewriteThreadDisplay.TurnLabel", "\"My own words\"", "new ToggleButton", "IsChecked = display.OwnWords" })
            Assert.Contains(name, view);
        Assert.DoesNotContain("Flyout", view);
        Assert.DoesNotContain("ContentDialog", view);
        Assert.DoesNotContain("Popup", view);
        // WinUI has no custom actions: the focused change's paragraph names both keys in its help text.
        var presentation = AppSource("Controls", "TranscriptView.Presentation.cs");
        Assert.Contains("RewriteThreadDisplay.TalkAction(talked.Ordinal)", presentation);
        Assert.Contains("RewriteThreadDisplay.OwnWordsAction(talked.Ordinal)", presentation);
    }

    [Fact]
    public void TheInlineCorrectionRowIsGoneAndF2EnterAndTheNewWordsOpenTheThread()
    {
        var editing = AppSource("Controls", "TranscriptView.InlineEditing.cs");
        Assert.DoesNotContain("New words for change", editing);
        Assert.DoesNotContain("Reject Change", editing);
        Assert.DoesNotContain("BeginProposalCorrection", editing);
        Assert.Contains("OpenThread(", editing);
        Assert.DoesNotContain("EditChangeRequested", AppSource("Controls", "TranscriptView.Presentation.cs"));
        Assert.DoesNotContain("EditChangeRequested", AppSource("Pages", "EditorPage.Integration.cs"));
        Assert.Contains("F2 talks to Claude about a proposed change", AppSource("Controls", "TranscriptView.cs"));
        Assert.Contains("VirtualKey.F2", editing);
        Assert.Contains("VirtualKey.PageUp", editing);
    }

    static string AppSource(string folder, string file) =>
        File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "..", "apps", "windows", "src", "VoxClip.App", folder, file));
}
#endif
