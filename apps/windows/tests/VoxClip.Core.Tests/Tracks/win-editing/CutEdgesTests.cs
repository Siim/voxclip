using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

/// <summary>The project-level cut edge calls the editors use (editing §5.10), twin of the Mac <c>CutEdgesTests</c>: the inline offer
/// and Fix cut edges, a recording whose waveform is not loaded, the freeze inputs, and an edge in a later recording. The algorithm
/// itself is pinned by the shared <c>cut-edges/*</c> and <c>session/cut-edge-*</c> vectors in <see cref="EditingFixtureTests"/>.</summary>
public sealed class CutEdgesTests
{
    /// <summary>V1 of the spec table: touching w1, w2, w3 with w2 cut, a quiet w1|w2 edge and a dip after w2 at frames 119–121.</summary>
    internal static AudioEnvelope V1Envelope()
    {
        var levels = Enumerable.Repeat(1f / 512, 300).ToArray();
        for (var frame = 30; frame <= 189; frame++) levels[frame] = 0.5f;
        foreach (var frame in new[] { 79, 80, 81, 119, 120, 121 }) levels[frame] = 0.0625f;
        return new(16_000, 0.01, levels);
    }

    internal static TimedWord[] Words() =>
        [EditingFixtureTests.Word("w1", "w1", 0.30, 0.80), EditingFixtureTests.Word("w2", "w2", 0.80, 1.30), EditingFixtureTests.Word("w3", "w3", 1.30, 1.90)];

