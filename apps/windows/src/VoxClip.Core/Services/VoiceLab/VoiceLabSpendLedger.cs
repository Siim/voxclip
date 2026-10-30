using System.Diagnostics;
using System.Globalization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>The shared Voice Lab price catalog; Voice Lab §3.2.</summary>
public static class VoiceLabPrices
{
    /// <summary>Read <c>catalog/voice-lab.json</c> beneath <paramref name="sharedRoot"/>, or beneath <see cref="SharedResources"/> when null.</summary>
    public static VoiceLabPriceCatalog Load(string? sharedRoot = null)
    {
        byte[] bytes;
        try { bytes = File.ReadAllBytes(Path.Combine(sharedRoot ?? SharedResources.ResolveRoot(), "catalog", "voice-lab.json")); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        }
        return VoiceLabPriceCatalog.Parse(bytes);
    }
}

/// <summary>Why a spend record was not applied as asked.</summary>
public enum VoiceLabSpendWarningKind
{
    /// <summary>The previous file was unreadable. It now has <c>BackupFileName</c> in the same directory; a fresh ledger holds the record.</summary>
    ReplacedCorruptLedger,
    /// <summary>Another holder kept <c>spend.json.lock</c> for <c>LockTimeout</c>; nothing was recorded.</summary>
    LockTimedOut,
    /// <summary>The caller's token was cancelled while the ledger waited for the lock; nothing was recorded.</summary>
    Cancelled,
    /// <summary>The ledger could not be read or written, for example on a read-only or full volume or without its data folder; nothing was
    /// recorded.</summary>
    WriteFailed,
    /// <summary>The estimate has no valid provider id or a negative amount; nothing was recorded.</summary>
    InvalidEstimate
}

/// <summary>A typed ledger warning. The provider already accepted the action, so the ledger never throws into it.</summary>
public sealed record VoiceLabSpendWarning(VoiceLabSpendWarningKind Kind, string? BackupFileName = null);

/// <summary><c>&lt;data&gt;/VoiceLab/spend.json</c>, the estimate of what Voice Lab actions cost per provider and local month; Voice Lab §3.1.
/// The App and CLI can record at the same time. A writer holds an exclusive open of <c>spend.json.lock</c>, which is never deleted, while it
/// reads, adds and replaces the file; a reader holds a shared one. .NET maps these to share modes on Windows and to <c>flock</c> elsewhere.
/// Only a sharing or lock violation (<c>EWOULDBLOCK</c> off Windows) means another holder; any other failure is <c>WriteFailed</c> at once.
/// Only <c>VoiceLab</c> itself is ever created, inside an existing data folder and with mode 0700 where modes exist, never the data folder.
/// <see cref="AtomicFile"/> flushes the 0600 temporary file to the disk (<c>Flush(true)</c>) before <c>File.Replace</c> or the move.</summary>
public sealed class VoiceLabSpendLedger
{
    private const UnixFileMode Private = UnixFileMode.UserRead | UnixFileMode.UserWrite;
    private const UnixFileMode PrivateDirectory = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
    private static readonly TimeSpan LongestRead = TimeSpan.FromMilliseconds(500);
    private readonly TimeZoneInfo? timeZone;

    /// <summary>The ledger under <c>&lt;data&gt;/VoiceLab</c>.</summary>
    public VoiceLabSpendLedger(DataLocations locations, TimeZoneInfo? timeZone = null, TimeSpan? lockTimeout = null)
        : this(Path.Combine((locations ?? throw new ArgumentNullException(nameof(locations))).Root, "VoiceLab", "spend.json"), timeZone, lockTimeout) { }

    /// <summary>A ledger file. Without <paramref name="timeZone"/> the system zone is used as it is at each action; the lock wait defaults
    /// to 5 seconds.</summary>
    public VoiceLabSpendLedger(string filePath, TimeZoneInfo? timeZone = null, TimeSpan? lockTimeout = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        FilePath = Path.GetFullPath(filePath);
        this.timeZone = timeZone;
        LockTimeout = lockTimeout ?? TimeSpan.FromSeconds(5);
    }

    /// <summary>The ledger file.</summary>
    public string FilePath { get; }
    /// <summary>The injected zone, or null for the system zone; a ledger month is the local calendar month at an action's start.</summary>
    public TimeZoneInfo? TimeZone => timeZone;
    /// <summary>How long a writer waits for another holder of the lock before it gives up with <c>LockTimedOut</c>.</summary>
    public TimeSpan LockTimeout { get; }
    /// <summary>How long a reader waits, at most half a second, so a cap check never stalls the interface.</summary>
    public TimeSpan ReadTimeout => LockTimeout < LongestRead ? LockTimeout : LongestRead;

