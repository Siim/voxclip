using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Rebuild from my videos (voice-lab.md §6.12, ADR-R44; Mac <c>VoiceRebuildTests</c>): the shared vectors in
/// shared/fixtures/voice-lab/voice-rebuild-cases.json, which the Mac replays too: one hop and the clean-speech floor, each video once
/// before any repeats, then the most different, within 24 files and 120 s with the consent clip counted, and the line shown first.</summary>
public sealed class VoiceRebuildTests
{
    private static VoiceRebuild.Candidate Candidate(JsonElement item) => new(item.GetProperty("video").GetString()!, item.GetProperty("startMs").GetInt64(),
        item.GetProperty("endMs").GetInt64(), item.GetProperty("snrDb").GetDouble(), item.GetProperty("score").GetDouble(),
        VoiceConsentRecord.DecodeEmbedding(item.GetProperty("embedding").GetString()!)!);

    private static string Reason(VoiceRebuild.Rejection rejection) => rejection switch
    {
        VoiceRebuild.Rejection.NotTheOwner => "notTheOwner",
        VoiceRebuild.Rejection.Noisy => "noisy",
        VoiceRebuild.Rejection.Length => "length",
        _ => "full"
    };

    [Fact]
    public void ReplaysEveryRebuildVector()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/voice-rebuild-cases.json");
        var root = document.RootElement;
        Assert.Equal("voxclip-voice-rebuild/1", root.GetProperty("schema").GetString());
        Assert.Equal(["schema", "description", "constants", "caseCount", "cases"], root.EnumerateObject().Select(property => property.Name));
        var constants = root.GetProperty("constants");
        Assert.Equal(VoiceRebuild.MaximumFiles, constants.GetProperty("maximumFiles").GetInt32());
        Assert.Equal(VoiceRebuild.MinimumTotalMs, constants.GetProperty("minimumTotalMs").GetInt64());
        Assert.Equal(VoiceRebuild.MaximumTotalMs, constants.GetProperty("maximumTotalMs").GetInt64());
        Assert.Equal(VoiceRebuild.MinimumPieceMs, constants.GetProperty("minimumPieceMs").GetInt64());
        Assert.Equal(VoiceRebuild.MaximumPieceMs, constants.GetProperty("maximumPieceMs").GetInt64());
        Assert.Equal(VoiceRebuild.MinimumSnrDb, constants.GetProperty("minimumSnrDb").GetDouble());
        Assert.Equal(8.0, constants.GetProperty("perVideoMinimumSnrDb").GetDouble());
        Assert.Equal(VoiceRebuild.CandidatesPerVideo, constants.GetProperty("candidatesPerVideo").GetInt32());
        var cases = root.GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(root.GetProperty("caseCount").GetInt32(), cases.Length);
        HashSet<string> kinds = [];
        foreach (var item in cases)
        {
            var kind = item.GetProperty("kind").GetString()!;
            var name = item.GetProperty("name").GetString()!;
            var expected = item.GetProperty("expected");
            kinds.Add(kind);
            switch (kind)
            {
                case "pick":
                    var kept = item.GetProperty("keptMs").ValueKind == JsonValueKind.Null ? (long?)null : item.GetProperty("keptMs").GetInt64();
                    var plan = VoiceRebuild.Pick(item.GetProperty("candidates").EnumerateArray().Select(Candidate).ToArray(), item.GetProperty("threshold").GetDouble(),
                        kept, item.GetProperty("minimumSnrDb").GetDouble());
                    Assert.True(expected.GetProperty("pieces").EnumerateArray().Select(piece => (piece[0].GetString()!, piece[1].GetInt64()))
                        .SequenceEqual(plan.Pieces.Select(piece => (piece.Video, piece.StartMs))), name);
                    Assert.Equal(kept, plan.KeptMs);
                    Assert.Equal(expected.GetProperty("rejected").EnumerateObject().Select(pair => (pair.Name, pair.Value.GetInt32())).OrderBy(pair => pair.Name, StringComparer.Ordinal),
                        plan.Rejected.Select(pair => (Reason(pair.Key), pair.Value)).OrderBy(pair => pair.Item1, StringComparer.Ordinal));
                    Assert.Equal(expected.GetProperty("totalMs").GetInt64(), plan.TotalMs);
                    Assert.Equal(expected.GetProperty("videoCount").GetInt32(), plan.VideoCount);
                    Assert.Equal(expected.GetProperty("fileCount").GetInt32(), plan.FileCount);
                    Assert.Equal(expected.GetProperty("enough").GetBoolean(), plan.Enough);
                    Assert.Equal(expected.GetProperty("summary").GetString(), VoiceRebuild.Summary(plan));
                    break;
                case "amount":
                    Assert.Equal(expected.EnumerateArray().Select(value => value.GetString()),
                        item.GetProperty("milliseconds").EnumerateArray().Select(value => VoiceRebuild.Amount(value.GetInt64())));
                    break;
                default:
                    Assert.Fail("unknown kind " + kind + " in " + name);
                    break;
            }
        }
        Assert.Equal(["pick", "amount"], kinds);
    }

    /// <summary>The per-video floor is cleanliness only (ADR-R45): a lower floor admits noisier owner speech, never a piece below τ.</summary>
    [Fact]
    public void TheFloorNeverAdmitsAnotherVoice()
    {
        float[] direction = [1, 0, 0, 0];
        VoiceRebuild.Candidate[] candidates = [new("v", 0, 20_000, 9, 0.44, direction), new("v", 30_000, 50_000, 9, 0.46, direction)];
        var strict = VoiceRebuild.Pick(candidates, 0.45);
        Assert.Empty(strict.Pieces);
        Assert.Equal(1, strict.Rejected[VoiceRebuild.Rejection.Noisy]);
        var relaxed = VoiceRebuild.Pick(candidates, 0.45, minimumSnrDb: 8);
        Assert.Equal(30_000, Assert.Single(relaxed.Pieces).StartMs);
        Assert.Equal(1, relaxed.Rejected[VoiceRebuild.Rejection.NotTheOwner]);
    }
}
