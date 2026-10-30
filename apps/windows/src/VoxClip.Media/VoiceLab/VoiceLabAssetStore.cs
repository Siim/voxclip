#pragma warning disable CS1591
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

public enum VoiceLabAssetStoreErrorCode
{
    AlreadyExists, UnsafePath, InvalidAudio, TooLarge, Unwritable, Altered, PublishedUnverified, RootMissing
}

public sealed class VoiceLabAssetStoreException(VoiceLabAssetStoreErrorCode code, string file) : Exception(Explain(code))
{
    public VoiceLabAssetStoreErrorCode Code { get; } = code;
    public string File { get; } = file;
    public string? OrphanedTemporaryPath { get; internal set; }
    private static string Explain(VoiceLabAssetStoreErrorCode code) => code switch
    {
        VoiceLabAssetStoreErrorCode.AlreadyExists => "This generated Voice Lab audio is already saved. The paid file was not replaced.",
        VoiceLabAssetStoreErrorCode.RootMissing => "The VoxClip data folder is missing, so the generated Voice Lab audio was not saved. Check the data location.",
        VoiceLabAssetStoreErrorCode.UnsafePath => "The Voice Lab storage folder is not a folder or contains a link. Check the storage location.",
        VoiceLabAssetStoreErrorCode.InvalidAudio => "The generated Voice Lab audio is empty or malformed, so it was not saved.",
        VoiceLabAssetStoreErrorCode.TooLarge => "The generated Voice Lab audio exceeds this build's supported length, so it was not saved.",
        VoiceLabAssetStoreErrorCode.Altered => "The saved Voice Lab audio did not read back as written. The file was kept; check the disk before using it.",
        VoiceLabAssetStoreErrorCode.PublishedUnverified => "The generated Voice Lab audio was saved but could not be confirmed; the file was kept.",
        _ => "The generated Voice Lab audio could not be saved. Check the free space and the storage folder's permissions."
    };
}

/// <summary>Immutable, canonical mono PCM16 paid assets; voice-lab.md §10.1 and §10.4.</summary>
public static class VoiceLabAssetStore
{
    internal const long MaxFrames = (uint.MaxValue - 36L) / 2;
    private const int BlockFrames = 65_536;

    /// <summary>Publishes provider PCM16LE once, then verifies the bytes at the final name.</summary>
    public static VoiceLabAsset Write(ReadOnlySpan<byte> pcm16, int sampleRate, string projectId, string assetId,
        string paidRoot, DateTimeOffset createdAt, CancellationToken cancellationToken = default)
        => Write(pcm16, sampleRate, projectId, assetId, paidRoot, createdAt, cancellationToken, null, null);

    internal static VoiceLabAsset Write(ReadOnlySpan<byte> pcm16, int sampleRate, string projectId, string assetId,
        string paidRoot, DateTimeOffset createdAt, CancellationToken cancellationToken, Action? beforePublish, Action? afterPublish)
    {
        var file = VoiceLabAssetNaming.File(projectId, assetId, "wav");
        if (pcm16.Length % 2 != 0) throw Failure(VoiceLabAssetStoreErrorCode.InvalidAudio, file);
        return Publish(pcm16, [], false, sampleRate, projectId, assetId, paidRoot, createdAt, file,
            cancellationToken, beforePublish, afterPublish);
    }

    /// <summary>Converts finite mono floats using binary64 multiplication, ties to even, and a ±32767 clamp.</summary>
    public static VoiceLabAsset WriteDerived(ReadOnlySpan<float> samples, int sampleRate, string projectId, string assetId,
        string paidRoot, DateTimeOffset createdAt, CancellationToken cancellationToken = default)
    {
        var file = VoiceLabAssetNaming.File(projectId, assetId, "wav");
        foreach (var sample in samples)
            if (!float.IsFinite(sample)) throw Failure(VoiceLabAssetStoreErrorCode.InvalidAudio, file);
        return Publish([], samples, true, sampleRate, projectId, assetId, paidRoot, createdAt, file,
            cancellationToken, null, null);
    }

    internal static short Pcm16(float sample)
        => (short)Math.Clamp(Math.Round((double)sample * 32_767, MidpointRounding.ToEven), -32_767, 32_767);
    public static int CleanupStalePartials(string paidRoot, string projectId, DateTimeOffset processStart)
    {
        var label = VoiceLabAssetNaming.File(projectId, "cleanup", "wav");
        var root = OpenRoot(paidRoot, label);
        var directory = Path.Combine(root, projectId);
        if (!Directory.Exists(directory)) return 0;
        using var rootLease = HoldDirectory(root, label, followLinks: true);
        RequireDirectory(directory, label, false);
        using var projectLease = HoldDirectory(directory, label);
        return VoiceLabPartialJournal.Sweep(directory);
    }
    public static VoiceLabAsset WriteWave(ReadOnlySpan<byte> pcm, int sampleRate, int channels, int bits, bool floating,
        string projectId, string assetId, string paidRoot, DateTimeOffset createdAt, CancellationToken ct = default)
    {
        var wave = new VoiceLabWavePcm(sampleRate, channels, bits, floating, pcm.ToArray());
        return Publish([], [], false, sampleRate, projectId, assetId, paidRoot, createdAt, VoiceLabAssetNaming.File(projectId, assetId, "wav"), ct, null, null, wave);
    }

