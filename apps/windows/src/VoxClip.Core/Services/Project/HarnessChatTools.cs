using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Music;
using VoxClip.Core.Services.VoiceLab;
using ClipProject = VoxClip.Core.Domain.Shared.Project;

namespace VoxClip.Core.Services.Project;

internal static class HarnessChatTools
{
    internal static string? Text(JsonElement fields, string key, int max) => fields.TryGetProperty(key, out var value) ? Text(value, max) : null;

    private static string Text(JsonElement value, int max)
    {
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { Length: > 0 } text || text != text.Trim() ||
            text.EnumerateRunes().Count() > max || text.EnumerateRunes().Any(rune => Rune.GetUnicodeCategory(rune) is
                UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator))
            throw new HarnessException("Unexpected or invalid text argument.");
        return text;
    }

    internal static IReadOnlyList<string> Strings(JsonElement fields, string key, int maxCount, int maxLength)
    {
        if (!fields.TryGetProperty(key, out var value)) return [];
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > maxCount)
            throw new HarnessException("Unexpected or invalid list argument.");
        return value.EnumerateArray().Select(item => Text(item, maxLength)).ToArray();
    }

    internal static (JsonElement Arguments, string? Revises, IReadOnlyList<string?> Labels) Timeline(JsonElement arguments)
    {
        if (arguments.ValueKind == JsonValueKind.Object && arguments.TryGetProperty("timelines", out var series))
        {
            HarnessTimeline.RequireObject(arguments, ["timelines", "revises"]);
            if (series.ValueKind != JsonValueKind.Array || series.GetArrayLength() is < 1 or > 6)
                throw new HarnessException("Propose one to six timelines.");
            var timelines = new JsonArray();
            var labels = new List<string?>();
            foreach (var timeline in series.EnumerateArray())
            {
                HarnessTimeline.RequireObject(timeline, [.. HarnessTimeline.Keys, "label"]);
                labels.Add(Text(timeline, "label", 120));
                timelines.Add(EditFields(timeline));
            }
            return (JsonElement.Parse(new JsonObject { ["timelines"] = timelines }.ToJsonString()), Text(arguments, "revises", 200), labels);
        }
        HarnessTimeline.RequireObject(arguments, [.. HarnessTimeline.Keys, "label", "revises"]);
        return (JsonElement.Parse(EditFields(arguments).ToJsonString()), Text(arguments, "revises", 200), [Text(arguments, "label", 120)]);
    }

    private static JsonObject EditFields(JsonElement arguments)
    {
        var fields = JsonNode.Parse(arguments.GetRawText())!.AsObject();
        fields.Remove("label");
        fields.Remove("revises");
        return fields;
    }

    internal static HarnessResult PointTo(JsonElement fields)
    {
        var panel = Text(fields, "panel", 32);
        var label = panel switch
        {
            "captions" => "Open Captions", "music" => "Open Music", "rewrite" => "Open Rewrite", "export" => "Open Export",
            "settingsAI" => "Open AI Settings", "outline" => "Open Outline",
            _ => throw new HarnessException("Choose a supported panel.")
        };
        var result = new JsonObject { ["panel"] = panel, ["label"] = label };
        if (Text(fields, "target", 200) is { } target) result["target"] = target;
        return new(result);
    }

    internal static HarnessResult Offer(JsonElement fields, ClipProject project, string sharedRoot, decimal? postableCap)
    {
        var kind = Text(fields, "kind", 32);
        var target = Text(fields, "target", 200);
        if (target is null || !project.Edits.Clips.Any(clip => clip.Id == target))
            throw new HarnessException("Choose a clip id from read_clips.");
        var brief = Text(fields, "brief", 2000);
        var wordIds = Strings(fields, "words", 500, 200);
        var wordsById = ProjectClock.Build(project).Words.ToDictionary(word => word.Id, StringComparer.Ordinal);
        var words = wordIds.Select(id => wordsById.TryGetValue(id, out var word) ? word :
            throw new HarnessException("Choose word ids from read_transcript.")).ToArray();
        var quote = kind switch
        {
            "generateMusic" => HarnessProposal.MusicPrice(project, sharedRoot, target),
            "illustration" => ClipIllustrationQuote.Load(sharedRoot).Price,
            "revoice" => RevoicePrice(),
            "lipSync" => LipSyncPrice(),
            "makeItPostable" => postableCap is { } cap ? "up to " + VoiceLabCostPresentation.Format(cap) : null,
            _ => throw new HarnessException("Choose a supported offer kind.")
        };
        var result = JsonNode.Parse(fields.GetRawText())!.AsObject();
        result["offerId"] = Guid.NewGuid().ToString("D");
        result["quote"] = quote;
        return new(result);

        string? RevoicePrice()
        {
            var script = brief ?? string.Join(' ', words.Select(word => project.Edits.Corrections.GetValueOrDefault(word.Id) ?? word.Text));
            if (script.Length == 0) throw new HarnessException("Give replacement text or choose word ids from read_transcript.");
            var estimate = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsTextToSpeech, "eleven_multilingual_v2",
                VoiceLabTextLength.Length(script), 1, null, VoiceLabPrices.Load(sharedRoot));
            return estimate.Usd is { } usd ? "about " + VoiceLabCostPresentation.Format(usd) : null;
        }

        string? LipSyncPrice()
        {
            var seconds = words.Length > 0 ? words.Max(word => word.End) - words.Min(word => word.Start) : HarnessProposal.RenderedSeconds(project, target);
            if (seconds is not > 0) return null;
            var estimate = WholeClipRevoice.LipsyncPrice(seconds.Value, WholeClipLipsyncValues.Standard, VoiceLabPrices.Load(sharedRoot));
            return estimate.Usd is { } usd ? "about " + VoiceLabCostPresentation.Format(usd) : null;
        }
    }
}

