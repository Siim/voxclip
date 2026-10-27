using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
namespace VoxClip.Core.Services.LLM;

/// <summary>Explicit clip finder request; AI §11.1. Consent must be obtained by the caller before cloud use.</summary>
public sealed record ClipFinderRequest(IReadOnlyList<TimedWord> Words, IReadOnlyDictionary<string, string> Corrections,
    IReadOnlySet<string> CutWordIds, ClipPreset Preset, string? Instructions, string? Language,
    ConnectorId Connector, string Model, bool Snap = true, bool DryRun = false);
/// <summary>Progress without prompt or transcript text; AI §4.9.</summary>
public sealed record ClipFinderProgress(string Stage, double? Fraction, int Window, int WindowCount);
/// <summary>Cancelable clip pipeline; architecture §7.2 and AI §11.</summary>
public interface IClipFinder
{
    /// <summary>Read presets in shared clip-finder.json order; W7.</summary>
    Task<IReadOnlyList<ClipPreset>> GetPresetsAsync(CancellationToken ct);
    /// <summary>Return validated suggestions; the caller stores the result and adds its clip ranges in one editor operation (AI §11.8).</summary>
    Task<AiResult> FindClipsAsync(ClipFinderRequest request, IProgress<ClipFinderProgress>? progress, CancellationToken ct);
}
/// <summary>Sequential, cancellable clip finder pipeline; AI §11.</summary>
public sealed class ClipFinder : IClipFinder
{
    private readonly LlmCatalog catalog;
    private readonly LlmRunner runner;
    private readonly Func<ConnectorId, ILlmConnector> connectors;
    private readonly SemaphoreSlim gate = new(1, 1);
    /// <summary>Canonical per-window requests prepared by the last dry run; AI §10.4.</summary>
    public IReadOnlyList<LlmRequest> DryRunRequests { get; private set; } = [];
    /// <summary>Whether any window used a fallback; null before or after an incomplete or dry run.</summary>
    public bool? LastUsedFallback { get; private set; }
    /// <summary>Build a media-free pipeline. The caller must obtain connector consent before invoking it.</summary>
    public ClipFinder() : this(new LlmCatalog(), new EmptyKeys(), new Redactor(), null) { }
    /// <summary>Build with the caller's runner and configured connector factory; W7.</summary>
    public ClipFinder(LlmRunner runner, Func<ConnectorId, ILlmConnector> connectorFor, string sharedRoot)
    {
        this.runner = runner;
        connectors = connectorFor;
        catalog = LlmCatalog.Load(sharedRoot);
    }
    /// <summary>App and CLI construction path. Supply the platform key provider and configured connectors; consent remains the caller's responsibility.</summary>
    public ClipFinder(LlmCatalog catalog, IKeyProvider keys, IRedactor redactor, Func<ConnectorId, ILlmConnector>? connectors)
    {
        this.catalog = catalog;
        runner = new(keys, catalog, redactor);
        this.connectors = connectors ?? (id => new LlmConnector(id, catalog, LlmRuntime.Http, keys, redactor));
    }
    /// <inheritdoc />
    public Task<IReadOnlyList<ClipPreset>> GetPresetsAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var presets = catalog.ReadAsset("prompts/clip-finder.json")["presets"]!.AsArray()
            .Select(preset => Enum.Parse<ClipPreset>(preset!["id"]!.GetValue<string>(), true)).ToArray();
        return Task.FromResult<IReadOnlyList<ClipPreset>>(presets);
    }
    /// <inheritdoc />
    public async Task<AiResult> FindClipsAsync(ClipFinderRequest request, IProgress<ClipFinderProgress>? progress, CancellationToken ct)
    {
        try
        {
            await gate.WaitAsync(ct).ConfigureAwait(false);
            try { return await FindCoreAsync(request, progress, ct).ConfigureAwait(false); }
            finally { gate.Release(); }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            var failure = LlmErrors.Create(LlmErrorKind.Cancelled, "");
            runner.ReportError(failure);
            throw failure;
        }
        catch (LlmException exception) { runner.ReportError(exception); throw; }
    }

    private async Task<AiResult> FindCoreAsync(ClipFinderRequest input, IProgress<ClipFinderProgress>? progress, CancellationToken ct)
    {
        DryRunRequests = [];
        LastUsedFallback = null;
        var prompts = new ClipPrompts(catalog);
        if (input.Words.Count == 0) throw new ClipFinderGateException(ClipFinderGateKind.NoWords, prompts.Clips["messages"]!["noWords"]!.GetValue<string>());
        var instructions = prompts.Instructions(input.Instructions);
        if (input.Preset == ClipPreset.Custom && instructions.Length == 0) throw new ClipFinderGateException(ClipFinderGateKind.NeedInstructions, prompts.Clips["messages"]!["needInstructions"]!.GetValue<string>());
        if (!Enum.IsDefined(input.Connector)) throw LlmErrors.Create(LlmErrorKind.NoConnector, "");
        var connector = connectors(input.Connector);
        var entries = ClipText.Entries(input.Words, input.Corrections, prompts.Clips["limits"]!["maxWordTextLength"]!.GetValue<int>());
        var lines = ClipText.Lines(entries);
        var limits = prompts.ValidationLimits;
        if (!input.DryRun) await runner.PreflightAsync(connector, input.Model, LlmFeature.ClipFinder, ct, reportErrors: false).ConfigureAwait(false);
        var context = await catalog.ResolveContextTokensAsync(connector, input.Model, ct, queryConnector: !input.DryRun).ConfigureAwait(false);
        var plan = prompts.Plan(lines, input.Preset.ToString().ToLowerInvariant(), instructions, input.Words[^1].End, context, catalog.Cap(input.Connector, 16000),
            localServer: input.Connector is ConnectorId.Ollama or ConnectorId.LmStudio, model: input.Model);
        var windows = plan.Windows;
        var candidates = new List<RawClip>();
        var dryRequests = new List<LlmRequest>();
        var model = input.Model;
        string? fallbackModel = null;
        int? lastEnd = null;
        for (var index = 0; index < windows.Count; index++)
        {
            ct.ThrowIfCancellationRequested();
            var window = windows[index];
            var instruction = prompts.Instruction(input.Preset, instructions, input.Words[^1].End, window, windows.Count, prompts.WindowClips(input.Preset, windows.Count), index > 0 ? lastEnd : null);
            var request = prompts.Request(input, window.Lines, instruction, index + 1, windows.Count, plan.OutputReserve);
            if (input.DryRun) { dryRequests.Add(request); continue; }
            progress?.Report(new("Finding clips…", (double)index / windows.Count, index + 1, windows.Count));
            var result = await runner.RunCoreAsync(request, connector, input.Model, ct, reportErrors: false).ConfigureAwait(false);
            model = result.Model;
            if (result.UsedFallback) fallbackModel = result.Model;
            var current = result.Object["clips"]!.AsArray().OfType<JsonObject>().Select(clip => new RawClip(clip["title"]!.GetValue<string>(), clip["reason"]!.GetValue<string>(),
                LlmOutput.Number(clip["score"]!), LlmOutput.Number(clip["start_word"]!), LlmOutput.Number(clip["end_word"]!))).ToArray();
            candidates.AddRange(current);
            foreach (var candidate in current)
            {
                var valid = ClipValidation.FinalizeClips(new(new[] { candidate }, input.Words, prompts.Rules(input.Preset) with { MaxClips = 1 }, lines.Select(line => line.Line).ToArray(), new HashSet<string>(), 1, input.Snap), limits);
                if (valid.Clips.Count > 0) lastEnd = Math.Max(lastEnd ?? -1, valid.Clips[0].End);
            }
        }
        DryRunRequests = dryRequests;
        var final = ClipValidation.FinalizeClips(new(candidates, input.Words, prompts.Rules(input.Preset), lines.Select(line => line.Line).ToArray(), input.CutWordIds, windows.Count, input.Snap), limits);
        var clips = final.Clips.Select(clip => new AiClip(clip.Title.Length > 0 ? clip.Title : FallbackTitle(entries.Skip(clip.Start).Take(clip.End - clip.Start + 1), limits.TitleMaxLength), clip.Reason, clip.Score,
            input.Words[clip.Start].Id, input.Words[clip.End].Id)).ToArray();
        ct.ThrowIfCancellationRequested();
        progress?.Report(new("Finding clips…", 1, windows.Count, windows.Count));
        var answeringModel = fallbackModel ?? model;
        var resultModel = answeringModel.EnumerateRunes().Count() is > 0 and <= 128 ? answeringModel : input.Model;
        if (!input.DryRun) LastUsedFallback = fallbackModel is not null;
        return new(Guid.NewGuid().ToString("N"), DateTimeOffset.UtcNow, LlmCatalog.WireId(input.Connector), resultModel, input.Preset, instructions.Length == 0 ? null : instructions, input.Language,
            Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(prompts.Block(lines)))), clips);
    }

    private static string FallbackTitle(IEnumerable<ClipWord> entries, int maxLength)
    {
        var full = string.Join(" ", entries.Select(entry => entry.Text));
        var title = ClipText.Limit(ClipText.Trim(full), maxLength);
        if (full.Length > title.Length && title.LastIndexOf(' ') > 0) title = title[..title.LastIndexOf(' ')];
        return title.Length == 0 ? "…" : title;
    }
}