    private static Project Fixture(params string[] cut)
    {
        var project = ContextDemoProject.UpgradeToV4(ProjectSerialization.Deserialize(File.ReadAllText(TestStorage.ProjectPath("interview-take.voxclip"))));
        return project with
        {
            Transcript = project.Transcript! with { Words = Words(), DurationSeconds = 3 },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 3 } },
            Edits = new(0.8, 0.15, cut, [], new Dictionary<string, string>(StringComparer.Ordinal), [], null),
        };
    }

    private static Dictionary<string, AudioEnvelope> Loaded(Project project) => new(StringComparer.Ordinal) { [project.Media.Source.ContentKey] = V1Envelope() };

    private static Dictionary<string, CutEdges.Freeze> Frozen(Project project, CutEdges.Freeze freeze) =>
        new(StringComparer.Ordinal) { [project.Media.Source.ContentKey] = freeze };

    private static IEnumerable<KeyValuePair<string, double>> Sorted(IReadOnlyDictionary<string, double>? edges) =>
        (edges ?? new Dictionary<string, double>()).OrderBy(pair => pair.Key, StringComparer.Ordinal);

    [Fact]
    public void TheOfferCountsOldCutsAndFixMovesThemInOneStep()
    {
        var project = Fixture("w2");
        var offer = CutEdges.Offer(project, Loaded(project));
        Assert.Equal((1, 0), (offer.Count, offer.Frozen));
        Assert.Empty(offer.Unloaded);
        var (fixedProject, applied) = CutEdges.Fix(project, Loaded(project));
        Assert.Equal(1, applied.Count);
        Assert.Equal(Sorted(new Dictionary<string, double> { ["w3"] = 1.205 }), Sorted(fixedProject.Edits.CutEdges));
        Assert.Equal(8, fixedProject.SchemaVersion);
        Assert.Equal(0, CutEdges.Offer(fixedProject, Loaded(project)).Count);
        var plan = EditingEngine.BuildPlan(EditingEngine.FromProject(fixedProject)!, 3, 48_000);
        Assert.Equal([new MediaInterval(38_400, 57_840)], plan.Cuts);
    }

    [Fact]
    public void AWaveformThatIsNotLoadedLeavesTodaysPadding()
    {
        var before = Fixture();
        var after = EditingEngine.ApplyEditing(before, new EditOperation.Toggle("w2"));
        var committed = CutEdges.Finalize(before, after, new Dictionary<string, AudioEnvelope>());
        Assert.Null(committed.Edits.CutEdges);
        Assert.Equal(before.SchemaVersion, committed.SchemaVersion);
        Assert.Equal([before.Media.Source.ContentKey], CutEdges.Offer(committed, new Dictionary<string, AudioEnvelope>()).Unloaded);
    }

    [Fact]
    public void VoicePatchesAndPaidScopesKeepTheirEdgesAndAreCounted()
    {
        var project = Fixture("w2");
        var voice = CutEdges.Offer(project, Loaded(project), Frozen(project, new([new TimeRange(1.30, 1.90)], [])));
        Assert.Equal((0, 1), (voice.Count, voice.Frozen));
        Assert.Empty(voice.Unloaded);
        var paid = CutEdges.Fix(project, Loaded(project), Frozen(project, new([], [new ClipWordRange("w3", "w3")])));
        Assert.Null(paid.Project.Edits.CutEdges);
        var inside = CutEdges.Fix(project, Loaded(project), Frozen(project, new([], [new ClipWordRange("w2", "w3")])));
        Assert.Equal(Sorted(new Dictionary<string, double> { ["w3"] = 1.205 }), Sorted(inside.Project.Edits.CutEdges));
    }

    [Fact]
    public void AnEdgeInALaterRecordingIsStoredInItsLocalSecondsAndPlannedOnTheClock()
    {
        var loaded = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "recordings", "two-recordings.voxclip")));
        var sources = loaded.Media.SpokenSources!.ToArray();
        sources[0] = sources[0] with { Transcript = sources[0].Transcript with { Words = Words() } };
        var key = sources[0].SourceKey;
        var project = loaded with
        {
            Media = loaded.Media with
            {
                SpokenSources = sources,
                AdditionalSources = loaded.Media.AdditionalSources!.Select(source => source.ContentKey == key ? source with { DurationSeconds = 3 } : source).ToArray(),
            },
            Edits = loaded.Edits with { CutWordIds = [], CutPauseIds = [], Clips = [], ActiveClipId = null, Corrections = new Dictionary<string, string>(StringComparer.Ordinal) },
        };
        var after = EditingEngine.ApplyEditing(project, new EditOperation.Toggle("r2.w2"));
        var envelopes = new Dictionary<string, AudioEnvelope>(StringComparer.Ordinal) { [key] = V1Envelope() };
        // The companion's own envelope and seconds: the key stores 1.205, not its clock time.
        var committed = CutEdges.Finalize(project, after, envelopes);
        Assert.Equal(Sorted(new Dictionary<string, double> { ["r2.w3"] = 1.205 }), Sorted(committed.Edits.CutEdges));
        Assert.Equal(8, committed.SchemaVersion);
        var reloaded = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(committed));
        Assert.Equal(Sorted(new Dictionary<string, double> { ["r2.w3"] = 1.205 }), Sorted(reloaded.Edits.CutEdges));
        var plan = EditingEngine.BuildPlan(EditingEngine.FromProject(reloaded)!, 0, 48_000);
        var offset = (long)sources[0].OffsetSeconds * 48_000;
        Assert.Contains(new MediaInterval(offset + 38_400, offset + 57_840), plan.Cuts);
        var restored = CutEdges.Finalize(committed, project, envelopes);
        Assert.Null(restored.Edits.CutEdges);
        Assert.Equal(7, restored.SchemaVersion);
    }

    [Fact]
    public void ReplacingTheTranscriptDropsItsCutEdges()
    {
        var project = CutEdges.Fix(Fixture("w2"), Loaded(Fixture("w2"))).Project;
        var state = EditingEngine.FromProject(project)!;
        Assert.Equal(1.205, state.CutEdges["w3"]);
        var replacement = state.Transcript with { Words = [.. Words().Select(word => word with { Text = "other" })] };
        var replaced = EditingEngine.Reduce(state, new EditOperation.ReplaceTranscript(replacement));
        Assert.Empty(replaced.CutEdges);
        Assert.Null(EditingEngine.ApplyToProject(project, replaced).Edits.CutEdges);
    }

    [Fact]
    public void AnEditThatChangesNoCutKeepsTheEdgesAndTheirOrder()
    {
        var project = CutEdges.Fix(Fixture("w2"), new Dictionary<string, AudioEnvelope>(StringComparer.Ordinal)
        {
            [Fixture().Media.Source.ContentKey] = BothSeams(),
        }).Project;
        Assert.Equal(["w2", "w3"], project.Edits.CutEdges!.Keys);
        var corrected = EditingEngine.ApplyEditing(project, new EditOperation.Correct("w1", "first"));
        var committed = CutEdges.Finalize(project, corrected, new Dictionary<string, AudioEnvelope>());
        Assert.Equal(Sorted(project.Edits.CutEdges), Sorted(committed.Edits.CutEdges));
        Assert.Equal(8, committed.SchemaVersion);
    }

    /// <summary>V3: dips at frames 69–71 and 119–121, so both edges of cut w2 move.</summary>
    private static AudioEnvelope BothSeams()
    {
        var levels = V1Envelope().Rms.ToArray();
        for (var frame = 79; frame <= 81; frame++) levels[frame] = 0.5f;
        for (var frame = 69; frame <= 71; frame++) levels[frame] = 0.0625f;
        return new(16_000, 0.01, levels);
    }
}
