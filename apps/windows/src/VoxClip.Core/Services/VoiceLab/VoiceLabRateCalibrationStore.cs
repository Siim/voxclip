using System.Text;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>Each voice's speaking-rate calibration across projects (ADR-R43; Mac <c>VoiceLabRateCalibrationStore</c>): one JSON file per
/// consent record in <c>VoiceLab/calibration/</c>, beside the consent records and never inside a project. A missing or unreadable file
/// reads as an empty calibration; the next measured take writes a clean one. Calls are serialised.</summary>
public sealed class VoiceLabRateCalibrationStore
{
    private readonly SemaphoreSlim gate = new(1, 1);

    /// <summary>The calibration folder.</summary>
    public string Root { get; }

    /// <summary>The store under <paramref name="locations"/>' data folder.</summary>
    public VoiceLabRateCalibrationStore(DataLocations locations) : this(Path.Combine(locations.Root, "VoiceLab", "calibration")) { }

    /// <summary>The store at <paramref name="root"/>.</summary>
    public VoiceLabRateCalibrationStore(string root) => Root = Path.GetFullPath(root);

    /// <summary>A consent record ID is a file name here: letters, digits, <c>-</c> and <c>_</c>, 1 to 128 of them.</summary>
    public static bool IsValid(string? recordId) => !string.IsNullOrEmpty(recordId) && recordId.Length <= 128 &&
        recordId.All(character => character is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_');

    /// <summary>The voice's calibration, or an empty one when it has none or its file can't be read.</summary>
    public async Task<VoiceLabVoiceCalibration> LoadAsync(string recordId, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try { return await ReadAsync(recordId, ct).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    /// <summary>Every stored voice's calibration, keyed by consent record ID.</summary>
    public async Task<IReadOnlyDictionary<string, VoiceLabVoiceCalibration>> AllAsync(CancellationToken ct = default)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var result = new Dictionary<string, VoiceLabVoiceCalibration>(StringComparer.Ordinal);
            if (!Directory.Exists(Root)) return result;
            foreach (var file in Directory.EnumerateFiles(Root, "*.json"))
            {
                var id = Path.GetFileNameWithoutExtension(file);
                if (IsValid(id)) result[id] = await ReadAsync(id, ct).ConfigureAwait(false);
            }
            return result;
        }
        finally { gate.Release(); }
    }

    /// <summary>Adds one measured take; returns the voice's calibration as stored.</summary>
    public async Task<VoiceLabVoiceCalibration> RecordAsync(string recordId, string model, string take, double measured, double estimated,
        CancellationToken ct = default)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var current = await ReadAsync(recordId, ct).ConfigureAwait(false);
            var next = current.Recording(model, take, measured, estimated);
            if (!next.Equals(current)) await WriteAsync(next, ct).ConfigureAwait(false);
            return next;
        }
        finally { gate.Release(); }
    }

    /// <summary>Replaces the voice's stored calibration.</summary>
    public async Task SaveAsync(VoiceLabVoiceCalibration calibration, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try { await WriteAsync(calibration, ct).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    private async Task<VoiceLabVoiceCalibration> ReadAsync(string recordId, CancellationToken ct)
    {
        if (!IsValid(recordId)) return new(recordId);
        try { return VoiceLabVoiceCalibration.Decode(await File.ReadAllTextAsync(PathFor(recordId), Encoding.UTF8, ct).ConfigureAwait(false), recordId); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or VoiceLabLengthBudgetException) { return new(recordId); }
    }

    private Task WriteAsync(VoiceLabVoiceCalibration calibration, CancellationToken ct)
    {
        if (!IsValid(calibration.RecordId)) throw new VoiceLabLengthBudgetException(VoiceLabLengthBudgetErrorCode.InvalidInput);
        return AtomicFile.WriteAsync(PathFor(calibration.RecordId), calibration.Encoded(), ct,
            unixCreateMode: UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }

    private string PathFor(string recordId) => Path.Combine(Root, recordId + ".json");
}
