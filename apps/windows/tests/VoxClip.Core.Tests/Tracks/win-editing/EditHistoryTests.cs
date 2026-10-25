using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinEditing.EditingFixtureTests;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class EditHistoryTests
{
    [Fact]
    public void AiContextRejectsBadReferencesAndBatchesWithoutChangingHistory()
    {
        var project = TestStorage.ProjectFixture();
        var result = project.Ai.Results[0];
        var state = State(project.Transcript!.Words);
        var word = state.Transcript.Words[0].Id;
        var history = new EditHistory(state, [], []).Apply(new EditOperation.Toggle(word), project.Ai.Results).Undo();
        var references = new (string? Id, int? Index)[] { (result.Id, -1), (result.Id, result.Clips.Count),
            (result.Id, int.MaxValue), ("missing-result", 0), (null, 0), ("bad/id", 0) };
        foreach (var (id, index) in references)
        {
            var operation = new EditOperation.AddClip(new("invalid-reference", word, word, null, ClipOrigin.Ai, id, index, true));
            Assert.Same(state, EditingEngine.Reduce(state, operation, project.Ai.Results));
            Assert.Same(history, history.Apply(operation, project.Ai.Results));
        }
        var prepared = Enumerable.Range(0, result.Clips.Count + 1).Select(index => new AiClip("prepared-" + index, "reason", 80, word, word)).ToArray();
        foreach (var operation in new[] { new EditOperation.AddAiClips(result.Id, prepared), new EditOperation.AddAiClips("missing-result", [prepared[0]]) })
        {
            Assert.Same(state, EditingEngine.Reduce(state, operation, project.Ai.Results));
            Assert.Same(history, history.Apply(operation, project.Ai.Results));
        }
        var valid = new ClipRange("valid-reference", word, word, null, ClipOrigin.Ai, result.Id, result.Clips.Count - 1, true);
        foreach (var operation in new EditOperation[] { new EditOperation.AddClip(valid),
            new EditOperation.AddClip(valid with { AiClipIndex = null }), new EditOperation.AddClip(valid with { AiResultId = null, AiClipIndex = null }),
            new EditOperation.AddAiClips(result.Id, [prepared[0]]) })
        {
            var next = history.Apply(operation, project.Ai.Results);
            Assert.Single(next.Present.Clips);
            Assert.Equal([state], next.UndoStack);
            Assert.Empty(next.RedoStack);
            Assert.Same(state, next.Undo().Present);
            Assert.Same(next.Present, next.Undo().Redo().Present);
        }
        var withoutContext = new EditOperation.AddClip(valid with { AiResultId = "missing-result" });
        Assert.Single(EditingEngine.Reduce(state, withoutContext).Clips);
        Assert.Same(state, EditingEngine.Reduce(state, withoutContext, []));
    }

    [Fact]
    public void IgnoredCommandsPreserveStateUndoAndRedoByIdentity()
    {
        var state = State([Word("a", "first", 0, 1), Word("b", "second", 2, 3)]) with {
            Clips = [new("clip", "a", "b", "title", ClipOrigin.Manual, null, null, true)] };
        var history = new EditHistory(state, [], []).Apply(new EditOperation.Toggle("a")).Undo();
        EditOperation[] ignored = [new EditOperation.Toggle("missing"), new EditOperation.CutSelection([]),
            new EditOperation.RestoreSelection(["a"]), new EditOperation.SetWordCuts(["missing"], true),
            new EditOperation.SetPauseCuts(["missing"], true), new EditOperation.Correct("a", "first"),
            new EditOperation.Correct("a", " "), new EditOperation.Correct("missing", "text"),
            new EditOperation.SetPauseKeep(5), new EditOperation.SetPauseKeep(state.PauseKeepSeconds),
            new EditOperation.SetPauseThreshold(state.PauseThresholdSeconds), new EditOperation.SetActiveClip("missing"),
            new EditOperation.SetActiveClip(null), new EditOperation.UpdateClip("missing", 0, 1),
            new EditOperation.UpdateClip("clip", 0, 1), new EditOperation.RenameClip("missing", "name"),
            new EditOperation.RenameClip("clip", "title"), new EditOperation.RenameClip("clip", new string('x', 201)),
            new EditOperation.SetClipSelected("missing", true), new EditOperation.SetClipSelected("clip", true),
            new EditOperation.RemoveClip("missing"), new EditOperation.RestoreCuts(), new EditOperation.CutFillers()];
        foreach (var operation in ignored)
        {
            Assert.Same(state, EditingEngine.Reduce(state, operation));
            Assert.Same(history, history.Apply(operation));
            Assert.Same(history.UndoStack, history.Apply(operation).UndoStack);
            Assert.Same(history.RedoStack, history.Apply(operation).RedoStack);
        }
        var empty = State([Word("a", "word", 0, 1)]);
        Assert.Same(empty, EditingEngine.Reduce(empty, new EditOperation.ReplaceTranscript(empty.Transcript)));
    }

    [Fact]
    public void HistoryRetainsOnlyTheMostRecentFiveHundredSteps()
    {
        var history = new EditHistory(State([Word("a", "word", 0, 1)]), [], []);
        var snapshots = new List<EditState>();
        for (var index = 0; index < 510; index++)
        {
            snapshots.Add(history.Present);
            history = history.Apply(new EditOperation.Toggle("a"));
            Assert.True(history.UndoStack.Count <= 500);
        }
        Assert.Equal(500, history.UndoStack.Count);
        Assert.Same(snapshots[10], history.UndoStack[0]);
        var latest = history.Present;
        for (var index = 0; index < 500; index++) history = history.Undo();
        Assert.Same(snapshots[10], history.Present);
        Assert.Same(history, history.Undo());
        for (var index = 0; index < 500; index++) history = history.Redo();
        Assert.Same(latest, history.Present);
        Assert.Equal(500, history.UndoStack.Count);
    }
}
