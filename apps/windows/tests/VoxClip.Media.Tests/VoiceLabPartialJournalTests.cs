using System.Diagnostics;
using System.IO.Pipes;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class VoiceLabPartialJournalTests
{
    public static bool IsWindows => OperatingSystem.IsWindows();
    private static string ProjectDirectory(VoiceLabTestStorage storage) => Path.Combine(storage.PaidRoot, storage.ProjectId);
    private static string Register(VoiceLabTestStorage storage, VoiceLabPartialOwner owner)
    {
        Directory.CreateDirectory(ProjectDirectory(storage));
        var partial = Path.Combine(ProjectDirectory(storage), ".owned.wav." + Guid.NewGuid().ToString("N") + ".partial");
        using var stream = new FileStream(partial, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        _ = VoiceLabPartialJournal.Register(partial, stream.SafeFileHandle, owner);
        stream.WriteByte(7);
        stream.Flush(true);
        return partial;
    }
    private static int Sweep(VoiceLabTestStorage storage) => VoiceLabAssetStore.CleanupStalePartials(storage.PaidRoot, storage.ProjectId, DateTimeOffset.MinValue);
    private static VoiceLabPartialOwner ReusedPid() => VoiceLabPartialOwner.Current() with { StartTicks = 1 };

    [Fact]
    public void ReviewProbe_UnjournaledStillOpenPartialIsNeverAgeDeleted()
    {
        using var storage = new VoiceLabTestStorage();
        var directory = Path.Combine(storage.PaidRoot, storage.ProjectId);
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, ".live.wav." + Guid.NewGuid().ToString("N") + ".partial");
        using var writer = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        writer.WriteByte(1); writer.Flush(true);
        File.SetLastWriteTimeUtc(path, DateTime.UnixEpoch);
        Assert.Equal(0, VoiceLabAssetStore.CleanupStalePartials(storage.PaidRoot, storage.ProjectId, DateTimeOffset.UtcNow));
        Assert.True(File.Exists(path));
    }

    [Fact]
    public void ReplacementSurvivesAndItsStaleJournalIsDropped()
    {
        using var storage = new VoiceLabTestStorage();
        var partial = Register(storage, ReusedPid());
        File.Move(partial, partial + ".retained");
        File.WriteAllText(partial, "replacement");
        Assert.Equal(0, Sweep(storage));
        Assert.Equal("replacement", File.ReadAllText(partial));
        Assert.Empty(Directory.GetFiles(Path.Combine(ProjectDirectory(storage), VoiceLabPartialJournal.Folder)));
    }

    [Fact]
    public void ReusedPidWithDifferentStartTimeIsAnAbandonedOwner()
    {
        using var storage = new VoiceLabTestStorage();
        var partial = Register(storage, ReusedPid());
        Assert.True(File.Exists(partial));
        Assert.Equal(1, Sweep(storage));
        Assert.False(File.Exists(partial));
    }

    [Fact]
    public void LiveOwnerSurvivesEvenWithAncientMtimeAndFutureSweepTime()
    {
        using var storage = new VoiceLabTestStorage();
        var partial = Register(storage, VoiceLabPartialOwner.Current());
        File.SetLastWriteTimeUtc(partial, DateTime.UnixEpoch);
        Assert.Equal(0, VoiceLabAssetStore.CleanupStalePartials(storage.PaidRoot, storage.ProjectId, DateTimeOffset.MaxValue));
        Assert.True(File.Exists(partial));
        Assert.Single(Directory.GetFiles(Path.Combine(ProjectDirectory(storage), VoiceLabPartialJournal.Folder)));
    }

    [Fact]
    public void CancellationCleanupNeverDeletesAReplacement()
    {
        using var storage = new VoiceLabTestStorage();
        using var cancellation = new CancellationTokenSource();
        string? replacement = null;
        Assert.Throws<OperationCanceledException>(() => VoiceLabAssetStore.Write([1, 0], 48000, storage.ProjectId,
            "cancel", storage.PaidRoot, DateTimeOffset.UnixEpoch, cancellation.Token, () =>
            {
                replacement = Assert.Single(Directory.GetFiles(ProjectDirectory(storage), "*.partial"));
                File.Move(replacement, replacement + ".retained");
                File.WriteAllText(replacement, "replacement");
                cancellation.Cancel();
            }, null));
        Assert.Equal("replacement", File.ReadAllText(replacement!));
        Assert.Empty(Directory.GetFiles(Path.Combine(ProjectDirectory(storage), VoiceLabPartialJournal.Folder)));
    }

    [Fact]
    public void MissingPartialDropsOnlyItsJournal()
    {
        using var storage = new VoiceLabTestStorage();
        var partial = Register(storage, ReusedPid());
        File.Delete(partial);
        Assert.Equal(0, Sweep(storage));
        Assert.Empty(Directory.GetFiles(Path.Combine(ProjectDirectory(storage), VoiceLabPartialJournal.Folder)));
    }

    [Fact]
    public void UnixReplacementAfterIdentityCheckIsRestoredAndNeverUnlinked()
    {
        if (OperatingSystem.IsWindows()) return;
        using var storage = new VoiceLabTestStorage();
        var partial = Register(storage, ReusedPid());
        VoiceLabFileIdentity identity;
        using (var handle = VoiceLabPartialFiles.Open(partial)) identity = VoiceLabPartialFiles.Identity(handle);
        Assert.False(VoiceLabPartialFiles.Delete(partial, identity, Path.Combine(ProjectDirectory(storage), VoiceLabPartialJournal.Folder), () =>
        {
            File.Move(partial, partial + ".retained");
            File.WriteAllText(partial, "replacement during reclamation");
        }));
        Assert.Equal("replacement during reclamation", File.ReadAllText(partial));
        Assert.True(File.Exists(partial + ".retained"));
    }

    [Fact]
    public void LinkedJournalIsNeverTrusted()
    {
        if (OperatingSystem.IsWindows()) return;
        using var storage = new VoiceLabTestStorage();
        var partial = Register(storage, ReusedPid());
        var journal = Assert.Single(Directory.GetFiles(Path.Combine(ProjectDirectory(storage), VoiceLabPartialJournal.Folder)));
        File.Move(journal, journal + ".retained");
        File.CreateSymbolicLink(journal, journal + ".retained");
        Assert.Equal(0, Sweep(storage));
        Assert.True(File.Exists(partial));
        Assert.NotNull(new FileInfo(journal).LinkTarget);
    }

    [Fact]
    public async Task LiveSecondProcessSurvivesAndDeadOwnersPartialIsRemoved()
    {
        using var storage = new VoiceLabTestStorage();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        var pipeName = "vl-" + Guid.NewGuid().ToString("N")[..16];
        await using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        var start = new ProcessStartInfo("dotnet") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { typeof(VoiceLabPartialJournalTests).Assembly.Location, "-method", "*PartialOwnerProcess", "-maxThreads", "1", "-noLogo" }) start.ArgumentList.Add(argument);
        start.Environment["VOXCLIP_PARTIAL_TEST_PIPE"] = pipeName;
        start.Environment["VOXCLIP_PARTIAL_TEST_ROOT"] = storage.PaidRoot;
        start.Environment["VOXCLIP_PARTIAL_TEST_PROJECT"] = storage.ProjectId;
        using var child = Process.Start(start)!;
        var stdout = child.StandardOutput.ReadToEndAsync(timeout.Token);
        var stderr = child.StandardError.ReadToEndAsync(timeout.Token);
        try
        {
            await pipe.WaitForConnectionAsync(timeout.Token);
            using var reader = new StreamReader(pipe, leaveOpen: true);
            var partial = await reader.ReadLineAsync(timeout.Token);
            Assert.NotNull(partial);
            Assert.Equal(0, Sweep(storage));
            Assert.True(File.Exists(partial));
            child.Kill(entireProcessTree: true);
            await child.WaitForExitAsync(timeout.Token);
            Assert.Equal(1, Sweep(storage));
            Assert.False(File.Exists(partial));
        }
        finally
        {
            if (!child.HasExited) child.Kill(entireProcessTree: true);
            await child.WaitForExitAsync(CancellationToken.None);
            _ = await stdout;
            _ = await stderr;
        }
    }

    [Fact]
    public void PartialOwnerProcess()
    {
        var pipeName = Environment.GetEnvironmentVariable("VOXCLIP_PARTIAL_TEST_PIPE");
        if (pipeName is null) return;
        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut);
        pipe.Connect(30_000);
        var root = Environment.GetEnvironmentVariable("VOXCLIP_PARTIAL_TEST_ROOT")!;
        var projectId = Environment.GetEnvironmentVariable("VOXCLIP_PARTIAL_TEST_PROJECT")!;
        using var writer = new StreamWriter(pipe, leaveOpen: true) { AutoFlush = true };
        using var reader = new StreamReader(pipe, leaveOpen: true);
        _ = VoiceLabAssetStore.Write([1, 0], 48000, projectId, "child", root, DateTimeOffset.UnixEpoch,
            TestContext.Current.CancellationToken, () =>
            {
                var partial = Assert.Single(Directory.GetFiles(Path.Combine(root, projectId), "*.partial"));
                File.SetLastWriteTimeUtc(partial, DateTime.UnixEpoch);
                writer.WriteLine(partial);
                _ = reader.ReadLine();
            }, null);
    }

    [Fact]
    public void LinkedPartialsAndJournalDirectoriesAreRefused()
    {
        if (OperatingSystem.IsWindows()) return;
        using var storage = new VoiceLabTestStorage();
        var partial = Register(storage, ReusedPid());
        var target = partial + ".original";
        File.Move(partial, target);
        File.CreateSymbolicLink(partial, target);
        Assert.Throws<IOException>(() => VoiceLabPartialFiles.Open(partial));
        Assert.Equal(0, Sweep(storage));
        Assert.True(File.Exists(target));
        Assert.NotNull(new FileInfo(partial).LinkTarget);
        var directory = Path.Combine(ProjectDirectory(storage), VoiceLabPartialJournal.Folder);
        Directory.Delete(directory);
        Directory.CreateSymbolicLink(directory, storage.Root);
        Assert.Equal(VoiceLabAssetStoreErrorCode.UnsafePath, Assert.Throws<VoiceLabAssetStoreException>(() => Sweep(storage)).Code);
    }

    [Fact(Skip = "Native Windows file-index, reparse and handle-delete evidence is owed to the VM.", SkipUnless = nameof(IsWindows))]
    [Trait("Category", "RequiresWindows")]
    public async Task NativeWindowsIdentityAndHandleDeleteRefuseReparsePoints()
    {
        using var storage = new VoiceLabTestStorage();
        var partial = Register(storage, ReusedPid());
        using (var handle = VoiceLabPartialFiles.Open(partial))
        {
            var identity = VoiceLabPartialFiles.Identity(handle);
            Assert.Equal("windows", identity.Platform);
            Assert.NotEqual(0ul, identity.Index);
        }
        Assert.Equal(1, Sweep(storage));
        var targetDirectory = Path.Combine(ProjectDirectory(storage), "target");
        Directory.CreateDirectory(targetDirectory);
        var target = Path.Combine(targetDirectory, "target.wav");
        File.WriteAllText(target, "keep");
        await VoiceLabTestStorage.JunctionAsync(partial, targetDirectory);
        Assert.True((File.GetAttributes(partial) & FileAttributes.ReparsePoint) != 0);
        Assert.Throws<IOException>(() => VoiceLabPartialFiles.Open(partial, delete: true));
        Assert.Equal("keep", File.ReadAllText(target));
        VoiceLabTestStorage.NativePassed(nameof(NativeWindowsIdentityAndHandleDeleteRefuseReparsePoints));
    }
}