    /// <summary>The ledger month of <paramref name="start"/>. Without an injected zone the system zone is read again for every call:
    /// <see cref="TimeZoneInfo.Local"/> is cached for the life of the process, so the cache is cleared first. That is cheap, because only the
    /// local zone is reloaded when next asked for, and safe, because code holding a zone keeps a valid instance; a zone change then applies
    /// to the next action.</summary>
    public string Month(DateTimeOffset start)
    {
        if (timeZone is not null) return VoiceLabSpendDocument.Month(start, timeZone);
        TimeZoneInfo.ClearCachedData();
        return VoiceLabSpendDocument.Month(start, TimeZoneInfo.Local);
    }

    /// <summary>The ledger, read under the shared lock. A missing ledger or directory reads as empty, and so does a corrupt file, which the
    /// next <see cref="RecordAsync"/> moves aside. Null when it cannot be read now, such as a writer holding the lock past
    /// <see cref="ReadTimeout"/>.</summary>
    public async Task<VoiceLabSpendDocument?> ReadAsync(CancellationToken ct)
    {
        if (!Directory.Exists(Path.GetDirectoryName(FilePath))) return new VoiceLabSpendDocument();
        var (held, failure) = await AcquireAsync(true, ReadTimeout, ct).ConfigureAwait(false);
        if (failure is not null) return null;
        // Without a lock file no writer has run here, so there is no replacement to read through.
        using (held)
        {
            if (!File.Exists(FilePath)) return new VoiceLabSpendDocument();
            return await TryReadAsync(ct).ConfigureAwait(false) is { } bytes ? VoiceLabSpendDocument.Parse(bytes) ?? new() : null;
        }
    }

    /// <summary>The provider's spend in the local month of <paramref name="start"/>, or null when the ledger cannot be read now.</summary>
    public async Task<VoiceLabSpendTotal?> TotalAsync(string provider, DateTimeOffset start, CancellationToken ct) =>
        (await ReadAsync(ct).ConfigureAwait(false))?.Total(provider, Month(start));

    /// <summary>Cap decisions never interpret malformed or unreadable persisted spending as zero.</summary>
    public async Task<VoiceLabSpendTotal?> TotalForCapAsync(string provider, DateTimeOffset start, CancellationToken ct)
    {
        if (!Directory.Exists(Path.GetDirectoryName(FilePath))) return new VoiceLabSpendDocument().Total(provider, Month(start));
        var (held, failure) = await AcquireAsync(true, ReadTimeout, ct).ConfigureAwait(false);
        if (failure is not null) return null;
        using (held)
        {
            if (!File.Exists(FilePath)) return new VoiceLabSpendDocument().Total(provider, Month(start));
            var bytes = await TryReadAsync(ct).ConfigureAwait(false);
            return bytes is null ? null : VoiceLabSpendDocument.Parse(bytes)?.Total(provider, Month(start));
        }
    }

    /// <summary>Add the estimate of one action that ran, once, after the provider accepted it, under the local month of <paramref name="start"/>.
    /// A free action (exactly $0) is not recorded and touches nothing. <paramref name="ct"/> applies only to the wait for the lock: once the
    /// lock is held the record completes, because the action already ran.</summary>
    public async Task<VoiceLabSpendWarning?> RecordAsync(CostEstimate estimate, DateTimeOffset start, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(estimate);
        var month = Month(start);
        try { new VoiceLabSpendDocument().Record(estimate, month); }
        catch (VoiceLabException) { return new(VoiceLabSpendWarningKind.InvalidEstimate); }
        if (estimate.Usd == 0) return null;
        if (!CreateDirectory()) return new(VoiceLabSpendWarningKind.WriteFailed);
        var (held, failure) = await AcquireAsync(false, LockTimeout, ct).ConfigureAwait(false);
        if (held is null) return new(failure ?? VoiceLabSpendWarningKind.WriteFailed);
        using (held)
        {
            var document = new VoiceLabSpendDocument();
            VoiceLabSpendWarning? warning = null;
            if (File.Exists(FilePath))
            {
                if (await TryReadAsync(CancellationToken.None).ConfigureAwait(false) is not { } bytes) return new(VoiceLabSpendWarningKind.WriteFailed);
                if (VoiceLabSpendDocument.Parse(bytes) is { } existing) document = existing;
                else if (MoveAside() is { } backup) warning = new(VoiceLabSpendWarningKind.ReplacedCorruptLedger, backup);
                else return new(VoiceLabSpendWarningKind.WriteFailed);
            }
            try { document.Record(estimate, month); }
            catch (VoiceLabException) { return new(VoiceLabSpendWarningKind.InvalidEstimate); }
            try { await AtomicFile.WriteAsync(FilePath, document.Encode(), CancellationToken.None, unixCreateMode: Private).ConfigureAwait(false); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return new(VoiceLabSpendWarningKind.WriteFailed); }
            return warning;
        }
    }