/// <summary>Free music discovery scoped to one live project's agent session.</summary>
/// <param name="library">The optional free Openverse client.</param>
/// <param name="folder">The host-approved local Music folder.</param>
/// <param name="materialize">The host's free audio import, called only for a previously discovered track.</param>
public sealed class HarnessMusicLibrary(OpenverseMusicClient? library = null, string? folder = null,
    Func<MusicCandidate, string, CancellationToken, Task<ProjectMusic>>? materialize = null)
{
    private readonly ConcurrentDictionary<string, MusicCandidate> discoveries = new(StringComparer.Ordinal);

    internal async Task<IReadOnlyList<JsonObject>> SearchAsync(string mood, double seconds, CancellationToken ct)
    {
        var brief = new MusicBrief(mood);
        var candidates = new List<MusicCandidate>();
        if (library is not null)
        {
            try { candidates.AddRange((await library.SearchAsync(brief.SearchText, brief.Keywords, seconds, ct).ConfigureAwait(false)).Take(8)); }
            catch (Domain.Shared.VoxClipException) { ct.ThrowIfCancellationRequested(); }
        }
        if (MusicLibraryFolder.Best(MusicLibraryFolder.Files(folder), brief.Keywords) is { } local) candidates.Add(local);
        return candidates.Where(candidate => candidate.Source is MusicSource.Library or MusicSource.File).Select(candidate =>
        {
            var id = "free-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(candidate.Id)));
            discoveries[id] = candidate;
            return new JsonObject { ["id"] = id, ["title"] = candidate.Title, ["source"] = candidate.Source.ToString().ToLowerInvariant(),
                ["durationSeconds"] = candidate.DurationSeconds, ["license"] = candidate.License.ToString().ToLowerInvariant() };
        }).ToArray();
    }

    internal async Task<IReadOnlyList<ProjectMusic>> PrepareAsync(IEnumerable<string> ids, string projectId, CancellationToken ct)
    {
        var result = new List<ProjectMusic>();
        foreach (var id in ids)
        {
            if (!discoveries.TryGetValue(id, out var candidate) || materialize is null)
                throw new HarnessException("Choose a saved music track or a track from find_music.");
            var track = await materialize(candidate, projectId, ct).ConfigureAwait(false);
            if (track.Source != candidate.Source) throw new HarnessException("This free music track couldn't be used.");
            result.Add(track with { Id = id, ClipId = null });
        }
        return result;
    }
}
