using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

internal static class AgentThreadWire
{
    internal const int MaxTurns = 200;
    internal const int MaxKeptCheckpoints = 30;
    internal const int MaxBytes = 2 * 1024 * 1024;
    private static readonly ProjectJsonContext Compact = new(new JsonSerializerOptions(ProjectJsonContext.Default.Options)
        { WriteIndented = false, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });

    internal static int Size(AgentThread thread) => JsonSerializer.SerializeToUtf8Bytes(thread, Compact.AgentThread).Length;

    internal static void Validate(AgentThread thread)
    {
        static void Require(bool valid, string reason)
        {
            if (!valid) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, $"agentThread: {reason}");
        }
        static bool Ids(IEnumerable<string> values) => values.All(value => !string.IsNullOrEmpty(value)) &&
            values.Distinct(StringComparer.Ordinal).Count() == values.Count();
        Require(!string.IsNullOrEmpty(thread.Id) && thread.Turns.Count <= MaxTurns && thread.Turns.All(turn => turn is not null) &&
            Ids(thread.Turns.Select(turn => turn.Id)), "Invalid thread id or turns.");
        foreach (var turn in thread.Turns)
        {
            Require(turn.Summary.EnumerateRunes().Count() <= 600 && turn.Steps.Count <= 24 &&
                turn.Steps.All(step => step is not null && step.Ms >= 0), "Invalid summary or steps.");
            Require(turn.Changes.All(change => change is not null) && Ids(turn.Changes.Select(change => change.Id)) &&
                turn.Offers.All(offer => offer is not null) && Ids(turn.Offers.Select(offer => offer.Id)), "Invalid change or offer id.");
            Require(turn.Request.Context.All(item => item is not null && (item.Part ?? 1) > 0 && (item.Line ?? 1) > 0), "Invalid context.");
            Require(turn.Offers.All(offer => Regex.IsMatch(offer.QuoteUSD, @"\A[0-9]+\.[0-9]{2}\z") &&
                (offer.Words is null || (offer.Words.Count <= 500 && offer.Words.All(word => word is not null)))), "Invalid offer.");
            Require(turn.Check is null || turn.Check.Lines.All(line => line is not null), "Invalid check lines.");
            Require(turn.Events.All(item => item is not null && (item.Kind == AgentEventKind.Hand || item.Patch is null)), "Invalid events.");
            foreach (var patch in turn.Changes.Select(change => change.Patch).Concat(turn.Events.Select(item => item.Patch).OfType<IReadOnlyList<AgentPatch>>()))
                Require(patch.All(item => item is not null && AgentPatchPath.IsValid(item)) &&
                    patch.Select(item => item.Path).Distinct(StringComparer.Ordinal).Count() == patch.Count, "Invalid checkpoint patch.");
        }
        Require(Size(thread) <= MaxBytes, "Thread exceeds the 2 MiB limit.");
    }
}
