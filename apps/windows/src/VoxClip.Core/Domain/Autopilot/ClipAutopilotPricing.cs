using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>What applying a plan would cost (ai.md §16.7): the creator's voice for the rewrites, the picked track, and whether the
/// plan's own LLM send costs anything extra.</summary>
/// <param name="Voice">The rewrites' text-to-speech, null when the plan has none.</param>
/// <param name="Music">The picked track, null when the plan has none.</param>
/// <param name="LlmIsFree">A CLI on the creator's plan, a local server or Apple: nothing extra. Otherwise VoxClip can't tell.</param>
public sealed record ClipAutopilotPrice(CostEstimate? Voice, CostEstimate? Music, bool LlmIsFree)
{
    /// <summary>Voice plus music when every present part has a known price; null when one is unknown.</summary>
    public decimal? Usd
    {
        get
        {
            var parts = new[] { Voice, Music }.OfType<CostEstimate>().ToArray();
            return parts.All(part => part.Usd is not null) ? parts.Sum(part => part.Usd!.Value) : null;
        }
    }
}

/// <summary>The plan's price. Pure. Twin of the Mac <c>ClipAutopilotPricing</c>.</summary>
public static class ClipAutopilotPricing
{
    /// <summary>Eleven Music, per second.</summary>
    public static readonly VoiceLabPricedOperation MusicOperation = new("elevenlabs", "music", null, "second");
    /// <summary>shared/catalog/music-prices.json, in the Voice Lab price format.</summary>
    public const string MusicCatalogPath = "catalog/music-prices.json";

    /// <summary>Reads the music price catalog under <paramref name="sharedRoot"/>.</summary>
    public static VoiceLabPriceCatalog LoadMusicCatalog(string sharedRoot) =>
        VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(sharedRoot, MusicCatalogPath)));

    /// <summary>Each rewrite bills its whole spoken text, bridge words included; the music bills the clip's edited length rounded up
    /// to whole seconds.</summary>
    public static ClipAutopilotPrice Price(ClipAutopilotPlan plan, string voiceModel, int candidates, VoiceLabPriceCatalog voiceCatalog,
        VoiceLabPriceCatalog? musicCatalog, double musicSeconds, ConnectorId connector, CliSignIn? signIn)
    {
        if (!double.IsFinite(musicSeconds) || musicSeconds < 0) throw ClipAutopilotRequestBuilder.Invalid();
        var characters = plan.Rewrites.Sum(rewrite => rewrite.Text.EnumerateRunes().Count());
        var voice = plan.Rewrites.Count == 0 ? null
            : VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsTextToSpeech, voiceModel, characters, candidates, null, voiceCatalog);
        CostEstimate? music = null;
        if (plan.PickedMusic is not null)
        {
            var seconds = Math.Ceiling(musicSeconds);
            music = musicCatalog is not null ? VoiceLabPricing.Estimate(MusicOperation, null, seconds, 1, null, musicCatalog)
                : new(MusicOperation.Provider, MusicOperation.Operation, seconds, "second", null, null, VoiceLabPricing.UnknownBasis);
        }
        var free = VoiceLabCostPresentation.KindForLlmSend(connector, signIn, LlmCatalog.WireId(connector)).Kind == VoiceLabCostPresentationKind.Inline;
        return new(voice, music, free);
    }
}
