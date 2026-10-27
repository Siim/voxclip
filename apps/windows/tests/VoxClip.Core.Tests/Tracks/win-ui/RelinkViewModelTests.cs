#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class RelinkViewModelTests
{
    private static Project Fixture() => ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(
        Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!, "fixtures", "projects", "interview-take.voxclip")));

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, true)]
    [InlineData(true, false)]
    public async Task MatchOrExplicitConfirmationSavesExactlyOnce(bool different, bool confirmed)
    {
        var original = Fixture();
        var model = new EditorViewModel(original);
        model.SetMediaUnavailable(true);
        var store = new Store(different);
        var picks = new Queue<string?>(["chosen.mp4", null]);
        var confirmations = 0;
        var result = await model.RelinkAsync(store, "project.voxclip", () => Task.FromResult(picks.Dequeue()),
            selected => Task.FromResult(new MediaInfo(selected, original.Media.Source.DurationSeconds, null, null, new(16, 9), null, null, false, 0, 0, 0)),
            () => { confirmations++; return Task.FromResult(confirmed); }, TestContext.Current.CancellationToken);
        Assert.Equal(!different || confirmed, result);
        Assert.Equal(result ? 1 : 0, store.Saves);
        Assert.Equal(different ? 1 : 0, confirmations);
        Assert.Equal(!result, model.IsReadOnly);
        Assert.Same(original.Transcript, model.Project.Transcript);
        Assert.Equal(original.Edits, model.Project.Edits);
        Assert.Equal(result ? "chosen.mp4" : original.Media.Source.AbsolutePath, model.Project.Media.Source.AbsolutePath);
        Assert.Equal("Locate the video to export.", model.ExportBlocked(false, true, null));
    }

    [Fact]
    public async Task CancelKeepsReadOnlyAndDoesNotSave()
    {
        var model = new EditorViewModel(Fixture());
        model.SetMediaUnavailable(true);
        var store = new Store(false);
        Assert.False(await model.RelinkAsync(store, "project.voxclip", () => Task.FromResult<string?>(null),
            _ => throw new InvalidOperationException(), () => throw new InvalidOperationException(), TestContext.Current.CancellationToken));
        Assert.True(model.IsReadOnly);
        Assert.Equal(0, store.Saves);
        Assert.False(model.Apply(new EditOperation.CutFillers()));
    }

    private sealed class Store(bool different) : IProjectStore
    {
        public int Saves { get; private set; }
        public Task SaveAsync(Project project, string path, CancellationToken ct) { Saves++; return Task.CompletedTask; }
        public Task<ProjectRelinkResult> RelinkAsync(Project project, string mediaPath, MediaInfo probe, bool confirmedDifferent, CancellationToken ct) =>
            Task.FromResult(different && !confirmedDifferent ? new ProjectRelinkResult(RelinkDecision.NeedsConfirmation, null)
                : new(different ? RelinkDecision.Different : RelinkDecision.Match, project with { Media = new(project.Media.Source with { AbsolutePath = mediaPath }) }));
        public Task<ProjectOpenResult> LoadAsync(string path, CancellationToken ct) => throw new NotSupportedException();
        public Task<string?> ResolveMediaAsync(MediaReference source, string projectPath, CancellationToken ct) => throw new NotSupportedException();
        public Task<string> ComputeContentKeyAsync(string mediaPath, IProgress<double>? progress, CancellationToken ct) => throw new NotSupportedException();
    }
}
#endif
