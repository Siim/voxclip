using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
#pragma warning disable CS1591

namespace VoxClip.Core.Services.VoiceLab;

[JsonConverter(typeof(JsonStringEnumConverter<VoiceOperationKind>))]
public enum VoiceOperationKind { Create, Delete }
[JsonConverter(typeof(JsonStringEnumConverter<VoiceOperationState>))]
public enum VoiceOperationState { Intent, Dispatched, Created, Saved, Withdrawing, Withdrawn, RemoteDeleted, AudioRemoved, Tombstoned, Abandoned }

public sealed record VoiceConsentAudit(string RecordId, string StatementSha256, string[] RecordingSha256s,
    DateTimeOffset CreatedAt, DateTimeOffset AcceptedAt, string Language, string? RemoteVoiceId, DateTimeOffset? DeletedAt,
    VoiceConsentCreator? Creator = null, bool RemoteStateUnknown = false)
{
    internal static VoiceConsentAudit From(VoiceConsentRecord record)
    {
        record.Validate();
        return new(record.RecordId, record.Statement.AudioSha256, record.Samples.Select(sample => sample.Sha256).ToArray(),
            record.CreatedAt, record.Attestations.AcceptedAt, record.Statement.Language, record.VoiceId == "pending" ? null : record.VoiceId, record.DeletedAt, record.CreatorIdentity);
    }
    internal void Validate(string recordId)
    {
        Creator?.Validate();
        if (RecordId != recordId || !VoiceConsentRecord.HashValid(StatementSha256) || RecordingSha256s.Length is < 1 or > 24 ||
            RecordingSha256s.Any(hash => !VoiceConsentRecord.HashValid(hash)) || Language is not ("en" or "et") ||
            RemoteVoiceId is { } remote && !VoiceConsentRecord.SafeId(remote)) throw VoiceConsentStore.Invalid();
    }
}

public sealed record VoiceOperation(Guid Id, VoiceOperationKind Kind, string RecordId, string ProviderNonce, ElevenLabsRegion Region,
    DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, VoiceOperationState State, string? RemoteVoiceId, bool WasDispatched,
    bool? RequiresVerification, int Attempts, DateTimeOffset? NextAttemptAt, bool Failed, VoiceConsentAudit? Audit, Guid[]? AmbiguousDispatchIds,
    string? RemoteNameSha256 = null, bool RecoveryNeedsReview = false, string? CreatorKeyFingerprint = null, bool RemoteStateUnknown = false)
{
    [JsonIgnore] public bool Finished => State is VoiceOperationState.Saved or VoiceOperationState.Withdrawn or VoiceOperationState.Tombstoned or VoiceOperationState.Abandoned;
    public bool BlocksCreation(DateTimeOffset now) => Kind == VoiceOperationKind.Create && WasDispatched && !Finished &&
        now - StartedAt < TimeSpan.FromHours(24);
    [JsonIgnore] public string DisplayState => Kind == VoiceOperationKind.Create && WasDispatched && RemoteVoiceId is null && !Finished
        ? "Checking your ElevenLabs account for an unfinished voice…" : Failed ? "Couldn't finish — Retry"
        : Kind == VoiceOperationKind.Delete || State == VoiceOperationState.Withdrawing ? "Removing…" : "Finishing…";
}

internal sealed class VoiceRootState
{
    internal readonly object Sync = new();
    internal readonly HashSet<Guid> Claimed = [];
    internal readonly HashSet<string> Live = new(StringComparer.OrdinalIgnoreCase);
    internal readonly HashSet<string> Revoked = new(StringComparer.OrdinalIgnoreCase);
    internal readonly Dictionary<string, HashSet<Guid>> Active = new(StringComparer.OrdinalIgnoreCase);
    internal readonly SemaphoreSlim Reconciler = new(1, 1);
    internal bool TemporaryReconciled;
}

internal sealed class VoiceDispatchPermit(VoiceConsentStore store, string recordId, Guid requestId, Action validate, VoiceLabDispatchBinding? binding = null)
{
    private bool consumed;
    internal Guid RequestId => requestId;
    internal Task<T> Start<T>(Func<Task<T>> transport, CancellationToken ct)
        => binding is null ? StartCurrent(transport, ct) : binding.Start(() => StartCurrent(transport, ct));
    private Task<T> StartCurrent<T>(Func<Task<T>> transport, CancellationToken ct)
    {
        lock (store.State.Sync)
        {
            ct.ThrowIfCancellationRequested();
            if (store.State.Revoked.Contains(recordId)) throw new VoiceConsentException(VoiceConsentError.Inactive);
            if (consumed) throw VoiceConsentStore.Invalid();
            consumed = true;
            validate();
            if (!store.State.Active.TryGetValue(recordId, out var active)) store.State.Active[recordId] = active = [];
            if (!active.Add(requestId)) throw VoiceConsentStore.Invalid();
            try { return transport(); }
            catch { active.Remove(requestId); throw; }
        }
    }
    internal void Finish()
    {
        lock (store.State.Sync) if (store.State.Active.TryGetValue(recordId, out var active)) active.Remove(requestId);
    }
}

