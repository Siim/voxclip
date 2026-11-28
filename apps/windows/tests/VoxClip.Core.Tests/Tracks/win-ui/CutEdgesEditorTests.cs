#if WIN_UI_TESTS
using System.Text;
using System.Text.RegularExpressions;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Cut edges in the Windows editor (editing §5.10, design §6.8), twin of the Mac "Cut edges in the editor" suite: every
/// commit path seats a new cut in its own undo step, paid and open work keep their edges, the inline offer and Fix cut edges, the
/// disabled reasons, and a selected cut's Use word edge / Use quiet point.</summary>
public sealed class CutEdgesEditorTests
{
    private static string Shared => SharedResources.ResolveRoot();
    private static string AppRoot => Path.Combine(Path.GetDirectoryName(Shared)!, "apps", "windows", "src", "VoxClip.App");

    /// <summary>300 frames of 10 ms at 16 kHz: room tone at 2^-9, speech at 0.5 over frames 30–189, and the dips given at 0.0625.</summary>
    private static AudioEnvelope Levels(params int[][] dips)
    {
        var levels = Enumerable.Repeat(1f / 512, 300).ToArray();
        for (var frame = 30; frame <= 189; frame++) levels[frame] = 0.5f;
        foreach (var dip in dips) for (var frame = dip[0]; frame <= dip[1]; frame++) levels[frame] = 0.0625f;
        return new(16_000, 0.01, levels);
    }

    /// <summary>V3: a dip before w2's true start and one after its true end, so both seams move.</summary>
    private static AudioEnvelope BothSeams() => Levels([69, 71], [119, 121]);
    /// <summary>V1: only the w2|w3 edge would move (to 1.205).</summary>
    private static AudioEnvelope LateBoundary() => Levels([79, 81], [119, 121]);

    private static TimedWord Word(string id, double start, double end) => new(id, id, WordKind.Word, start, end, start, end, null, null, TimingSource.Native);

