using System.Text.Json;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed record PlanAssetServices(
    decimal? Price,
    Func<CancellationToken, Task<string?>> Key,
    Func<ClipAutopilotAction.Asset, string, JsonElement?> Saved,
    Func<ClipAutopilotAction.Asset, string, CancellationToken, Task<JsonElement?>> Sound,
    Func<ClipAutopilotAction.Asset, string, string, CancellationToken, Task<JsonElement>> Illustrate)
{
    internal async Task<JsonElement?> CollectAsync(ClipAutopilotAction.Asset asset, string project, Func<decimal, bool> approve, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (asset.Kind == "soundEffect") return await Sound(asset, project, ct);
        if (asset.Kind != "illustration") return null;
        if (Saved(asset, project) is { } saved) return saved;
        if (Price is not { } price || await Key(ct) is not { Length: > 0 } key) return null;
        ct.ThrowIfCancellationRequested();
        return approve(price) ? await Illustrate(asset, project, key, ct) : null;
    }
}

public sealed partial class EditorViewModel
{
    private async Task<MakeItRow> MakeItAssetAsync(ClipAutopilotOperation operation, ClipAutopilotAction.Asset asset, PlanAssetServices assets, MakeItRun run)
    {
        var snapshot = project;
        var illustration = asset.Kind == "illustration";
        var title = illustration ? "Illustration" : "Sound effect";
        if (illustration && assets.Saved(asset, snapshot.Id) is null)
        {
            if (assets.Price is not { } quote) return new(operation.Id, "Kept the picture: illustration pricing isn't available");
            if ((run.Remaining ?? 0) < quote) return new(operation.Id, "Kept the picture: an illustration is over the spend cap");
        }
        run.Line(illustration ? "Making an illustration…" : "Finding a sound effect…");
        MakeItNotify();
        decimal charged = 0;
        try
        {
            var result = await assets.CollectAsync(asset, snapshot.Id, quote =>
            {
                if (MakeItStopped(run) || !ReferenceEquals(snapshot, project) || (run.Remaining ?? 0) < quote) return false;
                run.Charge(quote);
                charged = quote;
                return true;
            }, run.Cancellation.Token);
            if (result is not { } value)
                return new(operation.Id, illustration ? "No illustration was placed" : "No licensed sound fit this beat")
                    { Detail = illustration && charged == 0 ? "Add a fal.ai key in Settings to generate an illustration." : "" };
            if (MakeItStopped(run) || !ReferenceEquals(snapshot, project) || !ReplaceProject(ClipEffects.Adding([value], project), "Make it postable"))
                return new(operation.Id, title + " saved, not placed");
            var previous = snapshot.ClipEffects.FirstOrDefault(item => item.GetProperty("id").GetString() == asset.Id);
            run.Inverses[operation.Id] = new MakeItInverse.Effect(asset.Id, previous.ValueKind == JsonValueKind.Undefined ? null : previous);
            var detail = charged > 0 ? operation.Reason + " · Up to " + AssetPrice(charged) : operation.Reason;
            return new(operation.Id, title) { Detail = detail, Play = Math.Max(0, asset.Start - 0.5), Undoable = true };
        }
        catch (Exception)
        {
            return new(operation.Id, title + " wasn't placed");
        }
    }

    private static string AssetPrice(decimal usd) => MakeItController.Dollars(decimal.Ceiling(usd * 100) / 100);

    private async Task CheckAskIllustrationAsync(AskClaudeRun run)
    {
        var ready = false;
        try { ready = AskClaudeServices?.Assets is { Price: not null } assets && await assets.Key(CancellationToken.None) is { Length: > 0 }; }
        catch (Exception) { }
        if (!ReferenceEquals(AskClaude.Run, run)) return;
        AskClaude.IllustrationReady = ready;
        AskClaudeNotify();
    }

    internal (string Title, string? Blocked) AskAssetAction(ClipAutopilotAction.Asset asset)
    {
        var assets = AskClaudeServices?.Assets;
        var title = asset.Kind == "soundEffect" ? "Find sound · free" : "Generate illustration";
        if (assets is null) return (title, "This asset source isn't available.");
        string? disabled = AskClaude.AssetWorking is not null ? "An asset is being prepared…" : null;
        if (asset.Kind == "soundEffect") return (title, disabled);
        if (assets.Saved(asset, project.Id) is not null) return ("Place saved illustration", disabled);
        if (assets.Price is not { } price) return (title, "Illustration pricing isn't available.");
        return (title + " · up to " + AssetPrice(price), disabled ?? (AskClaude.IllustrationReady switch
        {
            true => null, false => "Add a fal.ai key in Settings to generate an illustration.", null => "Checking for a fal.ai key…"
        }));
    }

    internal async Task ApplyAskAssetAsync(string id)
    {
        if (AskClaude.Run is not { } run || AskClaudeServices?.Assets is not { } assets ||
            run.Rows.FirstOrDefault(row => row.Id == id) is not { Status: AskClaudeRowStatus.Asset, Operation.Action: ClipAutopilotAction.Asset asset } row ||
            AskAssetAction(asset).Blocked is not null || isLeaving || IsReadOnly) return;
        var snapshot = project;
        AskClaude.AssetWorking = id;
        using var cancellation = new CancellationTokenSource();
        AskClaude.AssetCancellation = cancellation;
        AskClaudeNotify();
        bool Current() => !isLeaving && ReferenceEquals(snapshot, project) && ReferenceEquals(run, AskClaude.Run);
        try
        {
            var effect = await assets.CollectAsync(asset, snapshot.Id, _ => Current(), cancellation.Token);
            if (effect is { } value && Current() && ReplaceProject(ClipEffects.Adding([value], project), "Ask Claude"))
            {
                row.Status = AskClaudeRowStatus.Applied;
                Announcement?.Invoke(this, "Placed the " + row.Title.ToLowerInvariant());
            }
            else row.Detail = effect is not null ? "Saved, but the clip changed. Ask again to place it." :
                asset.Kind == "soundEffect" ? "No licensed sound fit this beat." : "No illustration was returned.";
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception) { row.Detail = "Couldn't prepare the asset. Nothing was placed."; }
        finally { AskClaude.AssetCancellation = null; AskClaude.AssetWorking = null; AskClaudeNotify(); }
    }
}
