using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class WindowsV4CallerTests
{
    private static Project Visuals() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/context-demo/v4-project.voxclip"));
    private static Project Voice() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));

    /// <summary>The scope's rendered timeline, as the App and CLI build it: the edit plan with the clip active (or none).</summary>
    internal static RenderTimeline Scoped(Project project, string? clipId)
    {
        var state = EditingEngine.FromProject(project)! with { ActiveClipId = clipId };
        var duration = project.Media.Source.DurationSeconds;
        return new RenderTimeline.Legacy(EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, duration), duration,
            project.Media.Source.Audio!.SampleRate, state.PauseKeepSeconds));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ContextDemoPlacementsRenderOnTheScopesEditedClockWithoutMutation(bool motion)
    {
        var original = Visuals();
        var project = original with { MotionCues = motion ? original.MotionCues : [] };
        var before = ProjectSerialization.Serialize(project);
        foreach (var scope in new[] { VoiceLabOutputScope.Full, VoiceLabOutputScope.Clip(project.Edits.Clips[0].Id) })
            Assert.False(VoiceLabRenderContract.Prepare(project, scope, VoiceLabLabelPosition.TopRight).OutputPlan.RequiresSyntheticRendering);
        // The full video: placement-a shows demo-a's first second over edited 1–2 s, half-open.
        var full = Assert.IsType<ContextDemoRenderLayers>(ContextDemoRendering.Resolve(project, null, Scoped(project, null), "/data"));
        Assert.Equal(new TimeRange(0, 7), full.Input.Scope);
        Assert.Null(full.At(0.99));
        Assert.Equal(new ContextDemoLayerFrame("demo-a", 0.5), full.At(1.5));
        Assert.Null(full.At(2));
        Assert.Equal(Path.Combine("/data", "context-demo", project.Id, "demo-a.mp4"), full.AssetPath(full.Input.Assets.Single()));
        // The clip starts later in the narration, so the same placement starts earlier on its clock: rebased to the clip's start.
        var clipId = project.Edits.Clips[0].Id;
        var clip = Assert.IsType<ContextDemoRenderLayers>(ContextDemoRendering.Resolve(project, clipId, Scoped(project, clipId), "/data"));
        var offset = clip.Input.Scope.Start;
        Assert.InRange(offset, 0.01, 1);
        var placement = Assert.Single(clip.Input.Placements);
        Assert.Equal((1 - offset, 2 - offset), (placement.Output.Start, placement.Output.End), (left, right) =>
            Math.Abs(left.Item1 - right.Item1) < 1e-9 && Math.Abs(left.Item2 - right.Item2) < 1e-9);
        Assert.Equal("demo-a", clip.At(1.5 - offset)!.Value.AssetId);
        Assert.Equal(0.5, clip.At(1.5 - offset)!.Value.SourceTime, 9);
        // No placements, no layers.
        Assert.Null(ContextDemoRendering.Resolve(project with { ContextDemo = project.ContextDemo! with { Placements = [] } }, null, Scoped(project, null), "/data"));
        Assert.Equal(before, ProjectSerialization.Serialize(project));
    }

    [Fact]
    public void PlacementsThatNoLongerFitTheEditedNarrationStopWithAReason()
    {
        var project = Visuals();
        var cut = project with { Edits = project.Edits with { CutWordIds = ["w4"] } };
        var error = Assert.Throws<VoxClipException>(() => ContextDemoRendering.Resolve(cut, null, Scoped(cut, null), "/data"));
        Assert.Equal((VoxClipErrorCode.ExportFailed, ContextDemoRendering.StaleMessage), (error.Code, error.Message));
    }

    [Fact]
    public void ZoomMotionCuesAloneRenderOnWindows()
    {
        // Zooms crop the picture in preview and export (design §6.7), with or without context demos.
        var original = Visuals();
        var project = original with { ContextDemo = null };
        Assert.NotEmpty(project.MotionCues);
        foreach (var scope in new[] { VoiceLabOutputScope.Full, VoiceLabOutputScope.Clip(project.Edits.Clips[0].Id) })
            Assert.False(VoiceLabRenderContract.Prepare(project, scope, VoiceLabLabelPosition.TopRight).OutputPlan.RequiresSyntheticRendering);
        var clipId = project.MotionCues[0].ClipID;
        Assert.Equal(project.MotionCues.Where(cue => cue.ClipID == clipId), ClipRenderInput.Resolve(project, clipId, "/data", "/shared")!.Motion);
        Assert.Null(ClipRenderInput.Resolve(project, null, "/data", "/shared"));
    }

    [Fact]
    public void EmptyPlacementMetadataRemainsRenderableButCannotReuseContractAfterVisualsAreAdded()
    {
        var original = Visuals();
        var metadata = original with { ContextDemo = original.ContextDemo! with { Placements = [] }, MotionCues = [] };
        var prepared = VoiceLabRenderContract.Prepare(metadata, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        Assert.False(prepared.OutputPlan.RequiresSyntheticRendering);
        Assert.False(prepared.Disclosure.Required);
        prepared.Verify(metadata, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        // Adding the placements changes the project, so the prepared contract is stale rather than reused.
        Assert.Equal(VoiceLabProjectErrorCode.StaleRenderContract, Assert.Throws<VoiceLabProjectException>(() =>
            prepared.Verify(original, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight)).Code);
    }

    [Fact]
    public void V4RetainsV3SyntheticRecipesCaptionsAndDisclosure()
    {
        var original = Voice();
        var upgraded = original with { SchemaVersion = 4 };
        foreach (var scope in new[] { VoiceLabOutputScope.Full, VoiceLabOutputScope.Clip(original.Edits.Clips[0].Id) })
        {
            var v3 = VoiceLabRenderContract.Prepare(original, scope, VoiceLabLabelPosition.BottomLeft);
            var v4 = VoiceLabRenderContract.Prepare(upgraded, scope, VoiceLabLabelPosition.BottomLeft);
            Assert.True(v4.OutputPlan.RequiresSyntheticRendering);
            Assert.Equal(v3.OutputPlan.OutputSamples, v4.OutputPlan.OutputSamples);
            Assert.Equal(v3.OutputPlan.Pieces, v4.OutputPlan.Pieces);
            Assert.Equal(v3.OutputPlan.Captions, v4.OutputPlan.Captions);
            Assert.Equal(System.Text.Json.JsonSerializer.Serialize(v3.SelectedSegmentRecipes),
                System.Text.Json.JsonSerializer.Serialize(v4.SelectedSegmentRecipes));
            Assert.True(v4.Disclosure.Required);
            Assert.Equal(v3.Disclosure.Kinds, v4.Disclosure.Kinds);
            Assert.Equal(v3.Disclosure.Intervals, v4.Disclosure.Intervals);
            Assert.Equal(v3.Disclosure.OutputAiSeconds, v4.Disclosure.OutputAiSeconds);
            Assert.Equal(VoiceLabLabelPosition.BottomLeft, v4.Disclosure.Position);
        }
    }

    [Theory]
    [InlineData(3)]
    [InlineData(4)]
    public void CleanAudioRefusalAlsoAppliesWithoutEnabledSegments(int version)
    {
        var original = Voice();
        var project = original with { SchemaVersion = version, VoiceLab = original.VoiceLab with
        {
            Segments = [], CleanAudio = new(VoiceLabCleanAudioMode.On, original.VoiceLab.Assets![0].Id, 1)
        } };
        Assert.Equal(VoiceLabProjectErrorCode.CleanAudioUnsupported, Assert.Throws<VoiceLabProjectException>(() =>
            VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight)).Code);
    }

    [Fact]
    public void ClipRemovalPrunesOnlyItsMotionInThePersistedTransaction()
    {
        var original = Visuals();
        var removed = original.Edits.Clips[0];
        var retained = removed with { Id = "retained-clip" };
        var retainedCue = original.MotionCues[0] with { Id = "retained-motion", ClipID = retained.Id };
        original = original with { Edits = original.Edits with { Clips = [removed, retained] },
            MotionCues = original.MotionCues.Append(retainedCue).ToArray() };
        var state = EditingEngine.Reduce(EditingEngine.FromProject(original)!, new EditOperation.RemoveClip(removed.Id));
        var changed = EditingEngine.ApplyToProject(original, state);
        Assert.Equal(retained.Id, Assert.Single(changed.Edits.Clips).Id);
        Assert.Equal(retainedCue, Assert.Single(changed.MotionCues));
        Assert.Same(original.ContextDemo, changed.ContextDemo);
        Assert.Equal(2, original.MotionCues.Count);
        Assert.Single(ProjectSerialization.Deserialize(ProjectSerialization.Serialize(changed)).MotionCues);
    }

    [Fact]
    public void BothTranscriptReplacementEntryPointsExplicitlyClearVisuals()
    {
        var original = Visuals();
        var transcript = original.Transcript! with { Refined = !original.Transcript!.Refined };
        var edited = EditingEngine.ApplyToProject(original,
            EditingEngine.Reduce(EditingEngine.FromProject(original)!, new EditOperation.ReplaceTranscript(transcript)));
        foreach (var changed in new[] { edited, ProjectStore.ReplaceTranscript(original, transcript) })
        {
            Assert.Null(changed.ContextDemo);
            Assert.Empty(changed.MotionCues);
            Assert.Empty(changed.Edits.Clips);
            Assert.Equal(4, changed.SchemaVersion);
            Assert.Same(transcript, changed.Transcript);
            ProjectSerialization.Deserialize(ProjectSerialization.Serialize(changed));
        }
        Assert.NotNull(original.ContextDemo);
        Assert.NotEmpty(original.MotionCues);
    }

    [Fact]
    public async Task RelinkPreservesSameContentAndInvalidatesOnlyConfirmedDifferentContent()
    {
        using var storage = new TestStorage();
        var store = new ProjectStore();
        var first = storage.PathFor("first.mp4");
        var second = storage.PathFor("second.mp4");
        await File.WriteAllTextAsync(first, "original synthetic source", TestContext.Current.CancellationToken);
        await File.WriteAllTextAsync(second, "different synthetic source", TestContext.Current.CancellationToken);
        var original = Visuals();
        var key = await store.ComputeContentKeyAsync(first, null, TestContext.Current.CancellationToken);
        original = original with { Media = new(original.Media.Source with { AbsolutePath = first, SizeBytes = new FileInfo(first).Length, ContentKey = key }),
            ContextDemo = original.ContextDemo! with { SourceContentKey = key } };
        var source = original.Media.Source;
        MediaInfo Probe(string path) => new(path, source.DurationSeconds, source.Video, source.Audio, new(1920, 1080), "h264", "aac", false, 0, 1, 0);
        var match = await store.RelinkAsync(original, first, Probe(first), false, TestContext.Current.CancellationToken);
        Assert.Equal(RelinkDecision.Match, match.Decision);
        var matched = Assert.IsType<Project>(match.Project);
        Assert.Same(original.ContextDemo, matched.ContextDemo);
        Assert.Same(original.MotionCues, matched.MotionCues);
        var unconfirmed = await store.RelinkAsync(original, second, Probe(second), false, TestContext.Current.CancellationToken);
        Assert.Equal(RelinkDecision.NeedsConfirmation, unconfirmed.Decision);
        Assert.Null(unconfirmed.Project);
        var different = await store.RelinkAsync(original, second, Probe(second), true, TestContext.Current.CancellationToken);
        Assert.Equal(RelinkDecision.Different, different.Decision);
        var changed = Assert.IsType<Project>(different.Project);
        Assert.Null(changed.ContextDemo);
        Assert.Empty(changed.MotionCues);
        Assert.Same(original.Transcript, changed.Transcript);
        Assert.Equal(original.Edits, changed.Edits);
        ProjectSerialization.Deserialize(ProjectSerialization.Serialize(changed));
        Assert.NotNull(original.ContextDemo);
        Assert.NotEmpty(original.MotionCues);
    }
}
