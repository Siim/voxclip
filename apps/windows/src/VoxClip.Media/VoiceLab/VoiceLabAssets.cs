#pragma warning disable CS1591 // Public descriptor members are documented together in voice-lab.md §10.
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

public enum VoiceLabAssetErrorCode
{
    Missing, UnsafePath, Altered, UnsupportedFormat, Unreadable, InvalidAudio, InvalidSelection,
    RateMismatch, DurationMismatch, InvalidTrim, TooLarge
}

public sealed class VoiceLabAssetException(VoiceLabAssetErrorCode code, string file) : Exception(Explain(code, file))
{
    public VoiceLabAssetErrorCode Code { get; } = code;
    private static string Explain(VoiceLabAssetErrorCode code, string file) => code switch
    {
        VoiceLabAssetErrorCode.Missing => $"The generated Voice Lab audio {file} is missing. Restore the paid file before preview or export.",
        VoiceLabAssetErrorCode.UnsafePath => $"The generated Voice Lab audio {file} points outside its paid storage folder. Check the file location.",
        VoiceLabAssetErrorCode.Altered => $"The generated Voice Lab audio {file} has changed. Restore the original paid file.",
        VoiceLabAssetErrorCode.UnsupportedFormat => $"This build cannot decode the generated Voice Lab audio {file}. Keep the paid file for a supported build.",
        VoiceLabAssetErrorCode.Unreadable or VoiceLabAssetErrorCode.InvalidAudio => $"The generated Voice Lab audio {file} cannot be read. Restore a valid paid file.",
        VoiceLabAssetErrorCode.InvalidSelection => $"The selected Voice Lab take or output plan for {file} changed. Rebuild the preview or export request.",
        VoiceLabAssetErrorCode.RateMismatch or VoiceLabAssetErrorCode.DurationMismatch => $"The generated Voice Lab audio {file} no longer matches its project record. Restore the original paid file.",
        VoiceLabAssetErrorCode.InvalidTrim => $"The generated Voice Lab audio trim for {file} is outside the decoded file. Review the selected take.",
        _ => $"The generated Voice Lab audio {file} exceeds this build's supported length. Keep the paid file for a supported build."
    };
}

/// <summary>Owns validated snapshot bytes until a future composition releases them.</summary>
public sealed class PreparedVoiceLabAsset : IDisposable
{
    private readonly string scratch;
    public string SegmentId { get; }
    public string AssetId { get; }
    public string Path { get; }
    public int SampleRate { get; }
    public int Channels { get; }
    public long FrameCount { get; }
    public long TrimStartFrame { get; }
    public long TrimEndFrame { get; }
    public double Stretch { get; }
    public double GainDb { get; }
    internal PreparedVoiceLabAsset(string segmentId, string id, string path, string scratch, int rate, int channels, long frames,
        long trimStart, long trimEnd, double stretch, double gainDb)
    {
        SegmentId = segmentId; AssetId = id; Path = path; this.scratch = scratch; SampleRate = rate; Channels = channels;
        FrameCount = frames; TrimStartFrame = trimStart; TrimEndFrame = trimEnd; Stretch = stretch; GainDb = gainDb;
    }
    public void Dispose() { if (Directory.Exists(scratch)) Directory.Delete(scratch, true); }
}

public static class VoiceLabAssets
{
    private const long MaxBytes = 8L * 1024 * 1024 * 1024;
    private const long MaxFrames = 192_000L * 86_400;

