using System.CommandLine;
using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Pipeline;
using VoxClip.Media.Speech;

namespace VoxClip.Cli;

/// <summary><c>voxclip-cli check</c>: the export self-check (ADR-R49), headless, twin of the Mac command. The export is transcribed
/// again on this PC and compared word for word with the clip's edit, its tracks and each revoiced or rewritten phrase measured for
/// sync, its loudness metered against ADR-R47's target, and every caption card and the title checked against the frame's safe-zone
/// bands. Exit 0 when every check is ok or skipped, 8 when any warns.</summary>
internal static class CliCheck
{
    /// <summary>The exit status when any check warns (architecture §9.3).</summary>
    internal const int WarningExitCode = 8;

    /// <summary>The command's result fields: the export, the clip and the <c>check</c> object.</summary>
    internal static async Task<JsonObject> RunAsync(ParseResult arguments, CancellationToken ct, ExportInputReader? openExport)
    {
        var projectPath = Path.GetFullPath(CliOperations.Required(arguments, "--project"));
        var exportPath = Path.GetFullPath(arguments.GetValue<string>("export")!);
        if (!File.Exists(exportPath)) throw new VoxClipException(VoxClipErrorCode.MediaMissing, $"Can't find {Path.GetFileName(exportPath)}.");
        if (!File.Exists(projectPath)) throw new FileNotFoundException();
        var clips = (await ServicesMergeAdapter.Projects().LoadAsync(projectPath, ct).ConfigureAwait(false)).Project.Edits.Clips;
        var wanted = CliOperations.Required(arguments, "--clip");
        var clip = Clip(clips, wanted) ?? throw new CliUsageException("The requested clip does not exist.");
        var aspect = arguments.GetValue<string?>("--aspect") ?? await ExportedAspectAsync(exportPath, ct).ConfigureAwait(false);
        List<string> export = ["--open", projectPath, "--export", exportPath, "--clip", clip.Id, "--aspect", aspect, "--quiet"];
        if (arguments.GetValue<string?>("--style") is { } style) export.AddRange(["--style", style]);
        if (arguments.GetValue<string?>("--loudness") is { } loudness) export.AddRange(["--loudness", loudness]);
        var prepared = await CliOperations.PrepareExportAsync(CliApplication.Parse([.. export]), ct, openExport, checkingOutputs: false).ConfigureAwait(false);
        var hearing = await LocalHearingAsync(prepared.Project.Transcript, ct).ConfigureAwait(false);
        var outcome = await CheckExportAsync(exportPath, prepared, hearing, ct).ConfigureAwait(false);
        return new() { ["output"] = exportPath, ["clipId"] = clip.Id, ["check"] = Json(outcome) };
    }

