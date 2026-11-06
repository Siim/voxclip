#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Rebuild from my videos in Settings › Voices (voice-lab.md §6.12, ADR-R44; Mac <c>VoiceRebuildFlowTests</c>): found speech is shown
/// first, the three attestations draft the free quote, Rebuild · price is the only paid click, then Use the new voice for Rewrite and Remove
/// the old voice (confirmed inline) each act once. Rewrite starts with the voice the setting chose. Behind the closed parity gate nothing is
/// offered. A stub backend; nothing is sent.</summary>
public sealed class VoiceRebuildFlowTests
{
    private static Task Dispatch(Action action) { action(); return Task.CompletedTask; }

    [Fact]
    public async Task RebuildsFromVerifiedSpeechThenSwitchesAndRemovesTheOldVoiceInline()
    {
        var old = VoiceLabLearningTests.Record();
        var backend = new RebuildBackend { Records = [old], Available = true, Projects = ["/p/a.voxclip", "/p/b.voxclip"] };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.RefreshEnabledStateAsync();
        Assert.True(session.RebuildOffered(session.Records[0]));
        await session.FindRebuildAsync(old.RecordId);
        var state = session.Rebuild(old.RecordId);
        Assert.Equal(VoiceRebuildPhase.Found, state.Phase);
        Assert.Equal("1 min 8 s from 1 video and your consent clip", state.Summary);
        Assert.Equal([27.72, 15.4, 12.3, 13.0], state.Found!.PieceSeconds);
        Assert.Equal("Tick the three boxes to rebuild. Only this speech is sent to ElevenLabs; no video.", state.Line);
        Assert.Equal(["/p/a.voxclip", "/p/b.voxclip"], backend.Found);
        // Two boxes: still no quote. The third drafts it, free.
        await session.SetRebuildAttestationAsync(state, ownVoice: true);
        await session.SetRebuildAttestationAsync(state, adult: true);
        Assert.Equal(0, backend.Prepared);
        await session.SetRebuildAttestationAsync(state, ownVideosOnly: true);
        Assert.Equal(VoiceRebuildPhase.Ready, state.Phase);
        Assert.Equal("Rebuild · $0", VoiceLabSession.RebuildTitle(state));
        Assert.Equal("Sends 1 min 8 s of your speech to ElevenLabs to make a new voice, with your checkbox consent. No video is sent. Your current voice stays until you remove it.", state.Line);
        Assert.Equal("Example", backend.Name);
        // Unticking drops the draft; ticking again drafts a fresh one.
        await session.SetRebuildAttestationAsync(state, adult: false);
        Assert.Equal(VoiceRebuildPhase.Found, state.Phase);
        Assert.Equal(1, backend.Cancelled);
        await session.SetRebuildAttestationAsync(state, adult: true);
        Assert.Equal(2, backend.Prepared);
        Assert.Equal(0, backend.Approved);
        await session.ApproveRebuildAsync(state);
        Assert.Equal(1, backend.Approved);
        Assert.Equal(VoiceRebuildPhase.Created, state.Phase);
        Assert.Equal("Your rebuilt voice is ready. It keeps what VoxClip learned from 2 of your videos. Next: use it for Rewrite, then remove the old voice.", state.Line);
        // A second click does nothing: the quote is spent.
        await session.ApproveRebuildAsync(state);
        Assert.Equal(1, backend.Approved);
        await session.UseRebuiltVoiceAsync(state);
        Assert.Equal(backend.NewId, backend.RewriteVoiceSetting);
        Assert.Equal("Rewrite uses your rebuilt voice. Next: remove the old voice.", state.Line);
        // Remove the old voice confirms inline first.
        await session.RemoveOldVoiceAsync(state);
        Assert.Empty(backend.Deleted);
        session.ConfirmOldVoiceRemoval(state, true);
        await session.RemoveOldVoiceAsync(state);
        Assert.Equal([old.RecordId], backend.Deleted);
        Assert.True(state.Removed);
        Assert.Equal("Removed the old voice. Rewrite uses your rebuilt voice. Existing takes stay playable and labelled.", state.Line);
        Assert.Equal("siim", VoiceLabSession.RebuildName("siim (VoxClip)"));
    }

    [Fact]
    public async Task TooLittleSpeechSaysHowMuchWhyAndWhatToDo()
    {
        var old = VoiceLabLearningTests.Record();
        var backend = new RebuildBackend { Records = [old], Available = true, Projects = ["/p/a.voxclip"], NotEnough = (27_000, 15) };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.RefreshEnabledStateAsync();
        await session.FindRebuildAsync(old.RecordId);
        var state = session.Rebuild(old.RecordId);
        Assert.Equal(VoiceRebuildPhase.Failed, state.Phase);
        Assert.Equal("Only 27 s of clean speech that's clearly yours in 1 video, and 15 stretches were too noisy to train a voice. A rebuild needs 30 s. Transcribe a video recorded somewhere quiet, then try again.", state.Line);
        Assert.Equal(0, backend.Prepared);
        await session.FindRebuildAsync(old.RecordId, []);
        Assert.Equal("Open or export a video first. VoxClip rebuilds your voice from your projects on this PC.", state.Line);
    }

