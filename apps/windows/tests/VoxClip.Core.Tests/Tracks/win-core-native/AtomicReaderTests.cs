using System.Text;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Tests.Tracks.WinEditing;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCoreNative;

public sealed class AtomicReaderTests
{
    [Theory]
    [InlineData(2, 5)]
    [InlineData(2, 6)]
    [InlineData(32, 5)]
    [InlineData(33, 5)]
    [InlineData(32, 6)]
    [InlineData(33, 6)]
    [InlineData(5, 1)]
    public async Task ReaderRetriesOnlyReplacementOpenFailuresWithin775Milliseconds(int code, int failures)
    {
        using var files = new TestStorage();
        var path = files.PathFor("settings.json");
        await File.WriteAllTextAsync(path, "{\"version\":1}\n", TestContext.Current.CancellationToken);
        var operations = new ReadFaults { Code = code, RemainingFailures = failures };
        if (failures == 6 || code == 5)
        {
            var error = await Assert.ThrowsAsync<IOException>(() => AtomicFile.ReadAllTextAsync(path,
                new UTF8Encoding(false, true), TestContext.Current.CancellationToken, operations));
            Assert.Equal(code, error.HResult & 0xFFFF);
        }
        else Assert.Equal("{\"version\":1}\n", await AtomicFile.ReadAllTextAsync(path,
            new UTF8Encoding(false, true), TestContext.Current.CancellationToken, operations));
        Assert.Equal(code == 5 ? 1 : 6, operations.ReadAttempts);
        Assert.Equal(code == 5 ? [] : new[] { 25, 50, 100, 200, 400 }, operations.Delays);
        Assert.True(operations.Delays.Sum() <= 1000);
    }

    [Theory]
    [InlineData("settings.json")]
    [InlineData("project.voxclip")]
    public async Task DeleteSharingReaderKeepsWholeOldDocumentWhileWriterCommitsNewOne(string name)
    {
        using var files = new TestStorage();
        var path = files.PathFor(name);
        var oldDocument = "{\"old\":\"" + new string('a', 100_000) + "\"}\n";
        var newDocument = "{\"new\":\"" + new string('b', 100_000) + "\"}\n";
        await AtomicFile.WriteAsync(path, oldDocument, TestContext.Current.CancellationToken);
        await using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            await AtomicFile.WriteAsync(path, newDocument, TestContext.Current.CancellationToken);
            using var reader = new StreamReader(stream);
            Assert.Equal(oldDocument, await reader.ReadToEndAsync(TestContext.Current.CancellationToken));
        }
        Assert.Equal(newDocument, await AtomicFile.ReadAllTextAsync(path, new UTF8Encoding(false, true), TestContext.Current.CancellationToken));
        Assert.Equal([path], Directory.GetFiles(files.Root));
    }

    [Fact]
    public async Task ReaderBackoffHonorsCancellationAndInvalidUtf8DoesNotRetry()
    {
        using var files = new TestStorage();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var operations = new ReadFaults { Code = 32, RemainingFailures = 6, CancelOnDelay = cancellation };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => AtomicFile.ReadAllTextAsync(files.PathFor("settings.json"),
            new UTF8Encoding(false, true), cancellation.Token, operations));
        Assert.Equal(1, operations.ReadAttempts);
        Assert.Equal([25], operations.Delays);
        var path = files.PathFor("invalid.json");
        await File.WriteAllBytesAsync(path, [0xFF], TestContext.Current.CancellationToken);
        var strict = new ReadFaults();
        await Assert.ThrowsAsync<DecoderFallbackException>(() => AtomicFile.ReadAllTextAsync(path,
            new UTF8Encoding(false, true), TestContext.Current.CancellationToken, strict));
        Assert.Equal(1, strict.ReadAttempts);
        Assert.Empty(strict.Delays);
    }

    private sealed class ReadFaults : AtomicFileOperations
    {
        internal int Code { get; init; }
        internal int RemainingFailures { get; set; }
        internal int ReadAttempts { get; private set; }
        internal List<int> Delays { get; } = [];
        internal CancellationTokenSource? CancelOnDelay { get; init; }

        internal override Task<string> ReadAllTextAsync(string path, Encoding encoding, CancellationToken ct)
        {
            ReadAttempts++;
            return RemainingFailures-- > 0
                ? Task.FromException<string>(new IOException("Injected reader sharing failure.", unchecked((int)0x80070000) | Code))
                : base.ReadAllTextAsync(path, encoding, ct);
        }

        internal override Task DelayAsync(int milliseconds, CancellationToken ct)
        {
            Delays.Add(milliseconds);
            CancelOnDelay?.Cancel();
            ct.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }
    }
}
