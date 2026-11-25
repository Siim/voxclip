#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class HarnessReviewTests
{
    [Fact]
    public async Task KeepingAnIllustrationDoesNotSendAndOnlyItsQuotedClickCanGenerate()
    {
        using var review = new ReviewProject();
        var sends = 0;
        review.Editor.AskClaudeServices = new AskClaudeServices
        {
            Ask = (_, _) => throw new InvalidOperationException("The harness must not ask the connector."),
            Available = () => true,
            CostLine = () => "Fixture only",
            Assets = new(0.03m, _ => Task.FromResult<string?>("fixture"), (_, _) => null,
                (_, _, _) => throw new InvalidOperationException("No sound was requested."), (_, _, _, _) =>
                {
                    sends++;
                    return Task.FromResult(JsonSerializer.SerializeToElement(new
                    {
                        id = "fixture-illustration", clipId = "clip-2f1c", kind = "illustration", start = 1.0, end = 1.2,
                        imageFile = $"{review.Editor.Project.Id}/illustration-{new string('f', 64)}.png"
                    }));
                })
        };
        review.Stage("""
            {"clipId":"clip-2f1c","reason":"Show the scene.","effects":[{"kind":"illustration","startWord":9,"endWord":9,
                "prompt":"A lighthouse","reason":"Show the place."}]}
            """);
        var pending = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        Assert.Null(review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot, out var assets));
        Assert.False(review.Editor.CanUndo);
        Assert.Equal(0, sends);
        var asset = Assert.Single(assets);
        var snapshot = review.Editor.Project;
        Assert.False(await review.Editor.ApplyHarnessAssetAsync(asset, snapshot, 0.01m, TestContext.Current.CancellationToken));
        Assert.Equal(0, sends);
        Assert.True(await review.Editor.ApplyHarnessAssetAsync(asset, snapshot, 0.03m, TestContext.Current.CancellationToken));
        Assert.Equal(1, sends);
        Assert.True(review.Editor.CanUndo);
    }

    [Fact]
    public void KeepingThePendingTimelineIsOneUndoableEditAndDoesNotGenerateMusic()
    {
        using var review = new ReviewProject();
        review.Stage();
        var pending = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        var details = review.Editor.DescribeHarnessProposal(pending, FixtureLoader.SharedRoot);
        Assert.Null(details.Blocked);
        Assert.Equal("Make the point clear.", details.Reason);
        Assert.Contains("Title card “A faster edit”: Name the point.", details.Changes);
        Assert.Equal("A warm instrumental", details.MusicPrompt);
        Assert.StartsWith("$", details.MusicEstimate);

        var music = review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot);

        Assert.Equal(("clip-2f1c", "A warm instrumental"), (music?.ClipId, music?.Prompt));
        Assert.Equal("Keep timeline proposal", review.Editor.UndoActionName);
        Assert.Equal("A faster edit", review.Editor.Project.Edits.Clips[0].Title);
        Assert.Equal("titleCard", Assert.Single(review.Editor.Project.ClipEffects).GetProperty("template").GetProperty("name").GetString());
        Assert.Equal(review.Original.Music.ToArray(), review.Editor.Project.Music.ToArray());
        Assert.Equal(MusicPanelPhase.Idle, review.Editor.Music.Phase);
        Assert.Null(review.Editor.ReadHarnessProposal(review.Path));
        Assert.Equal(review.OriginalText, File.ReadAllText(review.Path));

        review.Editor.Undo();
        Assert.Equal(review.Original.Edits.Clips.ToArray(), review.Editor.Project.Edits.Clips.ToArray());
        Assert.Empty(review.Editor.Project.ClipEffects);
        Assert.False(review.Editor.CanUndo);
        Assert.Null(review.Editor.ReadHarnessProposal(review.Path));
    }

    [Fact]
    public void UnsavedEditsMakeTheProposalStaleButUndoCanDismissIt()
    {
        using var review = new ReviewProject();
        review.Stage();
        var pending = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        Assert.True(review.Editor.Apply(new EditOperation.RenameClip("clip-2f1c", "Creator's edit")));
        var edited = review.Editor.Project;

        Assert.Contains("project changed", review.Editor.DescribeHarnessProposal(pending, FixtureLoader.SharedRoot).Blocked);
        Assert.Contains("project changed", Assert.Throws<HarnessException>(() =>
            review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot)).Message);
        Assert.Same(edited, review.Editor.Project);
        Assert.True(pending.Matches(review.Editor.ReadHarnessProposal(review.Path)));

        review.Editor.DismissHarnessProposal(pending, review.Path);
        Assert.Same(edited, review.Editor.Project);
        Assert.Null(review.Editor.ReadHarnessProposal(review.Path));
        review.Editor.Undo();
        Assert.False(review.Editor.CanUndo);
        Assert.Throws<HarnessException>(() => review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot));
        Assert.False(review.Editor.CanUndo);
    }

    [Fact]
    public void KeepAndUndoCannotConsumeAReplacementEvenWithTheSameId()
    {
        using var review = new ReviewProject();
        review.Stage();
        var pending = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        var changed = pending.ToJson();
        changed["timeline"]!["title"] = "Not the reviewed title";
        File.WriteAllText(review.Sidecar, changed.ToJsonString());

        Assert.Throws<HarnessException>(() => review.Editor.DismissHarnessProposal(pending, review.Path));
        Assert.Throws<HarnessException>(() => review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot));
        Assert.Equal(changed.ToJsonString(), File.ReadAllText(review.Sidecar));
        Assert.False(review.Editor.CanUndo);
    }

    [Fact]
    public void ReadOnlyAndBusyEditorsCannotKeepTheProposal()
    {
        using var review = new ReviewProject();
        review.Stage();
        var pending = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        review.Editor.SetMediaUnavailable(true);
        Assert.Throws<HarnessException>(() => review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot));
        review.Editor.SetMediaUnavailable(false);
        review.Editor.Busy = true;
        Assert.Throws<HarnessException>(() => review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot));
        Assert.True(pending.Matches(review.Editor.ReadHarnessProposal(review.Path)));
        Assert.False(review.Editor.CanUndo);
    }

    [Fact]
    public void SelectingAnotherClipDoesNotInvalidateTheProposalOrSwitchTabsOnKeep()
    {
        using var review = new ReviewProject();
        review.Stage();
        var pending = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        Assert.True(review.Editor.SetScope("clip-9a0b"));

        review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot);

        Assert.Equal("clip-9a0b", review.Editor.Project.Edits.ActiveClipId);
        Assert.Equal("A faster edit", review.Editor.Project.Edits.Clips[0].Title);
    }

    [Fact]
    public void AForeignOrMalformedSidecarCannotEditTheProject()
    {
        using var review = new ReviewProject();
        review.Stage();
        var wire = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path)).ToJson();
        wire["projectId"] = "a-different-project";
        File.WriteAllText(review.Sidecar, wire.ToJsonString());
        var foreign = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        Assert.Throws<HarnessException>(() => review.Editor.KeepHarnessProposal(foreign, review.Path, FixtureLoader.SharedRoot));

        wire["approved"] = true;
        File.WriteAllText(review.Sidecar, wire.ToJsonString());
        Assert.Throws<HarnessException>(() => review.Editor.ReadHarnessProposal(review.Path));
        File.WriteAllBytes(review.Sidecar, new byte[HarnessProposal.MaximumBytes + 1]);
        Assert.Contains("too large", Assert.Throws<HarnessException>(() => review.Editor.ReadHarnessProposal(review.Path)).Message);
        Assert.False(review.Editor.CanUndo);
        Assert.Equal(review.OriginalText, File.ReadAllText(review.Path));
    }

    [Fact]
    public void ABriefWithoutFreeEditsDoesNotCreateAnUndoStep()
    {
        using var review = new ReviewProject();
        review.Stage("""{"clipId":"clip-2f1c","reason":"Set the mood.","generateMusic":"A warm instrumental"}""");
        var pending = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));

        Assert.NotNull(review.Editor.KeepHarnessProposal(pending, review.Path, FixtureLoader.SharedRoot));
        Assert.Null(review.Editor.ReadHarnessProposal(review.Path));
        Assert.Same(review.Original, review.Editor.Project);
        Assert.False(review.Editor.CanUndo);
        Assert.Equal(MusicPanelPhase.Idle, review.Editor.Music.Phase);
    }

    [Fact]
    public void SeriesCanKeepAndDismissIndividualTimelinesWithOneUndoEach()
    {
        using var review = new ReviewProject();
        using var cases = FixtureLoader.ReadJson("fixtures/clips-mode/harness-proposal-cases.json");
        var story = HarnessTimeline.Read(cases.RootElement.GetProperty("story"));
        var title = HarnessTimeline.Read(JsonSerializer.SerializeToElement(new { clipId = "clip-2f1c", title = "A faster edit", reason = "Clarify the point." }));
        var series = new HarnessProposal([story, title, title], review.Original);
        File.WriteAllText(review.Sidecar, series.ToJson().ToJsonString());

        review.Editor.DismissHarnessProposal(series, review.Path, 2);
        var two = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        Assert.Equal(2, two.Timelines.Count);
        Assert.False(review.Editor.CanUndo);
        Assert.Equal("Result first", review.Editor.DescribeHarnessProposal(two, FixtureLoader.SharedRoot, 0).ClipTitle);
        review.Editor.KeepHarnessTimeline(two, review.Path, FixtureLoader.SharedRoot, 1, out _, out _);
        Assert.Equal("A faster edit", review.Editor.Project.Edits.Clips[0].Title);
        var one = Assert.IsType<HarnessProposal>(review.Editor.ReadHarnessProposal(review.Path));
        Assert.Equal(two.ClipIdAt(0), one.ClipIdAt(0));
        Assert.Single(one.Timelines);

        review.Editor.KeepHarnessTimeline(one, review.Path, FixtureLoader.SharedRoot, 0, out _, out var rewrites);
        Assert.Equal("Result first", review.Editor.Project.Edits.Clips.Last().Title);
        Assert.Single(rewrites);
        Assert.Null(review.Editor.ReadHarnessProposal(review.Path));
        review.Editor.Undo();
        Assert.Equal(2, review.Editor.Project.Edits.Clips.Count);
        Assert.Equal("A faster edit", review.Editor.Project.Edits.Clips[0].Title);
        review.Editor.Undo();
        Assert.Equal(review.Original.Edits.Clips[0].Title, review.Editor.Project.Edits.Clips[0].Title);
    }

    private sealed class ReviewProject : IDisposable
    {
        private readonly DirectoryInfo folder = Directory.CreateTempSubdirectory("voxclip-harness-review-");
        public string OriginalText { get; } = FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip");
        public string Path => System.IO.Path.Combine(folder.FullName, "fixture.voxclip");
        public string Sidecar => Path + ".proposal.json";
        public Project Original { get; }
        public EditorViewModel Editor { get; }

        public ReviewProject()
        {
            Original = ProjectSerialization.Deserialize(OriginalText);
            Editor = new(Original);
            File.WriteAllText(Path, OriginalText);
        }

        public void Stage(string? timeline = null)
        {
            using var raw = JsonDocument.Parse(timeline ?? """
                {"clipId":"clip-2f1c","reason":"Make the point clear.","title":"A faster edit","generateMusic":"A warm instrumental",
                 "effects":[{"kind":"motionTemplate","startWord":9,"endWord":10,"reason":"Name the point.",
                             "template":{"name":"titleCard","text":"A faster edit"}}]}
                """);
            File.WriteAllText(Sidecar, new HarnessProposal(HarnessTimeline.Read(raw.RootElement), Original).ToJson().ToJsonString());
        }

        public void Dispose() => folder.Delete(recursive: true);
    }
}
#endif
