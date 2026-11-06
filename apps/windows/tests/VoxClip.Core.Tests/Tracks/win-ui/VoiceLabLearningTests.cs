#if WIN_UI_TESTS
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Settings › Voices, learned references (ADR-R41; Mac <c>VoiceLabSessionTests.settingsShowsLearnedVideosAndForgetsThemInline</c>):
/// each voice says how many videos taught it, Learn from my videos reads each project once with the progress inline, Forget learned
/// references removes them inline, and behind the closed parity gate Learn is not offered at all. Stubs only; nothing is sent.</summary>
public sealed class VoiceLabLearningTests
{
    private static Task Dispatch(Action action) { action(); return Task.CompletedTask; }
    internal static VoiceConsentRecord Record() => JsonSerializer.Deserialize<VoiceConsentRecord>(
        File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "voice-lab", "consent-record-project.json")),
        new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
    internal static VoiceConsentRecord WithReferences(VoiceConsentRecord record, int count) => record with
    {
        Speaker = record.Speaker.ReplacingReferences(Enumerable.Range(0, count).Select(index =>
            new VoiceConsentReference(record.Speaker.Embedding, "video-" + index, "2026-11-05T12:00:00Z", 1, record.Speaker.Model)).ToArray())
    };

    [Fact]
    public async Task SettingsShowsLearnedVideosAndForgetsThemInline()
    {
        var record = Record();
        var backend = new LearningBackend { Records = [record], Available = true, Outcomes = [VoiceReferenceLearnerOutcome.Learned, VoiceReferenceLearnerOutcome.NotTheOwner, VoiceReferenceLearnerOutcome.Kept] };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.RefreshEnabledStateAsync();
        Assert.Equal("Not learned from your videos yet. VoxClip learns your voice from each video you transcribe.", VoiceLabSession.LearnedLine(session.Records[0]));
        Assert.True(session.CanLearn(session.Records[0]));
        Assert.False(session.CanForget(session.Records[0]));
        backend.AfterLearn = () => backend.Records = [WithReferences(record, 2)];
        await session.LearnFromVideosAsync(record.RecordId, ["/p/a.voxclip", "/p/b.voxclip", "/p/c.voxclip"]);
        Assert.Equal(["read:/p/a.voxclip", "read:/p/b.voxclip", "read:/p/c.voxclip"], backend.Calls.Where(call => call.StartsWith("read:", StringComparison.Ordinal)));
        Assert.Equal("Checked 3 videos: your voice is learned from 2. 1 didn't sound like you; nothing was kept from it.", session.LearningLines[record.RecordId]);
        Assert.Equal("Learned from 2 of your videos", VoiceLabSession.LearnedLine(session.Records[0]));
        Assert.False(session.IsLearning);
        Assert.True(session.CanForget(session.Records[0]));
        backend.AfterForget = () => backend.Records = [record];
        await session.ForgetLearnedAsync(record.RecordId);
        Assert.Contains("forget", backend.Calls);
        Assert.Equal("Forgot what VoxClip learned from your videos. Your consent statement still checks every phrase.", session.LearningLines[record.RecordId]);
        Assert.Equal("Not learned from your videos yet. VoxClip learns your voice from each video you transcribe.", VoiceLabSession.LearnedLine(session.Records[0]));
        Assert.False(session.CanForget(session.Records[0]));
        Assert.Equal("Learned from 1 of your videos", VoiceLabSession.LearnedLine(WithReferences(record, 1)));
    }

    [Fact]
    public async Task NoProjectsSaysWhatToDoFirst()
    {
        var backend = new LearningBackend { Records = [Record()], Available = true };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.RefreshEnabledStateAsync();
        await session.LearnFromVideosAsync(Record().RecordId, []);
        Assert.Equal("Open or export a video first. VoxClip learns from your projects on this PC.", session.LearningLines[Record().RecordId]);
        Assert.DoesNotContain(backend.Calls, call => call.StartsWith("read:", StringComparison.Ordinal));
    }

    /// <summary>Behind the closed parity gate the speaker check is never ready: Learn is not offered, a call does nothing, and quiet learning
    /// after a transcription reads nothing. Forget still acts on what a Mac learned.</summary>
    [Fact]
    public async Task BehindTheGateLearnIsNotOfferedAndNothingIsRead()
    {
        var record = WithReferences(Record(), 1);
        var backend = new LearningBackend { Records = [record], Available = false };
        using var session = new VoiceLabSession(backend, Dispatch);
        await session.RefreshEnabledStateAsync();
        Assert.False(session.LearningOffered(session.Records[0]));
        Assert.False(session.CanLearn(session.Records[0]));
        await session.LearnFromVideosAsync(record.RecordId, ["/p/a.voxclip"]);
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "interview-take.voxclip")));
        await session.LearnFromTranscribedAsync(project, "/p/a.mp4");
        Assert.DoesNotContain(backend.Calls, call => call.StartsWith("read:", StringComparison.Ordinal) || call.StartsWith("learn", StringComparison.Ordinal));
        Assert.True(session.CanForget(session.Records[0]));
        // The production backend makes no speaker check here, so it never offers learning.
        Assert.Null(VoiceSpeakerProbe.From(VoxClip.Core.Services.VoiceLab.VoiceSpeakerCheck.Unavailable));
    }

    [Fact]
    public void LearningReadsRecentProjectsThenTheExportFolderOnce()
    {
        var folder = Path.Combine(Path.GetTempPath(), "voxclip-learning-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            File.WriteAllText(Path.Combine(folder, "b.voxclip"), "{}");
            File.WriteAllText(Path.Combine(folder, "a.voxclip"), "{}");
            File.WriteAllText(Path.Combine(folder, "c.mp4"), "");
            Directory.CreateDirectory(Path.Combine(folder, "nested"));
            File.WriteAllText(Path.Combine(folder, "nested", "d.voxclip"), "{}");
            var recent = Path.Combine(folder, "b.voxclip");
            var paths = VoiceLabSession.LearningProjects([recent, "relative.voxclip"], folder);
            Assert.Equal([recent, Path.Combine(folder, "a.voxclip")], paths);
            Assert.Equal([recent], VoiceLabSession.LearningProjects([recent], Path.Combine(folder, "missing")));
        }
        finally { Directory.Delete(folder, true); }
    }

    internal sealed class LearningBackend : IVoiceLabBackend
    {
        public bool Enabled { get; set; } = true;
        internal IReadOnlyList<VoiceConsentRecord> Records = [];
        internal bool Available;
        internal List<VoiceReferenceLearnerOutcome> Outcomes = [];
        internal Action? AfterLearn, AfterForget;
        internal readonly List<string> Calls = [];
        public Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct) => Task.FromResult(new VoiceLabSnapshot(Records, []));
        public Task ReconcileAsync(bool force, CancellationToken ct) => Task.CompletedTask;
        public Task PersistProviderConsentAsync(CancellationToken ct) => throw new InvalidOperationException();
        public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct) => throw new InvalidOperationException();
        public Task DeleteAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task RemoveLocalAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task WithdrawAsync(string recordId, CancellationToken ct) => throw new InvalidOperationException();
        public Task SaveAsync(VoiceConsentRecord record, CancellationToken ct) => throw new InvalidOperationException();
        public Task RemoveSpeakerAsync(CancellationToken ct) => throw new InvalidOperationException();
        public Task StopLookingAsync(Guid operationId, CancellationToken ct) => throw new InvalidOperationException();
        public bool LearningAvailable(string language) => Available;
        public Task<VoiceLabProjectSource?> ReadProjectAsync(string projectPath, CancellationToken ct)
        {
            Calls.Add("read:" + projectPath);
            var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "interview-take.voxclip")));
            return Task.FromResult<VoiceLabProjectSource?>(new(project, projectPath + ".mp4"));
        }
        public Task<VoiceReferenceLearnerOutcome> LearnAsync(VoiceLabProjectSource source, string recordId, CancellationToken ct)
        {
            Calls.Add("learn:" + recordId);
            var outcome = Outcomes.Count > 0 ? Outcomes[0] : VoiceReferenceLearnerOutcome.NoSpeech;
            if (Outcomes.Count > 0) Outcomes.RemoveAt(0);
            if (Outcomes.Count == 0) AfterLearn?.Invoke();
            return Task.FromResult(outcome);
        }
        public Task ForgetReferencesAsync(string recordId, CancellationToken ct) { Calls.Add("forget"); AfterForget?.Invoke(); return Task.CompletedTask; }
    }
}
#endif
