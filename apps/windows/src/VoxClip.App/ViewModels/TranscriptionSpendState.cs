using System.Globalization;
using System.Text.Json;
using VoxClip.Core.Domain.Transcript;

namespace VoxClip.App.ViewModels;

internal sealed class TranscriptionSpendState
{
    internal sealed record Entry(Guid Job, DateOnly Day, decimal Estimate, string State, string? RequestId = null);
    private readonly object sync = new();
    private readonly Dictionary<Guid, Entry> entries = [];
    private string? ledgerPath;
    private bool unavailable;
    internal static TranscriptionSpendState Shared { get; } = new();
    internal event EventHandler? Changed;
    internal bool HasPending { get { lock (sync) return entries.Values.Any(entry => entry.State == "pending"); } }
    internal bool HasActivity { get { lock (sync) return entries.Count > 0 || unavailable; } }
    internal int UnconfirmedCount { get { lock (sync) return entries.Values.Count(entry => entry.State == "unconfirmed"); } }

    internal void ConfigurePersistence(string path)
    {
        lock (sync)
        {
            if (ledgerPath is not null) return;
            ledgerPath = path;
            try
            {
                if (!File.Exists(path)) return;
                var saved = JsonSerializer.Deserialize<Entry[]>(File.ReadAllText(path)) ?? throw new InvalidDataException();
                if (saved.Any(entry => entry is null || entry.Job == Guid.Empty || entry.Estimate < 0 || entry.State is not ("pending" or "accepted" or "unconfirmed")) ||
                    saved.Select(entry => entry.Job).Distinct().Count() != saved.Length) throw new InvalidDataException();
                var loaded = saved.ToDictionary(entry => entry.Job, entry => entry.State == "pending" ? entry with { State = "unconfirmed" } : entry);
                entries.Clear();
                foreach (var entry in loaded) entries.Add(entry.Key, entry.Value);
                if (saved.Any(entry => entry.State == "pending")) Save();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
            { unavailable = true; }
        }
    }

    internal void Begin(Guid job, decimal estimate)
    {
        lock (sync)
        {
            if (unavailable) throw new IOException("Transcription accounting is unavailable. Nothing has been sent.");
            if (estimate < 0 || !entries.TryAdd(job, new(job, DateOnly.FromDateTime(DateTime.Now), estimate, "pending"))) throw new ArgumentException("Invalid transcription estimate.");
            Save();
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal void Observe(Guid job, DateOnly day, decimal estimate, TranscriptionEvidence evidence)
    {
        switch (evidence.Kind)
        {
            case TranscriptionEvidenceKind.Cached: Completed(job, day, estimate, true); break;
            case TranscriptionEvidenceKind.Accepted:
            case TranscriptionEvidenceKind.Completed: Accepted(job, evidence.RequestId ?? "", day, estimate); break;
            case TranscriptionEvidenceKind.UploadStarted:
                lock (sync)
                {
                    if (unavailable) throw new IOException("Transcription accounting is unavailable. Nothing has been sent.");
                    if (entries.TryGetValue(job, out var entry) && entry.State == "pending")
                    { entries[job] = entry with { State = "unconfirmed" }; Save(); }
                }
                Changed?.Invoke(this, EventArgs.Empty);
                break;
        }
    }

    internal void Accepted(Guid job, string requestId, DateOnly day, decimal? usd)
    {
        lock (sync)
        {
            if (usd is < 0) return;
            if (entries.TryGetValue(job, out var existing) && existing.State == "accepted")
            {
                if (existing.RequestId is null && !string.IsNullOrWhiteSpace(requestId))
                {
                    if (entries.Values.Any(entry => entry.Job != job && entry.State == "accepted" && entry.RequestId == requestId)) entries.Remove(job);
                    else entries[job] = existing with { RequestId = requestId };
                    Save();
                }
                return;
            }
            if (!string.IsNullOrWhiteSpace(requestId) && entries.Values.Any(entry => entry.RequestId == requestId && entry.State == "accepted"))
                entries.Remove(job);
            else entries[job] = new(job, day, usd ?? existing?.Estimate ?? 0, usd is null ? "unconfirmed" : "accepted", string.IsNullOrWhiteSpace(requestId) ? null : requestId);
            Save();
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal void Completed(Guid job, DateOnly day, decimal estimate, bool fromCache)
    {
        if (estimate < 0) throw new ArgumentOutOfRangeException(nameof(estimate));
        if (!fromCache) { Accepted(job, "", day, estimate); return; }
        lock (sync)
        {
            if (entries.TryGetValue(job, out var entry) && entry.State != "accepted") { entries.Remove(job); Save(); }
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal void End(Guid job, bool uploadMayHaveStarted)
    {
        lock (sync)
        {
            if (entries.TryGetValue(job, out var entry) && entry.State != "accepted")
            {
                if (uploadMayHaveStarted || entry.State == "unconfirmed") entries[job] = entry with { State = "unconfirmed" };
                else entries.Remove(job);
                Save();
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void Save()
    {
        if (ledgerPath is null) return;
        var temporary = ledgerPath + ".pending";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(ledgerPath)!);
            using (var file = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(file, entries.Values.ToArray());
                file.Flush(true);
            }
            File.Move(temporary, ledgerPath, true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { unavailable = true; throw new IOException("Transcription accounting could not be saved. Your media and edits are safe.", error); }
    }

    internal string Copy(DateOnly day)
    {
        lock (sync)
        {
            if (unavailable) return "Transcription accounting unavailable · billing may be unconfirmed";
            var today = entries.Values.Where(entry => entry.Day == day).ToArray();
            var recorded = today.Where(entry => entry.State == "accepted").Sum(entry => entry.Estimate).ToString("0.00", CultureInfo.InvariantCulture);
            var result = "ElevenLabs $" + recorded + (ledgerPath is null ? " estimated this session today" : " estimated today (local ledger)");
            var pending = entries.Values.Where(entry => entry.State == "pending").ToArray();
            var uncertain = entries.Values.Where(entry => entry.State == "unconfirmed").ToArray();
            if (pending.Length > 0) result += " · ≈ $" + pending.Sum(entry => entry.Estimate).ToString("0.00", CultureInfo.InvariantCulture) + " pending";
            if (uncertain.Length > 0) result += " · up to $" + uncertain.Sum(entry => entry.Estimate).ToString("0.00", CultureInfo.InvariantCulture) + " billing unconfirmed";
            return result;
        }
    }
}
