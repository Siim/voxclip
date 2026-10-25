using Xunit;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Updates;
namespace VoxClip.Core.Tests.Tracks;

public sealed class UiPlaceholderTests
{
    [Fact]
    public async Task LoggingRedactsEverySinkAndKeepsBoundedDiagnostics()
    {
        var path = Path.Combine(Path.GetTempPath(), "voxclip-log-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var sink = new StringWriter();
            await using (var log = new Log(path, sink))
            {
                log.RegisterSecret("unit_test_sensitive_value");
                for (var index = 0; index < 220; index++) log.Write(LogLevel.Info, "test", "unit_test_sensitive_value safe metadata " + index);
                await log.FlushAsync(CancellationToken.None);
                var lines = await log.ReadRecentAsync(500, CancellationToken.None);
                Assert.Equal(200, lines.Count); Assert.All(lines, line => Assert.DoesNotContain("unit_test_sensitive_value", line));
                Assert.DoesNotContain("unit_test_sensitive_value", sink.ToString()); Assert.Contains("[REDACTED]", sink.ToString());
            }
            Assert.NotEmpty(Directory.GetFiles(path));
            foreach (var file in Directory.GetFiles(path)) Assert.DoesNotContain("unit_test_sensitive_value", await File.ReadAllTextAsync(file, TestContext.Current.CancellationToken));
        }
        finally { if (Directory.Exists(path)) Directory.Delete(path, true); }
    }
    [Fact]
    public async Task DevelopmentUpdateCheckerDoesNotReportFakeUpdates()
    {
        Assert.Null(await new UpdateChecker().CheckAsync(false, CancellationToken.None));
    }
    [Fact]
    public async Task FailingLogSinkCannotBreakFlushOrDiagnostics()
    {
        var path = Path.Combine(Path.GetTempPath(), "voxclip-log-" + Guid.NewGuid().ToString("N"));
        try
        {
            await using var log = new Log(path, new FailingWriter());
            log.Write(LogLevel.Error, "test", "safe metadata");
            await log.FlushAsync(TestContext.Current.CancellationToken);
            Assert.Single(await log.ReadRecentAsync(10, TestContext.Current.CancellationToken));
        }
        finally { if (Directory.Exists(path)) Directory.Delete(path, true); }
    }
    private sealed class FailingWriter : StringWriter
    {
        public override Task WriteLineAsync(string? value) => throw new InvalidOperationException("sink unavailable");
    }
}
