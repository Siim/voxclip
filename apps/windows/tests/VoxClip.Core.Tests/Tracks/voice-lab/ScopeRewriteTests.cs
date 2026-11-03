using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class ScopeRewriteTests
{
    [Fact]
    public void StructuredExpressionsFollowOrderedScopedHunksRatherThanRepeatedWords()
    {
        var words = new[] { "Hello", "one", "two", "three", "old" }.Select((text, index) => Word("word" + index, text, index, index + .5)).ToArray();
        var entries = words.Select((word, index) => new ClipWord(index, word.Text, word.Start, word.End)).ToArray();
        var request = new PatchRewriteRequest(Guid.NewGuid(), entries, [new("[0-4]", 1, 50)], "Keep my tone", "en");
        var plan = new ScopeRewritePlan(RewriteScope.FullTake,
            [new("[0-4]", words, entries, words.Select(_ => false).ToArray(), 1, 50, ScopeRewritePlan.RangeSource.LineSpan)], request);
        var edit = new PatchRewriteEdit("[0-4]", "Hello one two three Hello", "Tone", 23, true, false, false)
            { AudioTags = [new(1, "laughs"), new(5, "sighs")] };
        var proposal = new PatchRewriteProposal(Guid.NewGuid(), [edit], 0, 0, 0, "", ConnectorId.OpenAI, "chosen", null);
        var hunk = Assert.Single(ScopeRewriteDiff.Hunks(plan, proposal)).Diff;
        Assert.Equal(new VoiceLabAudioTag(1, "sighs"), Assert.Single(hunk.AudioTags));
        Assert.Equal("Hello", Assert.Single(hunk.NewTokens));
    }
    static JsonNode Fixture(string name) => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/" + name + ".json"))!;
    static IEnumerable<JsonNode> Rows(JsonNode? node) => node?.AsArray().Select(value => value!) ?? [];
    static string S(JsonNode node, string key) => node[key]!.GetValue<string>();
    static double D(JsonNode node, string key) => node[key]!.GetValue<double>();
    static string[] Strings(JsonNode? node) => Rows(node).Select(value => value.GetValue<string>()).ToArray();
    static WordKind Kind(string text) => text switch { "event" => WordKind.Event, "unlabeledSpeech" => WordKind.UnlabeledSpeech, _ => WordKind.Word };
    static TimedWord Word(string id, string text, double start, double end, WordKind kind = WordKind.Word) => new(id, text, kind, start, end, null, null, null, null, TimingSource.Native);
    static TimedWord[] Words(JsonNode input)
    {
        if (input["wordsRepeat"] is not { } recipe)
            return Rows(input["words"]).Select(item => Word(S(item, "id"), S(item, "text"), D(item, "start"), D(item, "end"), Kind(S(item, "kind")))).ToArray();
        double step = D(recipe, "timingStep");
        return Enumerable.Range(0, recipe["count"]!.GetValue<int>()).Select(index => Word(S(recipe, "idPrefix") + index,
            S(recipe, "token"), index * step, index * step + step / 2)).ToArray();
    }
    static VoiceLabSeam Seam(JsonNode node) => new(Enum.Parse<VoiceLabSeamKind>(S(node, "kind"), true), node["fadeSamples"]!.GetValue<long>(), 0, 0);
    static Project Take(JsonNode input)
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var template = project.VoiceLab.Segments[0];
        var segments = Rows(input["segments"]).Select(row => template with
        {
            Id = S(row, "id"), Enabled = row["enabled"]!.GetValue<bool>(),
            Replace = new(D(row, "start"), D(row, "end"), S(row, "firstWordId"), S(row, "lastWordId")),
            Candidates = [template.Candidates[0] with { Recipe = template.Candidates[0].Recipe! with { Seams = new(Seam(row["inSeam"]!), Seam(row["outSeam"]!)) } }],
            SelectedCandidateIndex = 0
        }).ToArray();
        var edits = input["edits"]!;
        return project with
        {
            Transcript = project.Transcript! with { Words = Words(input) },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = D(input, "durationSeconds"),
                Audio = project.Media.Source.Audio! with { SampleRate = input["sampleRate"]!.GetValue<int>() } } },
            VoiceLab = project.VoiceLab with { Segments = segments, Assets = [] },
            Edits = project.Edits with { CutWordIds = Strings(edits["cutWordIds"]), CutPauseIds = Strings(edits["cutPauseIds"]),
                Corrections = edits["corrections"]!.AsObject().ToDictionary(pair => pair.Key, pair => pair.Value!.GetValue<string>(), StringComparer.Ordinal),
                PauseThresholdSeconds = D(edits, "pauseThresholdSeconds"), PauseKeepSeconds = D(edits, "pauseKeepSeconds"), ActiveClipId = null,
                Clips = Rows(edits["clips"]).Select(row => new ClipRange(S(row, "id"), S(row, "startWordId"), S(row, "endWordId"), null,
                    S(row, "origin") == "ai" ? ClipOrigin.Ai : ClipOrigin.Manual, null, null, row["selected"]!.GetValue<bool>())).ToArray() }
        };
    }
    static ScopeRewritePlan Plan(JsonNode input, Project? project = null, Guid? id = null)
    {
        var scope = input["scope"]!;
        var selection = S(scope, "kind") switch { "clip" => RewriteScope.Clip(S(scope, "clipId")),
            "selection" => RewriteScope.Selection(scope["first"]!.GetValue<int>(), scope["last"]!.GetValue<int>()), _ => RewriteScope.FullTake };
        AudioEnvelope? envelope = input["envelope"] is not { } raw ? null : new(raw["sampleRate"]!.GetValue<int>(), 0.01,
            Rows(raw["runs"]).SelectMany(run => Enumerable.Repeat(run[0]!.GetValue<float>(), run[1]!.GetValue<int>())).ToArray());
        return ScopeRewritePlan.Make(project ?? Take(input), selection, S(input, "instruction"), S(input, "language"), envelope,
            Rows(input["rateCandidates"]).Select(row => new VoiceLabRateCandidate(S(row, "text"), D(row, "firstCharStart"), D(row, "lastCharEnd"))).ToArray(), id);
    }
    static string Camel(object value) => char.ToLowerInvariant(value.ToString()![0]) + value.ToString()![1..];
    static void EqualBytes(string expected, string actual) => Assert.Equal(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(actual));
    static void Entry(ClipWord entry, JsonNode expected)
    {
        Assert.Equal(expected["index"]!.GetValue<int>(), entry.Index); EqualBytes(S(expected, "text"), entry.Text);
        Assert.Equal(D(expected, "start"), entry.Start); Assert.Equal(D(expected, "end"), entry.End);
    }
    [Fact]
    public async Task EveryPlanVectorReplaysExactly()
    {
        var document = Fixture("scope-rewrite-plan-cases");
        Assert.Equal("voxclip-voice-lab-scope-rewrite-plan/1", S(document, "schema"));
        Assert.Equal(document["caseCount"]!.GetValue<int>(), Rows(document["cases"]).Count());
        Assert.Equal(ScopeRewritePlan.MaxEntries, document["limits"]!["maxEntries"]!.GetValue<int>());
        Assert.Equal(ScopeRewritePlan.MaxBytes, document["limits"]!["maxBytes"]!.GetValue<int>());
        Assert.Equal(ScopeRewritePlan.MaxWordTextLength, document["limits"]!["maxWordTextLength"]!.GetValue<int>());
        Assert.Equal(ScopeRewritePlan.MaxChars, document["limits"]!["maxChars"]!.GetValue<int>());
        foreach (var row in Rows(document["cases"]))
        {
            var input = row["input"]!; var expected = row["expected"]!;
            var id = Guid.NewGuid();
            if (expected["error"] is { } error)
            {
                var failure = Assert.Throws<ScopeRewritePlanException>(() => Plan(input));
                Assert.True(Camel(failure.Code) == error.GetValue<string>(), S(row, "name") + ": " + failure.Code);
                Assert.Equal(expected["count"]?.GetValue<int>(), failure.Count); Assert.Equal(expected["bytes"]?.GetValue<int>(), failure.Bytes);
                continue;
            }
            var plan = Plan(input, id: id);
            Assert.Equal(id, plan.Request.RequestId); EqualBytes(S(input, "instruction"), plan.Request.Instruction); Assert.Equal(S(input, "language"), plan.Request.Language);
            Assert.Equal(plan.Lines.Select(line => new PatchRewriteLineRange(line.Label, line.MinChars, line.MaxChars)), plan.Request.Ranges);
            var summary = expected["summary"];
            var source = summary ?? expected;
            Assert.Equal(source["utf8Bytes"]!.GetValue<int>(), Encoding.UTF8.GetByteCount(string.Join(" ", plan.Entries.Select(entry => entry.Text))));
            if (summary is not null)
            {
                Assert.Equal(summary["entryCount"]!.GetValue<int>(), plan.Entries.Count);
                Entry(plan.Entries[0], summary["firstEntry"]!); Entry(plan.Entries[^1], summary["lastEntry"]!);
            }
            else
            {
                Assert.Equal(Rows(expected["entries"]).Count(), plan.Entries.Count);
                foreach (var (entry, value) in plan.Entries.Zip(Rows(expected["entries"]))) Entry(entry, value);
            }
            Assert.Equal(Rows(source["lines"]).Count(), plan.Lines.Count);
            foreach (var (line, value) in plan.Lines.Zip(Rows(source["lines"])))
            {
                EqualBytes(S(value, "line"), line.Label);
                Assert.Equal(value["minChars"]!.GetValue<int>(), line.MinChars); Assert.Equal(value["maxChars"]!.GetValue<int>(), line.MaxChars);
                Assert.Equal(S(value, "rangeSource"), Camel(line.Source));
                if (summary is not null)
                {
                    Assert.Equal(value["itemCount"]!.GetValue<int>(), line.ItemIds.Count); Assert.Equal(S(value, "firstItemId"), line.ItemIds[0]); Assert.Equal(S(value, "lastItemId"), line.ItemIds[^1]);
                }
                else
                {
                    Assert.Equal(Strings(value["itemIds"]), line.ItemIds);
                    Assert.Equal(line.Items.Count, line.RevoicedBefore.Count);
                    Assert.Equal(Strings(value["revoicedBefore"]), line.Items.Where((_, index) => line.RevoicedBefore[index]).Select(item => item.Id));
                }
            }
            _ = await new PatchRewriteService(Catalog()).PrepareAsync(plan.Request, new CapturingLlmConnector("{}"), "chosen", TestContext.Current.CancellationToken);
        }
    }
    static async Task<PatchRewriteProposal> Propose(PatchRewriteRequest request, string reply)
    {
        var service = new PatchRewriteService(Catalog()); var connector = new CapturingLlmConnector(reply);
        var approval = service.Approve(await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken), true);
        return await service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
    }
    static void Hunks(IReadOnlyList<ScopeRewriteDiff.Hunk> actual, JsonNode expected, IReadOnlyList<TimedWord> transcript)
    {
        Assert.Equal(Rows(expected["hunks"]).Count(), actual.Count);
        foreach (var (found, value) in actual.Zip(Rows(expected["hunks"])))
        {
            var hunk = found.Diff;
            Assert.Equal(S(value, "kind"), Camel(hunk.Kind));
            void StringsEqual(IReadOnlyList<string> items, string key)
            {
                var values = Strings(value[key]); Assert.Equal(values.Length, items.Count);
                foreach (var (item, want) in items.Zip(values)) EqualBytes(want, item);
            }
            StringsEqual(hunk.SourceWordIds, "sourceWordIds"); StringsEqual(hunk.NewTokens, "newTokens"); StringsEqual(hunk.CorrectedTexts, "correctedTexts");
            StringsEqual(hunk.AbsorbedItemIds, "absorbedItemIds"); StringsEqual(hunk.BridgeWordIds, "bridgeWordIds"); StringsEqual(found.Lines, "lines"); StringsEqual(found.Reasons, "reasons");
            Assert.Equal(value["sourceStartIndex"]!.GetValue<int>(), hunk.SourceStartIndex); Assert.Equal(value["sourceEndIndex"]!.GetValue<int>(), hunk.SourceEndIndex);
            Assert.Equal(value["anchorSeconds"]?.GetValue<double>(), hunk.AnchorSeconds); Assert.Equal(value["insertionAfterItemId"]?.GetValue<string>(), found.InsertionAfterItemId);
            Assert.Equal(value["checkThis"]!.GetValue<bool>(), found.CheckThis);
        }
        var budget = VoiceLabPatchBudget.Evaluate(new([], actual.Select(item => item.Diff).ToArray()), transcript);
        Assert.Equal(expected["budget"]!["voiceTokenCount"]!.GetValue<int>(), budget.VoiceTokenCount);
        Assert.Equal(expected["budget"]!["wordItems"]!.GetValue<int>(), budget.WordItems); Assert.Equal(S(expected["budget"]!, "flag"), Camel(budget.Flag));
    }
    [Fact]
    public async Task EveryScopeDiffVectorReplaysExactly()
    {
        var document = Fixture("scope-rewrite-diff-cases");
        Assert.Equal("voxclip-voice-lab-scope-rewrite-diff/1", S(document, "schema"));
        Assert.Equal(document["caseCount"]!.GetValue<int>(), Rows(document["cases"]).Count());
        Assert.Equal(ScopeRewriteDiff.MergeWords, document["merge"]!["words"]!.GetValue<int>()); Assert.Equal(ScopeRewriteDiff.MergeSeconds, D(document["merge"]!, "seconds"));
        foreach (var row in Rows(document["cases"]))
        {
            var input = row["input"]!; var expected = row["expected"]!; var project = Take(input); var plan = Plan(input, project);
            var proposal = input["reply"] is { } reply ? await Propose(plan.Request, reply.GetValue<string>()) : new PatchRewriteProposal(Guid.NewGuid(),
                Rows(input["proposal"]).Select(item => new PatchRewriteEdit(S(item, "line"), S(item, "text"), S(item, "reason"), VoiceLabTextLength.Length(S(item, "text")), true,
                    item["checkThis"]!.GetValue<bool>(), EditingAlgorithms.JsTrim(S(item, "text")).Length == 0)).ToArray(), 0, 0, 0, "", ConnectorId.OpenAI, "chosen", null);
            if (expected["error"] is not null)
            {
                Assert.Equal(VoiceLabWordDiffErrorCode.InvalidInput, Assert.Throws<VoiceLabWordDiffException>(() => ScopeRewriteDiff.Hunks(plan, proposal)).Code); continue;
            }
            foreach (var (edit, value) in proposal.Edits.Zip(Rows(expected["edits"])))
            {
                Assert.Equal(S(value, "line"), edit.Line); Assert.Equal(value["inRange"]!.GetValue<bool>(), edit.InRange);
                Assert.Equal(value["checkThis"]!.GetValue<bool>(), edit.CheckThis); Assert.Equal(value["isDeletion"]!.GetValue<bool>(), edit.IsDeletion);
            }
            try { Hunks(ScopeRewriteDiff.Hunks(plan, proposal), expected, project.Transcript!.Words); }
            catch (Exception error) { throw new InvalidDataException(S(row, "name"), error); }
        }
    }
    [Fact]
    public async Task EveryPatchReplyMapsToExactHunksAndTokenFlags()
    {
        var document = Fixture("scope-rewrite-diff-cases"); var patch = PatchRewriteServiceTests.Cases();
        Assert.Equal(document["patchRewriteCaseCount"]!.GetValue<int>(), patch["cases"]!.AsArray().Count);
        foreach (var (row, result) in Rows(patch["cases"]).Zip(Rows(document["patchRewriteCases"])))
        {
            Assert.Equal(S(row, "id"), S(result, "id"));
            var request = PatchRewriteServiceTests.Request(patch, S(row, "instruction"), row["entries"], row["ranges"]);
            var sources = new PatchRewriteValidator.Sources(request.Entries.Select(entry => entry.Text).Append(request.Instruction));
            foreach (var edit in Rows(row["expected"]!["edits"]))
            {
                var flags = sources.FlaggedTokens(S(edit, "text")); Assert.Equal(EditingAlgorithms.SplitWords(S(edit, "text")).Count, flags.Count);
                Assert.Equal(edit["checkThis"]!.GetValue<bool>(), flags.Any(flag => flag));
            }
            if (result["expected"]!["error"] is { } error) { Assert.Equal(error.GetValue<string>(), S(row["expected"]!, "error")); continue; }
            var proposal = await Propose(request, S(row, "reply"));
            var lines = ClipText.Lines(request.Entries).Zip(request.Ranges).Select(pair =>
            {
                var entries = request.Entries.Skip(pair.First.FirstPosition).Take(pair.First.LastPosition - pair.First.FirstPosition + 1).ToArray();
                return new ScopeRewritePlan.Line(pair.Second.Line, entries.Select(entry => Word("i" + entry.Index, entry.Text, entry.Start, entry.End)).ToArray(),
                    entries, entries.Select(_ => false).ToArray(), pair.Second.MinChars, pair.Second.MaxChars, ScopeRewritePlan.RangeSource.LineSpan);
            }).ToArray();
            var plan = new ScopeRewritePlan(RewriteScope.FullTake, lines, request);
            try { Hunks(ScopeRewriteDiff.Hunks(plan, proposal), result["expected"]!, lines.SelectMany(line => line.Items).ToArray()); }
            catch (Exception failure) { throw new InvalidDataException(S(row, "id"), failure); }
        }
    }
}