    /// <summary>Behind the closed parity gate the speaker check is never ready: Rebuild is not offered and a call finds nothing.</summary>
    [Fact]
    public async Task BehindTheGateNothingIsOfferedOrRead()
    {
        var old = VoiceLabLearningTests.Record();
        var backend = new RebuildBackend { Records = [old], Available = false, Projects = ["/p/a.voxclip"] };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.RefreshEnabledStateAsync();
        Assert.False(session.RebuildOffered(session.Records[0]));
        await session.FindRebuildAsync(old.RecordId);
        Assert.Empty(backend.Found);
        Assert.Equal(VoiceRebuildPhase.Idle, session.Rebuild(old.RecordId).Phase);
        // A statement voice (no project consent) is never offered a rebuild.
        Assert.False(session.RebuildOffered(old with { ProjectConsent = null }));
    }

    /// <summary>Mac <c>rewriteStartsWithTheVoiceSettingsChose</c>: Rewrite's first voice is the preferred one when it is listed, else the first.</summary>
    [Fact]
    public async Task RewriteStartsWithTheVoiceTheSettingChose()
    {
        RewriteVoice[] voices = [new("first", "First"), new("rebuilt", "Rebuilt")];
        Assert.Equal("rebuilt", RewriteGeneration.InitialVoice(voices, "rebuilt"));
        Assert.Equal("first", RewriteGeneration.InitialVoice(voices, "removed"));
        Assert.Equal("first", RewriteGeneration.InitialVoice(voices, null));
        Assert.Null(RewriteGeneration.InitialVoice([], "rebuilt"));
        using var session = Session(new(Reply, (_, ordinals) => Rows(ordinals, "x")));
        session.ConfigureGenerationFactory(index => new(new Runner((_, _) => (Fit, Passed)),
            _ => Task.FromResult(new RewriteGenerationChoices(voices, [new("eleven_v4", "Eleven v4", ["en"], true, false, 5000, 1)])),
            (voice, model, seed, ct) => Task.FromResult<VoiceLabTakeInput?>(null), _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null),
            () => session.GenerationIsCurrent) { PreferredVoice = () => "rebuilt" });
        Assert.True(await ProposeAsync(session));
        await session.DiscoverWindowsAsync();
        Assert.Equal("rebuilt", session.GenerationWindows[0].VoiceId);
    }

    private sealed class RebuildBackend : IVoiceLabBackend
    {
        public bool Enabled { get; set; } = true;
        internal IReadOnlyList<VoiceConsentRecord> Records = [];
        internal bool Available;
        internal IReadOnlyList<string> Projects = [];
        internal (long Milliseconds, int Noisy)? NotEnough;
        internal readonly List<string> Found = [];
        internal readonly List<string> Deleted = [];
        internal int Prepared, Cancelled, Approved;
        internal string? Name, RewriteVoiceSetting;
        internal readonly string NewId = Guid.NewGuid().ToString("D");
        public Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct) => Task.FromResult(new VoiceLabSnapshot(Records, []));
        public Task ReconcileAsync(bool force, CancellationToken ct) => Task.CompletedTask;
        public Task PersistProviderConsentAsync(CancellationToken ct) => Task.CompletedTask;
        public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct) => throw new InvalidOperationException();
        public Task DeleteAsync(string recordId, CancellationToken ct) { Deleted.Add(recordId); Records = Records.Where(record => record.RecordId != recordId).ToArray(); return Task.CompletedTask; }
        public Task RemoveLocalAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task WithdrawAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task SaveAsync(VoiceConsentRecord record, CancellationToken ct) => throw new InvalidOperationException();
        public Task RemoveSpeakerAsync(CancellationToken ct) => throw new InvalidOperationException();
        public Task StopLookingAsync(Guid operationId, CancellationToken ct) => throw new InvalidOperationException();
        public bool LearningAvailable(string language) => Available;
        public IReadOnlyList<string> LearningProjects() => Projects;
        public Task<VoiceRebuildFind> FindRebuildAsync(string recordId, IReadOnlyList<string> projects, Func<int, int, Task> progress, CancellationToken ct)
        {
            Found.AddRange(projects);
            if (NotEnough is { } little) throw new VoiceRebuildNotEnoughException(little.Milliseconds, little.Noisy);
            return Task.FromResult(new VoiceRebuildFind("1 min 8 s from 1 video and your consent clip", [27.72, 15.4, 12.3, 13.0], new object()));
        }
        public Task<VoiceRebuildQuote> PrepareRebuildAsync(VoiceConsentRecord old, VoiceRebuildFind found, VoiceConsentAttestations attestations, string displayName, CancellationToken ct)
        {
            Assert.True(attestations.OwnVoice && attestations.Adult && attestations.OwnVideosOnly);
            Prepared++; Name = displayName;
            return Task.FromResult(new VoiceRebuildQuote(NewId, 0m, 68_420, new object()));
        }
        public Task CancelRebuildAsync(VoiceRebuildQuote quote, CancellationToken ct) { Cancelled++; return Task.CompletedTask; }
        public Task<VoiceRebuildCreated> ApproveRebuildAsync(string oldRecordId, VoiceRebuildQuote quote, CancellationToken ct)
        {
            Approved++;
            var created = Records[0] with { RecordId = NewId, VoiceId = "rebuilt-voice" };
            Records = [.. Records, created];
            return Task.FromResult(new VoiceRebuildCreated(created, 2));
        }
        public Task SetRewriteVoiceAsync(string recordId, CancellationToken ct) { RewriteVoiceSetting = recordId; return Task.CompletedTask; }
        public string? RewriteVoice() => RewriteVoiceSetting;
    }
}
#endif
