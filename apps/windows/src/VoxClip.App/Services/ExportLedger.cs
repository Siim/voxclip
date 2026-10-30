using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Services;

internal sealed class ExportLedger(string file)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    private bool loaded;
    private IReadOnlyList<ExportRecord> records = [];
    internal IReadOnlyList<ExportRecord> Records => records;
    internal event EventHandler? Changed;
    internal async Task LoadAsync(CancellationToken ct)
    {
        await gate.WaitAsync(ct);
        try
        {
            if (loaded) return;
            records = File.Exists(file) ? JsonSerializer.Deserialize<ExportRecord[]>(await File.ReadAllTextAsync(file, ct), Json) ?? [] : [];
            loaded = true;
        }
        finally { gate.Release(); }
    }
    internal async Task RecordAsync(Project project, ExportTarget target, string output, CancellationToken ct,
        VoxClip.Core.Domain.VoiceLab.VoiceLabLabelPosition? labelPosition = null)
    {
        await LoadAsync(ct);
        await gate.WaitAsync(ct);
        var temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var entry = new ExportRecord(project.Id, ExportFingerprint.TargetId(target), DateTimeOffset.UtcNow, ExportFingerprint.For(project, target, labelPosition),
                project.Captions.StyleId, project.Export.Aspect, output);
            var next = records.Where(record => record.ProjectId != entry.ProjectId || record.TargetId != entry.TargetId).Append(entry)
                .OrderBy(record => record.ProjectId, StringComparer.Ordinal).ThenBy(record => record.TargetId, StringComparer.Ordinal).ToArray();
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous))
            {
                await JsonSerializer.SerializeAsync(stream, next, Json, ct);
                await stream.FlushAsync(ct); stream.Flush(true);
            }
            ct.ThrowIfCancellationRequested();
            if (File.Exists(file)) File.Replace(temporary, file, null); else File.Move(temporary, file);
            records = next;
            Changed?.Invoke(this, EventArgs.Empty);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); gate.Release(); }
    }
}
