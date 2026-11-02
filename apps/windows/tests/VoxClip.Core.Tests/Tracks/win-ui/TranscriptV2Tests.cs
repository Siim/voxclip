#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class TranscriptV2Tests
{
    private static TimedWord[] Words(params string[] text) => text.Select((word, index) =>
        new TimedWord("word-" + index, word, WordKind.Word, index * 0.5, index * 0.5 + 0.3, null, null, null, "speaker", TimingSource.Native)).ToArray();

    private static IReadOnlyList<TranscriptPiece> Present(TimedWord[] words, IReadOnlySet<string>? cuts = null,
        bool showCuts = false, IReadOnlyDictionary<int, Pause>? pauses = null, IReadOnlySet<string>? cutPauses = null,
        int clipFirst = 0, int clipLast = int.MaxValue, IReadOnlySet<string>? expanded = null,
        TranscriptProposalPresentation? proposal = null, int selectedFirst = -1, int selectedLast = -1) =>
        TranscriptParagraphPresentation.Build(words, 0, words.Length,
            index => new(words[index].Text, false, false, true, index), cuts ?? new HashSet<string>(), cutPauses ?? new HashSet<string>(),
            pauses ?? new Dictionary<int, Pause>(), clipFirst, clipLast, showCuts, true, expanded ?? new HashSet<string>(),
            proposal ?? TranscriptProposalPresentation.Empty, selectedFirst, selectedLast);

    [Fact]
    public void ConsecutiveFillersAndAPauseHaveOneFoldAndOriginalIdsStayUntouched()
    {
        var words = Words("include,", "uh,", "um,", "source");
        var original = words.ToArray();
        var pause = new Pause("gap", 1, 0.8, 2.2, 1.4, "pause 1.4s");
        var pieces = Present(words, new HashSet<string> { words[1].Id, words[2].Id }, pauses: new Dictionary<int, Pause> { [1] = pause },
            cutPauses: new HashSet<string> { pause.Id });
        var fold = Assert.Single(pieces, piece => piece.Kind == TranscriptPieceKind.Fold);
        Assert.Equal("include", pieces[0].Text);
        Assert.Equal(new[] { words[1].Id, words[2].Id }, fold.WordIds);
        Assert.Equal(new[] { pause.Id }, fold.PauseIds);
        Assert.Contains("pause 1.4 seconds", fold.FoldName);
        Assert.Equal(1, fold.First); Assert.Equal(2, fold.Last);
        Assert.Equal(original, words);
    }

    [Fact]
    public void ShowCutsKeepsAllSourceWordsAndPauseLengthsWithoutLegacyTokens()
    {
        var words = Words("include,", "uh,", "source");
        var pieces = Present(words, new HashSet<string> { words[1].Id }, showCuts: true,
            pauses: new Dictionary<int, Pause> { [1] = new("gap", 1, 0.8, 2.2, 1.4, "pause 1.4s") }, cutPauses: new HashSet<string> { "gap" });
        Assert.DoesNotContain(pieces, piece => piece.Kind == TranscriptPieceKind.Fold);
        Assert.Equal(3, pieces.Count(piece => piece.Selectable));
        Assert.Equal(", ", Assert.Single(pieces, piece => piece.Kind == TranscriptPieceKind.Comma).Text);
        Assert.Equal("1.4\u00a0s ", Assert.Single(pieces, piece => piece.Kind == TranscriptPieceKind.Pause).Text);
        Assert.DoesNotContain(pieces, piece => piece.Text.Contains('‖') || piece.Text.Contains("⋯", StringComparison.Ordinal));
    }

    [Fact]
    public void OutsideClipWordsNeverFoldOrAcquireProposalOrPauseMarkers()
    {
        var words = Words("before", "old", "inside", "after");
        var diff = VoiceLabWordDiff.Diff(words, "before new inside after");
        var proposal = TranscriptProposalPresentation.From(diff, words, words);
        var pieces = Present(words, new HashSet<string> { words[0].Id, words[1].Id, words[3].Id }, clipFirst: 2, clipLast: 2,
            pauses: new Dictionary<int, Pause> { [1] = new("gap", 1, 0.8, 2.2, 1.4, "pause 1.4s") }, proposal: proposal);
        Assert.DoesNotContain(pieces, piece => piece.Kind is TranscriptPieceKind.Fold or TranscriptPieceKind.Pause or TranscriptPieceKind.Inserted);
        Assert.All(pieces.Where(piece => piece.Outside), piece => { Assert.False(piece.Removed); Assert.Null(piece.Change); });
        Assert.Equal(4, pieces.Count(piece => piece.Selectable));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ASelectedCutStaysVisibleEvenWhenNewlyVirtualized(bool highContrast)
    {
        var words = Words("start", "uh", "finish");
        var pieces = Present(words, new HashSet<string> { words[1].Id }, selectedFirst: 1, selectedLast: 1);
        Assert.DoesNotContain(pieces, piece => piece.Kind == TranscriptPieceKind.Fold);
        Assert.Contains(pieces, piece => piece.Selectable && piece.First == 1 && piece.Removed);
        var selection = TranscriptWordHighlight.For(true, true, highContrast);
        Assert.Equal(highContrast ? "VcSelectionTranscriptBrush" : "VcTintSelectionBrush", selection?.BackgroundBrush);
        Assert.Equal(highContrast ? "SystemColorHighlightTextColor" : "VcTextPrimaryBrush", selection?.ForegroundBrush);
    }

    [Fact]
    public void ExpandingOneFoldDoesNotExpandTheOther()
    {
        var words = Words("start", "uh", "middle", "um", "finish");
        var pieces = Present(words, new HashSet<string> { words[1].Id, words[3].Id }, expanded: new HashSet<string> { words[1].Id });
        Assert.Contains(pieces, piece => piece.Selectable && piece.First == 1);
        Assert.Equal(3, Assert.Single(pieces, piece => piece.Kind == TranscriptPieceKind.Fold).First);
    }

    [Fact]
    public void RealDiffInsertionsHaveNoSourceIdAndDoNotHideTheirOriginalWords()
    {
        var words = Words("We", "make", "old", "clips", "today");
        var diff = VoiceLabWordDiff.Diff(words, "We make bright clips today");
        var proposal = TranscriptProposalPresentation.From(diff, words, words);
        var pieces = Present(words, proposal: proposal);
        var inserted = Assert.Single(pieces, piece => piece.Kind == TranscriptPieceKind.Inserted);
        Assert.Equal("bright ", inserted.Text);
        Assert.Equal(-1, inserted.First); Assert.Equal(-1, inserted.Last);
        Assert.Null(inserted.WordIds); Assert.False(inserted.Selectable);
        Assert.NotNull(inserted.Change);
        Assert.Contains(pieces, piece => piece.Selectable && piece.First == 2 && piece.Removed);
        Assert.Equal(words.Length, pieces.Count(piece => piece.Selectable));
    }

    [Fact]
    public void InsertionsAtBothEndsUseSourceTokenOwnersWithoutInventingIds()
    {
        var words = Words("original", "words");
        foreach (var text in new[] { "new original words", "original words new" })
        {
            var diff = VoiceLabWordDiff.Diff(words, text);
            var proposal = TranscriptProposalPresentation.From(diff, words, words);
            var pieces = Present(words, proposal: proposal);
            Assert.Single(pieces, piece => piece.Kind == TranscriptPieceKind.Inserted);
            Assert.Equal(text, string.Join(" ", pieces.Where(piece => !piece.Removed).Select(piece => piece.Text.Trim())));
            Assert.All(pieces.Where(piece => piece.Kind == TranscriptPieceKind.Inserted), piece => Assert.Equal(-1, piece.First));
        }
    }

    [Fact]
    public void MergedHunkBridgesAreNotInsertedTwice()
    {
        var words = Words("we", "old", "and", "stale", "clips");
        var diff = VoiceLabWordDiff.Diff(words, "we new and fresh clips");
        var proposal = TranscriptProposalPresentation.From(diff, words, words);
        var pieces = Present(words, proposal: proposal);
        Assert.DoesNotContain(pieces, piece => piece.Kind == TranscriptPieceKind.Inserted && piece.Text.Split(' ').Contains("and"));
        Assert.Contains(pieces, piece => piece.First == 2 && piece.Selectable && !piece.Removed);
        Assert.Equal("we new and fresh clips", string.Join(" ", pieces.Where(piece => !piece.Removed).Select(piece => piece.Text.Trim())));
    }

    [Fact]
    public void ACorrectedMultiTokenSourceWordKeepsOneOriginalOwnerAndAllUnchangedTokens()
    {
        var words = Words("old words", "today");
        var diff = VoiceLabWordDiff.Diff(words, "new words today");
        var proposal = TranscriptProposalPresentation.From(diff, words, words);
        var pieces = Present(words, proposal: proposal);
        Assert.Equal("new words ", Assert.Single(pieces, piece => piece.Kind == TranscriptPieceKind.Inserted).Text);
        Assert.Equal("new words today", string.Join(" ", pieces.Where(piece => !piece.Removed).Select(piece => piece.Text.Trim())));
        Assert.Equal(words[0].Id, Assert.Single(pieces, piece => piece.First == 0 && piece.Selectable).WordIds![0]);
    }

    [Fact]
    public void PunctuationOnlyChangesStayOutOfTheBufferButKeepThePanelOrdinals()
    {
        var words = Words("hello", "old", "world");
        var diff = VoiceLabWordDiff.Diff(words, "hello, new world");
        var proposal = TranscriptProposalPresentation.From(diff, words, words);
        Assert.Equal(diff.Hunks.Count, proposal.TotalCount);
        Assert.DoesNotContain(proposal.Hunks, hunk => hunk.Hunk.Kind == VoiceLabDiffHunkKind.TextOnly);
        Assert.All(proposal.Hunks, hunk => Assert.Equal(diff.Hunks[hunk.Ordinal - 1], hunk.Hunk));
    }

    [Fact]
    public void ExcludedAndKeptChangesNeverLeaveDisplayOnlyTextBehind()
    {
        var words = Words("we", "old", "clips");
        var diff = VoiceLabWordDiff.Diff(words, "we new clips");
        foreach (var state in new[] { TranscriptChangeState.Excluded, TranscriptChangeState.Kept })
        {
            var proposal = TranscriptProposalPresentation.From(diff, words, words, states: new Dictionary<int, TranscriptChangeState> { [1] = state });
            var pieces = Present(words, proposal: proposal);
            Assert.DoesNotContain(pieces, piece => piece.Kind == TranscriptPieceKind.Inserted || piece.Removed);
            if (state == TranscriptChangeState.Excluded) Assert.Equal(state, Assert.Single(proposal.Hunks).State);
            else Assert.Empty(proposal.Hunks);
        }
    }

    [Fact]
    public void Utf16HitRangesSkipInsertedTextAndNeverFallBackToThePreviousWord()
    {
        TranscriptTextSpan[] spans = [new(1, 5, 3, 3), new(5, 10, -1, -1, 2), new(12, 17, 4, 6)];
        Assert.Equal(3, TranscriptTextRanges.Hit(spans, 4)?.SourceIndex);
        Assert.Equal(-1, TranscriptTextRanges.Hit(spans, 5)?.SourceIndex);
        Assert.Equal(2, TranscriptTextRanges.Hit(spans, 9)?.ChangeOrdinal);
        Assert.Null(TranscriptTextRanges.Hit(spans, 10));
        Assert.Equal(6, TranscriptTextRanges.Hit(spans, 16)?.LastSourceIndex);
        Assert.Null(TranscriptTextRanges.Hit(spans, 17));
    }

    [Fact]
    public void ProjectionReadsOnlyItsSharedBoundedParagraph()
    {
        var words = Words(Enumerable.Repeat("word", 10_000).ToArray());
        var range = TranscriptParagraphs.Split(words)[30];
        var (start, count) = range.GetOffsetAndLength(words.Length);
        var reads = 0;
        var pieces = TranscriptParagraphPresentation.Build(words, start, count, index =>
        {
            Assert.InRange(index, start, start + count - 1);
            reads++;
            return new(words[index].Text, false, false, true, index);
        }, new HashSet<string>(), new HashSet<string>(), new Dictionary<int, Pause>(), 0, words.Length - 1, false, false,
            new HashSet<string>(), TranscriptProposalPresentation.Empty);
        Assert.Equal(count, reads); Assert.InRange(reads, 1, TranscriptParagraphs.MaximumWords);
        Assert.Equal(count, pieces.Count);
    }

    [Fact]
    public void RepeatedPaintUsesCachedGeometryUntilAnExplicitInvalidation()
    {
        var cache = new TranscriptGeometryCache<string, int>();
        var measurements = 0;
        for (var frame = 0; frame < 100; frame++)
        {
            cache.BeginDraw();
            Assert.Equal(new[] { 17 }, cache.Get("source", true, _ => { measurements++; return new[] { 17 }; }));
        }
        Assert.Equal(1, measurements);
        cache.Invalidate(); cache.BeginDraw();
        cache.Get("source", true, _ => { measurements++; return new[] { 19 }; });
        Assert.Equal(2, measurements);
    }

    [Fact]
    public void TranscriptProductionSurfaceHasNoPopupOrUnsupportedInsertionCommand()
    {
        var root = RepositoryRoot();
        var directory = Path.Combine(root, "apps/windows/src/VoxClip.App/Controls");
        var view = File.ReadAllText(Path.Combine(directory, "TranscriptView.cs"));
        var presentation = File.ReadAllText(Path.Combine(directory, "TranscriptView.Presentation.cs"));
        var editing = File.ReadAllText(Path.Combine(directory, "TranscriptView.InlineEditing.cs"));
        var implementation = view + presentation + editing;
        Assert.DoesNotContain("new Popup", implementation);
        Assert.DoesNotContain("Insert Words…", implementation);
        Assert.DoesNotContain("new TextHighlighter", implementation);
        Assert.Contains("TextCompositionStarted", editing);
        Assert.Contains("TextCompositionEnded", editing);
        Assert.Contains("ReferenceEquals(expectedProject, model.Project)", editing);
        Assert.Contains("new EditOperation.SetWordCuts", editing);
        Assert.Contains("new EditOperation.SetPauseCuts", editing);
        Assert.Contains("TranscriptParagraphPresentation.Build", presentation);
        Assert.Contains("TranscriptTextRanges.Hit(visual.TextMap", view);
        Assert.Contains("FrameProbePrepared", presentation);
    }

    [Fact]
    public void FoldRestoreIsOneExistingHistoryStepAndNeverRewritesSourceTimings()
    {
        var file = Path.Combine(RepositoryRoot(), "shared/fixtures/projects/interview-take.voxclip");
        var project = ProjectSerialization.Deserialize(File.ReadAllText(file));
        var editor = new EditorViewModel(project);
        var words = editor.Words.ToArray();
        string[] ids = [words[1].Id, words[2].Id];
        Assert.True(editor.Apply(new EditOperation.SetWordCuts(ids, true)));
        var cut = editor.State!;
        Assert.True(editor.ApplyBatch([new EditOperation.SetWordCuts(ids, false), new EditOperation.SetPauseCuts([], false)]));
        Assert.All(ids, id => Assert.DoesNotContain(id, editor.State!.CutWordIds));
        editor.Undo();
        Assert.Equal(cut.CutWordIds.Order(), editor.State!.CutWordIds.Order());
        Assert.Equal(words, editor.Words);
    }

    private static string RepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "shared/fixtures/projects/interview-take.voxclip"))) return directory.FullName;
        throw new FileNotFoundException("Shared transcript fixture not found.");
    }
}
#endif
