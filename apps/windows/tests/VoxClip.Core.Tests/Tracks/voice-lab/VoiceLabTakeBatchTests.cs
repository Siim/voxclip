using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabTakeBatchTests
{
    static IEnumerable<JsonNode> Rows(JsonNode? node) => node?.AsArray().Select(value => value!) ?? [];
    static string S(JsonNode node, string key) => node[key]!.GetValue<string>();
    static JsonNode Vectors() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/take-batch-cases.json"))!;
    static decimal? Money(JsonNode? node) => node is null ? null : decimal.Parse(node.GetValue<string>(), CultureInfo.InvariantCulture);
    static VoiceLabTakeBatch.Window Window(JsonNode row, int rate)
    {
        long start = row["startSample"]!.GetValue<long>(), end = row["endSample"]!.GetValue<long>();
        var window = new VoiceLabWindow("first", "last", [], [], start / (double)rate, end / (double)rate, start, end,
            new(VoiceLabSeamKind.Hard, start / (double)rate, start, 288), new(VoiceLabSeamKind.Hard, end / (double)rate, end, 288));
        var input = new VoiceLabTakeInput("phrase", S(row, "modelId"), S(row, "recordId"), S(row, "language"), 7, S(row, "contentKey"),
            [], rate, [], new HashSet<string>(), window, null, null, false, true);
        VoiceLabPreparedAction Quote(string key, VoiceLabOperation operation)
        {
            var amount = row[key]!;
            return new(Guid.NewGuid(), "fixture", DateTimeOffset.MaxValue,
                new("elevenlabs", operation, key == "synthesis" ? row["characters"]!.GetValue<int>() : 290, key == "synthesis" ? "character" : "second",
                    Money(amount["usd"]), amount["credits"]?.GetValue<int>(), amount["usd"] is null ? "unknown" : "list-fixture"),
                new(operation, Guid.NewGuid(), "elevenlabs", ElevenLabsRegion.Default, key, null, null, null, null, null));
        }
        return new(input, new(Guid.NewGuid(), Enumerable.Range(0, row["takes"]!.GetValue<int>()).Select(index =>
            new VoiceLabTakeQuote(index, (uint)(7 + index), Quote("synthesis", VoiceLabOperation.TextToSpeech), Quote("qa", VoiceLabOperation.SpeechToText))).ToArray()));
    }
    static void Estimate(CostEstimate actual, JsonNode expected)
    {
        Assert.Equal("elevenlabs", actual.Provider); Assert.Equal("take", actual.Unit); Assert.Equal("takeRun", actual.Operation);
        Assert.Equal(expected["units"]!.GetValue<double>(), actual.Units); Assert.Equal(Money(expected["usd"]), actual.Usd);
        Assert.Equal(expected["credits"]?.GetValue<int>(), actual.Credits); Assert.Equal(S(expected, "basis"), actual.Basis);
    }
    static Guid Request(JsonNode row, VoiceLabTakeBatch batch)
    {
        var take = batch.Windows[row[0]!.GetValue<int>()].Quote.Takes[row[1]!.GetValue<int>()];
        return row[2]!.GetValue<string>() == "synthesis" ? take.Synthesis.Review.RequestId : take.Qa.Review.RequestId;
    }
    [Fact]
    public void EveryBatchVectorReplaysExactly()
    {
        var document = Vectors();
        Assert.Equal("voxclip-take-batch-cases/1", S(document, "schema")); Assert.Equal(VoiceLabTakeBatch.ProviderName, S(document, "providerName"));
        Assert.Equal(3, document["candidates"]!.GetValue<int>()); Assert.Equal(VoiceLabTakeBatch.MaximumWindows, document["maximumWindows"]!.GetValue<int>());
        Assert.Equal(24, Rows(document["cases"]).Count());
        foreach (var row in Rows(document["cases"]))
        {
            try { Replay(row, document["sampleRate"]!.GetValue<int>()); }
            catch (Exception error) { throw new InvalidDataException(S(row, "id"), error); }
        }
    }
    static void Replay(JsonNode row, int rate)
    {
        var windows = Rows(row["windows"]).Select(value => Window(value, rate)).ToArray(); var expected = row["expected"]!;
        if (expected["error"] is not null)
        {
            Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => new VoiceLabTakeBatch(windows)).Kind);
            Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => VoiceLabTakeBatch.Validate(windows.Select(window => window.Input).ToArray())).Kind);
            return;
        }
        var batch = new VoiceLabTakeBatch(windows);
        Estimate(batch.Estimate, expected["estimate"]!); Assert.Equal(windows.Sum(window => window.Quote.Takes.Count), batch.TakeCount);
        var cap = row["cap"] is not { } limit ? null : new VoiceLabMonthlyCap(Money(limit["limit"])!.Value, Money(limit["spent"])!.Value);
        var kind = batch.Kind(cap);
        Assert.Equal(Enum.Parse<VoiceLabCostPresentationKind>(S(expected["kind"]!, "kind"), true), kind.Kind); Assert.Equal(S(expected["kind"]!, "text"), kind.Text);
        var progress = new VoiceLabTakeBatchProgress(batch);
        Assert.Equal(0, progress.Window); Assert.Empty(progress.Sent); Assert.Empty(progress.Discarded); Assert.Equal(batch.Estimate, progress.RemainingEstimate);
        foreach (var step in Rows(row["run"]))
        {
            int index = step["window"]!.GetValue<int>(); var want = step["expected"]!;
            HashSet<Guid> sent = [];
            foreach (var (part, ordinal) in Rows(step["sent"]).Select((value, ordinal) => (value.GetValue<string>(), ordinal)))
            {
                if (part == "none") continue;
                if (index < 0 || index >= batch.Windows.Count || ordinal >= batch.Windows[index].Quote.Takes.Count) { sent.Add(Guid.NewGuid()); continue; }
                var take = batch.Windows[index].Quote.Takes[ordinal]; sent.Add(take.Synthesis.Review.RequestId);
                if (part == "both") sent.Add(take.Qa.Review.RequestId);
            }
            var end = Enum.Parse<VoiceLabTakeRunEnd>(S(step, "end"), true);
            if (want["error"] is not null)
            {
                var before = (progress.Window, progress.Sent, progress.Discarded, progress.RemainingEstimate);
                Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => progress.Finish(index, sent, end)).Kind);
                Assert.Equal(before.Window, progress.Window); Assert.True(before.Sent.SetEquals(progress.Sent)); Assert.True(before.Discarded.SetEquals(progress.Discarded)); Assert.Equal(before.RemainingEstimate, progress.RemainingEstimate);
                continue;
            }
            foreach (var dispatch in Rows(want["dispatches"])) Estimate(progress.RemainingEstimateFrom(Request(dispatch["request"]!, batch))!, dispatch["remaining"]!);
            progress.Finish(index, sent, end);
            Assert.Equal(want["next"]?.GetValue<int>(), progress.Window); Estimate(progress.SentEstimate, want["sent"]!); Estimate(progress.RemainingEstimate, want["remaining"]!);
            Assert.True(progress.Discarded.SetEquals(Rows(want["discarded"]).Select(value => Request(value, batch))));
            Assert.False(progress.Sent.Overlaps(progress.Discarded));
            foreach (var request in progress.Sent.Concat(progress.Discarded)) Assert.Null(progress.RemainingEstimateFrom(request));
            Assert.Null(progress.RemainingEstimateFrom(Guid.NewGuid()));
            if (batch.Estimate.Usd is { } total) Assert.Equal(total, progress.SentEstimate.Usd + progress.RemainingEstimate.Usd + batch.EstimateOf(progress.Discarded).Usd);
        }
    }
    [Fact]
    public void UnionApprovalAndDispatchRemainderDoNotDoubleCountTheLedger()
    {
        var document = Vectors();
        var row = Rows(document["cases"]).Single(row => S(row, "id") == "three-windows-crossing-limit");
        var batch = new VoiceLabTakeBatch(Rows(row["windows"]).Select(value => Window(value, 24000)).ToArray());
        Assert.All(batch.Windows, window => Assert.Equal(VoiceLabCostPresentationKind.Inline, VoiceLabCostPresentation.Kind(window.Quote.Estimate, false, "ElevenLabs").Kind));
        Assert.Equal(VoiceLabCostPresentationKind.Confirm, batch.Kind().Kind);
        row = Rows(document["cases"]).Single(row => S(row, "id") == "three-windows-reaching-cap");
        batch = new(Rows(row["windows"]).Select(value => Window(value, 24000)).ToArray());
        var progress = new VoiceLabTakeBatchProgress(batch);
        decimal ledger = Money(row["cap"]!["spent"])!.Value, limit = Money(row["cap"]!["limit"])!.Value;
        for (int index = 0; index < batch.Windows.Count; index++)
        {
            foreach (var action in batch.Windows[index].Quote.Actions)
            {
                var remaining = progress.RemainingEstimateFrom(action.Review.RequestId)!;
                Assert.False(new VoiceLabMonthlyCap(limit, ledger).IsCrossedBy(remaining)); Assert.Equal(limit, ledger + remaining.Usd);
                ledger += action.Estimate.Usd!.Value;
            }
            progress.Finish(index, batch.Windows[index].RequestIds.ToHashSet(), VoiceLabTakeRunEnd.Completed);
        }
        Assert.Equal(limit, ledger);
    }
    [Fact]
    public void DuplicateRequestsAndQaWithoutSynthesisAreRefusedWithoutProgress()
    {
        var row = Rows(Vectors()["cases"]).First(); var windows = Rows(row["windows"]).Select(value => Window(value, 24000)).ToArray();
        var batch = new VoiceLabTakeBatch(windows); var take = windows[0].Quote.Takes[0];
        Assert.Throws<VoiceLabException>(() => new VoiceLabTakeBatch([windows[0], windows[1] with { Quote = windows[0].Quote }]));
        Assert.Throws<VoiceLabException>(() => new VoiceLabTakeBatch([windows[0], windows[1] with { Quote = new(Guid.NewGuid(), [take]) }]));
        var progress = new VoiceLabTakeBatchProgress(batch);
        Assert.Throws<VoiceLabException>(() => progress.Finish(0, new HashSet<Guid> { take.Qa.Review.RequestId }, VoiceLabTakeRunEnd.Completed));
        Assert.Empty(progress.Sent); Assert.Empty(progress.Discarded); Assert.Equal(0, progress.Window);
        var paid = new VoiceLabTakeRow(take.Synthesis.Review.RequestId, 0, take.Seed, Quote: take, Failure: new IOException())
            { Accepted = new HashSet<Guid> { take.Synthesis.Review.RequestId, take.Qa.Review.RequestId } };
        progress.Finish(0, new VoiceLabTakeRunResult([paid], VoiceLabTakeRunEnd.EarlyStop));
        Assert.True(progress.Sent.SetEquals(paid.Accepted)); Assert.Equal(1, progress.Window); Assert.Equal(1, progress.SentEstimate.Units);
    }
}