public sealed class VoiceConsentStore
{
    private static readonly ConcurrentDictionary<string, VoiceRootState> Roots = new(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
    internal VoiceRootState State { get; }
    private readonly Action<string>? fault;
    private readonly TimeProvider clock;
    private readonly string temporaryRecordings;
    public string Root { get; }
    public string OperationsRoot { get; }
    public VoiceConsentStore(DataLocations locations, TimeProvider? clock = null) : this(locations, null, clock) { }
    internal VoiceConsentStore(DataLocations locations, Action<string>? fault, TimeProvider? clock = null)
    {
        Root = Path.GetFullPath(Path.Combine(locations.Root, "VoiceLab", "consent"));
        OperationsRoot = Path.Combine(locations.Root, "VoiceLab", "voice-ops");
        temporaryRecordings = Path.Combine(locations.Cache, "voice-consent");
        State = Roots.GetOrAdd(Root, _ => new());
        this.fault = fault;
        this.clock = clock ?? TimeProvider.System;
        CheckDirectory(Root, false);
        CheckDirectory(OperationsRoot, false);
    }
    internal static VoiceConsentException Invalid() => new(VoiceConsentError.InvalidRecord);
    private string DirectoryFor(string id, bool create = false)
    {
        if (!Guid.TryParseExact(id, "D", out _)) throw Invalid();
        var path = Path.Combine(Root, id);
        CheckDirectory(Path.GetDirectoryName(Root)!, create);
        CheckDirectory(Root, create);
        CheckDirectory(path, create);
        return path;
    }
    private static void CheckDirectory(string path, bool create)
    {
        if (File.Exists(path) || Directory.Exists(path) || new DirectoryInfo(path).LinkTarget is not null)
        {
            var attributes = File.GetAttributes(path);
            if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != FileAttributes.Directory) throw Invalid();
            VoiceConsentPrivacy.Validate(path, true);
        }
        else if (create)
        {
            VoiceConsentPrivacy.CreateDirectory(path);
            SyncDirectory(Path.GetDirectoryName(path)!);
        }
    }
    private static string FileIn(string directory, string name)
    {
        var path = Path.Combine(directory, name);
        var info = new FileInfo(path);
        if (info.LinkTarget is not null || info.Exists && (info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw Invalid();
        if (info.Exists) VoiceConsentPrivacy.Validate(path, false);
        return path;
    }
    public void SaveStatement(byte[] wav, string recordId)
    {
        var snapshot = wav.ToArray();
        var format = VoiceConsentAudio.ValidateWav(snapshot);
        if (format.Frames < 5 * format.Rate || format.Frames > 30 * format.Rate) throw Invalid();
        lock (State.Sync)
        {
            if (HasOperation(recordId) || File.Exists(Path.Combine(DirectoryFor(recordId), "record.json")) || State.Revoked.Contains(recordId)) throw Invalid();
            Write(snapshot, FileIn(DirectoryFor(recordId, true), "statement.wav"), "saveStatement");
            State.Live.Add(recordId);
        }
    }
    public byte[] Statement(string recordId)
    {
        lock (State.Sync) return Read(FileIn(DirectoryFor(recordId), "statement.wav"), 16 * 1024 * 1024);
    }
    public void Save(VoiceConsentRecord record)
    {
        lock (State.Sync)
        {
            record.Validate();
            record = record.CanonicalCreator();
            if (record.Status != VoiceConsentStatus.Deleted && Hash(Statement(record.RecordId)) != record.Statement.AudioSha256) throw Invalid();
            Write(JsonSerializer.SerializeToUtf8Bytes(record, VoiceConsentJson.Default.VoiceConsentRecord), FileIn(DirectoryFor(record.RecordId, true), "record.json"), "saveRecord");
        }
    }
    public VoiceConsentRecord Load(string id)
    {
        lock (State.Sync)
        {
            var record = JsonSerializer.Deserialize(Read(FileIn(DirectoryFor(id), "record.json"), 256 * 1024), VoiceConsentJson.Default.VoiceConsentRecord) ?? throw Invalid();
            record.Validate();
            if (record.RecordId != id || record.Status != VoiceConsentStatus.Deleted && !HasOperation(id) && Hash(Statement(id)) != record.Statement.AudioSha256) throw Invalid();
            return record;
        }
    }
    public IReadOnlyList<VoiceConsentRecord> Records()
    {
        lock (State.Sync)
        {
            CheckDirectory(Root, false);
            return !Directory.Exists(Root) ? [] : Directory.EnumerateDirectories(Root).Where(path => Guid.TryParseExact(Path.GetFileName(path), "D", out _) &&
                File.Exists(Path.Combine(path, "record.json"))).Select(path => Load(Path.GetFileName(path))).OrderByDescending(record => record.CreatedAt).ToArray();
        }
    }
    public IReadOnlyList<VoiceConsentRecord> ActiveVoices()
    {
        lock (State.Sync) return Records().Where(record => record.Status == VoiceConsentStatus.Active && !HasOperation(record.RecordId) && !State.Revoked.Contains(record.RecordId)).ToArray();
    }
    public void RefreshVerification(IReadOnlyList<VoiceLabVoice> voices)
    {
        lock (State.Sync)
            foreach (var record in Records().Where(record => record.Status == VoiceConsentStatus.VerificationRequired && !HasOperation(record.RecordId)))
                if (voices.Any(voice => voice.Id == record.VoiceId && voice.IsOwner && voice.Category == "cloned" && voice.IsVerified))
                    Save(record with { Status = VoiceConsentStatus.Active });
    }
    public void ValidateUse(VoiceConsentRecord expected)
    {
        lock (State.Sync)
        {
            var current = Load(expected.RecordId);
            if (current.Status != VoiceConsentStatus.Active || current.VoiceId == "pending" || HasOperation(current.RecordId) || State.Revoked.Contains(current.RecordId) ||
                !JsonSerializer.SerializeToUtf8Bytes(expected, VoiceConsentJson.Default.VoiceConsentRecord).AsSpan().SequenceEqual(
                    JsonSerializer.SerializeToUtf8Bytes(current, VoiceConsentJson.Default.VoiceConsentRecord))) throw new VoiceConsentException(VoiceConsentError.Inactive);
        }
    }
    internal VoiceDispatchPermit UsePermit(VoiceConsentRecord record, Guid requestId) => new(this, record.RecordId, requestId, () => ValidateUse(record));
    internal OwnVoicePolicy CreateUsePolicy(VoiceConsentRecord record, Guid requestId, Func<CancellationToken, Task> validateDispatch, VoiceLabDispatchBinding? binding = null)
    {
        ArgumentNullException.ThrowIfNull(validateDispatch);
        if (!VoiceSpeakerCheck.WindowsNativeParityVerified) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
        ValidateUse(record);
        return new(record.RecordId, record.VoiceId, true, true, true, true, true)
        {
            DispatchPermit = new(this, record.RecordId, requestId, () =>
            {
                if (!VoiceSpeakerCheck.WindowsNativeParityVerified) throw new VoiceConsentException(VoiceConsentError.SpeakerUnavailable);
                ValidateUse(record);
            }, binding),
            ValidateDispatch = validateDispatch
        };
    }
    public VoiceCreationClaim ClaimCreation(VoiceConsentRecord record, Guid requestId, ElevenLabsRegion region, DateTimeOffset now) =>
        new(this, BeginClaimedCreation(record, requestId, region, now), record.Statement.AudioSha256);
    public OwnVoicePolicy CreateDeletionPolicy(string recordId)
    {
        lock (State.Sync)
        {
            var record = Load(recordId);
            if (record.Status == VoiceConsentStatus.Deleted || record.VoiceId == "pending") throw Invalid();
            return new(recordId, record.VoiceId, true, true, true, true, true)
                { Creator = record.CreatorIdentity };
        }
    }
    internal VoiceDispatchPermit CreationPermit(string recordId, Guid requestId, string statementHash) => new(this, recordId, requestId, () =>
    {
        var operation = Operation(requestId);
        if (operation.Kind != VoiceOperationKind.Create || operation.State != VoiceOperationState.Intent || operation.RecordId != recordId ||
            Operations().Any(other => other.Id != requestId && other.BlocksCreation(clock.GetUtcNow())) || Hash(Statement(recordId)) != statementHash) throw Invalid();
        Transition(requestId, VoiceOperationState.Dispatched, clock.GetUtcNow());
    });
    private string OperationFile(Guid id, bool create = false)
    {
        CheckDirectory(Path.GetDirectoryName(OperationsRoot)!, create);
        CheckDirectory(OperationsRoot, create);
        return FileIn(OperationsRoot, id.ToString("D") + ".json");
    }
    public IReadOnlyList<VoiceOperation> Operations()
    {
        lock (State.Sync)
        {
            MigrateLegacyOperations();
            CheckDirectory(OperationsRoot, false);
            if (!Directory.Exists(OperationsRoot)) return [];
            return Directory.EnumerateFiles(OperationsRoot, "*.json").Select(path => Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "D", out var id)
                ? Operation(id) : throw Invalid()).OrderBy(operation => operation.StartedAt).ToArray();
        }
    }
    private void MigrateLegacyOperations()
    {
        CheckDirectory(Path.GetDirectoryName(Root)!, false);
        CheckDirectory(Root, false);
        if (!Directory.Exists(Root)) return;
        foreach (var path in Directory.EnumerateDirectories(Root).Where(path => Guid.TryParseExact(Path.GetFileName(path), "D", out _)))
        {
            var recordId = Path.GetFileName(path);
            DirectoryFor(recordId);
            var creationPath = FileIn(path, "creation.json");
            var deletionPath = FileIn(path, "deletion.json");
            using var creation = File.Exists(creationPath) ? JsonDocument.Parse(Read(creationPath, 512 * 1024)) : null;
            using var deletion = File.Exists(deletionPath) ? JsonDocument.Parse(Read(deletionPath, 512 * 1024)) : null;
            if (creation is null && deletion is null) continue;
            var source = deletion?.RootElement ?? creation!.RootElement;
            var record = source.GetProperty("record").Deserialize(VoiceConsentJson.Default.VoiceConsentRecord) ?? throw Invalid();
            record.Validate();
            if (record.RecordId != recordId) throw Invalid();
            CheckDirectory(OperationsRoot, false);
            var existing = Directory.Exists(OperationsRoot) && Directory.EnumerateFiles(OperationsRoot, "*.json")
                .Any(file => Guid.TryParseExact(Path.GetFileNameWithoutExtension(file), "D", out var id) && Operation(id).RecordId == recordId);
            if (!existing)
            {
                var region = source.GetProperty("region").Deserialize(VoiceConsentJson.Default.ElevenLabsRegion);
                var date = source.GetProperty(deletion is null ? "startedAt" : "requestedAt");
                var started = date.ValueKind == JsonValueKind.String ? date.GetDateTimeOffset() :
                    new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero).AddSeconds(date.GetDouble());
                var id = creation?.RootElement.GetProperty("requestID").GetGuid() ?? Guid.NewGuid();
                var value = NewOperation(id, creation is null ? VoiceOperationKind.Delete : VoiceOperationKind.Create, recordId, region, started) with
                {
                    RemoteVoiceId = record.VoiceId == "pending" ? null : record.VoiceId, Audit = VoiceConsentAudit.From(record),
                    RemoteNameSha256 = Hash(System.Text.Encoding.UTF8.GetBytes(record.VoiceName)), WasDispatched = creation is not null,
                    RequiresVerification = record.Status == VoiceConsentStatus.VerificationRequired,
                    State = creation is not null ? deletion is not null || creation.RootElement.TryGetProperty("cancelled", out var cancelled) && cancelled.GetBoolean()
                        ? VoiceOperationState.Withdrawing : record.VoiceId == "pending" ? VoiceOperationState.Dispatched : VoiceOperationState.Created
                        : source.GetProperty("remoteDeleted").GetBoolean() ? VoiceOperationState.RemoteDeleted : VoiceOperationState.Intent
                };
                if (File.Exists(OperationFile(id))) throw Invalid();
                var recordPath = FileIn(path, "record.json");
                if (!File.Exists(recordPath)) Write(JsonSerializer.SerializeToUtf8Bytes(record, VoiceConsentJson.Default.VoiceConsentRecord), recordPath, "legacyRecord");
                WriteOperation(value, "legacyOperation");
            }
            DeleteFile(creationPath, "legacyCreationRemoved");
            DeleteFile(deletionPath, "legacyDeletionRemoved");
        }
    }
    internal VoiceOperation Operation(Guid id)
    {
        lock (State.Sync)
        {
            var value = JsonSerializer.Deserialize(Read(OperationFile(id), 16 * 1024), VoiceConsentJson.Default.VoiceOperation) ?? throw Invalid();
            if (value.Id != id || id == Guid.Empty || !Guid.TryParseExact(value.RecordId, "D", out _) || value.ProviderNonce != value.RecordId || value.Attempts < 0 ||
                value.UpdatedAt < value.StartedAt || !Enum.IsDefined(value.Region) || !Enum.IsDefined(value.Kind) || !Enum.IsDefined(value.State) ||
                value.RemoteVoiceId is { } remote && !VoiceConsentRecord.SafeId(remote) || value.Audit is { } audit && audit.RemoteVoiceId != value.RemoteVoiceId ||
                value.RemoteNameSha256 is { } nameHash && !VoiceConsentRecord.HashValid(nameHash)) throw Invalid();
            value.Audit?.Validate(value.RecordId);
            var allowed = value.Kind == VoiceOperationKind.Create
                ? value.State is VoiceOperationState.Intent or VoiceOperationState.Dispatched or VoiceOperationState.Created or VoiceOperationState.Saved or VoiceOperationState.Withdrawing or VoiceOperationState.Withdrawn or VoiceOperationState.Abandoned
                : value.State is VoiceOperationState.Intent or VoiceOperationState.RemoteDeleted or VoiceOperationState.AudioRemoved or VoiceOperationState.Tombstoned;
            if (!allowed || value.State is VoiceOperationState.Created or VoiceOperationState.Saved or VoiceOperationState.RemoteDeleted or VoiceOperationState.AudioRemoved or VoiceOperationState.Tombstoned && value.RemoteVoiceId is null) throw Invalid();
            return value;
        }
    }
    private VoiceOperation WriteOperation(VoiceOperation value, string checkpoint)
    {
        if (value.Kind == VoiceOperationKind.Delete || value.State is VoiceOperationState.Withdrawing or VoiceOperationState.Withdrawn)
        {
            State.Revoked.Add(value.RecordId);
            value = value with { AmbiguousDispatchIds = (value.AmbiguousDispatchIds ?? []).Concat(State.Active.GetValueOrDefault(value.RecordId) ?? [])
                .Distinct().Order().ToArray() };
        }
        Write(JsonSerializer.SerializeToUtf8Bytes(value, VoiceConsentJson.Default.VoiceOperation), OperationFile(value.Id, true), checkpoint);
        return value;
    }
    internal VoiceOperation BeginClaimedCreation(VoiceConsentRecord record, Guid requestId, ElevenLabsRegion region, DateTimeOffset now)
    {
        lock (State.Sync)
        {
            if ((record.Creator is not null || record.Region.HasValue) && record.CreatorIdentity.Region != region) throw new VoiceCreatorMismatchException();
            if (record.Creator is null && record.Region is null && region != ElevenLabsRegion.Default) record = record with { Region = region };
            if (requestId == Guid.Empty || State.Claimed.Contains(requestId) || State.Revoked.Contains(record.RecordId) ||
                Operations().Any(value => value.Id == requestId || value.BlocksCreation(now) || !value.Finished && value.RecordId == record.RecordId))
                throw new VoiceConsentException(VoiceConsentError.CreationPending);
            Save(record);
            var value = WriteOperation(NewOperation(requestId, VoiceOperationKind.Create, record.RecordId, region, now) with
                { Audit = VoiceConsentAudit.From(record), RemoteNameSha256 = Hash(System.Text.Encoding.UTF8.GetBytes(record.VoiceName)),
                    CreatorKeyFingerprint = record.Creator?.KeyFingerprint }, "creationIntent");
            State.Claimed.Add(value.Id);
            return value;
        }
    }
    private static VoiceOperation NewOperation(Guid id, VoiceOperationKind kind, string recordId, ElevenLabsRegion region, DateTimeOffset now) =>
        new(id, kind, recordId, recordId, region, now, now, VoiceOperationState.Intent, null, false, null, 0, null, false, null, null);
    internal VoiceOperation Transition(Guid id, VoiceOperationState target, DateTimeOffset now, string? remoteId = null, bool? verification = null)
    {
        lock (State.Sync)
        {
            var value = Operation(id);
            var permitted = (value.Kind, value.State, target) switch
            {
                (VoiceOperationKind.Create, VoiceOperationState.Intent, VoiceOperationState.Dispatched) => true,
                (VoiceOperationKind.Create, VoiceOperationState.Dispatched, VoiceOperationState.Created) => true,
                (VoiceOperationKind.Create, VoiceOperationState.Created, VoiceOperationState.Saved) => true,
                (VoiceOperationKind.Create, VoiceOperationState.Withdrawing, VoiceOperationState.Withdrawn) => true,
                (VoiceOperationKind.Create, VoiceOperationState.Dispatched or VoiceOperationState.Withdrawing, VoiceOperationState.Abandoned) => true,
                (VoiceOperationKind.Delete, VoiceOperationState.Intent, VoiceOperationState.RemoteDeleted) => true,
                (VoiceOperationKind.Delete, VoiceOperationState.RemoteDeleted, VoiceOperationState.AudioRemoved) => true,
                (VoiceOperationKind.Delete, VoiceOperationState.AudioRemoved, VoiceOperationState.Tombstoned) => true,
                _ => value.Kind == VoiceOperationKind.Create && value.State is not (VoiceOperationState.Withdrawn or VoiceOperationState.Abandoned) && target == VoiceOperationState.Withdrawing
            };
            if (!permitted || remoteId is not null && !VoiceConsentRecord.SafeId(remoteId)) throw Invalid();
            value = value with { State = target, UpdatedAt = now > value.UpdatedAt ? now : value.UpdatedAt, Failed = false, NextAttemptAt = null,
                WasDispatched = value.WasDispatched || target == VoiceOperationState.Dispatched, RemoteVoiceId = remoteId ?? value.RemoteVoiceId,
                RequiresVerification = verification ?? value.RequiresVerification };
            if (value.Audit is { } audit) value = value with { Audit = audit with { RemoteVoiceId = value.RemoteVoiceId } };
            return WriteOperation(value, target.ToString());
        }
    }
    internal void ScheduleRetry(Guid id, DateTimeOffset now)
    {
        lock (State.Sync)
        {
            var value = Operation(id);
            var next = now.AddSeconds(Math.Min(3600, 30 * Math.Pow(2, Math.Min(value.Attempts, 7))));
            var deadline = value.StartedAt.AddHours(24);
            if (value.Kind == VoiceOperationKind.Create && value.State is VoiceOperationState.Dispatched or VoiceOperationState.Withdrawing &&
                value.RemoteVoiceId is null && now < deadline && next > deadline) next = deadline;
            WriteOperation(value with { Attempts = checked(value.Attempts + 1), Failed = true, UpdatedAt = now > value.UpdatedAt ? now : value.UpdatedAt, NextAttemptAt = next }, "retryScheduled");
        }
    }
    internal bool Claim(Guid id) { lock (State.Sync) return State.Claimed.Add(id); }
    internal void RequireRecoveryReview(Guid id)
    {
        lock (State.Sync) WriteOperation(Operation(id) with { RecoveryNeedsReview = true }, "recoveryReview");
    }
    internal void Release(Guid id) { lock (State.Sync) State.Claimed.Remove(id); }
    internal void RollbackUndispatched(Guid id)
    {
        lock (State.Sync)
        {
            var operation = Operation(id);
            if (!State.Claimed.Contains(id) || operation.Kind != VoiceOperationKind.Create ||
                operation.State != VoiceOperationState.Intent || operation.WasDispatched || State.Revoked.Contains(operation.RecordId)) throw Invalid();
            DiscardUnresolvedDraft(operation);
            DeleteFile(OperationFile(id), "rollbackUndispatched");
            State.Live.Add(operation.RecordId);
        }
    }
    internal bool HasOperation(string id) => Operations().Any(value => value.RecordId == id && !value.Finished);
    public VoiceOperation BeginDeletion(string recordId, ElevenLabsRegion region, DateTimeOffset now)
    {
        lock (State.Sync)
        {
            var existing = Operations().FirstOrDefault(value => value.RecordId == recordId && !value.Finished);
            if (existing is not null) return existing.Kind == VoiceOperationKind.Create ? Transition(existing.Id, VoiceOperationState.Withdrawing, now) : existing;
            var record = Load(recordId);
            if (record.CreatorIdentity.Region != region) throw new VoiceCreatorMismatchException();
            if (record.Status == VoiceConsentStatus.Deleted || record.VoiceId == "pending") throw Invalid();
            return WriteOperation(NewOperation(Guid.NewGuid(), VoiceOperationKind.Delete, recordId, region, now) with
                { RemoteVoiceId = record.VoiceId, Audit = VoiceConsentAudit.From(record), CreatorKeyFingerprint = record.Creator?.KeyFingerprint }, "deletionIntent");
        }
    }
    public VoiceOperation BeginLocalRemoval(string recordId, bool approved, DateTimeOffset now)
    {
        if (!approved) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        lock (State.Sync)
        {
            var record = Load(recordId);
            var operation = BeginDeletion(recordId, record.CreatorIdentity.Region, now);
            if (operation.Kind != VoiceOperationKind.Delete) throw Invalid();
            return WriteOperation(operation with { RemoteStateUnknown = true }, "localRemovalIntent");
        }
    }
    public void WithdrawCreation(string recordId, DateTimeOffset now)
    {
        lock (State.Sync)
        {
            var value = Operations().FirstOrDefault(value => value.RecordId == recordId && value.Kind == VoiceOperationKind.Create && !value.Finished);
            if (value is null && File.Exists(FileIn(DirectoryFor(recordId), "record.json")))
            {
                var record = Load(recordId);
                if (record.VoiceId != "pending") return;
            }
            if (value is not null)
            {
                PreserveAudit(value.Id);
                Transition(value.Id, VoiceOperationState.Withdrawing, now);
            }
            DiscardStatement(recordId);
            State.Live.Remove(recordId);
        }
    }
    internal void DiscardStatement(string recordId)
    {
        lock (State.Sync) DeleteFile(FileIn(DirectoryFor(recordId), "statement.wav"), "removeStatement");
    }
    internal void DiscardUnresolvedDraft(VoiceOperation value)
    {
        lock (State.Sync)
        {
            if (value.RemoteVoiceId is not null) return;
            var path = FileIn(DirectoryFor(value.RecordId), "record.json");
            if (!File.Exists(path)) return;
            var draft = JsonSerializer.Deserialize(Read(path, 256 * 1024), VoiceConsentJson.Default.VoiceConsentRecord) ?? throw Invalid();
            if (draft.RecordId != value.RecordId || draft.VoiceId != "pending") throw Invalid();
            DeleteFile(path, "removeDraft");
        }
    }
    internal VoiceOperation PreserveAudit(Guid id)
    {
        lock (State.Sync)
        {
            var value = Operation(id);
            if (value.Audit is not null && value.RemoteNameSha256 is not null) return value;
            var path = FileIn(DirectoryFor(value.RecordId), "record.json");
            if (!File.Exists(path)) return value;
            var record = JsonSerializer.Deserialize(Read(path, 256 * 1024), VoiceConsentJson.Default.VoiceConsentRecord) ?? throw Invalid();
            record.Validate();
            if (record.RecordId != value.RecordId) throw Invalid();
            return WriteOperation(value with
            {
                Audit = value.Audit ?? VoiceConsentAudit.From(record) with { RemoteVoiceId = value.RemoteVoiceId },
                RemoteNameSha256 = value.RemoteNameSha256 ?? Hash(System.Text.Encoding.UTF8.GetBytes(record.VoiceName))
            }, "saveAudit");
        }
    }
    internal void SaveCreated(VoiceOperation value)
    {
        lock (State.Sync)
        {
            if (Operation(value.Id).State != VoiceOperationState.Created || value.RemoteVoiceId is null) throw Invalid();
            Save(Load(value.RecordId).AssignVoice(value.RemoteVoiceId, value.RequiresVerification ?? true));
        }
    }
    internal void Tombstone(VoiceOperation value)
    {
        lock (State.Sync)
        {
            if (value.Audit is { } audit && value.RemoteVoiceId is { } remote)
            {
                audit = audit with { RemoteVoiceId = remote, DeletedAt = value.UpdatedAt, RemoteStateUnknown = value.RemoteStateUnknown };
                Write(JsonSerializer.SerializeToUtf8Bytes(audit, VoiceConsentJson.Default.VoiceConsentAudit), FileIn(DirectoryFor(value.RecordId, true), "audit.json"), "tombstoneRecord");
            }
            if (File.Exists(FileIn(DirectoryFor(value.RecordId), "record.json")))
            {
                var record = Load(value.RecordId);
                Save(record with { VoiceId = value.RemoteVoiceId ?? record.VoiceId, Status = VoiceConsentStatus.Deleted, DeletedAt = value.UpdatedAt });
            }
        }
    }
    public VoiceConsentAudit? AuditTombstone(string recordId)
    {
        lock (State.Sync)
        {
            var path = FileIn(DirectoryFor(recordId), "audit.json");
            if (!File.Exists(path)) return null;
            var audit = JsonSerializer.Deserialize(Read(path, 16 * 1024), VoiceConsentJson.Default.VoiceConsentAudit) ?? throw Invalid();
            audit.Validate(recordId);
            if (audit.DeletedAt is null || audit.RemoteVoiceId is null) throw Invalid();
            return audit;
        }
    }
    internal void RemoveOperation(VoiceOperation value)
    {
        lock (State.Sync)
        {
            if (!Operation(value.Id).Finished) throw Invalid();
            DeleteFile(OperationFile(value.Id), "clearOperation");
        }
    }
    public void ReconcileAbandonedEnrollments()
    {
        lock (State.Sync)
        {
            if (!State.TemporaryReconciled)
            {
                CheckDirectory(temporaryRecordings, false);
                if (Directory.Exists(temporaryRecordings)) Directory.Delete(temporaryRecordings, true);
                State.TemporaryReconciled = true;
            }
            CheckDirectory(Root, false);
            if (!Directory.Exists(Root)) return;
            foreach (var path in Directory.EnumerateDirectories(Root))
            {
                var id = Path.GetFileName(path);
                if (!Guid.TryParseExact(id, "D", out _) || State.Live.Contains(id) || HasOperation(id) || AuditTombstone(id) is not null) continue;
                DirectoryFor(id);
                if (File.Exists(FileIn(path, "record.json")))
                {
                    var record = Load(id);
                    if (record.VoiceId != "pending")
                    {
                        if (record.Status == VoiceConsentStatus.Deleted) DiscardStatement(id);
                        continue;
                    }
                }
                foreach (var name in new[] { "statement.wav", "record.json" }) DeleteFile(FileIn(path, name), "abandonedEnrollment");
                if (!Directory.EnumerateFileSystemEntries(path).Any()) Directory.Delete(path);
            }
        }
    }
    public static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    private static byte[] Read(string path, int maximum)
    {
        if (new FileInfo(path).Length > maximum) throw Invalid();
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > maximum) throw Invalid();
        var bytes = new byte[checked((int)stream.Length)];
        stream.ReadExactly(bytes);
        if (stream.ReadByte() != -1) throw Invalid();
        return bytes;
    }
    private void Write(byte[] bytes, string path, string checkpoint)
    {
        fault?.Invoke(checkpoint);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, Options = FileOptions.WriteThrough };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var stream = new FileStream(temporary, options))
            {
                VoiceConsentPrivacy.ProtectNewFile(temporary);
                VoiceConsentPrivacy.Validate(temporary, false);
                stream.Write(bytes);
                stream.Flush(true);
            }
            fault?.Invoke(checkpoint + ":rename");
            FileIn(Path.GetDirectoryName(path)!, Path.GetFileName(path));
            if (OperatingSystem.IsWindows())
            {
                if (!MoveFileExW(temporary, path, 0x1 | 0x8)) throw new IOException("Cannot durably publish voice consent.");
            }
            else { File.Move(temporary, path, true); SyncDirectory(Path.GetDirectoryName(path)!); }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private void DeleteFile(string path, string checkpoint)
    {
        fault?.Invoke(checkpoint);
        if (!File.Exists(path)) return;
        File.Delete(path);
        SyncDirectory(Path.GetDirectoryName(path)!);
    }
    private static void SyncDirectory(string path)
    {
        if (OperatingSystem.IsWindows()) return;
        var descriptor = Open(path, 0);
        if (descriptor < 0) throw new IOException("Cannot open voice consent directory.");
        try { if (Fsync(descriptor) != 0) throw new IOException("Cannot synchronize voice consent directory."); }
        finally { Close(descriptor); }
    }
    [DllImport("libc", EntryPoint = "open", SetLastError = true)] private static extern int Open(string path, int flags);
    [DllImport("libc", EntryPoint = "fsync", SetLastError = true)] private static extern int Fsync(int descriptor);
    [DllImport("libc", EntryPoint = "close")] private static extern int Close(int descriptor);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool MoveFileExW(string existing, string destination, uint flags);
}

