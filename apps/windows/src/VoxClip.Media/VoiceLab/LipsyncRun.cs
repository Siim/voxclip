using System.Net;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed record LipsyncRunWindow(string InputsFingerprint, double Seconds, double FrameRate, WholeClipLipsync Model, SyncMode Mode)
{
    internal string Key => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(FormattableString.Invariant(
        $"windows-lipsync/1\n{Model.RawValue()}\n{(int)Mode}\n{Seconds:R}\n{FrameRate:R}\n{InputsFingerprint}"))));
}

public enum LipsyncAttemptState { NotSent, Unconfirmed, Accepted, Downloaded, Failed }
public sealed record SavedLipsyncPicture(string Path, string RequestId, string Sha256);

public sealed class LipsyncRun(FalLipsyncProvider provider, VoiceConsentStore consent, string paidRoot, string projectId,
    VoiceLabSpendLedger? spend = null)
{
    private readonly LipsyncAttemptStore journal = new(paidRoot, projectId);

    public LipsyncAttemptState State(LipsyncRunWindow window)
    {
        using var attempt = journal.Open(window);
        return attempt.State;
    }

    public decimal? AcceptedPrice(LipsyncRunWindow window)
    {
        using var attempt = journal.Open(window);
        return attempt.Price;
    }

    public Task<FalLipsyncQuote> QuoteAsync(LipsyncRunWindow window, CancellationToken ct) =>
        provider.QuoteAsync(window.Model, window.Seconds, window.FrameRate, window.Mode, ct);

    public async Task<SavedLipsyncPicture> ExecuteAsync(LipsyncRunWindow window, FalLipsyncQuote? approved, string? videoPath,
        string? audioPath, VoiceConsentRecord record, VoiceLabDispatchBinding? binding, IProgress<LipsyncState>? progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        using var attempt = journal.Open(window);
        if (attempt.SavedPicture(ct) is { } saved) return saved;
        if (attempt.State == LipsyncAttemptState.Unconfirmed) throw new FalLipsyncException(FalLipsyncError.SubmissionUnconfirmed);
        if (attempt.State == LipsyncAttemptState.Failed) throw new FalLipsyncException(FalLipsyncError.RemoteFailed);
        LipsyncJob job;
        if (attempt.RequestId is { } existing)
            job = provider.Recover(window.Model, existing);
        else
        {
            if (approved is null || approved.Model != window.Model || approved.Mode != window.Mode ||
                approved.Estimate.Units != FalLipsyncProvider.UploadSeconds(window.Seconds, window.FrameRate) ||
                approved.Estimate.Usd is not { } price || videoPath is null || audioPath is null)
                throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
            var account = await provider.AccountFingerprintAsync(ct).ConfigureAwait(false);
            if (!approved.MatchesAccount(account)) throw new FalLipsyncException(FalLipsyncError.ApprovalRequired);
            var started = DateTimeOffset.Now;
            try
            {
                job = await provider.SubmitApprovedAsync(approved, videoPath, audioPath, consent, record, binding, ct,
                    beforeSubmit: () => { attempt.Begin(); return Task.CompletedTask; },
                    accepted: async accepted =>
                    {
                        attempt.Accept(accepted.RemoteId, account, price);
                        if (spend is not null) await spend.RecordAsync(approved.Estimate, started, CancellationToken.None).ConfigureAwait(false);
                    }).ConfigureAwait(false);
            }
            catch (FalLipsyncException error) when (error is { Code: FalLipsyncError.Http, Status: >= 400 and < 500 and not 408 })
            {
                attempt.Refused();
                throw;
            }
            catch (Exception error) when (error is VoiceConsentException or VoiceLabRunInvalidatedException)
            {
                attempt.Refused();
                throw;
            }
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(FalLipsyncProvider.JobDeadline);
        for (int poll = 0, failures = 0; ; poll++)
        {
            deadline.Token.ThrowIfCancellationRequested();
            LipsyncState state;
            try
            {
                state = await provider.PollAsync(job, attempt.Account, deadline.Token).ConfigureAwait(false);
                failures = 0;
            }
            catch (Exception error) when (!deadline.IsCancellationRequested && Transient(error))
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 1 << Math.Min(5, failures++))), deadline.Token).ConfigureAwait(false);
                continue;
            }
            progress?.Report(state);
            if (state is LipsyncState.Done done)
            {
                await provider.DownloadAsync(done.Result, attempt.PicturePath, null, CancellationToken.None).ConfigureAwait(false);
                var picture = attempt.KeepDownloaded(CancellationToken.None);
                try { await provider.CleanupAsync(job, attempt.Account, CancellationToken.None).ConfigureAwait(false); }
                catch (Exception error) when (error is FalLipsyncException or HttpRequestException or IOException or OperationCanceledException) { }
                return picture;
            }
            if (state is LipsyncState.Failed)
            {
                attempt.Fail();
                throw new FalLipsyncException(FalLipsyncError.RemoteFailed);
            }
            await Task.Delay(TimeSpan.FromSeconds(Math.Min(15, 2 + poll / 5)), deadline.Token).ConfigureAwait(false);
        }
    }

    private static bool Transient(Exception error) => error is HttpRequestException or IOException or OperationCanceledException ||
        error is FalLipsyncException { Code: FalLipsyncError.Http, Status: (int)HttpStatusCode.TooManyRequests or 408 or >= 500 };
}