    /// <summary>The clip <paramref name="wanted"/> names: its number in the project's clip list (1 is the first) or its id.</summary>
    internal static ClipRange? Clip(IReadOnlyList<ClipRange> clips, string wanted) =>
        int.TryParse(wanted, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number >= 1 && number <= clips.Count
            ? clips[number - 1] : clips.FirstOrDefault(item => item.Id == wanted);

    /// <summary>The command's exit status: <see cref="WarningExitCode"/> when its <c>check</c> did not pass, else 0.</summary>
    internal static int ExitCode(JsonObject fields) => fields["check"]?["passed"]?.GetValue<bool>() == false ? WarningExitCode : 0;

    /// <summary>The export's frame as an aspect: 9:16, 16:9 or 1:1 when it is one, else source.</summary>
    internal static async Task<string> ExportedAspectAsync(string path, CancellationToken ct)
    {
        var size = (await CliOperations.ProbeInputAsync(path, ct).ConfigureAwait(false)).OrientedSize;
        return Aspect(size);
    }

    internal static string Aspect(PixelSize size) =>
        size.Width <= 0 || size.Height <= 0 ? "source" : 16L * size.Width == 9L * size.Height ? "9:16" : 9L * size.Width == 16L * size.Height ? "16:9"
        : size.Width == size.Height ? "1:1" : "source";

    /// <summary>The local engine for <paramref name="transcript"/>'s project (<see cref="ExportChecker.LocalHearingAsync"/>): installed,
    /// verified Whisper models only; null without one.</summary>
    internal static async Task<ExportChecker.Hearing?> LocalHearingAsync(Transcript? transcript, CancellationToken ct)
    {
        var installed = await ServicesMergeAdapter.ModelStorage().ListInstalledAsync(ct).ConfigureAwait(false);
        if (!installed.Any(model => model.Verified)) return null;
        var whisper = MergeApi.Construct<WhisperNetTranscriber>([ServicesMergeAdapter.ModelStorage()]);
        return await ExportChecker.LocalHearingAsync(transcript, ServicesMergeAdapter.Models(), installed, whisper, ct).ConfigureAwait(false);
    }

    /// <summary>One export checked against what <see cref="CliOperations.PrepareExportAsync"/> made for it.</summary>
    internal static Task<ExportChecker.Outcome> CheckExportAsync(string export, PreparedExport prepared, ExportChecker.Hearing? hearing, CancellationToken ct)
    {
        var edit = ExportCheckExpectation.Make(prepared.Snapshot, prepared.State);
        var scratch = Path.Combine(DataLocations.Resolve().Root, "Scratch", "export-check");
        return new ExportChecker(hearing, scratch, SharedResources.ResolveRoot()).CheckAsync(export, prepared.Snapshot, edit, prepared.Loudness, ct);
    }

    /// <summary>The <c>check</c> object, the Mac's shape: <c>passed</c>, the wall time, the engine that heard the export, and each
    /// check's result keyed by its name (status, reason, items and its own numbers).</summary>
    internal static JsonObject Json(ExportChecker.Outcome outcome)
    {
        static JsonNode Rounded(double value) => JsonValue.Create(Math.Round(value * 1000, MidpointRounding.AwayFromZero) / 1000)!;
        var fields = new JsonObject
        {
            ["passed"] = outcome.Report.Passed, ["seconds"] = Rounded(outcome.TotalSeconds), ["hearSeconds"] = Rounded(outcome.HearSeconds),
            ["engine"] = outcome.Engine switch { null => null, TranscriptEngine.Whispercpp => "whispercpp", var other => other.Value.ToString().ToLowerInvariant() },
            ["model"] = outcome.Model,
        };
        foreach (var result in outcome.Report.Results)
        {
            var encoded = result.ToJson();
            encoded.Remove("check");
            fields[ExportCheck.Name(result.Check)] = encoded;
        }
        return fields;
    }

    /// <summary>The human-readable report from the <c>check</c> object: one line per check, then one per finding, then "passed" or
    /// "warnings".</summary>
    internal static string Summary(JsonObject check)
    {
        static string Time(double seconds) => ((int)seconds / 60).ToString(CultureInfo.InvariantCulture) + ":" +
            (seconds % 60).ToString("00.00", CultureInfo.InvariantCulture);
        static string Fixed(double value, string format) => value.ToString(format, CultureInfo.InvariantCulture);
        var lines = new List<string>();
        foreach (var kind in Enum.GetValues<ExportCheckKind>())
        {
            if (check[ExportCheck.Name(kind)] is not JsonObject result) continue;
            var line = ExportCheck.Name(kind) + ": " + result["status"]!.GetValue<string>();
            if (result["matched"] is { } matched && result["total"] is { } total) line += $", {matched.GetValue<int>()}/{total.GetValue<int>()} words as edited";
            if (result["integratedLufs"] is { } lufs) line += ", " + Fixed(lufs.GetValue<double>(), "0.0") + " LUFS";
            if (result["truePeakDbtp"] is { } peak) line += ", " + Fixed(peak.GetValue<double>(), "0.0") + " dBTP";
            if (result["reason"] is { } reason) line += " (" + reason.GetValue<string>() + ")";
            lines.Add(line);
            foreach (var item in result["items"]!.AsArray())
            {
                var itemKind = item!["kind"]!.GetValue<string>();
                var detail = "  " + Time(item["time"]!.GetValue<double>()) + " " + itemKind;
                if (item["expected"] is { } expected) detail += " \"" + expected.GetValue<string>() + "\"";
                if (itemKind is "mismatch" or "cutOff") detail += item["heard"] is { } heard ? " heard \"" + heard.GetValue<string>() + "\"" : " not heard";
                if (item["value"] is { } value) detail += " " + Fixed(value.GetValue<double>(), "0.000");
                if (item["band"] is { } band) detail += " in the " + band.GetValue<string>() + " band";
                if (item["count"] is { } count) detail += " (" + count.GetValue<int>().ToString(CultureInfo.InvariantCulture) + " cards)";
                lines.Add(detail);
            }
        }
        lines.Add(check["passed"]!.GetValue<bool>() ? "passed" : "warnings");
        return string.Join("\n", lines);
    }
}

/// <summary>The autopilot's checks: one per exported clip, each started as its export is written and run one after another (the local
/// engine hears one file at a time) beside the other clips' plans and exports. The engine is chosen once.</summary>
internal sealed class ClipChecks
{
    private readonly Lazy<Task<ExportChecker.Hearing?>> hearing;
    private readonly ClaudeModeClock clock;
    private readonly CancellationToken ct;
    private readonly object gate = new();
    private Task last = Task.CompletedTask;
    private readonly Dictionary<int, Task<JsonObject>> results = [];

    internal ClipChecks(Transcript? transcript, ClaudeModeClock clock, CancellationToken ct)
    {
        this.clock = clock; this.ct = ct;
        hearing = new(() => Task.Run(async () =>
        {
            try { return await CliCheck.LocalHearingAsync(transcript, ct).ConfigureAwait(false); }
            catch (Exception error) when (error is not OperationCanceledException) { return null; }
        }, ct));
    }

    /// <summary>Queues the check of <paramref name="rank"/>'s export; it returns at once.</summary>
    internal void Start(int rank, string export, PreparedExport prepared)
    {
        lock (gate)
        {
            var previous = last;
            var task = Task.Run(async () =>
            {
                try { await previous.ConfigureAwait(false); } catch (Exception) { }
                clock.Begin(ClaudeModeStage.Check, rank);
                try
                {
                    var outcome = await CliCheck.CheckExportAsync(export, prepared, await hearing.Value.ConfigureAwait(false), ct).ConfigureAwait(false);
                    return CliCheck.Json(outcome);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception error)
                {
                    return new JsonObject { ["passed"] = false, ["error"] = ServicesMergeAdapter.DiagnosticRedactor().Redact(error.Message) };
                }
                finally { clock.End(ClaudeModeStage.Check, rank); }
            }, ct);
            last = task;
            results[rank] = task;
        }
    }

    /// <summary>The clip's check once it has run; null when it was not started.</summary>
    internal async Task<JsonObject?> ResultAsync(int rank)
    {
        Task<JsonObject>? task;
        lock (gate) results.TryGetValue(rank, out task);
        return task is null ? null : await task.ConfigureAwait(false);
    }
}
