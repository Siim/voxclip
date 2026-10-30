using System.Buffers.Binary;
using System.Security.Cryptography;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class VoiceLabAssetStoreTests
{
    private static readonly DateTimeOffset CreatedAt = DateTimeOffset.Parse("2026-10-27T12:00:00Z");
    private static VoiceLabAsset Write(VoiceLabTestStorage storage, string id = "take", byte[]? pcm = null,
        int rate = 24_000)
        => VoiceLabAssetStore.Write(pcm ?? [1, 0, 254, 255, 255, 127], rate, storage.ProjectId, id, storage.PaidRoot, CreatedAt, TestContext.Current.CancellationToken);
    private static void Refuses(VoiceLabAssetStoreErrorCode code, Action action)
        => Assert.Equal(code, Assert.Throws<VoiceLabAssetStoreException>(action).Code);

    [Fact]
    public void CanonicalHeaderAndMetadataMatchMacExactly()
    {
        using var storage = new VoiceLabTestStorage();
        var asset = Write(storage);
        var bytes = File.ReadAllBytes(storage.AssetPath(asset));
        Assert.Equal(Convert.FromHexString("524946462a00000057415645666d74201000000001000100c05d000080bb0000020010006461746106000000"), bytes[..44]);
        Assert.Equal(new byte[] { 1, 0, 254, 255, 255, 127 }, bytes[44..]);
        Assert.Equal(new VoiceLabAsset("take", "audio", storage.ProjectId + "/take.wav",
            Convert.ToHexStringLower(SHA256.HashData(bytes)), 3d / 24_000, 24_000, CreatedAt), asset);
        Assert.Equal(new[] { storage.AssetPath(asset) }, Directory.GetFiles(Path.GetDirectoryName(storage.AssetPath(asset))!));
    }

    [Fact]
    public void DerivedFloatRuleUsesDoubleProductTiesToEvenAndClamp()
    {
        using var storage = new VoiceLabTestStorage();
        float[] values = [-2, -1, -0.5f, -0.50006103515625f, 0, 0.5f, 0.50006103515625f, 1, 2, float.MaxValue, -float.MaxValue];
        short[] expected = [-32767, -32767, -16384, -16385, 0, 16384, 16385, 32767, 32767, 32767, -32767];
        var asset = VoiceLabAssetStore.WriteDerived(values, 48_000, storage.ProjectId, "derived", storage.PaidRoot, CreatedAt, TestContext.Current.CancellationToken);
        var bytes = File.ReadAllBytes(storage.AssetPath(asset));
        Assert.Equal(expected, Enumerable.Range(0, values.Length).Select(index => BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(44 + index * 2))).ToArray());
        foreach (var invalid in new[] { float.NaN, float.PositiveInfinity, float.NegativeInfinity })
            Refuses(VoiceLabAssetStoreErrorCode.InvalidAudio, () => VoiceLabAssetStore.WriteDerived([0, invalid], 48_000,
                storage.ProjectId, "nonfinite", storage.PaidRoot, CreatedAt, TestContext.Current.CancellationToken));
        Assert.Single(Directory.GetFiles(Path.GetDirectoryName(storage.AssetPath(asset))!));
    }

    [Fact]
    public void BoundsAndIdsAreCheckedBeforeCreatingStorage()
    {
        using var storage = new VoiceLabTestStorage();
        foreach (var rate in new[] { 7_999, 192_001, 0, -1 })
            Refuses(VoiceLabAssetStoreErrorCode.InvalidAudio, () => Write(storage, rate: rate));
        Refuses(VoiceLabAssetStoreErrorCode.InvalidAudio, () => Write(storage, pcm: []));
        Refuses(VoiceLabAssetStoreErrorCode.InvalidAudio, () => Write(storage, pcm: [1]));
        Refuses(VoiceLabAssetStoreErrorCode.InvalidAudio, () => VoiceLabAssetStore.WriteDerived([], 24_000, storage.ProjectId, "empty", storage.PaidRoot, CreatedAt, TestContext.Current.CancellationToken));
        VoiceLabAssetStore.Validate(VoiceLabAssetStore.MaxFrames, 192_000, "test.wav");
        Refuses(VoiceLabAssetStoreErrorCode.TooLarge, () => VoiceLabAssetStore.Validate(VoiceLabAssetStore.MaxFrames + 1, 192_000, "test.wav"));
        foreach (var id in new[] { "../escape", "con", "a/b", "TAKE", "" })
            Assert.Equal(VoiceLabProjectErrorCode.InvalidAsset, Assert.Throws<VoiceLabProjectException>(() => Write(storage, id)).Code);
        Assert.False(Directory.Exists(storage.PaidRoot));
        foreach (var rate in new[] { 8_000, 192_000 }) Assert.Equal(rate, Write(storage, "rate-" + rate, rate: rate).SampleRate);
    }

    [Fact]
    public void ExistingFilesDirectoriesAndLinksAreNeverReplaced()
    {
        using var storage = new VoiceLabTestStorage();
        var asset = Write(storage);
        var saved = File.ReadAllBytes(storage.AssetPath(asset));
        Refuses(VoiceLabAssetStoreErrorCode.AlreadyExists, () => Write(storage, pcm: [7, 0]));
        Assert.Equal(saved, File.ReadAllBytes(storage.AssetPath(asset)));
        var directory = Path.GetDirectoryName(storage.AssetPath(asset))!;
        Directory.CreateDirectory(Path.Combine(directory, "directory.wav"));
        Refuses(VoiceLabAssetStoreErrorCode.AlreadyExists, () => Write(storage, "directory"));
        if (!OperatingSystem.IsWindows())
        {
            File.CreateSymbolicLink(Path.Combine(directory, "link.wav"), Path.Combine(storage.Root, "missing"));
            Refuses(VoiceLabAssetStoreErrorCode.AlreadyExists, () => Write(storage, "link"));
        }
        Assert.Empty(Directory.GetFiles(directory, "*.partial"));
    }

    [Fact]
    public void CancellationAndPublicationRaceDeleteOnlyTheTemporaryFile()
    {
        using var storage = new VoiceLabTestStorage();
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => VoiceLabAssetStore.Write([1, 0], 24_000, storage.ProjectId, "take", storage.PaidRoot, CreatedAt, cancelled.Token));
        var directory = Path.Combine(storage.PaidRoot, storage.ProjectId);
        using var cancellation = new CancellationTokenSource();
        Assert.Throws<OperationCanceledException>(() => VoiceLabAssetStore.Write([1, 0], 24_000, storage.ProjectId,
            "cancelled", storage.PaidRoot, CreatedAt, cancellation.Token, cancellation.Cancel, null));
        Assert.Empty(Directory.GetFiles(directory));
        Assert.Empty(Directory.GetFileSystemEntries(Path.Combine(directory, VoiceLabPartialJournal.Folder)));
        var raced = Path.Combine(directory, "race.wav");
        Refuses(VoiceLabAssetStoreErrorCode.AlreadyExists, () => VoiceLabAssetStore.Write([1, 0], 24_000, storage.ProjectId,
            "race", storage.PaidRoot, CreatedAt, default, () => File.WriteAllBytes(raced, [42]), null));
        Assert.Equal(new byte[] { 42 }, File.ReadAllBytes(raced));
        Assert.Equal(new[] { raced }, Directory.GetFiles(directory));
    }

    [Fact]
    public async Task ConcurrentWritersPublishExactlyOneCompleteAsset()
    {
        using var storage = new VoiceLabTestStorage();
        var results = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => Task.Run(() =>
        {
            try { Write(storage); return true; }
            catch (VoiceLabAssetStoreException failure) when (failure.Code == VoiceLabAssetStoreErrorCode.AlreadyExists) { return false; }
        }, TestContext.Current.CancellationToken)));
        Assert.Single(results, result => result);
        Assert.Equal(50, File.ReadAllBytes(Path.Combine(storage.PaidRoot, storage.ProjectId, "take.wav")).Length);
        Assert.Single(Directory.GetFiles(Path.Combine(storage.PaidRoot, storage.ProjectId)));
    }

    [Fact]
    public void FailureAfterPublicationKeepsThePaidFileAndReportsConfirmationState()
    {
        using var storage = new VoiceLabTestStorage();
        var final = Path.Combine(storage.PaidRoot, storage.ProjectId, "altered.wav");
        Refuses(VoiceLabAssetStoreErrorCode.Altered, () => VoiceLabAssetStore.Write([1, 0], 24_000, storage.ProjectId,
            "altered", storage.PaidRoot, CreatedAt, default, null, () => File.WriteAllBytes(final, [99])));
        Assert.Equal(new byte[] { 99 }, File.ReadAllBytes(final));
        Refuses(VoiceLabAssetStoreErrorCode.PublishedUnverified, () => VoiceLabAssetStore.Write([1, 0], 24_000,
            storage.ProjectId, "unverified", storage.PaidRoot, CreatedAt, default, null, () => throw new IOException("read-back failed")));
        Assert.Equal(46, new FileInfo(Path.Combine(storage.PaidRoot, storage.ProjectId, "unverified.wav")).Length);
        Refuses(VoiceLabAssetStoreErrorCode.AlreadyExists, () => Write(storage, "unverified"));
        Assert.Empty(Directory.GetFiles(Path.Combine(storage.PaidRoot, storage.ProjectId), "*.partial"));
    }

    [Fact]
    public void OnlyTheMissingRootIsCreatedAndNonDirectoriesAreRefused()
    {
        using var storage = new VoiceLabTestStorage();
        var missing = Path.Combine(storage.Root, "missing-data", "VoiceLab");
        Refuses(VoiceLabAssetStoreErrorCode.RootMissing, () => VoiceLabAssetStore.Write([1, 0], 24_000,
            storage.ProjectId, "take", missing, CreatedAt, TestContext.Current.CancellationToken));
        Assert.False(Directory.Exists(Path.GetDirectoryName(missing)));
        File.WriteAllText(storage.PaidRoot, "not a directory");
        Refuses(VoiceLabAssetStoreErrorCode.UnsafePath, () => Write(storage));
        File.Delete(storage.PaidRoot); Directory.CreateDirectory(storage.PaidRoot);
        File.WriteAllText(Path.Combine(storage.PaidRoot, storage.ProjectId), "not a directory");
        Refuses(VoiceLabAssetStoreErrorCode.UnsafePath, () => Write(storage));
    }

    [Fact, Trait("Category", "RequiresWindows")]
    public void WindowsWriteThroughPublicationMovesTheTemporaryHandleToFinalName()
    {
        NativeTest.Require(OperatingSystem.IsWindows(), "Windows file-system regressions require Windows.");
        using (var storage = new VoiceLabTestStorage())
        {
            var final = Path.Combine(storage.PaidRoot, storage.ProjectId, "take.wav");
            FileStream? temporaryView = null;
            try
            {
                var asset = VoiceLabAssetStore.Write([1, 0, 254, 255], 24_000, storage.ProjectId, "take", storage.PaidRoot,
                    CreatedAt, TestContext.Current.CancellationToken, () =>
                    {
                        var temporary = Assert.Single(Directory.GetFiles(Path.GetDirectoryName(final)!, "*.partial"));
                        temporaryView = new FileStream(temporary, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    }, () => Assert.Equal(final, VoiceLabWindowsFiles.FinalPath(temporaryView!.SafeFileHandle), ignoreCase: true));
                Assert.NotNull(temporaryView);
                Assert.Equal(asset.Sha256, Convert.ToHexStringLower(SHA256.HashData(temporaryView)));
                Assert.Equal(asset.Sha256, Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(final))));
                Assert.Equal(new[] { final }, Directory.GetFiles(Path.GetDirectoryName(final)!));
            }
            finally { temporaryView?.Dispose(); }
        }
        VoiceLabTestStorage.NativePassed(nameof(WindowsWriteThroughPublicationMovesTheTemporaryHandleToFinalName));
    }

    [Fact, Trait("Category", "RequiresWindows")]
    public void WindowsWriteThroughPublicationNeverReplacesAnExistingDestination()
    {
        NativeTest.Require(OperatingSystem.IsWindows(), "Windows file-system regressions require Windows.");
        using (var storage = new VoiceLabTestStorage())
        {
            var final = Path.Combine(storage.PaidRoot, storage.ProjectId, "take.wav");
            Refuses(VoiceLabAssetStoreErrorCode.AlreadyExists, () => VoiceLabAssetStore.Write([1, 0], 24_000,
                storage.ProjectId, "take", storage.PaidRoot, CreatedAt, TestContext.Current.CancellationToken,
                () => File.WriteAllBytes(final, [42]), null));
            Assert.Equal(new byte[] { 42 }, File.ReadAllBytes(final));
            Assert.Equal(new[] { final }, Directory.GetFiles(Path.GetDirectoryName(final)!));
            Refuses(VoiceLabAssetStoreErrorCode.AlreadyExists, () => Write(storage));
        }
        VoiceLabTestStorage.NativePassed(nameof(WindowsWriteThroughPublicationNeverReplacesAnExistingDestination));
    }

    [Fact, Trait("Category", "RequiresWindows")]
    public void WindowsWriteThroughPublicationKeepsFinalAfterConfirmationFailure()
    {
        NativeTest.Require(OperatingSystem.IsWindows(), "Windows file-system regressions require Windows.");
        using (var storage = new VoiceLabTestStorage())
        {
            Refuses(VoiceLabAssetStoreErrorCode.PublishedUnverified, () => VoiceLabAssetStore.Write([1, 0], 24_000,
                storage.ProjectId, "take", storage.PaidRoot, CreatedAt, TestContext.Current.CancellationToken,
                null, () => throw new IOException("confirmation failed")));
            var final = Path.Combine(storage.PaidRoot, storage.ProjectId, "take.wav");
            Assert.Equal(new byte[] { 1, 0 }, File.ReadAllBytes(final)[44..]);
            Assert.Equal(new[] { final }, Directory.GetFiles(Path.GetDirectoryName(final)!));
            Refuses(VoiceLabAssetStoreErrorCode.AlreadyExists, () => Write(storage));
        }
        VoiceLabTestStorage.NativePassed(nameof(WindowsWriteThroughPublicationKeepsFinalAfterConfirmationFailure));
    }

    [Fact]
    public void MacCompatibleRootAliasResolvesButProjectLinksAreRefused()
    {
        using var storage = new VoiceLabTestStorage();
        if (OperatingSystem.IsWindows()) return;
        Directory.CreateDirectory(storage.PaidRoot);
        var elsewhere = Directory.CreateDirectory(Path.Combine(storage.Root, "elsewhere")).FullName;
        var project = Path.Combine(storage.PaidRoot, storage.ProjectId);
        Directory.CreateSymbolicLink(project, elsewhere);
        Refuses(VoiceLabAssetStoreErrorCode.UnsafePath, () => Write(storage));
        Assert.Empty(Directory.GetFileSystemEntries(elsewhere)); Directory.Delete(project);
        var alias = Path.Combine(storage.Root, "alias"); Directory.CreateSymbolicLink(alias, storage.PaidRoot);
        var asset = VoiceLabAssetStore.Write([1, 0], 24_000, storage.ProjectId, "aliased", alias, CreatedAt, TestContext.Current.CancellationToken);
        Assert.True(File.Exists(storage.AssetPath(asset)));
        var dangling = Path.Combine(storage.Root, "dangling"); Directory.CreateSymbolicLink(dangling, Path.Combine(storage.Root, "absent"));
        Refuses(VoiceLabAssetStoreErrorCode.UnsafePath, () => VoiceLabAssetStore.Write([1, 0], 24_000, storage.ProjectId, "take", dangling, CreatedAt, TestContext.Current.CancellationToken));
    }

    [Fact, Trait("Category", "RequiresWindows")]
    public async Task WindowsDirectPaidRootJunctionPublishesUnderItsPinnedTarget()
    {
        NativeTest.Require(OperatingSystem.IsWindows(), "Windows file-system regressions require Windows.");
        using (var storage = new VoiceLabTestStorage())
        {
            Directory.CreateDirectory(storage.PaidRoot);
            var alias = Path.Combine(storage.Root, "alias");
            await VoiceLabTestStorage.JunctionAsync(alias, storage.PaidRoot);
            try
            {
                var asset = VoiceLabAssetStore.Write([1, 0], 24_000, storage.ProjectId, "take", alias, CreatedAt, TestContext.Current.CancellationToken);
                Assert.Equal(new byte[] { 1, 0 }, File.ReadAllBytes(storage.AssetPath(asset))[44..]);
                Assert.Equal(File.ReadAllBytes(storage.AssetPath(asset)), File.ReadAllBytes(Path.Combine(alias, asset.File)));
            }
            finally { Directory.Delete(alias); }
        }
        VoiceLabTestStorage.NativePassed(nameof(WindowsDirectPaidRootJunctionPublishesUnderItsPinnedTarget));
    }

    [Fact, Trait("Category", "RequiresWindows")]
    public async Task WindowsAncestorJunctionResolvesBeforeCreatingThePaidRoot()
    {
        NativeTest.Require(OperatingSystem.IsWindows(), "Windows file-system regressions require Windows.");
        using (var storage = new VoiceLabTestStorage())
        {
            var target = Directory.CreateDirectory(Path.Combine(storage.Root, "real-data")).FullName;
            var alias = Path.Combine(storage.Root, "data-alias");
            await VoiceLabTestStorage.JunctionAsync(alias, target);
            try
            {
                var root = Path.Combine(alias, "VoiceLab");
                var asset = VoiceLabAssetStore.Write([2, 0], 24_000, storage.ProjectId, "take", root, CreatedAt, TestContext.Current.CancellationToken);
                var final = Path.Combine(target, "VoiceLab", asset.File);
                Assert.Equal(new byte[] { 2, 0 }, File.ReadAllBytes(final)[44..]);
                var second = VoiceLabAssetStore.Write([3, 0], 24_000, storage.ProjectId, "second", root, CreatedAt, TestContext.Current.CancellationToken);
                Assert.Equal(new byte[] { 3, 0 }, File.ReadAllBytes(Path.Combine(target, "VoiceLab", second.File))[44..]);
                Assert.Equal(2, Directory.GetFiles(Path.GetDirectoryName(final)!).Length);
            }
            finally { Directory.Delete(alias); }
        }
        VoiceLabTestStorage.NativePassed(nameof(WindowsAncestorJunctionResolvesBeforeCreatingThePaidRoot));
    }

    [Fact, Trait("Category", "RequiresWindows")]
    public async Task WindowsJunctionBelowTheCanonicalPaidRootIsRefused()
    {
        NativeTest.Require(OperatingSystem.IsWindows(), "Windows file-system regressions require Windows.");
        using (var storage = new VoiceLabTestStorage())
        {
            Directory.CreateDirectory(storage.PaidRoot);
            var target = Directory.CreateDirectory(Path.Combine(storage.PaidRoot, "another-project")).FullName;
            var junction = Path.Combine(storage.PaidRoot, storage.ProjectId);
            await VoiceLabTestStorage.JunctionAsync(junction, target);
            try
            {
                Refuses(VoiceLabAssetStoreErrorCode.UnsafePath, () => Write(storage));
                Assert.Empty(Directory.GetFileSystemEntries(target));
            }
            finally { Directory.Delete(junction); }
        }
        VoiceLabTestStorage.NativePassed(nameof(WindowsJunctionBelowTheCanonicalPaidRootIsRefused));
    }

    [Theory, Trait("Category", "RequiresWindows")]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void WindowsDeniedTemporaryDeletionPreservesPrimaryFailure(bool readOnly, bool cancelled)
    {
        NativeTest.Require(OperatingSystem.IsWindows(), "Windows file-system regressions require Windows.");
        using (var storage = new VoiceLabTestStorage())
        {
            var paid = Write(storage, "paid");
            var saved = File.ReadAllBytes(storage.AssetPath(paid));
            var directory = Path.Combine(storage.PaidRoot, storage.ProjectId);
            string? temporary = null;
            FileStream? denied = null;
            using var cancellation = new CancellationTokenSource();
            void DenyDeletion()
            {
                temporary = Assert.Single(Directory.GetFiles(directory, "*.partial"));
                if (readOnly) File.SetAttributes(temporary, FileAttributes.ReadOnly);
                else denied = new FileStream(temporary, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (cancelled) cancellation.Cancel();
                else throw new IOException("primary write failure");
            }
            void Publish() => VoiceLabAssetStore.Write([2, 0], 24_000, storage.ProjectId, "orphan", storage.PaidRoot,
                CreatedAt, cancellation.Token, DenyDeletion, null);
            try
            {
                if (cancelled)
                {
                    var failure = Assert.Throws<OperationCanceledException>(Publish);
                    Assert.Equal(cancellation.Token, failure.CancellationToken);
                    Assert.Equal(temporary, failure.Data[nameof(VoiceLabAssetStoreException.OrphanedTemporaryPath)]);
                }
                else
                {
                    var failure = Assert.Throws<VoiceLabAssetStoreException>(Publish);
                    Assert.Equal(VoiceLabAssetStoreErrorCode.Unwritable, failure.Code);
                    Assert.Equal(temporary, failure.OrphanedTemporaryPath);
                    Assert.Equal(temporary, failure.Data[nameof(VoiceLabAssetStoreException.OrphanedTemporaryPath)]);
                }
                Assert.NotNull(temporary);
                Assert.True(File.Exists(temporary));
                Assert.False(File.Exists(Path.Combine(directory, "orphan.wav")));
                Assert.Equal(saved, File.ReadAllBytes(storage.AssetPath(paid)));
            }
            finally
            {
                denied?.Dispose();
                if (temporary is not null) { File.SetAttributes(temporary, FileAttributes.Normal); File.Delete(temporary); }
            }
            Assert.Empty(Directory.GetFiles(directory, "*.partial"));
        }
        VoiceLabTestStorage.NativePassed($"{nameof(WindowsDeniedTemporaryDeletionPreservesPrimaryFailure)}(readOnly: {readOnly}, cancelled: {cancelled})");
    }

    [Fact]
    public async Task WrittenV3AssetPreparesAndOneChangedByteIsAltered()
    {
        using var storage = new VoiceLabTestStorage();
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-render-v3.voxclip")));
        var recorded = project.VoiceLab.Assets!.Single(asset => asset.Id == "asset-one");
        var frames = (int)Math.Round(recorded.DurationSeconds * recorded.SampleRate);
        var asset = VoiceLabAssetStore.Write(new byte[frames * 2], recorded.SampleRate, project.Id, recorded.Id, storage.PaidRoot, recorded.CreatedAt, TestContext.Current.CancellationToken);
        project = project with { VoiceLab = project.VoiceLab with
        {
            Assets = project.VoiceLab.Assets!.Select(item => item.Id == asset.Id ? asset : item).ToArray(),
            Segments = project.VoiceLab.Segments.Select(segment => segment with
            {
                Candidates = segment.Candidates.Select(candidate => candidate.Recipe is { } recipe
                    ? candidate with { Recipe = recipe with { Chunks = recipe.Chunks.Select(chunk => chunk.AssetId == asset.Id
                        ? chunk with { AssetSha256 = asset.Sha256 } : chunk).ToArray() } } : candidate).ToArray()
            }).ToArray()
        } };
        var plan = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full);
        var scratch = Directory.CreateDirectory(Path.Combine(storage.Root, "prepared-scratch")).FullName;
        var prepared = await VoiceLabAssets.PrepareAsync(project, plan, storage.PaidRoot, scratch, TestContext.Current.CancellationToken);
        string? snapshot = null;
        try
        {
            var handle = Assert.Single(prepared).Value;
            snapshot = handle.Path;
            Assert.StartsWith(scratch + Path.DirectorySeparatorChar, snapshot, OperatingSystem.IsWindows()
                ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
            Assert.Single(Directory.GetFileSystemEntries(scratch));
            Assert.Equal(frames, handle.FrameCount); Assert.Equal(asset.SampleRate, handle.SampleRate); Assert.Equal(1, handle.Channels);
            var final = Path.Combine(storage.PaidRoot, asset.File.Replace('/', Path.DirectorySeparatorChar));
            var bytes = File.ReadAllBytes(final); bytes[1000] ^= 1; File.WriteAllBytes(final, bytes);
            var failure = await Assert.ThrowsAsync<VoiceLabAssetException>(() => VoiceLabAssets.PrepareAsync(project, plan, storage.PaidRoot, scratch, TestContext.Current.CancellationToken));
            Assert.Equal(VoiceLabAssetErrorCode.Altered, failure.Code); Assert.NotEqual(bytes, File.ReadAllBytes(handle.Path));
            Assert.Single(Directory.GetFileSystemEntries(scratch));
        }
        finally { foreach (var handle in prepared.Values) handle.Dispose(); }
        Assert.NotNull(snapshot); Assert.False(File.Exists(snapshot));
        Assert.Empty(Directory.GetFileSystemEntries(scratch));
    }
}

