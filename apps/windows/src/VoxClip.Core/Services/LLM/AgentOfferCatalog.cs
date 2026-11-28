using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Services.Project;
using ClipProject = VoxClip.Core.Domain.Shared.Project;

namespace VoxClip.Core.Services.LLM;

internal static partial class AgentOfferCatalog
{
    internal static AgentOffer Make(string id, JsonObject fields, ClipProject project)
    {
        var kind = AgentChatPrompt.String(fields["kind"]) switch
        {
            "generateMusic" => AgentOfferKind.GenerateMusic,
            "revoice" => AgentOfferKind.Revoice,
            "illustration" => AgentOfferKind.Illustration,
            "lipSync" => AgentOfferKind.LipSync,
            "makeItPostable" => AgentOfferKind.MakeItPostable,
            _ => (AgentOfferKind?)null
        };
        if (kind is null || AgentChatPrompt.String(fields["target"]) is not { } target || Amount(AgentChatPrompt.String(fields["quote"])) is not { } amount)
            throw new HarnessException("A local price isn't available for this offer.");
        var label = kind switch
        {
            AgentOfferKind.GenerateMusic => MusicLabel(project, target),
            AgentOfferKind.Illustration => "Generate an illustration",
            AgentOfferKind.Revoice => "Revoice in Rewrite",
            AgentOfferKind.LipSync => "Lip sync in Rewrite",
            _ => "Make it postable"
        };
        var words = (fields["words"] as JsonArray)?.Select(AgentChatPrompt.String).OfType<string>().ToArray();
        return new(id, kind.Value, label, Currency(amount), AgentOfferState.Offered, Target: target,
            Brief: AgentChatPrompt.String(fields["brief"]), Words: words);
    }

    private static string MusicLabel(ClipProject project, string target)
    {
        var duration = HarnessProposal.RenderedSeconds(project, target);
        if (duration is not { } seconds || !double.IsFinite(seconds) || seconds < 0 || seconds >= int.MaxValue)
            return "Generate a track";
        var rounded = (int)Math.Round(seconds, MidpointRounding.AwayFromZero);
        return FormattableString.Invariant($"Generate a track for {rounded / 60}:{rounded % 60:00}");
    }

    internal static decimal? Amount(string? formatted)
    {
        if (formatted is null || !Price().Match(formatted) .Groups["amount"].Success) return null;
        var number = Price().Match(formatted).Groups["amount"].Value;
        return decimal.TryParse(number, NumberStyles.AllowDecimalPoint | NumberStyles.AllowThousands, CultureInfo.InvariantCulture, out var amount) ? amount : null;
    }

    [GeneratedRegex(@"\A\s*(?:(?:up to|about)\s+)?\$?(?<amount>[0-9][0-9,]*(?:\.[0-9]+)?)\s*\z", RegexOptions.CultureInvariant)]
    private static partial Regex Price();

    internal static string Currency(decimal amount) => amount.ToString("0.00", CultureInfo.InvariantCulture);
}
