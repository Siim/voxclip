using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class RewriteContextTests
{
    [Fact]
    public async Task SharedContextResolution()
    {
        var rows = VoiceRewriteBudgetTests.VoiceLabFixture("rewrite-checks-cases.json")["contextResolution"]!.AsArray();
        var catalog = Catalog();
        var ct = TestContext.Current.CancellationToken;
        Assert.Equal(7, rows.Count);
        foreach (var row in rows)
        {
            var connectorId = VoiceRewriteBudgetTests.Connector(row!["connector"]!.GetValue<string>());
            var model = row["model"]!.GetValue<string>();
            var connector = new CapturingLlmConnector("{\"rewrite\":\"Fine.\"}", connectorId, models: [model], context: row["connectorContext"]?.GetValue<int>());
            var models = new[] { new LlmModel(model, model, null, row["modelContext"]?.GetValue<int>(), ModelSource.Custom) };
            var context = await catalog.ResolveContextTokensAsync(connector, model, ct, models);
            Assert.Equal(row["context"]!.GetValue<int>(), context);
            if (row["sourceWordCount"] is not { } wordCount) continue;
            var source = Enumerable.Range(0, wordCount.GetValue<int>()).Select(index => new TimedWord("w" + index, "word", WordKind.Word,
                index / 10.0, index / 10.0 + 0.05, null, null, null, null, TimingSource.Native)).ToArray();
            var request = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.FullTake, source, "Improve", "en", 150, 1, 5000);
            var service = new VoiceRewriteService(catalog);
            async Task Rewrite()
            {
                var quote = await service.PrepareAsync(request, connector, model, ct);
                await service.ProposeAsync(request, connector, model, service.Approve(quote, true), ct);
            }
            var entries = source.Select((word, index) => new ClipWord(index, word.Text, word.Start, word.End)).ToArray();
            var ranges = ClipText.Lines(entries).Select(line => new PatchRewriteLineRange($"[{line.Line.FirstIndex}-{line.Line.LastIndex}]", 1, 5000)).ToArray();
            var patch = new PatchRewriteRequest(Guid.NewGuid(), entries, ranges, "Improve", "en");
            var patches = new PatchRewriteService(catalog);
            var patchConnector = new CapturingLlmConnector("{\"edits\":[]}", connectorId, models: [model], context: null);
            async Task Patch()
            {
                var quote = await patches.PrepareAsync(patch, patchConnector, model, ct);
                await patches.ProposeAsync(patch, patchConnector, model, patches.Approve(quote, true), ct);
            }
            foreach (var send in new Func<Task>[] { Rewrite, Patch })
            {
                if (row["fits"]!.GetValue<bool>()) await send();
                else Assert.Equal(LlmErrorKind.ContextTooLong, (await Assert.ThrowsAsync<LlmException>(send)).Error.Kind);
            }
        }
    }
}
