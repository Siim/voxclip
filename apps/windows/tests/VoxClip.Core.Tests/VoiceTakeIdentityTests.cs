using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;
#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;
#else
using VoxClip.Tests.Support;
#endif

namespace VoxClip.Core.Tests;

#if !WIN_UI_TESTS
/// <summary>What paid voice work is made from (voice-lab.md "What counts as an edit"), replayed from the shared
/// voice-take-identity-cases.json the Mac Core replays too (<c>RewriteTakeCurrencyTests</c>): a save, the tab, music, captions, clip
/// controls, motion, export, share and VoxClip's own rate samples leave <see cref="ProjectVoiceTakeIdentity"/> as it is; the clip's
/// words, cuts, pauses and corrections, the transcript, the pause threshold, the source and clean audio change it.</summary>
public sealed class VoiceTakeIdentityTests
{
    private static readonly Lazy<JsonObject> Cases = new(() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/voice-take-identity-cases.json"))!.AsObject());
    private static IEnumerable<JsonNode> Rows(string key) => Cases.Value[key]!.AsArray().Select(row => row!);

    [Fact]
    public void SharedCasesHaveTheirSchemaAndCount()
    {
        var root = Cases.Value;
        Assert.Equal(new[] { "schema", "caseCount", "project", "base", "cases" }, root.Select(pair => pair.Key));
        Assert.Equal("voxclip-voice-take-identity/1", root["schema"]!.GetValue<string>());
        Assert.Equal(32, root["caseCount"]!.GetValue<int>());
        Assert.Equal(32, Rows("cases").Count());
        Assert.Equal(32, Rows("cases").Select(row => row["id"]!.GetValue<string>()).Distinct().Count());
    }

    [Fact]
    public void EveryCaseKeepsOrChangesWhatTakesAreMadeFrom()
    {
        var baseline = Project(Rows("base"));
        foreach (var row in Rows("cases"))
        {
            var id = row["id"]!.GetValue<string>();
            var changed = Project(Rows("base").Concat(row["set"]!.AsArray().Select(set => set!)));
            var (scope, enclosing) = Scope(row["scope"]!);
            var sameIdentity = ProjectVoiceTakeIdentity.IdentityKey(baseline, scope, enclosing) == ProjectVoiceTakeIdentity.IdentityKey(changed, scope, enclosing);
            Assert.True(sameIdentity == row["sameIdentity"]!.GetValue<bool>(), id + ": " + row["why"]!.GetValue<string>());
            var sameInputs = ProjectVoiceTakeIdentity.RewriteInputsKey(baseline, scope, enclosing) == ProjectVoiceTakeIdentity.RewriteInputsKey(changed, scope, enclosing);
            Assert.True(sameInputs == row["sameRewriteInputs"]!.GetValue<bool>(), id + " (rewrite inputs): " + row["why"]!.GetValue<string>());
            Assert.NotEqual(ProjectSerialization.Serialize(baseline), ProjectSerialization.Serialize(changed));
        }
    }

    [Fact]
    public void AProjectWithNoCleanAudioChoiceIsCleanAudioOff()
    {
        var project = Project(Rows("base"));
        var legacy = project with { VoiceLab = project.VoiceLab with { CleanAudio = null } };
        Assert.Equal(ProjectVoiceTakeIdentity.IdentityKey(project, RewriteScope.Clip("clip-main"), null),
            ProjectVoiceTakeIdentity.IdentityKey(legacy, RewriteScope.Clip("clip-main"), null));
    }

    private static Project Project(IEnumerable<JsonNode> sets)
    {
        var root = JsonNode.Parse(FixtureLoader.ReadText(Cases.Value["project"]!.GetValue<string>()))!;
        foreach (var set in sets) Set(root, set["path"]!.GetValue<string>(), set["value"]);
        return ProjectSerialization.Deserialize(root.ToJsonString());
    }

    /// <summary><paramref name="value"/> at the JSON pointer <paramref name="path"/> (no escapes).</summary>
    private static void Set(JsonNode root, string path, JsonNode? value)
    {
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var node = root;
        foreach (var part in parts[..^1]) node = node is JsonArray array ? array[int.Parse(part)]! : node[part]!;
        var copy = value?.DeepClone();
        if (node is JsonArray list) list[int.Parse(parts[^1])] = copy;
        else node.AsObject()[parts[^1]] = copy;
    }

    private static (RewriteScope Scope, string? Enclosing) Scope(JsonNode scope) => scope["kind"]!.GetValue<string>() switch
    {
        "clip" => (RewriteScope.Clip(scope["clipId"]!.GetValue<string>()), null),
        "fullTake" => (RewriteScope.FullTake, null),
        "selection" => (RewriteScope.Selection(scope["first"]!.GetValue<int>(), scope["last"]!.GetValue<int>()), scope["enclosingClipId"]?.GetValue<string>()),
        var kind => throw new InvalidDataException(kind),
    };
}
#else
/// <summary>The Rewrite session follows only what it reads (Mac <c>RewriteSession.move</c>): an export, caption or clip style change
/// moves it on to the edited project and keeps its generation, paid takes included; an edit inside it closes it, as before. Another
/// AI connector no longer ends takes.</summary>
public sealed class VoiceTakeIdentitySessionTests
{
    [Fact]
    public void EditsOutsideTheRewriteKeepTheSessionAndItsGeneration()
    {
        var editor = Editor();
        using var session = new RewriteSession(editor, 10, 12, Envelope(), null);
        var generation = Generation(session);
        session.ConfigureGeneration(generation);
        Assert.True(session.GenerationIsCurrent);
        editor.SetExport(editor.Project.Export with { Aspect = ExportAspect.Square });
        Assert.True(session.IsOpen && ReferenceEquals(session.Generation, generation) && ReferenceEquals(session.Project, editor.Project));
        Assert.True(session.GenerationIsCurrent && session.VoiceSpendCurrent);
        editor.SetCaptions(editor.Project.Captions with { Position = new(0.5, 0.2) });
        Assert.True(session.IsOpen && ReferenceEquals(session.Generation, generation) && ReferenceEquals(session.Project, editor.Project));
        Assert.True(session.GenerationIsCurrent);
        // A cut outside the selection's words is outside what it reads, too.
        Assert.True(editor.Apply(new EditOperation.SetWordCuts(["w40"], true)));
        Assert.True(session.IsOpen && ReferenceEquals(session.Generation, generation) && session.GenerationIsCurrent);
        // One inside them closes the Rewrite, as before.
        Assert.True(editor.Apply(new EditOperation.SetWordCuts(["w11"], true)));
        Assert.False(session.IsOpen);
        Assert.Null(session.Generation);
    }

