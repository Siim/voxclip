using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.ClipAutopilotTests;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Claude mode's planner (ai.md §16.12), twin of the Mac <c>ClipAutopilotStreamingTests</c>: Find Clips' moments in a
/// <c>clips</c> request (prompt version 7), at most three plans in flight, each plan sent to the caller the moment it is ready, a cancel
/// that reaches every plan in flight, and each clip's frames asked for on its own lane. Stub connectors only; nothing waits on a clock.</summary>
[Trait("Track", "win-ai")]
public sealed class ClipAutopilotStreamingTests
{
    /// <summary>Holds clip-plan sends until three wait at once (a deadlock fails at the one-minute guard); counts the most in flight and
    /// the sends that saw a cancel.</summary>
    private sealed class Hold
    {
        private readonly object gate = new();
        private readonly TaskCompletionSource three = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int inFlight;
        internal int Most { get; private set; }
        internal int Cancelled;
        internal bool Released { get; init; } = true;
        internal Task Three => three.Task;
        internal async Task EnterAsync(CancellationToken ct)
        {
            lock (gate) { inFlight++; Most = Math.Max(Most, inFlight); if (inFlight == 3) three.TrySetResult(); }
            try
            {
                if (Released) await three.Task.WaitAsync(TimeSpan.FromMinutes(1), ct);
                else await Task.Delay(Timeout.Infinite, ct);
            }
            catch (OperationCanceledException) { Interlocked.Increment(ref Cancelled); throw; }
            finally { lock (gate) inFlight--; }
        }
    }

    private static readonly JsonObject Good = Sendable(Reply("valid-clip"));

    /// <summary>A valid reply for the span the instruction names.</summary>
    internal static string PlanReply(LlmRequest request)
    {
        var reply = Good.DeepClone().AsObject();
        var span = Regex.Match(request.Instruction, "from word (\\d+) to word (\\d+)");
        reply["startWord"] = int.Parse(span.Groups[1].Value, CultureInfo.InvariantCulture);
        reply["endWord"] = int.Parse(span.Groups[2].Value, CultureInfo.InvariantCulture);
        foreach (var key in new[] { "cuts", "pauseCuts", "corrections", "rewrites", "zooms" }) reply[key] = new JsonArray();
        return reply.ToJsonString();
    }

    private static ScriptedConnector Stub(Hold hold) => new(ConnectorId.Ollama, async (request, model, ct) =>
    {
        await hold.EnterAsync(ct);
        return new RawCompletion(PlanReply(request), null, model, new StopKind.Complete(), null, null);
    });

    private static IReadOnlyList<ClipAutopilotMoment> Moments(IReadOnlyList<WordSpan> spans) =>
        spans.Select((span, index) => ClipAutopilotMoment.Found(span, $"Found {index + 1}", $"Reason {index + 1}.", 9 - index)).ToArray();

    private static readonly WordSpan[] Five = [new(0, 14), new(15, 29), new(30, 44), new(45, 59), new(60, 74)];

    private static ClipAutopilotRequest Input(IReadOnlyList<WordSpan> spans) =>
        new(Transcript(Fixture("plan-v2-cases.json"), 75), Edits() with { PauseThresholdSeconds = 1 }, new ClipAutopilotMode.Clips(spans)) { Moments = Moments(spans) };