    /// <summary>True when a known estimate takes the provider's total for the month of <paramref name="start"/> from at most
    /// <paramref name="cap"/> to above it. The total is read under the lock; a ledger that cannot be read now gives false.</summary>
    public async Task<bool> WouldCrossAsync(decimal cap, string provider, CostEstimate estimate, DateTimeOffset start, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(estimate);
        if (estimate.Usd is null || await TotalAsync(provider, start, ct).ConfigureAwait(false) is not { } spent) return false;
        return new VoiceLabMonthlyCap(cap, spent.Usd).IsCrossedBy(estimate);
    }

    /// <summary>Creates only the ledger's directory, and only inside an existing data folder, as the paid-asset root is created.</summary>
    private bool CreateDirectory()
    {
        var directory = Path.GetDirectoryName(FilePath)!;
        try
        {
            if (Directory.Exists(directory)) return true;
            if (!Directory.Exists(Path.GetDirectoryName(directory))) return false;
            if (OperatingSystem.IsWindows()) Directory.CreateDirectory(directory);
            else Directory.CreateDirectory(directory, PrivateDirectory);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>Polls the lock so a busy ledger costs at most <paramref name="timeout"/>, never a hang. A reader finds no lock file before
    /// the first write and then reads without it (null held, null failure).</summary>
    private async Task<(FileStream? Held, VoiceLabSpendWarningKind? Failure)> AcquireAsync(bool shared, TimeSpan timeout, CancellationToken ct)
    {
        var options = shared
            ? new FileStreamOptions { Mode = FileMode.Open, Access = FileAccess.Read, Share = FileShare.Read }
            : new FileStreamOptions { Mode = FileMode.OpenOrCreate, Access = FileAccess.ReadWrite, Share = FileShare.None };
        if (!shared && !OperatingSystem.IsWindows()) options.UnixCreateMode = Private;
        var watch = Stopwatch.StartNew();
        while (true)
        {
            try { return (new FileStream(FilePath + ".lock", options), null); }
            catch (IOException exception) when (IsContention(exception))
            {
                if (watch.Elapsed >= timeout) return (null, VoiceLabSpendWarningKind.LockTimedOut);
                try { await Task.Delay(10, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return (null, VoiceLabSpendWarningKind.Cancelled); }
            }
            catch (FileNotFoundException) when (shared) { return (null, null); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                return (null, VoiceLabSpendWarningKind.WriteFailed);
            }
        }
    }

    /// <summary>A sharing or lock violation on Windows (HResult 32 or 33), or the <c>EWOULDBLOCK</c> that .NET raises elsewhere for a held
    /// <c>flock</c> (errno 11 on Linux, 35 on macOS). Anything else, such as read-only media or a full disk, is not worth waiting for.</summary>
    private static bool IsContention(IOException exception) =>
        OperatingSystem.IsWindows() ? (exception.HResult & 0xFFFF) is 32 or 33 : exception.HResult == (OperatingSystem.IsLinux() ? 11 : 35);

    /// <summary>Reads the file as bytes, so a byte-order mark is not skipped; brief Windows sharing violations, such as a scanner's, are
    /// retried.</summary>
    private async Task<byte[]?> TryReadAsync(CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                await using var stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.Asynchronous);
                using var buffer = new MemoryStream();
                await stream.CopyToAsync(buffer, ct).ConfigureAwait(false);
                return buffer.ToArray();
            }
            catch (IOException exception) when ((exception.HResult & 0xFFFF) is 32 or 33 && attempt < 5)
            {
                await Task.Delay(25 << attempt, ct).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return null; }
        }
    }

    /// <summary>Renames the unreadable file to <c>&lt;name&gt;.corrupt-&lt;unix milliseconds&gt;.json</c>, adding <c>-1</c>, <c>-2</c> … if that exists.</summary>
    private string? MoveAside()
    {
        var directory = Path.GetDirectoryName(FilePath)!;
        var stem = Path.GetFileNameWithoutExtension(FilePath) + ".corrupt-" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture);
        for (var suffix = 0; suffix < 1000; suffix++)
        {
            var name = stem + (suffix == 0 ? "" : "-" + suffix.ToString(CultureInfo.InvariantCulture)) + ".json";
            if (File.Exists(Path.Combine(directory, name))) continue;
            try
            {
                File.Move(FilePath, Path.Combine(directory, name), overwrite: false);
                return name;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return null; }
        }
        return null;
    }
}