    internal static byte[] WavHeader(long frames, int sampleRate)
    {
        Validate(frames, sampleRate, "audio.wav");
        var header = new byte[44];
        "RIFF"u8.CopyTo(header);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(4), checked((uint)(36 + frames * 2)));
        "WAVEfmt "u8.CopyTo(header.AsSpan(8));
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(16), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(20), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(22), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(24), (uint)sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(28), (uint)sampleRate * 2);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(32), 2);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(34), 16);
        "data"u8.CopyTo(header.AsSpan(36));
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(40), checked((uint)(frames * 2)));
        return header;
    }

    internal static void Validate(long frames, int sampleRate, string file)
    {
        if (sampleRate is < 8_000 or > 192_000 || frames < 1)
            throw Failure(VoiceLabAssetStoreErrorCode.InvalidAudio, file);
        if (frames > MaxFrames) throw Failure(VoiceLabAssetStoreErrorCode.TooLarge, file);
    }

    private static VoiceLabAsset Publish(ReadOnlySpan<byte> pcm16, ReadOnlySpan<float> samples, bool derived,
        int sampleRate, string projectId, string assetId, string paidRoot, DateTimeOffset createdAt, string file,
        CancellationToken cancellationToken, Action? beforePublish, Action? afterPublish, VoiceLabWavePcm? wave = null)
    {
        var frames = wave?.Frames ?? (derived ? samples.Length : pcm16.Length / 2);
        Validate(frames, sampleRate, file);
        cancellationToken.ThrowIfCancellationRequested();
        string? temporary = null;
        VoiceLabPartialJournal? partialJournal = null;
        var published = false;
        Exception? primaryError = null;
        try
        {
            var root = OpenRoot(paidRoot, file);
            using var rootLease = HoldDirectory(root, file, followLinks: true);
            if (rootLease is not null) root = VoiceLabWindowsFiles.FinalPath(rootLease);
            var directory = Path.Combine(root, projectId);
            RequireDirectory(directory, file, create: true);
            using var projectLease = HoldDirectory(directory, file);
            if (projectLease is not null) VoiceLabAssets.RequireWithinRoot(root, directory, projectLease, file);
            var final = Path.Combine(directory, Path.GetFileName(file));
            if (EntryExists(final)) throw Failure(VoiceLabAssetStoreErrorCode.AlreadyExists, file);
            temporary = Path.Combine(directory, "." + Path.GetFileName(file) + "." + Guid.NewGuid().ToString("N") + ".partial");
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var options = new FileStreamOptions
            {
                Mode = FileMode.CreateNew, Access = FileAccess.ReadWrite, Share = FileShare.None,
                Options = FileOptions.WriteThrough, BufferSize = 131_072
            };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var output = new FileStream(temporary, options))
            {
                partialJournal = VoiceLabPartialJournal.Register(temporary, output.SafeFileHandle);
                VoiceLabAssets.RequireWithinRoot(root, temporary, output.SafeFileHandle, file);
                var header = wave?.Header() ?? WavHeader(frames, sampleRate);
                output.Write(header); hash.AppendData(header);
                var buffer = derived ? new byte[2 * Math.Min(BlockFrames, frames)] : [];
                for (var start = 0; start < frames; start += Math.Min(BlockFrames, frames - start))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var count = Math.Min(BlockFrames, frames - start);
                    ReadOnlySpan<byte> bytes;
                    if (derived)
                    {
                        for (var index = 0; index < count; index++)
                            BinaryPrimitives.WriteInt16LittleEndian(buffer.AsSpan(2 * index), Pcm16(samples[start + index]));
                        bytes = buffer.AsSpan(0, count * 2);
                    }
                    else bytes = wave is null ? pcm16.Slice(start * 2, count * 2) : wave.Pcm.AsSpan(start * wave.Stride, count * wave.Stride);
                    output.Write(bytes); hash.AppendData(bytes);
                }
                if (wave is not null && wave.Pcm.Length % 2 != 0) { output.WriteByte(0); hash.AppendData([0]); }
                output.Flush(true);
            }
            beforePublish?.Invoke();
            cancellationToken.ThrowIfCancellationRequested();
            RequireDirectory(directory, file, create: false);
            try { MoveExclusive(temporary, final, file); }
            catch (IOException) when (EntryExists(final)) { throw Failure(VoiceLabAssetStoreErrorCode.AlreadyExists, file); }
            published = true;
            afterPublish?.Invoke();
            var digest = Convert.ToHexStringLower(hash.GetHashAndReset());
            if (!EntryExists(final) || (System.IO.File.GetAttributes(final) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                throw Failure(VoiceLabAssetStoreErrorCode.Altered, file);
            using var stored = new FileStream(final, FileMode.Open, FileAccess.Read, FileShare.Read);
            VoiceLabAssets.RequireWithinRoot(root, final, stored.SafeFileHandle, file);
            if (stored.Length != 44L + (wave is null ? 2L * frames : wave.Pcm.Length + wave.Pcm.Length % 2) || Convert.ToHexStringLower(SHA256.HashData(stored)) != digest)
                throw Failure(VoiceLabAssetStoreErrorCode.Altered, file);
            return new(assetId, "audio", file, digest, frames / (double)sampleRate, sampleRate, createdAt);
        }
        catch (VoiceLabAssetException)
        {
            primaryError = Failure(published ? VoiceLabAssetStoreErrorCode.Altered : VoiceLabAssetStoreErrorCode.UnsafePath, file);
            throw primaryError;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            primaryError = Failure(published ? VoiceLabAssetStoreErrorCode.PublishedUnverified : VoiceLabAssetStoreErrorCode.Unwritable, file);
            throw primaryError;
        }
        catch (Exception error) { primaryError = error; throw; }
        finally
        {
            if (partialJournal is not null && temporary is not null)
            {
                try { partialJournal.Complete(deletePartial: !published); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    if (primaryError is VoiceLabAssetStoreException failure) failure.OrphanedTemporaryPath = temporary;
                    if (primaryError is not null) primaryError.Data[nameof(VoiceLabAssetStoreException.OrphanedTemporaryPath)] = temporary;
                }
            }
        }
    }

    private static string OpenRoot(string paidRoot, string file)
    {
        var root = Path.GetFullPath(paidRoot);
        if (EntryExists(root))
        {
            if (!Directory.Exists(root)) throw Failure(VoiceLabAssetStoreErrorCode.UnsafePath, file);
            if (OperatingSystem.IsWindows()) return root;
            var info = new DirectoryInfo(root);
            if (info.LinkTarget is not null) root = info.ResolveLinkTarget(true)?.FullName ?? root;
            RequireDirectory(root, file, create: false);
        }
        else
        {
            var parent = Path.GetDirectoryName(root);
            if (parent is null || !EntryExists(parent)) throw Failure(VoiceLabAssetStoreErrorCode.RootMissing, file);
            if (!Directory.Exists(parent)) throw Failure(VoiceLabAssetStoreErrorCode.UnsafePath, file);
            RequireDirectory(root, file, create: true);
        }
        return root;
    }

    internal static void RequireDirectory(string path, string file, bool create)
    {
        if (!EntryExists(path) && create)
        {
            if (OperatingSystem.IsWindows()) Directory.CreateDirectory(path);
            else Directory.CreateDirectory(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        var attributes = System.IO.File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
            throw Failure(VoiceLabAssetStoreErrorCode.UnsafePath, file);
    }

    private static bool EntryExists(string path)
    {
        try { _ = System.IO.File.GetAttributes(path); return true; }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return false; }
    }

    internal static SafeFileHandle? HoldDirectory(string path, string file, bool followLinks = false)
    {
        if (!OperatingSystem.IsWindows()) return null;
        var handle = CreateFileW(path, 0x80000000, FileShare.Read | FileShare.Write, IntPtr.Zero, FileMode.Open,
            followLinks ? 0x02000000u : 0x02200000u, IntPtr.Zero);
        try
        {
            if (handle.IsInvalid) throw Failure(VoiceLabAssetStoreErrorCode.Unwritable, file);
            var attributes = VoiceLabWindowsFiles.Attributes(handle);
            if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
                throw Failure(VoiceLabAssetStoreErrorCode.UnsafePath, file);
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, FileShare share, IntPtr security,
        FileMode disposition, uint flags, IntPtr template);

    private static void MoveExclusive(string temporary, string final, string file)
    {
        if (OperatingSystem.IsWindows())
        {
            if (!VoiceLabWindowsFiles.MoveFileExW(temporary, final, VoiceLabWindowsFiles.MoveWriteThrough))
                throw Failure(Marshal.GetLastPInvokeError() is 80 or 183
                    ? VoiceLabAssetStoreErrorCode.AlreadyExists : VoiceLabAssetStoreErrorCode.Unwritable, file);
            return;
        }
        var result = OperatingSystem.IsMacOS() ? RenameExclusive(temporary, final, 4) :
            RenameAtExclusive(-100, temporary, -100, final, 1);
        if (result != 0) throw Failure(Marshal.GetLastPInvokeError() == 17
            ? VoiceLabAssetStoreErrorCode.AlreadyExists : VoiceLabAssetStoreErrorCode.Unwritable, file);
    }

    [DllImport("libc", EntryPoint = "renamex_np", SetLastError = true)]
    private static extern int RenameExclusive([MarshalAs(UnmanagedType.LPUTF8Str)] string source,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string destination, uint flags);
    [DllImport("libc", EntryPoint = "renameat2", SetLastError = true)]
    private static extern int RenameAtExclusive(int sourceDirectory, [MarshalAs(UnmanagedType.LPUTF8Str)] string source,
        int destinationDirectory, [MarshalAs(UnmanagedType.LPUTF8Str)] string destination, uint flags);

    private static VoiceLabAssetStoreException Failure(VoiceLabAssetStoreErrorCode code, string file) => new(code, file);
}