    [Fact]
    public async Task FindClipsMomentsPlanAtMostThreeAtOnceEachToldTheOthersAndSentAsReady()
    {
        var ct = TestContext.Current.CancellationToken;
        var hold = new Hold();
        var main = Stub(hold);
        var lanes = new[] { Stub(hold), Stub(hold), Stub(hold) };
        var events = new List<ClipAutopilotProgress>();
        var service = Service();
        var input = Input(Five);
        var result = await service.PlanAsync(input, main, "fixture", lanes, item => { lock (events) events.Add(item); }, ct);
        Assert.Equal(3, hold.Most);
        Assert.Empty(lanes[2].Requests);
        var sent = main.Requests.Concat(lanes.SelectMany(lane => lane.Requests)).ToArray();
        Assert.Equal(5, sent.Length);
        Assert.All(sent, request => Assert.Equal(("clip-autopilot-series-clip", Effort.XHigh), (request.Tag, request.Effort!.Value)));
        // Each plan knows its rank, Find Clips' title and reason, and the other clips by title and start; no caption style is
        // suggested, since Find Clips picks none.
        var first = sent.Single(request => request.Instruction.Contains("from word 0 to word 14", StringComparison.Ordinal));
        Assert.StartsWith("This clip is moment 1 of 5 picked from a longer video for a series: “Found 1”. Reason 1.\nThe other clips of this series: “Found 2” at 0:",
            first.Instruction, StringComparison.Ordinal);
        Assert.Contains("“Found 5” at ", first.Instruction, StringComparison.Ordinal);
        Assert.DoesNotContain("“Found 1” at ", first.Instruction, StringComparison.Ordinal);
        Assert.DoesNotContain("Caption style picked", first.Instruction, StringComparison.Ordinal);
        Assert.Equal(first.Instruction, service.Request(input, ConnectorId.Ollama).Instruction);
        Assert.Equal(5, result.Series.Plans.Count);
        // Every clip's plan is sent as ready between its planning and planned events.
        for (var clip = 0; clip < 5; clip++)
        {
            var planning = events.FindIndex(item => item == new ClipAutopilotProgress.Planning(clip, 5));
            var ready = events.FindIndex(item => item is ClipAutopilotProgress.Ready { Clip: var index, Of: 5 } found && index == clip && Five[clip].Contains(found.Plan.StartWord));
            var planned = events.FindIndex(item => item == new ClipAutopilotProgress.Planned(clip, 5));
            Assert.True(planning >= 0 && planning < ready && ready < planned, $"clip {clip}: {planning} {ready} {planned}");
        }
        // Moments must match the spans one for one.
        await Assert.ThrowsAsync<VoiceLabException>(() => service.PlanAsync(Input(Five) with { Moments = Moments([new(0, 14)]) }, main, "fixture", ct: ct));
    }

    [Fact]
    public async Task TheFirstClipIsReadyBeforeTheOthersFinish()
    {
        var ct = TestContext.Current.CancellationToken;
        var others = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<RawCompletion> Respond(LlmRequest request, string model, CancellationToken token)
        {
            if (!request.Instruction.Contains("from word 0 to word 14", StringComparison.Ordinal)) await others.Task.WaitAsync(TimeSpan.FromMinutes(1), token);
            return new RawCompletion(PlanReply(request), null, model, new StopKind.Complete(), null, null);
        }
        var connector = new ScriptedConnector(ConnectorId.Ollama, Respond);
        var lanes = new[] { new ScriptedConnector(ConnectorId.Ollama, Respond), new ScriptedConnector(ConnectorId.Ollama, Respond) };
        ClipAutopilotProgress? firstReady = null;
        var run = Service().PlanAsync(Input(Five[..3]), connector, "fixture", lanes, item =>
        {
            if (item is ClipAutopilotProgress.Ready && firstReady is null) { firstReady = item; others.TrySetResult(); }
        }, ct);
        var result = await run;
        // Only clip 0 could answer until its plan was handed over, so it was ready while 1 and 2 were still waiting.
        Assert.Equal(0, Assert.IsType<ClipAutopilotProgress.Ready>(firstReady).Clip);
        Assert.Equal(3, result.Series.Plans.Count);
    }

    [Fact]
    public async Task AConnectorThatThrowsFailsOnlyItsClip()
    {
        var connector = new ScriptedConnector(ConnectorId.Ollama, (request, model, _) => request.Instruction.Contains("from word 15 to word 29", StringComparison.Ordinal)
            ? throw new InvalidOperationException("the stub broke") : Task.FromResult(new RawCompletion(PlanReply(request), null, model, new StopKind.Complete(), null, null)));
        var events = new List<ClipAutopilotProgress>();
        var result = await Service().PlanAsync(Input(Five[..3]), connector, "fixture", progress: item => { lock (events) events.Add(item); }, ct: TestContext.Current.CancellationToken);
        Assert.Equal([0, 30], result.Series.Plans.Select(plan => plan.StartWord).Order());
        Assert.Equal(1, Assert.Single(events.OfType<ClipAutopilotProgress.Failed>()).Clip);
    }

    /// <summary>A connector that takes images, with a fixed context.</summary>
    private sealed class Seeing(int context) : ILlmConnector
    {
        internal int Sent;
        public ConnectorId Id => ConnectorId.Anthropic;
        public bool SupportsImages => true;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => Task.FromResult<IReadOnlyList<LlmModel>>([]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(context);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            Interlocked.Increment(ref Sent);
            return Task.FromResult(new RawCompletion(PlanReply(request), null, model, new StopKind.Complete(), null, null));
        }
    }