internal sealed class LipsyncAttemptStore(string paidRoot, string projectId)
{
    internal LipsyncAttempt Open(LipsyncRunWindow window)
    {
        _ = VoiceLabAssetNaming.VideoFile(projectId, "lipsync");
        var root = Path.GetFullPath(paidRoot);
        var project = Path.Combine(root, projectId);
        var folder = Path.Combine(project, "lipsync-attempts");
        VoiceLabAssetStore.RequireDirectory(root, "lipsync", create: true);
        VoiceLabAssetStore.RequireDirectory(project, "lipsync", create: true);
        if (!Directory.Exists(folder)) VoiceConsentPrivacy.CreateDirectory(folder);
        VoiceLabAssetStore.RequireDirectory(folder, "lipsync", create: false);
        VoiceConsentPrivacy.Validate(folder, directory: true);
        return new(Path.Combine(folder, window.Key));
    }
}

internal sealed class LipsyncAttempt : IDisposable
{
    private readonly string marker;
    private readonly FileStream lease;
    private string? hash;
    internal string PicturePath { get; }
    internal LipsyncAttemptState State { get; private set; }
    internal string? RequestId { get; private set; }
    internal string? Account { get; private set; }
    internal decimal? Price { get; private set; }

    internal LipsyncAttempt(string stem)
    {
        marker = stem + ".receipt";
        PicturePath = stem + ".mp4";
        var lockPath = stem + ".lock";
        CheckFile(lockPath);
        lease = new(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        try
        {
            if (!CheckFile(marker)) return;
            if (new FileInfo(marker).Length > 512) throw InvalidReceipt();
            var lines = File.ReadAllLines(marker);
            switch (lines)
            {
                case ["unconfirmed"]: State = LipsyncAttemptState.Unconfirmed; break;
                case ["accepted" or "failed", var id, var account, var price]:
                    Load(id, account, price); State = lines[0] == "accepted" ? LipsyncAttemptState.Accepted : LipsyncAttemptState.Failed; break;
                case ["downloaded", var id, var account, var price, var digest] when Digest(digest):
                    Load(id, account, price); State = LipsyncAttemptState.Downloaded; hash = digest; break;
                default: throw InvalidReceipt();
            }
        }
        catch { lease.Dispose(); throw; }
    }

    internal void Begin()
    {
        if (State != LipsyncAttemptState.NotSent) throw InvalidReceipt();
        Save("unconfirmed\n");
        State = LipsyncAttemptState.Unconfirmed;
    }

    internal void Accept(string id, string account, decimal price)
    {
        if (State != LipsyncAttemptState.Unconfirmed || !ValidId(id)) throw InvalidReceipt();
        Load(id, account, price.ToString(CultureInfo.InvariantCulture));
        Save("accepted\n" + AcceptedFields());
        State = LipsyncAttemptState.Accepted;
    }

    internal void Fail()
    {
        if (State != LipsyncAttemptState.Accepted) throw InvalidReceipt();
        Save("failed\n" + AcceptedFields());
        State = LipsyncAttemptState.Failed;
    }

    internal void Refused()
    {
        if (State != LipsyncAttemptState.Unconfirmed) return;
        File.Delete(marker);
        State = LipsyncAttemptState.NotSent;
    }

    internal SavedLipsyncPicture? SavedPicture(CancellationToken ct)
    {
        if (RequestId is null || State is not (LipsyncAttemptState.Accepted or LipsyncAttemptState.Downloaded) || !CheckFile(PicturePath)) return null;
        if (State == LipsyncAttemptState.Accepted) return KeepDownloaded(ct);
        var actual = PictureHash(ct);
        return hash == actual ? new(PicturePath, RequestId, actual) : null;
    }

    internal SavedLipsyncPicture KeepDownloaded(CancellationToken ct)
    {
        var id = RequestId ?? throw InvalidReceipt();
        hash = PictureHash(ct);
        Save("downloaded\n" + AcceptedFields() + hash + "\n");
        State = LipsyncAttemptState.Downloaded;
        return new(PicturePath, id, hash);
    }

    private string AcceptedFields() => FormattableString.Invariant($"{RequestId}\n{Account}\n{Price}\n");

    private void Load(string id, string account, string cost)
    {
        if (!ValidId(id) || !Digest(account) || !decimal.TryParse(cost, NumberStyles.Number, CultureInfo.InvariantCulture, out var price) || price < 0)
            throw InvalidReceipt();
        RequestId = id;
        Account = account;
        Price = price;
    }

    private string PictureHash(CancellationToken ct)
    {
        if (!CheckFile(PicturePath)) throw InvalidReceipt();
        using var stream = File.OpenRead(PicturePath);
        if (stream.Length is < 1 or > FalLipsyncProvider.MaximumVideoBytes) throw InvalidReceipt();
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[65536];
        for (int read; (read = stream.Read(buffer)) > 0; )
        {
            ct.ThrowIfCancellationRequested();
            digest.AppendData(buffer.AsSpan(0, read));
        }
        return Convert.ToHexStringLower(digest.GetHashAndReset());
    }

    private void Save(string receipt)
    {
        var partial = marker + "." + Guid.NewGuid().ToString("N") + ".part";
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.WriteThrough };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try
        {
            using (var file = new FileStream(partial, options)) { file.Write(Encoding.UTF8.GetBytes(receipt)); file.Flush(true); }
            File.Move(partial, marker, true);
        }
        finally { File.Delete(partial); }
    }

    private static bool CheckFile(string path)
    {
        try
        {
            if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw InvalidReceipt();
            return true;
        }
        catch (FileNotFoundException) { return false; }
    }

    private static bool ValidId(string id) => id.Length is >= 1 and <= 128 && id.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_');
    private static bool Digest(string value) => value.Length == 64 && value.All(Uri.IsHexDigit);
    private static InvalidOperationException InvalidReceipt() => new("The saved lip sync couldn't be verified. No new job was sent.");
    public void Dispose() => lease.Dispose();
}