    /// <summary>Prepare only paid assets used by a Core output plan. Caller disposes each handle.</summary>
    public static async Task<IReadOnlyDictionary<string, PreparedVoiceLabAsset>> PrepareAsync(Project project,
        VoiceLabOutputPlan plan, string paidRoot, CancellationToken cancellationToken = default)
    {
        VoiceLabProject.Validate(project);
        var expected = VoiceLabOutputPlanner.Build(project, plan.Scope);
        if (expected.SampleRate != plan.SampleRate || expected.TotalSourceSamples != plan.TotalSourceSamples ||
            !expected.Pieces.SequenceEqual(plan.Pieces) || !expected.Captions.SequenceEqual(plan.Captions))
            throw new VoiceLabAssetException(VoiceLabAssetErrorCode.InvalidSelection, "output plan");
        var prepared = new Dictionary<string, PreparedVoiceLabAsset>(StringComparer.Ordinal);
        try
        {
            foreach (var piece in plan.Pieces.Where(piece => piece.Kind == VoiceLabOutputPieceKind.Synth))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var audio = piece.Audio ?? throw new VoiceLabAssetException(VoiceLabAssetErrorCode.InvalidSelection, piece.SegmentId ?? "segment");
                var asset = project.VoiceLab.Assets?.FirstOrDefault(item => item.Id == piece.AssetId)
                    ?? throw new VoiceLabAssetException(VoiceLabAssetErrorCode.InvalidSelection, piece.SegmentId ?? "segment");
                if (piece.SegmentId is null) throw new VoiceLabAssetException(VoiceLabAssetErrorCode.InvalidSelection, asset.File);
                if (!prepared.ContainsKey(piece.SegmentId))
                    prepared.Add(piece.SegmentId, await PrepareAsync(project, asset, audio, piece.SegmentId, paidRoot, cancellationToken).ConfigureAwait(false));
            }
            return prepared;
        }
        catch
        {
            foreach (var handle in prepared.Values) handle.Dispose();
            throw;
        }
    }

    public static async Task<PreparedVoiceLabAsset> PrepareAsync(Project project, VoiceLabAsset asset,
        VoiceLabAudio audio, string segmentId, string paidRoot, CancellationToken cancellationToken = default)
    {
        VoiceLabProject.Validate(project);
        if (project.VoiceLab.Assets?.Contains(asset) != true ||
            project.VoiceLab.Segments.FirstOrDefault(segment => segment.Id == segmentId)?.Audio != audio ||
            audio.AssetId != asset.Id)
            throw new VoiceLabAssetException(VoiceLabAssetErrorCode.InvalidSelection, asset.File);
        var rootPath = System.IO.Path.GetFullPath(paidRoot);
        var sourcePath = System.IO.Path.Combine(rootPath, project.Id, System.IO.Path.GetFileName(asset.File));
        var scratch = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "voxclip-voice-" + Guid.NewGuid().ToString("N"));
        try { Directory.CreateDirectory(scratch); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { throw new VoiceLabAssetException(VoiceLabAssetErrorCode.Unreadable, asset.File); }
        try
        {
            await using var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read,
                1024 * 1024, FileOptions.SequentialScan | FileOptions.Asynchronous);
            RequireWithinRoot(rootPath, sourcePath, source.SafeFileHandle, asset.File);
            if (source.Length <= 0 || source.Length > MaxBytes)
                throw new VoiceLabAssetException(VoiceLabAssetErrorCode.TooLarge, asset.File);
            VoiceLabCapacity.Require([new VoiceLabCapacity.Allocation(scratch, source.Length)]);
            var snapshot = System.IO.Path.Combine(scratch, System.IO.Path.GetFileName(asset.File));
            await using (var output = new FileStream(snapshot, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                1024 * 1024, FileOptions.SequentialScan | FileOptions.Asynchronous))
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                var buffer = new byte[1024 * 1024];
                long copied = 0;
                while (true)
                {
                    var count = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                    if (count == 0) break;
                    copied += count;
                    if (copied > MaxBytes) throw new VoiceLabAssetException(VoiceLabAssetErrorCode.TooLarge, asset.File);
                    hash.AppendData(buffer, 0, count);
                    await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                    if (copied / (64L * 1024 * 1024) != (copied - count) / (64L * 1024 * 1024))
                        VoiceLabCapacity.Require([new VoiceLabCapacity.Allocation(scratch, source.Length - copied)]);
                }
                if (copied != source.Length || Convert.ToHexStringLower(hash.GetHashAndReset()) != asset.Sha256)
                    throw new VoiceLabAssetException(VoiceLabAssetErrorCode.Altered, asset.File);
            }
            if (!asset.File.EndsWith(".wav", StringComparison.Ordinal))
                throw new VoiceLabAssetException(VoiceLabAssetErrorCode.UnsupportedFormat, asset.File);
            var (rate, channels, frames) = ReadWav(snapshot, asset.File, cancellationToken);
            if (rate != asset.SampleRate) throw new VoiceLabAssetException(VoiceLabAssetErrorCode.RateMismatch, asset.File);
            if (Math.Abs(frames - asset.DurationSeconds * rate) > 1)
                throw new VoiceLabAssetException(VoiceLabAssetErrorCode.DurationMismatch, asset.File);
            var start = Frame(audio.TrimStart, rate); var end = Frame(audio.TrimEnd, rate);
            if (start < 0 || end <= start || end > frames)
                throw new VoiceLabAssetException(VoiceLabAssetErrorCode.InvalidTrim, asset.File);
            return new PreparedVoiceLabAsset(segmentId, asset.Id, snapshot, scratch, rate, channels, frames,
                start, end, audio.Stretch, audio.GainDb);
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            Directory.Delete(scratch, true);
            throw new VoiceLabAssetException(VoiceLabAssetErrorCode.Missing, asset.File);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Directory.Delete(scratch, true);
            throw new VoiceLabAssetException(VoiceLabAssetErrorCode.Unreadable, asset.File);
        }
        catch
        {
            Directory.Delete(scratch, true);
            throw;
        }
    }

    private static void RequireWithinRoot(string root, string file, SafeFileHandle handle, string label)
    {
        string canonicalRoot, canonicalFile;
        if (OperatingSystem.IsWindows())
        {
            canonicalRoot = new DirectoryInfo(root).ResolveLinkTarget(true)?.FullName ?? root;
            canonicalFile = FinalPath(handle);
            if (canonicalFile.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase))
                canonicalFile = "\\\\" + canonicalFile[8..];
            else if (canonicalFile.StartsWith("\\\\?\\", StringComparison.Ordinal))
                canonicalFile = canonicalFile[4..];
        }
        else
        {
            canonicalRoot = new DirectoryInfo(root).ResolveLinkTarget(true)?.FullName ?? root;
            canonicalFile = new FileInfo(file).ResolveLinkTarget(true)?.FullName ?? file;
            var parent = new DirectoryInfo(System.IO.Path.GetDirectoryName(file)!);
            if (parent.LinkTarget is not null)
                canonicalFile = System.IO.Path.Combine(parent.ResolveLinkTarget(true)!.FullName, System.IO.Path.GetFileName(canonicalFile));
        }
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!canonicalFile.StartsWith(canonicalRoot.TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar, comparison))
            throw new VoiceLabAssetException(VoiceLabAssetErrorCode.UnsafePath, label);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
    private static string FinalPath(SafeFileHandle handle)
    {
        var text = new StringBuilder(32768);
        var length = GetFinalPathNameByHandle(handle, text, (uint)text.Capacity, 0);
        if (length == 0 || length >= text.Capacity) throw new IOException("Cannot resolve Voice Lab file path");
        return text.ToString();
    }

    private static long Frame(double seconds, int rate) => checked((long)Math.Floor(seconds * rate + 0.5));

    private static (int rate, int channels, long frames) ReadWav(string path, string label, CancellationToken ct)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024);
        using var reader = new BinaryReader(input);
        void Invalid() => throw new VoiceLabAssetException(VoiceLabAssetErrorCode.InvalidAudio, label);
        if (input.Length < 44 || Encoding.ASCII.GetString(reader.ReadBytes(4)) != "RIFF") Invalid();
        var riffSize = reader.ReadUInt32();
        if (riffSize + 8L != input.Length || Encoding.ASCII.GetString(reader.ReadBytes(4)) != "WAVE") Invalid();
        int rate = 0, channels = 0, bits = 0, block = 0, format = 0;
        long dataStart = -1, dataBytes = 0;
        while (input.Position + 8 <= input.Length)
        {
            ct.ThrowIfCancellationRequested();
            var id = Encoding.ASCII.GetString(reader.ReadBytes(4));
            var length = (long)reader.ReadUInt32();
            var start = input.Position;
            if (length > input.Length - start || length + (length & 1) > input.Length - start) Invalid();
            if (id == "fmt ")
            {
                if (rate != 0 || length < 16) Invalid();
                format = reader.ReadUInt16(); channels = reader.ReadUInt16(); rate = reader.ReadInt32();
                var byteRate = reader.ReadInt32(); block = reader.ReadUInt16(); bits = reader.ReadUInt16();
                if (format != 1 && format != 3 || format == 1 && bits is not (16 or 24 or 32) ||
                    format == 3 && bits is not (32 or 64))
                    throw new VoiceLabAssetException(VoiceLabAssetErrorCode.UnsupportedFormat, label);
                if (channels is < 1 or > 8 || rate is < 8000 or > 192000 ||
                    block != channels * bits / 8 || byteRate != rate * block) Invalid();
            }
            else if (id == "data")
            {
                if (dataStart >= 0) Invalid();
                dataStart = start; dataBytes = length;
            }
            input.Position = start + length + (length & 1);
        }
        if (input.Position != input.Length || rate == 0 || dataStart < 0 || dataBytes == 0 || dataBytes % block != 0) Invalid();
        var frames = dataBytes / block;
        if (frames > MaxFrames) throw new VoiceLabAssetException(VoiceLabAssetErrorCode.TooLarge, label);
        input.Position = dataStart;
        var buffer = new byte[64 * 1024];
        var left = dataBytes;
        while (left > 0)
        {
            ct.ThrowIfCancellationRequested();
            var count = (int)Math.Min(buffer.Length, left);
            input.ReadExactly(buffer.AsSpan(0, count));
            if (format == 3)
            {
                var bytesPerSample = bits / 8;
                // Float samples may straddle a chunk, so the buffer size is a multiple of both float widths.
                for (var offset = 0; offset + bytesPerSample <= count; offset += bytesPerSample)
                {
                    var value = bits == 32
                        ? BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(buffer.AsSpan(offset)))
                        : BitConverter.Int64BitsToDouble(BinaryPrimitives.ReadInt64LittleEndian(buffer.AsSpan(offset)));
                    if (!double.IsFinite(value)) Invalid();
                }
            }
            left -= count;
        }
        return (rate, channels, frames);
    }
}
