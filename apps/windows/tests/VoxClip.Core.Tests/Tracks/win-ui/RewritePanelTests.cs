#if WIN_UI_TESTS
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

public sealed class RewritePanelTests
{
    private static string Shared => Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
    private static EditorViewModel Editor(params TimedWord[] words)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures", "projects", "interview-take.voxclip")));
        if (words.Length == 0) words = Enumerable.Range(0, 80).Select(index => Word(index, "word" + index)).ToArray();
        project = project with { Transcript = project.Transcript! with { Words = words },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 100, Audio = new(48000, 1) } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } };
        return new(project);
    }
    private static TimedWord Word(int index, string text, WordKind kind = WordKind.Word) =>
        new("w" + index, text, kind, index + 1, index + 1.4, null, null, 1, null, TimingSource.Aligned);
    private static AudioEnvelope Envelope() => new(48000, 0.01, Enumerable.Repeat(0.01f, 10000).ToArray());

    [Fact]
    public async Task PanelProposalIsInertUntilTheDisplayedEstimateIsApproved()
    {
        var editor = Editor();
        var fake = new RecordingConnector();
        using var session = new RewriteSession(editor, 10, 12, Envelope(), new(fake, "chosen", "Test connector", "apiKey", ""));
        Assert.Equal(editor.SelectionText, "");
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

    private sealed class RecordingConnector : ILlmConnector
    {
        internal List<string> Calls { get; } = [];
        public ConnectorId Id => ConnectorId.OpenAI;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) { Calls.Add("status"); return Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready()); }
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct)
        { Calls.Add("models"); return Task.FromResult<IReadOnlyList<LlmModel>>([new("chosen", "Chosen", null, 32768, ModelSource.Discovered)]); }
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) { Calls.Add("context"); return Task.FromResult<int?>(32768); }
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        { Calls.Add("send"); return Task.FromResult(new RawCompletion(null, new JsonObject { ["rewrite"] = "Better passage" }, model, new StopKind.Complete(), null, "fake")); }
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
        Assert.Equal(entry == RewriteEntry.InsertWords ? RewriteEntryAction.OpenInsertion : RewriteEntryAction.OpenPassage,
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
#if !DEBUG
        Assert.False(RewriteEntryPolicy.BuildEnabled);
#endif
    }
}
#endif