public sealed class VoiceCreationClaim : IDisposable
{
    private readonly VoiceConsentStore store;
    private readonly Guid id;
    private readonly string statementHash;
    private bool disposed;
    internal VoiceCreationClaim(VoiceConsentStore store, VoiceOperation operation, string statementHash)
    { this.store = store; id = operation.Id; this.statementHash = statementHash; }
    public VoiceOperation Operation => store.Operation(id);
    public void RollbackUndispatched()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        store.RollbackUndispatched(id);
        Dispose();
    }
    public OwnVoicePolicy DispatchPolicy(Func<CancellationToken, Task> validateDispatch)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        ArgumentNullException.ThrowIfNull(validateDispatch);
        var operation = Operation;
        return new(operation.RecordId, null, true, true, true, true, true)
        {
            DispatchPermit = store.CreationPermit(operation.RecordId, id, statementHash), ValidateDispatch = validateDispatch,
            Creator = new(operation.Region, operation.CreatorKeyFingerprint)
        };
    }
    public void PreserveAmbiguousDispatch(DateTimeOffset now)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var operation = store.PreserveAudit(id);
        store.DiscardStatement(operation.RecordId);
        store.DiscardUnresolvedDraft(operation);
        store.ScheduleRetry(id, now);
    }
    public void RecordRemoteResult(VoiceLabCloneResult result, DateTimeOffset now)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var operation = Operation;
        if (result.ConsentRecordId != operation.RecordId) throw VoiceConsentStore.Invalid();
        store.Transition(id, operation.State == VoiceOperationState.Withdrawing ? VoiceOperationState.Withdrawing : VoiceOperationState.Created,
            now, result.VoiceId, result.RequiresVerification);
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        store.Release(id);
    }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true)]
[JsonSerializable(typeof(VoiceConsentRecord))]
[JsonSerializable(typeof(VoiceOperation))]
[JsonSerializable(typeof(VoiceConsentAudit))]
[JsonSerializable(typeof(VoiceConsentText))]
[JsonSerializable(typeof(ElevenLabsRegion))]
internal partial class VoiceConsentJson : JsonSerializerContext;
