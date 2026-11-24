using System.Net;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class LipsyncRunTests
{
    private const string ProjectId = "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11";

    [Fact]
    public void APublishedVoiceIsRecoverableFromItsClipWithoutASeparateIndexWrite()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-whole-clip-").FullName;
        try
        {
            var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/whole-clip-revoice-project.voxclip"));
            var previous = Assert.Single(project.VoiceLab.WholeClipRevoices!);
            var segment = project.VoiceLab.Segments[0];
            var candidate = segment.Candidates[segment.SelectedCandidateIndex];
            var source = segment with { Id = Guid.NewGuid().ToString("D"), Candidates = [candidate with
                { Recipe = candidate.Recipe! with { Video = VoiceLabLipsync.Base(candidate.Recipe!.Video) } }], SelectedCandidateIndex = 0 };
            var voice = Assert.Single(project.VoiceLab.Voices!) with { Status = VoiceLabVoiceStatus.Active };
            project = project with { VoiceLab = project.VoiceLab with { Voices = [voice] } };
            var draft = WholeClipRevoiceDraft.Voice(project, previous.ClipId, new([source], [], voice));
            var baseKey = new string('a', 64);
            var identity = new string('b', 64);
            var info = new WholeClipVoiceRecovery(baseKey, identity, previous.ClipId, Guid.NewGuid().ToString("D"), previous.Script);
            WholeClipVoiceCheckpoint.Keep(root, new(draft, [source.Id], 1.25m) { Recovery = info });

            var saved = Assert.IsType<SavedWholeClipVoice>(WholeClipVoiceCheckpoint.ReadLatest(root, project.Id, baseKey));
            Assert.Equal(info, saved.Recovery);
            Assert.Equal(1.25m, saved.Spent);
            Assert.Equal(source.Id, Assert.Single(saved.SegmentIds));
            Assert.Null(WholeClipVoiceCheckpoint.ReadLatest(root, project.Id, new string('c', 64)));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task AcceptedJobSurvivesCancellationAndResumesOnlyOnTheSameAccount()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-lipsync-").FullName;
        var token = TestContext.Current.CancellationToken;
        try
        {
            var data = new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "models"), Path.Combine(root, "cache"),
                Path.Combine(root, "autosave"), Path.Combine(root, "secrets"), Path.Combine(root, "logs"));
            var store = new VoiceConsentStore(data);
            var spend = new VoiceLabSpendLedger(data);
            var reference = JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"), VoiceConsentJson.Default.VoiceConsentRecord)!;
            var wave = VoiceLabTakeProcessing.EncodeQaWav(new float[16000 * 6], 16000);
            store.SaveStatement(wave, reference.RecordId);
            var record = reference with { Statement = reference.Statement! with { AudioSha256 = VoiceConsentStore.Hash(wave) } };
            store.Save(record);
            var prices = VoiceLabPriceCatalog.Parse(System.Text.Encoding.UTF8.GetBytes(FixtureLoader.ReadText("catalog/voice-lab.json")));
            var video = Path.Combine(root, "window.mp4");
            var audio = Path.Combine(root, "mixed.wav");
            File.WriteAllBytes(video, [1, 2]);
            File.WriteAllBytes(audio, [3, 4]);
            var window = new LipsyncRunWindow("approved-edited-window", 4, 30, WholeClipLipsync.Lipsync2, SyncMode.Remap);
            using var stopped = CancellationTokenSource.CreateLinkedTokenSource(token);
            var initial = new QueueHandler(stopped);
            using var provider = new FalLipsyncProvider(new Key("original-account"), prices, initial);
            var run = new LipsyncRun(provider, store, root, ProjectId, spend);
            var quote = await run.QuoteAsync(window, token);
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run.ExecuteAsync(window, quote, video, audio, record, null, null, stopped.Token));

            using var stoppedAfterDone = CancellationTokenSource.CreateLinkedTokenSource(token);
            var recovery = new QueueHandler(stopAtDownload: stoppedAfterDone, denyCleanup: true);
            using var wrong = new FalLipsyncProvider(new Key("another-account"), prices, recovery);
            var reopened = new LipsyncRun(wrong, store, root, ProjectId);
            Assert.Equal(LipsyncAttemptState.Accepted, reopened.State(window));
            var error = await Assert.ThrowsAsync<FalLipsyncException>(() => reopened.ExecuteAsync(window, null, null, null, record, null, null, token));
            Assert.Equal(FalLipsyncError.ApprovalRequired, error.Code);
            Assert.Empty(recovery.Requests);

            var denied = new List<(string Fingerprint, int Status)>();
            using var right = new FalLipsyncProvider(new Key("original-account"), prices, recovery, (fingerprint, status) => denied.Add((fingerprint, status)));
            var resume = new LipsyncRun(right, store, root, ProjectId, spend);
            var picture = await resume.ExecuteAsync(window, null, null, null, record, null, null, stoppedAfterDone.Token);
            Assert.True(stoppedAfterDone.IsCancellationRequested);
            Assert.Equal("fixture-job", picture.RequestId);
            Assert.Equal("fixture-picture", File.ReadAllText(picture.Path));
            Assert.Equal(LipsyncAttemptState.Downloaded, resume.State(window));
            Assert.Equal((await right.AccountFingerprintAsync(token), 403), Assert.Single(denied));
            Assert.Equal(quote.Estimate.Usd, resume.AcceptedPrice(window));
            Assert.Equal([HttpMethod.Get, HttpMethod.Get, HttpMethod.Get, HttpMethod.Delete], recovery.Requests);
            Assert.Equal(picture, await resume.ExecuteAsync(window, null, null, null, record, null, null, token));
            Assert.Equal(4, recovery.Requests.Count);
            Assert.Equal(quote.Estimate.Usd, (await spend.TotalAsync("fal", DateTimeOffset.Now, token))?.Usd);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void AReopenedAttemptDistinguishesUnconfirmedSubmissionFromAcceptedJob()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-lipsync-").FullName;
        try
        {
            var window = new LipsyncRunWindow("clip-inputs", 10, 30, WholeClipLipsync.Lipsync2, SyncMode.Remap);
            var journal = new LipsyncAttemptStore(root, ProjectId);
            using (var attempt = journal.Open(window)) attempt.Begin();

            journal = new(root, ProjectId);
            using (var attempt = journal.Open(window))
            {
                Assert.Equal(LipsyncAttemptState.Unconfirmed, attempt.State);
                Assert.Throws<InvalidOperationException>(attempt.Begin);
                attempt.Accept("fixture-job", new string('a', 64), 0.50m);
            }

            journal = new(root, ProjectId);
            using (var attempt = journal.Open(window))
            {
                Assert.Equal(LipsyncAttemptState.Accepted, attempt.State);
                Assert.Equal("fixture-job", attempt.RequestId);
                Assert.Throws<InvalidOperationException>(attempt.Begin);
            }
            using var upgrade = journal.Open(window with { Model = WholeClipLipsync.Sync3 });
            Assert.Equal(LipsyncAttemptState.NotSent, upgrade.State);
        }
        finally { Directory.Delete(root, true); }
    }

    private sealed class Key(string value) : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => Task.FromResult<string?>(value);
    }

    private sealed class QueueHandler(CancellationTokenSource? stop = null, CancellationTokenSource? stopAtDownload = null, bool denyCleanup = false) : HttpMessageHandler
    {
        internal List<HttpMethod> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(request.Method);
            var uri = request.RequestUri!;
            if (request.Method == HttpMethod.Get && stop is not null)
            {
                stop.Cancel();
                ct.ThrowIfCancellationRequested();
            }
            if (uri.Host == "v3.fal.media" && stopAtDownload is not null)
            {
                stopAtDownload.Cancel();
                ct.ThrowIfCancellationRequested();
            }
            var response = (request.Method.Method, uri.Host, uri.AbsolutePath) switch
            {
                ("POST", "rest.fal.ai", "/storage/upload/initiate") => """{"upload_url":"https://storage.fal.ai/put","file_url":"https://v3.fal.media/files/upload"}""",
                ("PUT", "storage.fal.ai", "/put") => "",
                ("POST", "queue.fal.run", "/fal-ai/sync-lipsync/v2") when stop is not null => """{"request_id":"fixture-job"}""",
                ("GET", "queue.fal.run", "/fal-ai/sync-lipsync/requests/fixture-job/status") => """{"status":"COMPLETED"}""",
                ("GET", "queue.fal.run", "/fal-ai/sync-lipsync/requests/fixture-job") => """{"video":{"url":"https://v3.fal.media/files/result"}}""",
                ("GET", "v3.fal.media", "/files/result") => "fixture-picture",
                ("DELETE", "api.fal.ai", "/v1/models/requests/fixture-job/payloads") => "",
                _ => throw new InvalidOperationException("Unexpected request to the stand-in queue."),
            };
            var status = denyCleanup && request.Method == HttpMethod.Delete ? HttpStatusCode.Forbidden : HttpStatusCode.OK;
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(response) });
        }
    }
}
