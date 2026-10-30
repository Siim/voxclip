#if WIN_UI_TESTS
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class RewritePanelTests
{
    [Theory]
    [InlineData("edit")]
    [InlineData("readonly")]
    [InlineData("leaving")]
    [InlineData("settings")]
    [InlineData("connector")]
    [InlineData("close")]
    public void EveryClosePathHandsPanelFocusOffBeforeRemoval(string path)
    {
        var editor = Editor();
        var current = true;
        using var session = new RewriteSession(editor, 10, 12, Envelope(), null, connectorIsCurrent: () => current);
        var closed = 0;
        session.Changed += (_, _) => { if (!session.IsOpen) closed++; };
        switch (path)
        {
            case "edit": editor.Apply(new EditOperation.Correct("w10", "changed")); break;
            case "readonly": editor.SetMediaUnavailable(true); break;
            case "leaving": editor.BeginLeaving(); break;
            case "settings": session.SettingsChanged(false); break;
            case "connector": current = false; session.SettingsChanged(true); break;
            default: session.Dispose(); break;
        }
        Assert.False(session.IsOpen);
        Assert.Equal(1, closed);
        Assert.True(FocusCycle.RestoreRewriteFocus(true, false, false));
        Assert.False(FocusCycle.RestoreRewriteFocus(false, false, false));
        Assert.False(FocusCycle.RestoreRewriteFocus(true, true, true));
        var page = AppSource("Pages", "EditorPage.xaml.cs");
        var handoff = page.IndexOf("FocusCycle.RestoreRewriteFocus", StringComparison.Ordinal);
        Assert.True(handoff >= 0 && handoff < page.IndexOf("rightContent.CloseRewrite()", handoff, StringComparison.Ordinal));
        Assert.Contains("InputState.DescendsFrom(FocusManager.GetFocusedElement(XamlRoot) as DependencyObject, panel)", page);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CostConfirmationCancelsOnCloseOrRevisionWithoutSending(bool revise)
    {
        var fake = new RecordingConnector();
        using var session = new RewriteSession(Editor(), 10, 12, Envelope(), new(fake, "chosen", "Test", "local", ""));
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        CancellationToken observed = default;
        var waiting = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = session.ConfirmCostAsync(action, token => { observed = token; return waiting.Task; });
        if (revise) session.Edit("changed"); else session.Dispose();
        Assert.True(observed.IsCancellationRequested);
        Assert.False(await pending);
        waiting.SetResult(true);
        Assert.DoesNotContain("send", fake.Calls);
        Assert.Contains("session.ConfirmCostAsync(action, token => Ui.ConfirmAsync", AppSource("Controls", "RewritePanel.cs"));
        Assert.Contains("DefaultButton = ContentDialogButton.Close", AppSource("Controls", "Ui.cs"));
    }

    [Fact]
    public void NarratorAnnouncesOnlyTransitionsAndEachArrivingProposal()
    {
        var announcements = new RewriteAnnouncements();
        Assert.Empty(announcements.Next(false, 0, "", ""));
        Assert.Equal(["AI request in progress"], announcements.Next(true, 0, "", ""));
        Assert.Empty(announcements.Next(true, 0, "", ""));
        Assert.Equal(["New words ready: 2 changes"], announcements.Next(false, 1, "", "2 changes"));
        Assert.Empty(announcements.Next(false, 1, "", "2 changes"));
        Assert.Equal(["Refused"], announcements.Next(false, 1, "Refused", ""));
        Assert.Empty(announcements.Next(false, 1, "Refused", ""));
        Assert.Empty(announcements.Next(false, 1, "", ""));
        Assert.Equal(new[] { "Refused" }, announcements.Next(false, 1, "Refused", ""));
        Assert.Equal(["New words ready: 2 changes"], announcements.Next(false, 2, "", "2 changes"));
        var panel = AppSource("Controls", "RewritePanel.cs");
        Assert.Contains("Ui.Announce(this, message, \"rewrite\", AutomationNotificationProcessing.All)", panel);
        Assert.DoesNotContain("LiveSetting", panel);
    }

    [Fact]
    public void RapidRewriteTransitionsQueueEveryDeduplicatedMessageInOrder()
    {
        var announcements = new RewriteAnnouncements();
        var emitted = new List<string>();
        emitted.AddRange(announcements.Next(true, 0, "", ""));
        emitted.AddRange(announcements.Next(false, 1, "", "2 changes"));
        emitted.AddRange(announcements.Next(false, 1, "Refused", ""));
        emitted.AddRange(announcements.Next(false, 1, "Refused", ""));
        Assert.Equal(["AI request in progress", "New words ready: 2 changes", "Refused"], emitted);
        Assert.Contains("Ui.Announce(this, message, \"rewrite\", AutomationNotificationProcessing.All)", AppSource("Controls", "RewritePanel.cs"));
        Assert.Contains("AutomationNotificationProcessing processing = AutomationNotificationProcessing.MostRecent", AppSource("Controls", "Ui.cs"));
        Assert.Contains("processing, text, activity", AppSource("Controls", "Ui.cs"));
    }

    [Fact]
    public void PanelHasOneOuterHairlineAndRefreshesAllOwnedBrushesAfterParenting()
    {
        var panel = AppSource("Controls", "RewritePanel.cs");
        Assert.DoesNotContain("BorderThickness = new(0, 1, 0, 0);", panel);
        Assert.Contains("ActualThemeChanged += (_, _) => RefreshBrushes()", panel);
        Assert.Contains("Ui.EffectsChanged += EffectsChanged", panel);
        Assert.Contains("Ui.EffectsChanged -= EffectsChanged", panel);
        Assert.Contains("foreach (var (target, property, key) in brushes) target.SetValue(property, Ui.ThemeBrush(this, key))", panel);
        var loaded = panel.IndexOf("Loaded +=", StringComparison.Ordinal);
        Assert.True(panel.IndexOf("RefreshBrushes();", loaded, StringComparison.Ordinal) > loaded);
        Assert.Contains("x:Name=\"CaptionsHost\"", AppSource("Pages", "EditorPage.xaml"));
    }

    [Theory]
    [InlineData("instruction", true, false, true, false)]
    [InlineData("proposed words", true, false, true, false)]
    [InlineData("correction", false, true, true, false)]
    [InlineData("footer", false, false, true, true)]
    [InlineData("elsewhere", false, false, false, false)]
    public void ReturnDefaultRespectsFocusedEditorsAndTheEnabledButton(string focus, bool textFocus, bool correctionOpen, bool enabled, bool expected)
    {
        Assert.NotEmpty(focus);
        Assert.Equal(expected, enabled && ShortcutPolicy.EditorMayHandle(textFocus, correctionOpen, false, false, true));
        var panel = AppSource("Controls", "RewritePanel.cs");
        Assert.Contains("apply.IsEnabled && ShortcutPolicy.EditorMayHandle", panel);
        Assert.Contains("InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot)), correctionOpen()", panel);
        Assert.Contains("apply.IsEnabled = session.LocalAction is not null && !session.Editor.Busy", panel);
        Assert.Contains("new RewritePanel(rewrite, () => Transcript.CorrectionOpen)", AppSource("Pages", "EditorPage.xaml.cs"));
    }

    [Theory]
    [InlineData("word12", "Apply Cuts")]
    [InlineData("WORD10 word11 word12", "Apply Correction")]
    public void ReturnAppliesTheLabelledLocalDefaultWithoutAi(string text, string label)
    {
        var editor = Editor();
        using var session = new RewriteSession(editor, 10, 12, Envelope(), null);
        session.Edit(text);
        Assert.Equal(label, session.LocalAction);
        Assert.True(session.ApplyLocalChanges());
        Assert.False(session.IsOpen);
        Assert.True(editor.CanUndo);
        editor.Undo();
        Assert.False(editor.CanUndo);
        var panel = AppSource("Controls", "RewritePanel.cs");
        Assert.Contains("args.Key == VirtualKey.Enter", panel);
        Assert.Contains("PreviewKeyDown += Escape", panel);
        Assert.Contains("session.LocalAction is not null && !session.Editor.Busy", panel);
    }

    private static string AppSource(string directory, string name) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "src", "VoxClip.App", directory, name));

    private static string Shared => Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
    private static EditorViewModel Editor(params TimedWord[] words)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures", "projects", "interview-take.voxclip")));
        if (words.Length == 0) words = Enumerable.Range(0, 80).Select(index => Word(index, "word" + index)).ToArray();
        project = project with { Transcript = project.Transcript! with { Words = words },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 100, Audio = new(48000, 1) } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } };
        return new(project, now: () => new DateTimeOffset(2026, 10, 28, 0, 0, 0, TimeSpan.Zero));
    }
    private static TimedWord Word(int index, string text, WordKind kind = WordKind.Word) =>
        new("w" + index, text, kind, index + 1, index + 1.4, null, null, 1, null, TimingSource.Native);
    private static AudioEnvelope Envelope() => new(48000, 0.01, Enumerable.Repeat(0.01f, 10000).ToArray());

    [Fact]
    public void CaptionRegionOnlyFocusesAVisibleTileOrItsVisibleToggle()
    {
        var panel = File.ReadAllText(Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "src", "VoxClip.App", "Controls", "CaptionsPanel.cs"));
        Assert.Contains("gallery.IsEnabled && gallery.ActualHeight > 0", panel);
        Assert.Contains("gallery.ScrollIntoView(selected, ScrollIntoViewAlignment.Leading);", panel);
        Assert.Contains("gallery.ContainerFromItem(selected) is Control target", panel);
        Assert.Contains("CreatePeerForElement(target).IsOffscreen()", panel);
        Assert.Contains("if (enabled.IsEnabled) return enabled;", panel);
        Assert.Contains("FocusManager.FindFirstFocusableElement(fineTuneViewport)", panel);
        Assert.Contains("Read-only Captions has no enabled, visible F6 focus target.", panel);
    }

    [Fact]
    public void PanelUsesTheRightColumnFocusSlotAndExactControlNames()
    {
        var app = Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "src", "VoxClip.App");
        var panel = File.ReadAllText(Path.Combine(app, "Controls", "RewritePanel.cs"));
        var column = File.ReadAllText(Path.Combine(app, "Controls", "RightColumn.cs"));
        var page = File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.xaml.cs"));
        Assert.Contains("SetName(close, \"Close Rewrite\")", panel);
        Assert.Contains("SetName(instruction, \"What should change?\")", panel);
        Assert.Contains("SetName(words, \"New words\")", panel);
        Assert.Contains("instruction.Focus(FocusState.Programmatic)", panel);
        Assert.Contains("VirtualKey.Escape", panel);
        Assert.Contains("ReturnFocusOnClose = true", panel);
        Assert.Contains("if (!session.ApplyLocalChanges()) ReturnFocusOnClose = false", panel);
        Assert.Contains("rewrite?.FocusTarget ?? captions.FocusTarget", column);
        Assert.Contains("EditorFocusRegion.Captions: if (rightContent", page);
        Assert.Contains("panel.ReturnFocusOnClose", page);
        Assert.Contains("FocusTranscript()", page);
        Assert.DoesNotContain("Use Take", panel);
        Assert.Contains("Content = \"Generate Takes\"", panel);
    }

    [Fact]
    public void LeavingOrLosingTheSourceClosesAndClearsThePassage()
    {
        var leaving = Editor();
        using var first = new RewriteSession(leaving, 10, 12, Envelope(), null);
        leaving.BeginLeaving();
        Assert.False(first.IsOpen);
        Assert.Equal(-1, leaving.RewriteStart);
        var missing = Editor();
        using var second = new RewriteSession(missing, 10, 12, Envelope(), null);
        missing.SetMediaUnavailable(true);
        Assert.False(second.IsOpen);
        Assert.Equal(-1, missing.RewriteEnd);
    }

    [Fact]
    public void ApplyCutsMatchesTheManualSavedProjectByteForByteAndUndoesOnce()
    {
        var edited = Editor();
        var manual = new EditorViewModel(edited.Project, now: () => new DateTimeOffset(2026, 10, 28, 0, 0, 0, TimeSpan.Zero));
        using var session = new RewriteSession(edited, 10, 12, null, null);
        session.Edit("word12");
        Assert.Equal("Apply Cuts", session.LocalAction);
        Assert.True(session.ApplyLocalChanges());
        Assert.False(session.IsOpen);
        Assert.True(manual.ApplyBatch([new EditOperation.SetWordCuts(["w10", "w11"], true)]));
        Assert.Equal(System.Text.Encoding.UTF8.GetBytes(ProjectSerialization.Serialize(manual.Project)),
            System.Text.Encoding.UTF8.GetBytes(ProjectSerialization.Serialize(edited.Project)));
        edited.Undo();
        Assert.Empty(edited.State!.CutWordIds);
        Assert.False(edited.CanUndo);
        edited.Redo();
        Assert.Equal(new[] { "w10", "w11" }, edited.State.CutWordIds.Order());
        Assert.False(session.ApplyLocalChanges());
    }

    [Fact]
    public void ApplyCorrectionUsesWholeItemTextsAndOneUndoStepWithoutAi()
    {
        var words = Enumerable.Range(0, 80).Select(index => Word(index, "word" + index)).ToArray();
        words[10] = Word(10, "Hello world"); words[11] = Word(11, "SUNDAY");
        var editor = Editor(words);
        var fake = new RecordingConnector();
        using var session = new RewriteSession(editor, 10, 11, null, new(fake, "chosen", "Test", "local", ""));
        session.Edit("hello WORLD, Sunday!");
        Assert.Equal("Apply Correction", session.LocalAction);
        Assert.True(session.ApplyLocalChanges());
        Assert.Equal("hello WORLD,", editor.State!.Corrections["w10"]);
        Assert.Equal("Sunday!", editor.State.Corrections["w11"]);
        Assert.Equal(words, editor.Words);
        Assert.Empty(fake.Calls);
        editor.Undo();
        Assert.Empty(editor.State.Corrections);
        Assert.False(editor.CanUndo);
    }

    [Fact]
    public void VoiceChangesCannotApplyLocalOrAcceptAndStateChangesCloseThePanel()
    {
        var editor = Editor();
        using var session = new RewriteSession(editor, 10, 12, Envelope(), null);
        session.Edit("Sunday");
        Assert.Null(session.LocalAction);
        Assert.False(session.ApplyLocalChanges());
        editor.Apply(new EditOperation.SetWordCuts(["w1"], true));
        Assert.False(session.IsOpen);
        Assert.Equal(-1, editor.RewriteStart);
    }

    [Fact]
    public void LiveReviewUsesCoreMetersAndCompletePatchPricingForEachHunk()
    {
        var prices = VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(Shared, "catalog", "voice-lab.json")));
        using var session = new RewriteSession(Editor(), 10, 18, Envelope(), null, prices: prices, synthesisModel: "eleven_multilingual_v2");
        session.Edit("Sunday word11 word12 word13 word14 word15 word16 word17 five");
        var review = Assert.IsType<RewriteReview>(session.Review);
        Assert.Equal(2, review.VoiceHunks.Count);
        foreach (var hunk in review.VoiceHunks)
        {
            var window = Assert.IsType<VoiceLabWindow>(hunk.Window);
            var silence = VoiceLabWindowPlanner.LendableSilence(session.Project, session.Scope, window);
            var expected = VoiceLabFitMeter.Measure(hunk.PatchText!, window, silence.Incoming, silence.Outgoing,
                VoiceLabLengthBudget.Rate(session.Transcript).CharactersPerSecond, string.Join(" ", hunk.Hunk.NewTokens), true);
            Assert.Equal(expected, hunk.Meter);
            Assert.StartsWith("“" + string.Join(" ", hunk.Hunk.NewTokens) + "” · about ", hunk.Meter!.Copy);
        }
        var summary = VoiceLabDiffSummary.Make(review.Diff, review.VoiceHunks.Select(hunk => hunk.Meter!).ToArray(), prices,
            "eleven_multilingual_v2", patchTexts: review.VoiceHunks.Select(hunk => hunk.PatchText).ToArray());
        Assert.Equal(summary, review.Summary);
        Assert.NotNull(review.Summary!.CostEstimate!.Usd);
        session.Edit("Sunday word11 word12 word13 word14 word15 word16 word17 word18");
        Assert.Single(session.Review!.VoiceHunks);
        Assert.StartsWith("about ", session.Review.VoiceHunks[0].Meter!.Copy);
    }

    [Fact]
    public void MissingWindowsAndUnknownModelNeverInventAHeaderPrice()
    {
        var prices = VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(Shared, "catalog", "voice-lab.json")));
        using var unavailable = new RewriteSession(Editor(), 10, 12, null, null, prices: prices, synthesisModel: "eleven_multilingual_v2");
        unavailable.Edit("Sunday word11 word12");
        Assert.Null(unavailable.Review!.Summary);
        Assert.All(unavailable.Review.VoiceHunks, hunk => { Assert.Null(hunk.Window); Assert.Null(hunk.PatchText); Assert.NotNull(hunk.Refusal); });
        using var unknown = new RewriteSession(Editor(), 10, 12, Envelope(), null, prices: prices, synthesisModel: "unknown-model");
        unknown.Edit("Sunday word11 word12");
        Assert.Null(unknown.Review!.Summary!.CostEstimate!.Usd);
        Assert.DoesNotContain("$", unknown.Review.Summary.Copy);
        Assert.Equal("This change is too close to the end of the take to blend in. Re-record this sentence instead.",
            RewriteSession.Refusal(new VoiceLabGeometryException(VoiceLabGeometryErrorCode.SeamFadeOutsideTake) { TakeEdgeIsStart = false }));
    }

    [Fact]
    public void DiffLineIncludesAbsorbedLabelsBridgesAndTheSpokenDescription()
    {
        var words = Enumerable.Range(0, 80).Select(index => Word(index, "word" + index)).ToArray();
        words[10] = Word(10, "one"); words[18] = Word(18, "seven");
        using var session = new RewriteSession(Editor(words), 10, 18, Envelope(), null);
        session.Edit("on Sunday word11 word12 word13 word14 word15 word16 word17 five");
        Assert.Equal("one becomes on Sunday, seven becomes five", session.Review!.AccessibleDescription);
        Assert.Contains(session.Review.Runs, run => run.Text == "one" && run.Kind == RewriteDiffKind.Removed);
        Assert.Contains(session.Review.Runs, run => run.Text == "Sunday" && run.Kind == RewriteDiffKind.Inserted);
        session.Edit("on Sunday word11 word12 five word14 word15 word16 word17 seven");
        Assert.Contains(session.Review!.Runs, run => run.SourceId == "w11" && run.Kind == RewriteDiffKind.Bridge);
        words[11] = Word(11, "[laughter]", WordKind.Event);
        words[12] = Word(12, "[unlabeled speech]", WordKind.UnlabeledSpeech);
        using var absorbed = new RewriteSession(Editor(words), 10, 13, Envelope(), null);
        absorbed.Edit("Sunday");
        Assert.Contains(absorbed.Review!.Runs, run => run.Text == "[laughter]" && run.Kind == RewriteDiffKind.Removed);
        Assert.Contains(absorbed.Review.Runs, run => run.Text == "[unlabeled speech]" && run.Kind == RewriteDiffKind.Removed);
        Assert.Contains("[laughter] removed", absorbed.Review.AccessibleDescription);
        Assert.Contains("[unlabeled speech] removed", absorbed.Review.AccessibleDescription);
    }

    [Fact]
    public void PatchBudgetUsesTheWholeTranscriptAndUpdatesWithoutCalls()
    {
        var fake = new RecordingConnector();
        using var session = new RewriteSession(Editor(), 10, 29, Envelope(), new(fake, "chosen", "Test", "local", ""));
        session.Edit(string.Join(" ", Enumerable.Repeat("replacement", 20)));
        Assert.Equal(VoiceLabPatchBudgetFlag.ReRecordInstead, session.Review!.Budget.Flag);
        Assert.Equal(VoiceLabPatchBudget.DisabledCopy, session.Review.Budget.Copy);
        Assert.Equal(VoiceLabPatchBudget.Evaluate(session.Review.Diff, session.Transcript), session.Review.Budget);
        session.Edit("");
        Assert.Equal(VoiceLabPatchBudgetFlag.Allowed, session.Review!.Budget.Flag);
        Assert.Empty(fake.Calls);
    }

    [Fact]
    public async Task PanelProposalIsInertUntilTheDisplayedEstimateIsApproved()
    {
        var editor = Editor();
        var fake = new RecordingConnector();
        using var session = new RewriteSession(editor, 10, 12, Envelope(), new(fake, "chosen", "Test connector", "apiKey", ""),
            consent: _ => Task.FromResult(true));
        Assert.Equal("", editor.SelectionText);
        Assert.Equal("3 words at 0:11.0", session.Header);
        Assert.Equal("word10 word11 word12", session.NewWords);
        await session.SetInstructionAsync("Say it plainly");
        Assert.Equal("", session.Problem);
        var action = Assert.IsType<VoxClip.Core.Domain.VoiceLab.VoiceLabPreparedAction>(session.Prepared);
        Assert.False(session.CanPropose);
        Assert.False(await session.ProposeAsync(action, true));
        Assert.Empty(fake.Calls);
        session.MarkEstimateShown(action);
        Assert.True(session.CanPropose);
        Assert.False(await session.ProposeAsync(action, false));
        Assert.Empty(fake.Calls);
        Assert.True(await session.ProposeAsync(action, true));
        Assert.Equal("Better passage", session.NewWords);
        Assert.Equal(1, fake.Calls.Count(call => call == "send"));
        Assert.Equal("word10", editor.Words[10].Text);
        session.Edit("My own words");
        Assert.Equal("My own words", session.NewWords);
        session.Dispose();
        Assert.False(session.IsOpen);
        Assert.Equal(-1, editor.RewriteStart);
        Assert.False(await session.ProposeAsync(action, true));
    }

    [Fact]
    public async Task ChangedInstructionInvalidatesTheDisplayedAuthorizationWithoutDiscovery()
    {
        var fake = new RecordingConnector();
        using var session = new RewriteSession(Editor(), 10, 12, Envelope(), new(fake, "chosen", "Test", "local", ""));
        await session.SetInstructionAsync("First");
        var first = session.Prepared!;
        session.MarkEstimateShown(first);
        await session.SetInstructionAsync("Second");
        Assert.False(await session.ProposeAsync(first, true));
        Assert.Empty(fake.Calls);
        Assert.Equal("Runs on this PC. Nothing leaves it.", session.SendLine);
    }

    [Fact]
    public async Task FailedProposalKeepsItsInlineErrorAndLateProposalCannotReplaceTyping()
    {
        var failed = new RecordingConnector { Failure = new IOException("offline") };
        using var failure = new RewriteSession(Editor(), 10, 12, Envelope(), new(failed, "chosen", "Test", "apiKey", ""),
            consent: _ => Task.FromResult(true));
        await failure.SetInstructionAsync("First");
        var quote = failure.Prepared!;
        failure.MarkEstimateShown(quote);
        Assert.False(await failure.ProposeAsync(quote, true));
        Assert.NotEmpty(failure.Problem);
        Assert.DoesNotContain("offline", failure.Problem);
        failed.Failure = null;
        var retry = failure.Prepared!;
        failure.MarkEstimateShown(retry);
        Assert.True(await failure.ProposeAsync(retry, true));
        Assert.Empty(failure.Problem);
        var late = new RecordingConnector { Pending = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var typing = new RewriteSession(Editor(), 10, 12, Envelope(), new(late, "chosen", "Test", "apiKey", ""),
            consent: _ => Task.FromResult(true));
        await typing.SetInstructionAsync("Second");
        var action = typing.Prepared!;
        typing.MarkEstimateShown(action);
        var pending = typing.ProposeAsync(action, true);
        Assert.Contains("send", late.Calls);
        typing.Edit("Keep my typing");
        late.Pending.SetResult(new(null, new JsonObject { ["rewrite"] = "Late answer" }, "chosen", new StopKind.Complete(), null, "fake"));
        Assert.False(await pending);
        Assert.Equal("Keep my typing", typing.NewWords);
    }

    [Fact]
    public async Task PersistingConsentDoesNotCloseTheUnchangedSession()
    {
        var fake = new RecordingConnector();
        RewriteSession? open = null;
        using var session = new RewriteSession(Editor(), 10, 12, Envelope(), new(fake, "chosen", "Test", "apiKey", ""),
            consent: _ => { open!.SettingsChanged(true); return Task.FromResult(true); }, connectorIsCurrent: () => true);
        open = session;
        await session.SetInstructionAsync("Plainly");
        var quote = session.Prepared!;
        session.MarkEstimateShown(quote);
        Assert.True(await session.ProposeAsync(quote, true));
        Assert.True(session.IsOpen);
        Assert.Single(fake.Calls, call => call == "send");
        session.SettingsChanged(false);
        Assert.False(session.IsOpen);
    }

    [Theory]
    [InlineData("apiKey", false)]
    [InlineData("apiKey", true)]
    [InlineData("cli", false)]
    [InlineData("cli", true)]
    public async Task ConsentPrecedesAllDiscoveryAndOnlyAnApprovedProposalSends(string group, bool granted)
    {
        var fake = new RecordingConnector();
        var asked = 0;
        using var session = new RewriteSession(Editor(), 10, 12, Envelope(), new(fake, "chosen", "Test", group, ""),
            consent: _ => { Assert.Empty(fake.Calls); asked++; return Task.FromResult(granted); });
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        Assert.Equal(granted, await session.ProposeAsync(action, true));
        Assert.Equal(1, asked);
        Assert.Equal(granted ? 1 : 0, fake.Calls.Count(call => call == "send"));
        if (!granted) Assert.Empty(fake.Calls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RealRewriteProposalNeverSendsWhileConsentIsPendingOrCancelled(bool grant)
    {
        var fake = new RecordingConnector();
        var consent = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var session = new RewriteSession(Editor(), 10, 12, Envelope(), new(fake, "chosen", "Test", "apiKey", ""), consent: _ => consent.Task);
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        var pending = session.ProposeAsync(action, true);
        Assert.False(pending.IsCompleted);
        Assert.DoesNotContain("send", fake.Calls);
        consent.SetResult(grant);
        Assert.Equal(grant, await pending);
        Assert.Equal(grant ? 1 : 0, fake.Calls.Count(call => call == "send"));
    }

    [Theory]
    [InlineData("instruction")]
    [InlineData("words")]
    [InlineData("passage")]
    [InlineData("connector")]
    [InlineData("close")]
    public async Task ChangesDuringConsentNeverDiscoverOrSend(string change)
    {
        var fake = new RecordingConnector();
        var consent = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var currentConnector = true;
        var editor = Editor();
        using var session = new RewriteSession(editor, 10, 12, Envelope(), new(fake, "chosen", "Test", "apiKey", ""),
            consent: _ => consent.Task, connectorIsCurrent: () => currentConnector);
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        var proposing = session.ProposeAsync(action, true);
        Assert.False(await session.ProposeAsync(action, true));
        switch (change)
        {
            case "instruction": await session.SetInstructionAsync("Differently"); break;
            case "words": session.Edit("My typing"); break;
            case "passage": editor.Apply(new EditOperation.Correct("w10", "New passage")); break;
            case "connector": currentConnector = false; break;
            case "close": session.Dispose(); break;
        }
        consent.SetResult(true);
        Assert.False(await proposing);
        Assert.Empty(fake.Calls);
    }

    [Fact]
    public async Task LocalConnectorNeverAsksForConsentAndCloudFailsClosedWithoutIt()
    {
        foreach (var group in new[] { "local", "apiKey" })
        {
            var fake = new RecordingConnector();
            using var session = new RewriteSession(Editor(), 10, 12, Envelope(), new(fake, "chosen", "Test", group, ""));
            await session.SetInstructionAsync("Plainly");
            var action = session.Prepared!;
            session.MarkEstimateShown(action);
            Assert.Equal(group == "local", await session.ProposeAsync(action, true));
            if (group != "local") Assert.Empty(fake.Calls);
        }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task FindClipsAndRewriteShareOneRunInEitherStartOrder(bool rewriteFirst)
    {
        var editor = Editor();
        var fake = new RecordingConnector { Pending = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var session = new RewriteSession(editor, 10, 12, Envelope(), new(fake, "chosen", "Test", "local", ""));
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        if (rewriteFirst)
        {
            var pending = session.ProposeAsync(action, true);
            Assert.True(editor.Busy);
            AssertFindEntries(editor, false, true);
            Assert.Null(editor.LlmRuns.TryAcquire());
            Assert.False(session.CanPropose);
            session.Dispose();
            Assert.False(await pending);
        }
        else
        {
            using (var findRun = editor.LlmRuns.TryAcquire())
            {
                Assert.NotNull(findRun);
                Assert.True(editor.Busy);
                AssertFindEntries(editor, false, true);
                Assert.False(session.CanPropose);
                Assert.False(await session.ProposeAsync(action, true));
                Assert.Empty(fake.Calls);
            }
            Assert.True(session.CanPropose);
        }
        Assert.False(editor.Busy);
        AssertFindEntries(editor, true, false);
        using var next = editor.LlmRuns.TryAcquire();
        Assert.NotNull(next);
        var source = Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "src", "VoxClip.App", "Controls", "FindClipsFlyout.cs");
        var find = File.ReadAllText(source);
        Assert.Contains("using var run = model.LlmRuns.TryAcquire()", find);
        Assert.True(find.IndexOf("model.LlmRuns.TryAcquire()", StringComparison.Ordinal) < find.IndexOf("await ChosenAsync()", find.IndexOf("private async Task FindAsync()", StringComparison.Ordinal), StringComparison.Ordinal));
    }

    private static void AssertFindEntries(EditorViewModel editor, bool enabled, bool busy)
    {
        Assert.Equal(enabled, editor.CanFindClips);
        var shell = new ShellViewModel { NoneFound = "No clips found.", Callout = new("Try again", "", "Retry") };
        shell.Update(editor, false, [], null);
        var action = shell.Rows.Single(row => row.Key == "action:find");
        Assert.Equal(enabled, action.IsEnabled);
        Assert.Equal(busy, action.IsLlmBusy);
        Assert.Equal(enabled, shell.Rows.Single(row => row.Kind == SidebarKind.NoneFound).Edits);
        Assert.Equal(enabled, shell.Rows.Single(row => row.Kind == SidebarKind.Callout).IsEnabled);
        var app = Path.Combine(Path.GetDirectoryName(Shared)!, "apps/windows/src/VoxClip.App");
        var page = File.ReadAllText(Path.Combine(app, "Pages/EditorPage.xaml.cs"));
        Assert.Contains("FindClipsCommand.IsEnabled = ViewModel.CanFindClips", page);
        Assert.Contains("FindClipsBusy.IsActive = ViewModel.LlmRuns.IsBusy", page);
        Assert.Contains("!ViewModel.Busy && !ViewModel.IsLeaving", page);
        Assert.Contains("IsActive=\"{x:Bind IsLlmBusy, Mode=OneWay}\"", File.ReadAllText(Path.Combine(app, "MainWindow.xaml")));
    }

    [Fact]
    public async Task ClosingPendingConsentReleasesTheLeaseWithoutCompletingTheDialog()
    {
        var editor = Editor();
        var fake = new RecordingConnector();
        var dialog = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var session = new RewriteSession(editor, 10, 12, Envelope(), new(fake, "chosen", "Test", "cli", ""), consent: _ => dialog.Task);
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        var proposing = session.ProposeAsync(action, true);
        Assert.True(editor.Busy);
        session.Dispose();
        Assert.False(editor.Busy);
        using var next = editor.LlmRuns.TryAcquire();
        Assert.NotNull(next);
        Assert.False(await proposing.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken));
        Assert.False(dialog.Task.IsCompleted);
        Assert.Empty(fake.Calls);
        Assert.True(editor.Busy);
    }

    [Fact]
    public async Task ClosingAfterDispatchHoldsTheLeaseUntilTheRequestActuallyStops()
    {
        var editor = Editor();
        var fake = new RecordingConnector { Pending = new(TaskCreationOptions.RunContinuationsAsynchronously), IgnoreCancellation = true };
        using var session = new RewriteSession(editor, 10, 12, Envelope(), new(fake, "chosen", "Test", "local", ""));
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        var proposing = session.ProposeAsync(action, true);
        Assert.Contains("send", fake.Calls);
        session.Dispose();
        Assert.True(editor.Busy);
        Assert.Null(editor.LlmRuns.TryAcquire());
        Assert.False(proposing.IsCompleted);
        fake.Pending.SetResult(new(null, new JsonObject { ["rewrite"] = "Late answer" }, "chosen", new StopKind.Complete(), null, "fake"));
        Assert.False(await proposing);
        Assert.False(editor.Busy);
        using var next = editor.LlmRuns.TryAcquire();
        Assert.NotNull(next);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ProposalSuccessAndFailureBothReleaseTheProjectRun(bool fail)
    {
        var editor = Editor();
        var fake = new RecordingConnector { Failure = fail ? new IOException("offline") : null };
        using var session = new RewriteSession(editor, 10, 12, Envelope(), new(fake, "chosen", "Test", "local", ""));
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        Assert.Equal(!fail, await session.ProposeAsync(action, true));
        Assert.False(editor.Busy);
        using var next = editor.LlmRuns.TryAcquire();
        Assert.NotNull(next);
    }

    [Fact]
    public async Task ProjectRunIsAtomicAndAConcurrentFindCancellationReleasesIt()
    {
        var runs = new ProjectLlmRuns();
        using var ready = new CountdownEvent(8);
        using var release = new ManualResetEventSlim();
        var winners = 0;
        var tasks = Enumerable.Range(0, 8).Select(_ => Task.Run(() =>
        {
            using var run = runs.TryAcquire();
            if (run is not null) Interlocked.Increment(ref winners);
            ready.Signal();
            release.Wait(TestContext.Current.CancellationToken);
        }, TestContext.Current.CancellationToken)).ToArray();
        try { Assert.True(ready.Wait(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken)); Assert.Equal(1, winners); }
        finally { release.Set(); await Task.WhenAll(tasks); }
        Assert.False(runs.IsBusy);
        using var cancellation = new CancellationTokenSource();
        async Task FindAsync()
        {
            using var run = runs.TryAcquire();
            Assert.NotNull(run);
            await Task.Delay(Timeout.Infinite, cancellation.Token);
        }
        var find = FindAsync();
        Assert.Null(runs.TryAcquire());
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => find);
        Assert.False(runs.IsBusy);
        using var resumed = runs.TryAcquire();
        Assert.NotNull(resumed);
    }

    [Theory]
    [InlineData("selection", false)]
    [InlineData("selection-away-and-back", false)]
    [InlineData("caret", false)]
    [InlineData("project", false)]
    [InlineData("outline", true)]
    [InlineData("unchanged", true)]
    public async Task DelayedOpeningNeverUsesAnOldSelectionOrCaret(string change, bool opens)
    {
        var editor = Editor();
        editor.Select(10); editor.Select(12, true);
        var opening = new RewriteOpening(editor, null);
        var loading = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<RewriteSession?> OpenAsync()
        {
            await loading.Task;
            return opening.IsCurrent ? new RewriteSession(editor, opening.First, opening.Last, Envelope(), null, opening.InsertionAfter) : null;
        }
        var pending = OpenAsync();
        switch (change)
        {
            case "selection": editor.Select(20); break;
            case "selection-away-and-back": editor.Select(20); editor.Select(10); editor.Select(12, true); break;
            case "caret": editor.RewriteCaretChanged(); break;
            case "project": editor.Apply(new EditOperation.Correct("w10", "changed")); break;
            case "outline": editor.SetRewriteRange(1, 2); break;
        }
        loading.SetResult();
        using var session = await pending;
        Assert.Equal(opens, session is not null);
        if (opens) Assert.Equal("word10 word11 word12", session!.NewWords);
        else Assert.Equal(-1, editor.RewriteStart);
        var app = Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "src", "VoxClip.App");
        Assert.Contains("!passage.IsCurrent", File.ReadAllText(Path.Combine(app, "Pages", "EditorPage.xaml.cs")));
        Assert.Contains("model?.RewriteCaretChanged()", File.ReadAllText(Path.Combine(app, "Controls", "TranscriptView.cs")));
    }

    private sealed class RecordingConnector : ILlmConnector
    {
        internal List<string> Calls { get; } = [];
        internal Exception? Failure { get; set; }
        internal TaskCompletionSource<RawCompletion>? Pending { get; init; }
        internal bool IgnoreCancellation { get; init; }
        public ConnectorId Id => ConnectorId.OpenAI;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) { Calls.Add("status"); return Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready()); }
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct)
        { Calls.Add("models"); return Task.FromResult<IReadOnlyList<LlmModel>>([new("chosen", "Chosen", null, 32768, ModelSource.Discovered)]); }
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) { Calls.Add("context"); return Task.FromResult<int?>(32768); }
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            Calls.Add("send");
            if (Failure is not null) return Task.FromException<RawCompletion>(Failure);
            return (IgnoreCancellation ? Pending?.Task : Pending?.Task.WaitAsync(ct)) ?? Task.FromResult(new RawCompletion(null, new JsonObject { ["rewrite"] = "Better passage" }, model, new StopKind.Complete(), null, "fake"));
        }
    }
    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public void EveryEntryRespectsTheReleaseGate(int entryIndex)
    {
        var entry = (RewriteEntry)entryIndex;
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(entry, true, true, true, true, false));
        Assert.Equal(entry == RewriteEntry.InsertWords ? RewriteEntryAction.Unavailable : RewriteEntryAction.OpenPassage,
            RewriteEntryPolicy.Resolve(entry, true, true, true, true, true));
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(entry, true, false, true, true, true));
    }

    [Fact]
    public void DisabledVoiceLabOnlyOffersTheOneTimeOverflowFlow()
    {
        foreach (var entry in Enum.GetValues<RewriteEntry>())
            Assert.Equal(entry == RewriteEntry.Overflow ? RewriteEntryAction.TurnOnVoiceLab : RewriteEntryAction.Unavailable,
                RewriteEntryPolicy.Resolve(entry, false, true, true, true, true));
        Assert.Equal(RewriteEntryAction.Unavailable, RewriteEntryPolicy.Resolve(RewriteEntry.InsertWords, true, true, true, false, true));
        Assert.True(RewriteEntryPolicy.BetweenWords([Word(0, "one"), Word(1, "two")], 0));
        Assert.False(RewriteEntryPolicy.BetweenWords([Word(0, "one"), Word(1, "[event]", WordKind.Event)], 0));
        Assert.False(RewriteEntryPolicy.BetweenWords([Word(0, "one")], 0));
#if !DEBUG
        Assert.False(RewriteEntryPolicy.BuildEnabled);
#endif
    }

    [Fact]
    public async Task ApprovedFallbackCopyAndConnectorTitlesMatchDesign()
    {
        using var missing = new RewriteSession(Editor(), 10, 12, null, null);
        Assert.Equal("Choose a connector in Settings → AI.", missing.SendLine);
        Assert.Equal("This change can't be placed in this take. Your edits are saved.",
            RewriteSession.Refusal(new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InvalidInput)));
        Assert.Equal("Inserting words isn't available yet. Your edits are saved.",
            RewriteSession.Refusal(new VoiceLabGeometryException(VoiceLabGeometryErrorCode.InsertionUnsupported)));
        foreach (var group in new[] { "local", "cli" })
        {
            using var session = new RewriteSession(Editor(), 10, 12, Envelope(), new(new RecordingConnector(), "chosen", "Test", group, "ChatGPT plan"));
            await session.SetInstructionAsync("Plainly");
            Assert.Equal(group == "local" ? "Rewrite · No charge" : "Rewrite", session.ProposalButton);
        }
        using var video = new RewriteSession(Editor(), 10, 12, null, new(new RecordingConnector(), "chosen", "Test", "local", ""));
        await video.SetInstructionAsync("Plainly");
        Assert.Equal("Find the original video before rewriting speech. Your edits are saved.", video.Problem);
    }
}
#endif