    [Fact]
    public async Task TheImagesCountInTheContextCheckOfAConnectorThatTakesThem()
    {
        // 24 frames of 2,000 × 1,500 px are 4,000 image tokens each (96,000 in all): they fit a text model's 128k context, not this one's
        // once they count.
        var large = ClipAutopilotFramesTests.Sheet(images: true) with
        {
            Images = Enumerable.Range(1, 24).Select(index => new LlmImage($"Frame {index}", "image/jpeg", [1], 2000, 1500)).ToArray()
        };
        Task<ClipAutopilotFrames?> Source(int clip, WordSpan span, CancellationToken token) => Task.FromResult<ClipAutopilotFrames?>(large);
        var input = Input(Five[..1]) with { Moments = [] };
        var roomy = new Seeing(200_000);
        await Service().PlanAsync(input, roomy, "fixture", ct: TestContext.Current.CancellationToken, frames: Source);
        Assert.Equal(1, roomy.Sent);
        var tight = new Seeing(100_000);
        var error = await Assert.ThrowsAsync<LlmException>(() => Service().PlanAsync(input, tight, "fixture", ct: TestContext.Current.CancellationToken, frames: Source));
        Assert.Equal(LlmErrorKind.ContextTooLong, error.Error.Kind);
        Assert.Equal(0, tight.Sent);
        // A connector that takes no images is sent none, so they don't count.
        var text = new ScriptedConnector(ConnectorId.Ollama, (request, model, _) => Task.FromResult(new RawCompletion(PlanReply(request), null, model, new StopKind.Complete(), null, null)))
            { ContextTokens = 100_000 };
        await Service().PlanAsync(input, text, "fixture", ct: TestContext.Current.CancellationToken, frames: Source);
        Assert.Single(text.Requests);
    }

    [Fact]
    public async Task CancellingThePlanStopsEveryPlanInFlight()
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var hold = new Hold { Released = false };
        var main = Stub(hold);
        var lanes = new[] { Stub(hold), Stub(hold) };
        var run = Service().PlanAsync(Input(Five[..4]), main, "fixture", lanes, ct: stop.Token);
        await hold.Three.WaitAsync(TimeSpan.FromMinutes(1), TestContext.Current.CancellationToken);
        await stop.CancelAsync();
        var error = await Assert.ThrowsAsync<LlmException>(() => run);
        Assert.Equal(LlmErrorKind.Cancelled, error.Error.Kind);
        Assert.Equal(3, hold.Cancelled);
        Assert.Equal(3, main.Requests.Count + lanes.Sum(lane => lane.Requests.Count));
    }

    [Fact]
    public async Task EachClipAsksForItsFramesOnItsOwnLaneAndAFailedClipFailsAlone()
    {
        var ct = TestContext.Current.CancellationToken;
        var asked = new List<(int Clip, WordSpan Span)>();
        var images = ClipAutopilotFramesTests.Sheet(images: true);
        Task<ClipAutopilotFrames?> Source(int clip, WordSpan span, CancellationToken token)
        {
            lock (asked) asked.Add((clip, span));
            return Task.FromResult<ClipAutopilotFrames?>(clip == 1 ? null : images);
        }
        var connector = new ScriptedConnector(ConnectorId.Anthropic, (request, model, token) => Task.FromResult(request.Instruction.Contains("from word 30 to word 44", StringComparison.Ordinal)
            ? new RawCompletion("never json", null, model, new StopKind.Complete(), null, null) : new RawCompletion(PlanReply(request), null, model, new StopKind.Complete(), null, null)));
        var events = new List<ClipAutopilotProgress>();
        var result = await Service().PlanAsync(Input(Five[..3]), connector, "fixture", progress: item => { lock (events) events.Add(item); }, ct: ct, frames: Source);
        Assert.Equal([(0, Five[0]), (1, Five[1]), (2, Five[2])], asked.OrderBy(item => item.Clip));
        var withFrames = connector.Requests.Where(request => request.Instruction.Contains("Cover candidates:", StringComparison.Ordinal)).ToArray();
        // Clip 0 once, and clip 2 twice (its first reply was not JSON, so the corrective retry repeats it).
        Assert.Equal(3, withFrames.Length);
        Assert.All(withFrames, request => Assert.Equal(5, request.Images.Count));
        Assert.Empty(connector.Requests.Single(request => request.Instruction.Contains("from word 15 to word 29", StringComparison.Ordinal)).Images);
        // The failed clip fails alone; the others are planned, and their plans carry the frames' choices.
        Assert.Equal([0, 15], result.Series.Plans.Select(plan => plan.StartWord).Order());
        Assert.Single(events.OfType<ClipAutopilotProgress.Failed>(), item => item.Clip == 2);
        Assert.NotNull(result.Series.Plans.Single(plan => plan.StartWord == 0).Frames);
        Assert.Null(result.Series.Plans.Single(plan => plan.StartWord == 15).Frames);
    }
}