internal sealed class VoiceLabTestStorage : IDisposable
{
    private static readonly object EvidenceLock = new();
    private readonly string? previousData = Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR");
    internal string Root { get; } = Directory.CreateTempSubdirectory("voxclip-vl-media-").FullName;
    internal string ProjectId { get; } = "12345678-1234-1234-1234-123456789abc";
    internal string PaidRoot => Path.Combine(Root, "VoiceLab");
    internal VoiceLabTestStorage() => Environment.SetEnvironmentVariable("VOXCLIP_DATA_DIR", Root);
    internal string AssetPath(VoiceLabAsset asset) => Path.Combine(PaidRoot, asset.File.Replace('/', Path.DirectorySeparatorChar));
    internal static void NativePassed(string name)
    {
        var output = Environment.GetEnvironmentVariable("VOXCLIP_E2E_OUT");
        if (string.IsNullOrEmpty(output)) return;
        var directory = Path.GetDirectoryName(Path.GetFullPath(output))!;
        Directory.CreateDirectory(directory);
        lock (EvidenceLock)
            File.AppendAllText(Path.Combine(directory, "voice-lab-media-r2-tests.log"), "PASS " + name + Environment.NewLine);
    }
    internal static async Task JunctionAsync(string alias, string target)
    {
        using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe",
            $"/d /c mklink /J \"{alias}\" \"{target}\"") { UseShellExecute = false, CreateNoWindow = true })!;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None); } throw; }
        Assert.Equal(0, process.ExitCode);
    }
    public void Dispose()
    {
        Environment.SetEnvironmentVariable("VOXCLIP_DATA_DIR", previousData);
        Directory.Delete(Root, true);
    }
}