    /// <summary>Touching w1 0.30–0.80, w2 0.80–1.30 and w3 1.30–1.90 at 48 kHz, at v4 as a project with Voice Lab segments is.</summary>
    private static Project Fixture(params string[] cut)
    {
        var project = ContextDemoProject.UpgradeToV4(ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures", "projects", "interview-take.voxclip"))));
        return project with
        {
            Transcript = project.Transcript! with { Words = [Word("w1", 0.30, 0.80), Word("w2", 0.80, 1.30), Word("w3", 1.30, 1.90)], DurationSeconds = 3 },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 3 } },
            Edits = new(0.8, 0.15, cut, [], new Dictionary<string, string>(StringComparer.Ordinal), [], null),
        };
    }

    /// <summary>A clip over w3 alone, so the w2|w3 edge is that clip's edge.</summary>
    private static Project WithClip(Project project) =>
        project with { Edits = project.Edits with { Clips = [new ClipRange("c3", "w3", "w3", null, ClipOrigin.Manual, null, null, true)] } };

    private static EditorViewModel Editor(Project project, AudioEnvelope? levels)
    {
        var model = new EditorViewModel(project, now: () => project.ModifiedAt.AddSeconds(1));
        if (levels is not null) model.SetCutEdgeLevels(project.Media.Source.ContentKey, levels);
        return model;
    }

    private static IReadOnlyList<MediaInterval> Cuts(EditorViewModel model) =>
        EditingEngine.BuildPlan(model.State!, model.Project.Media.Source.DurationSeconds, 48_000).Cuts;

    private static string EditsJson(Project project) => System.Text.Json.JsonSerializer.Serialize(project.Edits, ProjectJsonContext.Default.ProjectEdits);

    private static IEnumerable<KeyValuePair<string, double>> Sorted(IReadOnlyDictionary<string, double>? edges) =>
        (edges ?? new Dictionary<string, double>()).OrderBy(pair => pair.Key, StringComparer.Ordinal);

    private static Dictionary<string, double> Edges(params (string Id, double Value)[] edges) =>
        edges.ToDictionary(edge => edge.Id, edge => edge.Value, StringComparer.Ordinal);

    /// <summary>A Voice Lab segment over <paramref name="first"/>…<paramref name="last"/> taken from a shared fixture, its takes playing
    /// the source video.</summary>
    private static VoiceLabSegment Patch(double start, double end, string first, string last, bool enabled = true)
    {
        var revoiced = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures", "voice-lab", "whole-clip-revoice-project.voxclip")));
        var segment = revoiced.VoiceLab.Segments[0];
        return segment with
        {
            Enabled = enabled,
            Replace = new(start, end, first, last),
            Candidates = segment.Candidates.Select(candidate => candidate.Recipe is { } recipe
                ? candidate with { Recipe = recipe with { Video = recipe.Video with { Mode = VoiceLabVideoMode.Source } } } : candidate).ToArray(),
        };
    }

    private static Project WithPatch(Project project, VoiceLabSegment segment) => project with { VoiceLab = project.VoiceLab with { Segments = [segment] } };

    // MARK: The commit hook

    [Fact]
    public void ANewCutLandsInTheQuietInTheSameUndoStep()
    {
        var original = Fixture();
        var model = Editor(original, BothSeams());
        model.Select(1);
        model.CutSelection();
        Assert.Equal(["w2"], model.Project.Edits.CutWordIds);
        Assert.Equal(Sorted(Edges(("w2", 0.705), ("w3", 1.205))), Sorted(model.Project.Edits.CutEdges));
        Assert.Equal(8, model.Project.SchemaVersion);
        Assert.Equal([new MediaInterval(33_840, 57_840)], Cuts(model));
        model.Undo();
        Assert.False(model.CanUndo);
        Assert.Equal(EditsJson(original), EditsJson(model.Project));
        Assert.Equal(original.SchemaVersion, model.Project.SchemaVersion);
        Assert.Empty(Cuts(model));
        model.Redo();
        Assert.Equal(Sorted(Edges(("w2", 0.705), ("w3", 1.205))), Sorted(model.Project.Edits.CutEdges));
        Assert.Equal([new MediaInterval(33_840, 57_840)], Cuts(model));
        var saved = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(model.Project));
        Assert.Equal(Sorted(Edges(("w2", 0.705), ("w3", 1.205))), Sorted(saved.Edits.CutEdges));
    }

    [Fact]
    public void ACutWithoutLevelsAndItsRestoreKeepTodaysPadding()
    {
        var original = Fixture();
        var model = Editor(original, null);
        model.Select(1);
        model.CutSelection();
        Assert.Null(model.Project.Edits.CutEdges);
        Assert.Equal(original.SchemaVersion, model.Project.SchemaVersion);
        Assert.Equal([new MediaInterval(38_400, 62_400)], Cuts(model));
        // Seated, then restored as a new step (not an Undo): the edits are byte for byte the ones before the cut.
        model.SetCutEdgeLevels(original.Media.Source.ContentKey, BothSeams());
        model.CutSelection(restore: true);
        model.CutSelection();
        Assert.Equal(Sorted(Edges(("w2", 0.705), ("w3", 1.205))), Sorted(model.Project.Edits.CutEdges));
        model.CutSelection(restore: true);
        Assert.Equal(EditsJson(original), EditsJson(model.Project));
        // The v4 file went to v8 with its first key and lands at 6 once the last one goes (editing §10.1).
        Assert.Equal(6, model.Project.SchemaVersion);
    }

    /// <summary>The members that push an undo step. The ones whose step can change the cut set run the cut edge hook; the rest change
    /// captions or the clip style only. A new commit path fails here until it is listed, and seats if it edits.</summary>
    private static readonly IReadOnlyDictionary<string, bool> HistorySteps = new Dictionary<string, bool>(StringComparer.Ordinal)
    {
        ["ApplyBatch"] = true, ["ApplyVoiceLabCore"] = true, ["ReplaceProject"] = true,
        ["RecordCaptionLook"] = false, ["RecordCaptions"] = false, ["MoveCaptionSettings"] = false, ["RecordClipStyle"] = false,
    };

    [Fact]
    public void EveryUndoStepIsEnumeratedAndEveryEditingOneSeatsCutEdges()
    {
        var members = new Dictionary<string, string>(StringComparer.Ordinal);
        var signature = new Regex(@"^    (?:public|private|internal)\b[^=;]*?\b(\w+)\s*(?:<[^>]*>)?\(", RegexOptions.Compiled);
        foreach (var path in Directory.EnumerateFiles(Path.Combine(AppRoot, "ViewModels"), "*.cs"))
        {
            var lines = File.ReadAllLines(path);
            for (var index = 0; index < lines.Length; index++)
            {
                if (!lines[index].Contains("PushHistory(", StringComparison.Ordinal) || lines[index].Contains("void PushHistory(", StringComparison.Ordinal)) continue;
                var start = index;
                while (start > 0 && !signature.IsMatch(lines[start])) start--;
                var name = signature.Match(lines[start]).Groups[1].Value;
                var end = index;
                while (end < lines.Length - 1 && lines[end] != "    }") end++;
                members[name] = string.Join("\n", lines[start..(end + 1)]);
            }
        }
        Assert.Equal(HistorySteps.Keys.Order(StringComparer.Ordinal), members.Keys.Order(StringComparer.Ordinal));
        foreach (var (name, edits) in HistorySteps)
        {
            var body = members[name];
            if (edits) Assert.True(body.Contains("SeatCutEdges(", StringComparison.Ordinal) || body.Contains("CommittingCutEdges(", StringComparison.Ordinal), name);
            else
            {
                Assert.DoesNotContain("Edits =", body, StringComparison.Ordinal);
                Assert.DoesNotContain("state =", body, StringComparison.Ordinal);
                Assert.DoesNotContain("EditingEngine.", body, StringComparison.Ordinal);
            }
        }
    }

    [Fact]
    public void EachEditingCommitPathSeatsTheCutInItsOwnStep()
    {
        var expected = Sorted(Edges(("w2", 0.705), ("w3", 1.205)));
        // Apply and ApplyBatch: Cut selection, a toggle, fillers, pauses, Ask Claude's cuts.
        var batch = Editor(Fixture(), BothSeams());
        Assert.True(batch.ApplyBatch([new EditOperation.Toggle("w2")]));
        Assert.Equal(expected, Sorted(batch.Project.Edits.CutEdges));
        Assert.Equal([new MediaInterval(33_840, 57_840)], Cuts(batch));
        // ReplaceProject: timeline edits, Make it postable, the harness and agent changes; the step keeps its own name.
        var replaced = Editor(Fixture(), BothSeams());
        Assert.True(replaced.ReplaceProject(EditingEngine.ApplyEditing(replaced.Project, new EditOperation.Toggle("w2")), "Ask Claude"));
        Assert.Equal("Ask Claude", replaced.UndoActionName);
        Assert.Equal(expected, Sorted(replaced.Project.Edits.CutEdges));
        Assert.Equal([new MediaInterval(33_840, 57_840)], Cuts(replaced));
        replaced.Undo();
        Assert.Null(replaced.Project.Edits.CutEdges);
        Assert.False(replaced.CanUndo);
        // A Rewrite's accepted takes with its local cut: the cut is seated in the takes' step, beside the new voice patches.
        var vectors = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(Path.Combine(Shared, "fixtures", "voice-lab", "accept-all-cases.json")))!;
        var input = vectors["inputs"]!["mixed"]!;
        T Read<T>(System.Text.Json.Nodes.JsonNode node, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type) => System.Text.Json.JsonSerializer.Deserialize(node.ToJsonString(), type)!;
        var project = ProjectSerialization.Deserialize(input["project"]!.ToJsonString());
        var segments = input["segments"]!.AsArray().Select(item => Read(item!, ProjectJsonContext.Default.VoiceLabSegment)).ToArray();
        var assets = input["assets"]!.AsArray().Select(item => Read(item!, ProjectJsonContext.Default.VoiceLabAsset)).ToArray();
        var voice = Read(input["voice"]!, ProjectJsonContext.Default.VoiceLabVoiceReference);
        // Words w1 0.3–0.6, w2 0.7–1.0, w3 1.1–1.5 over 7 s: speech at 0.5 from 0.3 to 4.2 s, a dip at 0.57–0.60 s and one at 1.11–1.14 s.
        var levels = Enumerable.Repeat(1f / 512, 700).ToArray();
        for (var frame = 30; frame < 420; frame++) levels[frame] = 0.5f;
        foreach (var frame in new[] { 57, 58, 59, 111, 112, 113 }) levels[frame] = 0.0625f;
        var voiced = Editor(project, new(16_000, 0.01, levels));
        Assert.True(voiced.ApplyVoiceLab(segments, assets, voice, VoiceLabOutputScope.Full, "Rewrite full take", project,
            [new EditOperation.SetWordCuts(["w2"], true)]), voiced.Notice);
        Assert.Equal("Rewrite full take", voiced.UndoActionName);
        Assert.Equal(Sorted(Edges(("w2", 0.585), ("w3", 1.125))), Sorted(voiced.Project.Edits.CutEdges));
        Assert.Equal(Sorted(voiced.Project.Edits.CutEdges), Sorted(voiced.State!.CutEdges));
        Assert.Equal(8, ProjectSerialization.Deserialize(ProjectSerialization.Serialize(voiced.Project)).SchemaVersion);
        voiced.Undo();
        Assert.Null(voiced.Project.Edits.CutEdges);
        Assert.Empty(voiced.Project.VoiceLab.Segments);
    }

    [Fact]
    public void PaidAndOpenWorkKeepTheEdgesBesideIt()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-cut-edges-").FullName;
        try
        {
            IReadOnlyDictionary<string, double>? CutW2(Project project, Action<EditorViewModel>? prepare = null)
            {
                var model = Editor(project, LateBoundary());
                model.SetCutEdgePaidRoot(root);
                prepare?.Invoke(model);
                Assert.True(model.ApplyBatch([new EditOperation.Toggle("w2")]));
                Assert.Equal(["w2"], model.Project.Edits.CutWordIds);
                return model.Project.Edits.CutEdges;
            }
            Assert.Equal(Sorted(Edges(("w3", 1.205))), Sorted(CutW2(WithClip(Fixture()))));
            // A voice patch over w3, enabled or not.
            foreach (var enabled in new[] { true, false })
                Assert.Null(CutW2(WithPatch(WithClip(Fixture()), Patch(1.30, 1.90, "w3", "w3", enabled))));
            // A whole-clip revoice of the clip over w3.
            var revoiced = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures", "voice-lab", "whole-clip-revoice-project.voxclip")));
            var record = revoiced.VoiceLab.WholeClipRevoices![0] with { ClipId = "c3" };
            var whole = WithClip(Fixture());
            Assert.Null(CutW2(whole with { VoiceLab = whole.VoiceLab with { WholeClipRevoices = [record] } }));
            // An open Rewrite on that clip, paid or not; once it closes, the edge moves again.
            RewriteSession? session = null;
            Assert.Null(CutW2(WithClip(Fixture()), model => session = new RewriteSession(model, 2, 2, null, null, scope: RewriteScope.Clip("c3"))));
            var closed = Editor(WithClip(Fixture()), LateBoundary());
            new RewriteSession(closed, 2, 2, null, null, scope: RewriteScope.Clip("c3")).Dispose();
            Assert.True(closed.ApplyBatch([new EditOperation.Toggle("w2")]));
            Assert.Equal(Sorted(Edges(("w3", 1.205))), Sorted(closed.Project.Edits.CutEdges));
            session?.Dispose();
            // Paid takes saved beside the project for that clip; a saved proposal with nothing paid keeps nothing.
            var change = new SavedRewriteChange(new(VoiceLabDiffHunkKind.Voice, ["w3"], ["New"], [], [], [], 0, 1, null), null, false, [], [], "pending");
            foreach (var takes in new[] { 1, 0 })
            {
                var project = WithClip(Fixture());
                var store = new SavedRewriteProposalStore(root, project.Id, RewriteScope.Clip("c3"), null);
                store.Save(new("x", "", [change], [], [], null, takes, 0, []), DateTimeOffset.UtcNow);
                var edges = CutW2(project);
                if (takes > 0) Assert.Null(edges); else Assert.Equal(Sorted(Edges(("w3", 1.205))), Sorted(edges));
                store.Remove();
            }
        }
        finally { Directory.Delete(root, true); }
    }

    // MARK: Old cuts

    [Fact]
    public void OldCutsAreOfferedInlineAndFixedInOneStep()
    {
        var original = Fixture("w2");
        var model = Editor(original, BothSeams());
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        // Opening changes nothing; the timeline offers the two edges.
        Assert.Same(original, model.Project);
        Assert.Equal((2, 0), (model.CutEdgeOffer.Count, model.CutEdgeOffer.Frozen));
        Assert.Empty(model.CutEdgeOffer.Unloaded);
        Assert.Equal(new CutEdgeBarRow("2 cuts can land in the quiet", "Fix cut edges"), model.CutEdgeBarRow);
        Assert.True(model.CanFixCutEdges);
        Assert.Null(model.FixCutEdgesReason);
        Assert.True(model.RunCutEdgeBarAction());
        Assert.Equal("Fix cut edges", model.UndoActionName);
        Assert.Equal(Sorted(Edges(("w2", 0.705), ("w3", 1.205))), Sorted(model.Project.Edits.CutEdges));
        Assert.Equal(8, model.Project.SchemaVersion);
        Assert.Equal([new MediaInterval(33_840, 57_840)], Cuts(model));
        Assert.Equal(new CutEdgeBarRow("Moved 2 cut edges into the quiet"), model.CutEdgeBarRow);
        Assert.Equal(["Moved 2 cut edges into the quiet"], announced);
        // The ClipBar's Fix cut edges stays, disabled with its reason.
        Assert.False(model.CanFixCutEdges);
        Assert.Equal("All cut edges are in the quiet", model.FixCutEdgesReason);
        model.Undo();
        Assert.False(model.CanUndo);
        Assert.Equal(EditsJson(original), EditsJson(model.Project));
        Assert.Equal("Fix cut edges", model.CutEdgeBarRow?.Action);
        // The result line goes with the next edit.
        model.Redo();
        Assert.True(model.ApplyBatch([new EditOperation.Correct("w1", "first")]));
        Assert.Null(model.CutEdgeBarRow);
    }

    [Fact]
    public void FixingBesideAVoicePatchSaysWhatItKept()
    {
        var model = Editor(WithPatch(Fixture("w2"), Patch(1.30, 1.90, "w3", "w3")), BothSeams());
        Assert.Equal((1, 1), (model.CutEdgeOffer.Count, model.CutEdgeOffer.Frozen));
        Assert.Equal("1 cut can land in the quiet", model.CutEdgeBarRow?.Text);
        Assert.True(model.FixCutEdges());
        Assert.Equal(Sorted(Edges(("w2", 0.705))), Sorted(model.Project.Edits.CutEdges));
        Assert.Equal(new CutEdgeBarRow("Moved 1 cut edge into the quiet · 1 kept beside voice patches"), model.CutEdgeBarRow);
    }

    /// <summary>Saves a Rewrite proposal with one paid take beside <paramref name="project"/> for <paramref name="scope"/>, with the inputs
    /// digest it is restored by.</summary>
    private static SavedRewriteProposalStore SavePaidProposal(string root, Project project, RewriteScope scope)
    {
        var change = new SavedRewriteChange(new(VoiceLabDiffHunkKind.Voice, ["w3"], ["New"], [], [], [], 0, 1, null), null, false, [], [], "pending");
        var store = new SavedRewriteProposalStore(root, project.Id, scope, null);
        store.Save(new(store.Inputs(project), "", [change], [], [], null, 1, 0, []), DateTimeOffset.UtcNow);
        Assert.NotNull(store.Load(project, DateTimeOffset.UtcNow));
        return store;
    }

    /// <summary>An old cut inside paid work (both words of the edge in a clip with paid takes saved, or anywhere under a full-take
    /// proposal): Fix cut edges and the selected cut's action leave it alone, so the saved proposal still restores.</summary>
    [Fact]
    public void OldCutsInsidePaidWorkKeepTheirEdges()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-cut-edges-").FullName;
        try
        {
            var project = Fixture("w2");
            project = project with { Edits = project.Edits with { Clips = [new ClipRange("c23", "w2", "w3", null, ClipOrigin.Manual, null, null, true)] } };
            var store = SavePaidProposal(root, project, RewriteScope.Clip("c23"));
            var model = Editor(project, LateBoundary());
            model.SetCutEdgePaidRoot(root);
            Assert.Equal((0, 1), (model.CutEdgeOffer.Count, model.CutEdgeOffer.Frozen));
            Assert.False(model.CanFixCutEdges);
            Assert.Null(model.CutEdgeBarRow);
            Assert.False(model.FixCutEdges());
            model.Select(1);
            Assert.Equal(new CutEdgeBarRow("Cut edge: word edge", "Use quiet point", "Kept beside a voice patch"), model.CutEdgeBarRow);
            Assert.False(model.RunCutEdgeBarAction());
            Assert.False(model.CanUndo);
            Assert.Null(model.Project.Edits.CutEdges);
            Assert.NotNull(store.Load(model.Project, DateTimeOffset.UtcNow));
            store.Remove();
            // A full-take proposal holds every edge of the first recording.
            var plain = Fixture("w2");
            var full = SavePaidProposal(root, plain, RewriteScope.FullTake);
            var whole = Editor(plain, BothSeams());
            whole.SetCutEdgePaidRoot(root);
            Assert.Equal((0, 2), (whole.CutEdgeOffer.Count, whole.CutEdgeOffer.Frozen));
            Assert.False(whole.FixCutEdges());
            Assert.Null(whole.Project.Edits.CutEdges);
            Assert.NotNull(full.Load(whole.Project, DateTimeOffset.UtcNow));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void FixCutEdgesSaysWhyItCannotRun()
    {
        var project = Fixture("w2");
        var loading = Editor(project, null);
        Assert.Equal([project.Media.Source.ContentKey], loading.CutEdgeOffer.Unloaded);
        Assert.Null(loading.CutEdgeBarRow);
        Assert.False(loading.CanFixCutEdges);
        Assert.Equal("Waveform still loading", loading.FixCutEdgesReason);
        Assert.False(loading.FixCutEdges());
        Assert.False(loading.CanUndo);
        // The video is missing or unreadable: its waveform can't load until it is found again.
        var reconnect = $"Reconnect {ProjectClock.Label(project.Media.Source)} to fix its cut edges";
        var missing = Editor(project, null);
        missing.SetCutEdgeLevels(project.Media.Source.ContentKey, null);
        Assert.Equal(reconnect, missing.FixCutEdgesReason);
        var unavailable = Editor(project, null);
        unavailable.SetMediaUnavailable(true);
        Assert.Equal(reconnect, unavailable.FixCutEdgesReason);
        // Loaded again: it can run.
        missing.SetCutEdgeLevels(project.Media.Source.ContentKey, BothSeams());
        Assert.True(missing.CanFixCutEdges);
        missing.ClearCutEdgeLevels();
        Assert.Equal("Waveform still loading", missing.FixCutEdgesReason);
        // No old cut to move.
        var none = Editor(Fixture(), BothSeams());
        Assert.Equal("All cut edges are in the quiet", none.FixCutEdgesReason);
        Assert.Null(none.CutEdgeBarRow);
    }

    // MARK: A selected cut

    [Fact]
    public void ASelectedCutGoesToItsWordEdgeAndBack()
    {
        var seated = Fixture("w2");
        seated = seated with { SchemaVersion = 8, Edits = seated.Edits with { CutEdges = Edges(("w2", 0.705), ("w3", 1.205)) } };
        var model = Editor(seated, BothSeams());
        Assert.Null(model.CutEdgeBarRow);
        model.Select(1);
        Assert.Equal(new CutEdgeBarRow("Cut edge: quiet point", "Use word edge"), model.CutEdgeBarRow);
        Assert.True(model.RunCutEdgeBarAction());
        Assert.Equal("Use word edge", model.UndoActionName);
        // The pin is the word edge itself, which today's padding gave: the cut is the stored words' cut again.
        Assert.Equal(Sorted(Edges(("w2", 0.80), ("w3", 1.30))), Sorted(model.Project.Edits.CutEdges));
        Assert.Equal([new MediaInterval(38_400, 62_400)], Cuts(model));
        Assert.Equal(new CutEdgeBarRow("Cut edge: word edge", "Use quiet point"), model.CutEdgeBarRow);
        // A pin stays: nothing is offered for it.
        model.ClearSelection();
        Assert.Null(model.CutEdgeBarRow);
        Assert.Equal("All cut edges are in the quiet", model.FixCutEdgesReason);
        model.Select(1);
        Assert.True(model.RunCutEdgeBarAction());
        Assert.Equal("Use quiet point", model.UndoActionName);
        Assert.Equal(Sorted(Edges(("w2", 0.705), ("w3", 1.205))), Sorted(model.Project.Edits.CutEdges));
        Assert.Equal([new MediaInterval(33_840, 57_840)], Cuts(model));
        model.Undo();
        Assert.Equal(Sorted(Edges(("w2", 0.80), ("w3", 1.30))), Sorted(model.Project.Edits.CutEdges));
        // A kept word selected beside no cut shows no row.
        model.Select(0);
        Assert.Null(model.SelectedCutEdge);
    }

    [Fact]
    public void ASelectedCutSaysWhyItsEdgeCannotMove()
    {
        // Coarticulated: no dip near either edge.
        var flat = Editor(Fixture("w2"), Levels());
        flat.Select(1);
        Assert.Equal(new CutEdgeBarRow("Cut edge: word edge", "Use quiet point", "No quiet point near this edge"), flat.CutEdgeBarRow);
        Assert.False(flat.RunCutEdgeBarAction());
        Assert.False(flat.CanUndo);
        var loading = Editor(Fixture("w2"), null);
        loading.Select(1);
        Assert.Equal(new CutEdgeBarRow("Cut edge: word edge", "Use quiet point", "Waveform still loading"), loading.CutEdgeBarRow);
        // Beside a voice patch over w1–w3 (both edges): an edge seated before the patch stays where it is.
        var patched = WithPatch(Fixture("w2"), Patch(0.30, 1.90, "w1", "w3"));
        var frozen = Editor(patched, BothSeams());
        frozen.Select(1);
        Assert.Equal(new CutEdgeBarRow("Cut edge: word edge", "Use quiet point", "Kept beside a voice patch"), frozen.CutEdgeBarRow);
        var kept = Editor(patched with { SchemaVersion = 8, Edits = patched.Edits with { CutEdges = Edges(("w3", 1.205)) } }, BothSeams());
        kept.Select(1);
        Assert.Equal(new CutEdgeBarRow("Cut edge: quiet point", "Use word edge", "Kept beside a voice patch"), kept.CutEdgeBarRow);
        Assert.False(kept.RunCutEdgeBarAction());
        Assert.Equal(Sorted(Edges(("w3", 1.205))), Sorted(kept.Project.Edits.CutEdges));
    }

    // MARK: The page

    [Fact]
    public void TheClipBarListsFixCutEdgesAndThePageFeedsTheLevels()
    {
        var page = File.ReadAllText(Path.Combine(AppRoot, "Pages", "EditorPage.xaml"));
        var commands = page[page.IndexOf("<controls:ClipBar.SecondaryCommands>", StringComparison.Ordinal)..page.IndexOf("</controls:ClipBar.SecondaryCommands>", StringComparison.Ordinal)];
        Assert.Matches(new Regex(@"<AppBarButton x:Name=""FixCutEdgesCommand"" Label=""Fix cut edges""[^>]*Click=""FixCutEdgesClicked""/>"), commands);
        var code = string.Concat(Directory.EnumerateFiles(Path.Combine(AppRoot, "Pages"), "EditorPage*.cs").Select(File.ReadAllText));
        Assert.Contains("ViewModel.SetCutEdgeLevels(", code, StringComparison.Ordinal);
        Assert.Contains("ViewModel.SetCutEdgePaidRoot(", code, StringComparison.Ordinal);
        Assert.Contains("ViewModel.FixCutEdges()", code, StringComparison.Ordinal);
        Assert.Contains("ViewModel.FixCutEdgesReason", code, StringComparison.Ordinal);
        var timeline = string.Concat(Directory.EnumerateFiles(Path.Combine(AppRoot, "Controls"), "TimelineView*.cs").Select(File.ReadAllText));
        Assert.Contains("model?.CutEdgeBarRow", timeline, StringComparison.Ordinal);
        Assert.Contains("model?.RunCutEdgeBarAction()", timeline, StringComparison.Ordinal);
        // View models never reach the WinUI App: the page hands the levels and the Voice Lab folder in.
        Assert.DoesNotContain("App.Services", File.ReadAllText(Path.Combine(AppRoot, "ViewModels", "EditorViewModel.CutEdges.cs")), StringComparison.Ordinal);
    }
}
#endif
