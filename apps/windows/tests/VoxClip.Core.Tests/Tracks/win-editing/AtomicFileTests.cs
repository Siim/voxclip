using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class AtomicFileTests
{
    [Theory]
    [InlineData(5, 5)]
    [InlineData(32, 5)]
    [InlineData(33, 5)]
    [InlineData(1175, 5)]
    [InlineData(5, 6)]
    [InlineData(32, 6)]
    [InlineData(33, 6)]
    [InlineData(1175, 6)]
    public async Task FirstWriteRetriesMovesAndNeverLeavesTemporaryFiles(int code, int failures)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("new.json");
        var operations = new Faults { RemainingMoveFailures = failures, ErrorCode = code };
        if (failures == 6)
        {
            var error = await Assert.ThrowsAnyAsync<Exception>(() => AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, operations));
            Assert.Equal(code, error.HResult & 0xFFFF);
            Assert.Empty(Directory.GetFiles(storage.Root));
        }
        else
        {
            await AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, operations);
            Assert.Equal("new", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
            Assert.Equal([path], Directory.GetFiles(storage.Root));
        }
        Assert.Equal(6, operations.MoveAttempts);
        Assert.Equal([25, 50, 100, 200, 400], operations.Delays);
    }

    [Fact]
    public async Task TransientFailureRetriesBackupRestorationWhenDestinationIsMissing()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "old", TestContext.Current.CancellationToken);
        var operations = new Faults { RemainingFailures = 1, ErrorCode = 32, RemoveDestination = true, KeepBackup = true, RemainingRecoveryFailures = 2 };
        await AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, operations);
        Assert.Equal("new", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal([25, 50], operations.Delays);
        Assert.Equal([path], Directory.GetFiles(storage.Root));
    }

    [Theory]
    [InlineData(5)]
    [InlineData(32)]
    [InlineData(33)]
    [InlineData(1175)]
    public async Task TransientWindowsFailuresRetryWithBoundedBackoff(int code)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "old", TestContext.Current.CancellationToken);
        var operations = new Faults { RemainingFailures = 5, ErrorCode = code };
        await AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, operations);
        Assert.Equal("new", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal(6, operations.Attempts);
        Assert.Equal([25, 50, 100, 200, 400], operations.Delays);
        Assert.Equal([path], Directory.GetFiles(storage.Root));
    }

    [Theory]
    [InlineData(5)]
    [InlineData(32)]
    public async Task ExhaustedRetriesKeepTheOriginalAndRawException(int code)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "old", TestContext.Current.CancellationToken);
        var operations = new Faults { RemainingFailures = 6, ErrorCode = code, FailCleanup = true };
        var error = await Assert.ThrowsAnyAsync<Exception>(() => AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, operations));
        Assert.Equal(code, error.HResult & 0xFFFF);
        Assert.Equal(code == 5 ? typeof(AccessDenied) : typeof(IOException), error.GetType());
        Assert.Equal(6, operations.Attempts);
        Assert.Equal("old", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(1176, true)]
    [InlineData(1177, true)]
    [InlineData(32, true)]
    [InlineData(1176, false)]
    public async Task PartialReplaceAlwaysRestoresAnOldOrNewCopy(int code, bool backup)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "old", TestContext.Current.CancellationToken);
        var operations = new Faults { RemainingFailures = 1, ErrorCode = code, RemoveDestination = true, KeepBackup = backup };
        if (backup && code != 32)
        {
            var error = await Assert.ThrowsAsync<IOException>(() => AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, operations));
            Assert.Equal(code, error.HResult & 0xFFFF);
            Assert.Equal("old", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        }
        else
        {
            await AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, operations);
            Assert.Equal("new", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        }
    }

    [Fact]
    public async Task FailedRecoveryPreservesBothRemainingFilesAndOriginalError()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "old", TestContext.Current.CancellationToken);
        var operations = new Faults { RemainingFailures = 1, ErrorCode = 1176, RemoveDestination = true, KeepBackup = true, FailRecovery = true };
        var error = await Assert.ThrowsAsync<IOException>(() => AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, operations));
        Assert.Equal(1176, error.HResult & 0xFFFF);
        Assert.Equal("old", await File.ReadAllTextAsync(Assert.Single(Directory.GetFiles(storage.Root, "*.bak")), TestContext.Current.CancellationToken));
        Assert.Equal("new", await File.ReadAllTextAsync(Assert.Single(Directory.GetFiles(storage.Root, "*.tmp")), TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(50)]
    [InlineData(87)]
    public async Task UnsupportedReplaceFallsBackToOverwriteMove(int code)
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "old", TestContext.Current.CancellationToken);
        await AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken, new Faults { RemainingFailures = 1, ErrorCode = code });
        Assert.Equal("new", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        Assert.Equal([path], Directory.GetFiles(storage.Root));
    }

    [Fact]
    public async Task CancellationDuringBackoffPreservesTheDestination()
    {
        using var storage = new TestStorage();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "old", cancellation.Token);
        var operations = new Faults { RemainingFailures = 6, ErrorCode = 32, CancelOnDelay = cancellation };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => AtomicFile.WriteAsync(path, "new", cancellation.Token, operations));
        Assert.Equal(1, operations.Attempts);
        Assert.Equal("old", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
    }

    public static bool IsWindows => OperatingSystem.IsWindows();

    [Fact(Skip = "Requires Windows sharing semantics.", SkipUnless = nameof(IsWindows))]
    public async Task NtfsReaderWithoutDeleteSharingCannotLoseTheOriginal()
    {
        using var storage = new TestStorage();
        var path = storage.PathFor("project.voxclip");
        await File.WriteAllTextAsync(path, "old", TestContext.Current.CancellationToken);
        using (var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            await Assert.ThrowsAnyAsync<Exception>(() => AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken));
        Assert.Equal("old", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        await AtomicFile.WriteAsync(path, "new", TestContext.Current.CancellationToken);
        Assert.Equal("new", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
    }

    private sealed class AccessDenied : UnauthorizedAccessException
    {
        internal AccessDenied() : base("Injected access denial.") => HResult = unchecked((int)0x80070005);
    }

    private sealed class Faults : AtomicFileOperations
    {
        internal int RemainingFailures { get; set; }
        internal int RemainingMoveFailures { get; set; }
        internal int RemainingRecoveryFailures { get; set; }
        internal int ErrorCode { get; init; }
        internal bool RemoveDestination { get; init; }
        internal bool KeepBackup { get; init; }
        internal bool FailRecovery { get; init; }
        internal bool FailCleanup { get; init; }
        internal CancellationTokenSource? CancelOnDelay { get; init; }
        internal int Attempts { get; private set; }
        internal int MoveAttempts { get; private set; }
        internal List<int> Delays { get; } = [];
        internal override bool UseReplace => true;

        internal override void Replace(string temporary, string path, string backup)
        {
            Attempts++;
            Assert.Equal(Path.GetDirectoryName(path), Path.GetDirectoryName(backup));
            if (RemainingFailures-- > 0)
            {
                if (RemoveDestination)
                {
                    if (KeepBackup) File.Move(path, backup);
                    else File.Delete(path);
                }
                if (ErrorCode == 5) throw new AccessDenied();
                throw new IOException("Injected replacement failure.", unchecked((int)0x80070000) | ErrorCode);
            }
            base.Replace(temporary, path, backup);
        }

        internal override void Move(string source, string destination, bool overwrite)
        {
            if (FailRecovery) throw new IOException("Injected recovery failure.");
            if (source.EndsWith(".bak", StringComparison.Ordinal) && RemainingRecoveryFailures-- > 0)
                throw new IOException("Injected transient recovery failure.", unchecked((int)0x80070020));
            if (source.EndsWith(".tmp", StringComparison.Ordinal))
            {
                MoveAttempts++;
                if (RemainingMoveFailures-- > 0)
                {
                    if (ErrorCode == 5) throw new AccessDenied();
                    throw new IOException("Injected move failure.", unchecked((int)0x80070000) | ErrorCode);
                }
            }
            base.Move(source, destination, overwrite);
        }

        internal override void Delete(string path)
        {
            if (FailCleanup) throw new IOException("Injected cleanup failure.");
            base.Delete(path);
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
