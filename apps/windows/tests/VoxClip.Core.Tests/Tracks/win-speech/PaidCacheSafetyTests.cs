using System.Security.AccessControl;
using System.Security.Principal;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class PaidCacheSafetyTests
{
    [Fact]
    public async Task ReadOnlyCacheAfterUploadStillReturnsAndReusesThePaidTranscript()
    {
        using var files = new SpeechFiles();
        var request = files.Request();
        var directory = Path.Combine(files.Root, "Cache", request.ContentKey, "transcripts");
        ReadOnlyDirectory? protection = null;
        using var handler = new StubHttp(async (message, ct) =>
        {
            await message.Content!.CopyToAsync(Stream.Null, ct);
            protection = new(directory);
            return StubHttp.Json(ElevenLabsTests.Response);
        });
        using var http = new HttpClient(handler);
        await using var log = new CacheLog();
        try
        {
            var fresh = await new TranscriptionService([new ElevenLabsTranscriber(new TestKeys(), http, baseUri: null, logger: log)], dataRoot: files.Root)
                .TranscribeAsync(request, null, null, TestContext.Current.CancellationToken);
            Assert.False(fresh.FromCache);
            Assert.Contains(fresh.Words, word => word.Text == "Tere,");
            Assert.Equal(1, handler.Calls);
            Assert.NotEmpty(log.Warnings);
            Assert.All(log.Warnings, warning =>
            {
                Assert.DoesNotContain(files.Root, warning);
                Assert.DoesNotContain("Tere", warning);
                Assert.DoesNotContain("synthetic-test-credential", warning);
            });
        }
        finally { protection?.Dispose(); }
        var cached = await new TranscriptionService([new ElevenLabsTranscriber(new TestKeys(), http, baseUri: null)], dataRoot: files.Root)
            .TranscribeAsync(request, null, null, TestContext.Current.CancellationToken);
        Assert.True(cached.FromCache);
        Assert.Contains(cached.Words, word => word.Text == "Tere,");
        Assert.Equal(1, handler.Calls);
        Assert.Single(Directory.EnumerateFiles(directory, "*.json"));
        await new TranscriptionService([new ElevenLabsTranscriber(new TestKeys(), http, baseUri: null)], dataRoot: files.Root)
            .TranscribeAsync(request, null, null, TestContext.Current.CancellationToken);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task ReadOnlyPreflightIsNotReportedAsDiskFull()
    {
        using var files = new SpeechFiles();
        var request = files.Request();
        var directory = Path.Combine(files.Root, "Cache", request.ContentKey, "transcripts");
        Directory.CreateDirectory(directory);
        using var protection = new ReadOnlyDirectory(directory);
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not upload."));
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<VoxClipException>(() =>
            new TranscriptionService([new ElevenLabsTranscriber(new TestKeys(), http, baseUri: null)], dataRoot: files.Root)
                .TranscribeAsync(request, null, null, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.TranscriptionFailed, error.Code);
        Assert.Equal("Transcription stopped: the transcript cache is unavailable. Your video is still here.", error.Message);
        Assert.Equal(0, handler.Calls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PaidCallbackRetriesCacheErrorsWithoutRetryingTheUpload(bool accessDenied)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(ElevenLabsTests.Response)));
        using var http = new HttpClient(handler);
        var writes = 0;
        var raw = await new ElevenLabsTranscriber(new TestKeys(), http, baseUri: null).TranscribeAndCacheAsync(files.Request(),
            new CaptureProgress<TranscriptionProgress>(), _ =>
            {
                writes++;
                throw accessDenied ? new UnauthorizedAccessException() : new IOException();
            }, TestContext.Current.CancellationToken);
        Assert.NotEmpty(raw.Tokens);
        Assert.Equal(3, writes);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task TransientCacheWriteRetriesAndSucceeds()
    {
        var writes = 0;
        Assert.True(await SpeechTransport.TryCacheWriteAsync(() =>
        {
            if (++writes < 3) throw new IOException();
            return Task.CompletedTask;
        }, TestContext.Current.CancellationToken));
        Assert.Equal(3, writes);
    }

    [Fact]
    public void PreflightUsesARealisticSizeAndFormatsTheActualShortfall()
    {
        using var files = new SpeechFiles();
        Assert.True(TranscriptionService.EstimatedResponseBytes(1) >= 4 * 1024 * 1024);
        Assert.True(TranscriptionService.EstimatedResponseBytes(36_000) > 4 * 1024 * 1024);
        var error = Assert.Throws<VoxClipException>(() => TranscriptionService.RequireCacheSpace(files.Root, 4_000_000, 1_000_000));
        Assert.Equal(VoxClipErrorCode.DiskFull, error.Code);
        Assert.EndsWith("Free up 3 MB and try again.", error.Message);
        Assert.Equal("1 byte", SpeechCopy.Bytes(1));
        TranscriptionService.RequireCacheSpace(files.Root, 4_000_000, 4_000_000);
    }

    private sealed class ReadOnlyDirectory : IDisposable
    {
        private readonly string path;
        private readonly UnixFileMode unixMode;
        private readonly byte[]? windowsAccess;

        internal ReadOnlyDirectory(string path)
        {
            this.path = path;
            if (OperatingSystem.IsWindows())
            {
                var directory = new DirectoryInfo(path);
                windowsAccess = directory.GetAccessControl().GetSecurityDescriptorBinaryForm();
                var denied = directory.GetAccessControl();
                using var identity = WindowsIdentity.GetCurrent();
                denied.AddAccessRule(new FileSystemAccessRule(identity.User!, FileSystemRights.Write | FileSystemRights.Delete,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Deny));
                directory.SetAccessControl(denied);
            }
            else
            {
                unixMode = File.GetUnixFileMode(path);
                File.SetUnixFileMode(path, unixMode & ~(UnixFileMode.UserWrite | UnixFileMode.GroupWrite | UnixFileMode.OtherWrite));
            }
        }

        public void Dispose()
        {
            if (OperatingSystem.IsWindows())
            {
                var restored = new DirectorySecurity();
                restored.SetSecurityDescriptorBinaryForm(windowsAccess!, AccessControlSections.Access);
                new DirectoryInfo(path).SetAccessControl(restored);
            }
            else File.SetUnixFileMode(path, unixMode);
        }
    }

    private sealed class CacheLog : ILog
    {
        internal List<string> Warnings { get; } = [];
        public void RegisterSecret(string secret) { }
        public void Write(LogLevel level, string category, string message) { if (level == LogLevel.Warn) Warnings.Add(message); }
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