    [Fact]
    public void AnotherConnectorDoesNotEndTakes()
    {
        var connector = true;
        var editor = Editor();
        using var session = new RewriteSession(editor, 10, 12, Envelope(), null, connectorIsCurrent: () => connector);
        session.ConfigureGeneration(Generation(session));
        connector = false;
        Assert.True(session.GenerationIsCurrent);
    }

    private static RewriteGeneration Generation(RewriteSession session) =>
        new(new UnusedRunner(), _ => Task.FromResult(new RewriteGenerationChoices([], [])), (_, _, _, _) => Task.FromResult<VoiceLabTakeInput?>(null),
            _ => Task.FromResult(false), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent, action => { action(); return Task.CompletedTask; });

    private static EditorViewModel Editor()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "interview-take.voxclip")));
        var words = Enumerable.Range(0, 80).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word, index + 1, index + 1.4,
            null, null, 1, null, TimingSource.Native)).ToArray();
        project = project with { Transcript = project.Transcript! with { Words = words },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 100, Audio = new(48000, 1) } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } };
        return new(project, now: () => new DateTimeOffset(2026, 11, 21, 0, 0, 0, TimeSpan.Zero));
    }
    private static AudioEnvelope Envelope() => new(48000, 0.01, Enumerable.Repeat(0.01f, 10000).ToArray());

    /// <summary>No take is made here: nothing reaches a provider.</summary>
    private sealed class UnusedRunner : IVoiceLabTakeRunner
    {
        public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved, Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null,
            CancellationToken ct = default) => throw new NotSupportedException();
        public Task DiscardPendingAsync() => Task.CompletedTask;
        public void InvalidatePreparation() { }
        public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => false;
        public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => Task.FromResult(cap);
        public Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default) => throw new NotSupportedException();
    }
}
#endif
