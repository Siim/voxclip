using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>shared/fixtures/ask-claude/ask-claude-cases.json: the Ask Claude request and the op-by-op validation of stub replies
/// (ai.md §18). The twin of the Swift AskClaudeTests; every case replays here byte for byte.</summary>
public sealed class AskClaudeTests
{
    private static string Root => FixtureLoader.SharedRoot;
    private static JsonObject Fixture() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/ask-claude/ask-claude-cases.json"))!.AsObject();
    private static AskClaudePrompt Prompt() => AskClaudePrompt.Load(Root);
    internal static Project Project() => ProjectSerialization.Deserialize(Fixture()["project"]!.ToJsonString());

    internal static IReadOnlyList<AskClaudeDetection> Detections(JsonNode? value) => (value as JsonArray ?? []).Select(item => new AskClaudeDetection(
        item!["label"]!.GetValue<string>(), item["kind"]!.GetValue<string>() == "face" ? AskClaudeDetectionKind.Face : AskClaudeDetectionKind.Text,
        item["start"]!.GetValue<double>(), item["end"]!.GetValue<double>(),
        new(item["x"]!.GetValue<double>(), item["y"]!.GetValue<double>(), item["width"]!.GetValue<double>(), item["height"]!.GetValue<double>()),
        item["text"]?.GetValue<string>())).ToArray();

    internal static AskClaudeSelection Selection(JsonNode item)
    {
        var words = item["selection"]!["words"]!.AsArray();
        return new(new AskClaudeSelection.Scope.Words(words[0]!.GetValue<int>(), words[1]!.GetValue<int>()), item["clipID"]?.GetValue<string>());
    }

    private static bool Close(double? a, JsonNode? b) => b is null ? a is null : a is { } value && Math.Abs(value - b.GetValue<double>()) < 1e-6;
    private static string? Text(JsonNode? node, string key) => node?[key]?.GetValue<string>();

    [Fact]
    public void TheFixtureIsCurrentForThePromptFile()
    {
        var bytes = File.ReadAllBytes(Path.Combine(Root, AskClaudePrompt.Path));
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(bytes)), Text(Fixture(), "promptSha256"));
        Assert.Equal(Text(Fixture(), "promptSha256"), Prompt().Sha256);
        Assert.Equal("voxclip-ask-claude/1", Text(Fixture(), "format"));
        Assert.Equal(20, Prompt().Kinds.Count);
        Assert.Equal(1, Prompt().PromptVersion);
        // Stickers are exactly the bundled emoji images, so every sticker renders from the app's own files.
        var bundled = Directory.GetFiles(Path.Combine(Root, "fonts", "noto-emoji", "png128"), "emoji_u*.png").Select(path =>
            string.Concat(Path.GetFileNameWithoutExtension(path)["emoji_u".Length..].Split('_').Select(hex => char.ConvertFromUtf32(int.Parse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture)))))
            .ToHashSet(StringComparer.Ordinal);
        Assert.Equal(50, bundled.Count);
        Assert.True(Prompt().Stickers.ToHashSet(StringComparer.Ordinal).SetEquals(bundled));
    }

    [Fact]
    public void TheRequestMatchesTheIndependentRenderAtExtraHighEffort()
    {
        var project = Project();
        var service = Service();
        foreach (var item in Fixture()["requests"]!.AsArray())
        {
            var request = service.Request(Text(item, "instruction")!, Selection(item!), project, Detections(item!["detections"]), Text(item, "aspect")!, ConnectorId.ClaudeCode);
            Assert.Equal(Text(item, "expectedInstruction"), request.Instruction);
            Assert.Equal((LlmFeature.AskClaude, Effort.XHigh, "ask_claude_ops", "ask-claude"), (request.Feature, request.Effort!.Value, request.SchemaName, request.Tag));
            Assert.Contains("Never ask a question", request.System, StringComparison.Ordinal);
            Assert.Null(request.CachedBlock);
            Assert.Equal(4000, request.MaxOutputTokens);
        }
    }

    [Fact]
    public void StubRepliesValidateOpByOp()
    {
        var project = Project();
        var words = project.Transcript!.Words;
        foreach (var item in Fixture()["replies"]!.AsArray())
        {
            var id = Text(item, "id")!;
            var scope = AskClaudeScope.Resolve(Selection(item!), project);
            var answer = new AskClaudeValidator(Prompt(), scope, project, Detections(item!["detections"])).Answer(item["reply"]);
            var expected = item["expect"]!.AsArray();
            Assert.True(answer.Operations.Count == expected.Count, id);
            Assert.True(answer.Repairs.Count == item["repairs"]!.GetValue<int>(), id + ": " + string.Join(" | ", answer.Repairs));
            Assert.NotEmpty(answer.Summary);
            foreach (var (operation, want) in answer.Operations.Zip(expected))
            {
                var label = id + " " + operation.Id;
                Assert.True(Decision(operation.Decision) == Text(want, "decision"), label);
                Assert.False(string.IsNullOrEmpty(operation.Reason), label);
                Assert.True(answer.Choices.GetValueOrDefault(operation.Id) == Text(want, "choice"), label + " choice");
                switch (operation.Action)
                {
                    case ClipAutopilotAction.Effect { Value: var value }:
                    {
                        var effect = ClipEffect.Parse(value);
                        Assert.True(effect.Kind == Text(want, "kind"), label);
                        Assert.True(Close(effect.Start, want!["start"]) && Close(effect.End, want["end"]), label + " range");
                        Assert.True(effect.ClipId == "clip-main", label);
                        if (want["wordIds"] is JsonArray ids) Assert.Equal(ids.Select(node => node!.GetValue<string>()), effect.WordIds);
                        if (want["rect"] is JsonArray rect)
                            Assert.Equal(new ClipEffectRect(rect[0]!.GetValue<double>(), rect[1]!.GetValue<double>(), rect[2]!.GetValue<double>(), rect[3]!.GetValue<double>()), effect.Rect);
                        if (Text(want, "tracking") is { } tracking) Assert.Equal(tracking, effect.Tracking);
                        if (Text(want, "text") is { } text) Assert.Equal(text, effect.Text);
                        if (Text(want, "position") is { } position) Assert.Equal(position, effect.Position);
                        if (want["scale"] is { } scale) Assert.Equal(scale.GetValue<double>(), effect.Scale);
                        if (Text(want, "sound") is { } sound) Assert.Equal(sound, effect.Sound?.Id);
                        Assert.True(ClipEffects.IsValidEntry(value, project.Id), label);
                        break;
                    }
                    case ClipAutopilotAction.Stretch stretch:
                        Assert.True(Text(want, "kind") == "stretch" && stretch.ClipId == "clip-main" && stretch.Rate == want!["rate"]!.GetValue<double>(), label);
                        Assert.True(Close(stretch.Start, want["start"]) && Close(stretch.End, want["end"]), label);
                        break;
                    case ClipAutopilotAction.Motion { Cue: var cue }:
                        Assert.True(Text(want, "kind") == "zoom" && cue.ClipID == "clip-main", label);
                        Assert.True(Close(cue.SourceStart, want!["start"]) && Close(cue.SourceEnd, want["end"]), label);
                        Assert.Equal([want["scale"]!.GetValue<double>(), want["scale"]!.GetValue<double>()], cue.Keyframes.Select(frame => frame.Scale));
                        break;
                    case ClipAutopilotAction.Edit { Operation: EditOperation.Correct correct }:
                        Assert.True(Text(want, "kind") == "correction" && Text(want, "text") == correct.Text, label);
                        Assert.Equal(want!["wordIds"]!.AsArray().Select(node => node!.GetValue<string>()), [correct.Id]);
                        break;
                    case ClipAutopilotAction.Edit { Operation: EditOperation.CutSelection cut }:
                        Assert.True(Text(want, "kind") == "jumpCut", label);
                        Assert.Equal(want!["wordIds"]!.AsArray().Select(node => node!.GetValue<string>()), cut.Ids);
                        break;
                    case ClipAutopilotAction.Rewrite rewrite:
                    {
                        var span = want!["wordRange"]!.AsArray();
                        Assert.True(rewrite.Words == new WordSpan(span[0]!.GetValue<int>(), span[1]!.GetValue<int>()) && rewrite.Text == Text(want, "text"), label);
                        Assert.True(answer.Paid.Contains(operation) && want["paid"]!.GetValue<bool>(), label);
                        break;
                    }
                    case ClipAutopilotAction.TranslateCaptions translate:
                    {
                        var span = want!["wordRange"]!.AsArray();
                        Assert.True(translate.StartWord == span[0]!.GetValue<int>() && translate.EndWord == span[1]!.GetValue<int>() &&
                                    translate.Language == Text(want, "language") && translate.Text == Text(want, "text"), label);
                        break;
                    }
                    default: Assert.Fail("Unexpected action in " + label + ": " + operation.Action); break;
                }
            }
            Assert.NotEmpty(words);
        }
    }

    internal static string Decision(ClipAutopilotDecision decision)
    {
        var name = decision.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    [Fact]
    public void ApplyingAnAnswerAddsEveryFreeChangeInOneStepAndEachComesOffAlone()
    {
        var project = Project();
        var item = Fixture()["replies"]!.AsArray().First(reply => Text(reply, "id") == "timing-sound-and-words")!;
        var scope = AskClaudeScope.Resolve(Selection(item), project);
        var answer = new AskClaudeValidator(Prompt(), scope, project, []).Answer(item["reply"]);
        var (applied, pending) = ClipAutopilotMapping.Apply(answer.Operations, project);
        Assert.Equal(4, applied.SchemaVersion);
        Assert.Equal(["freeze", "sound"], applied.ClipEffects.Select(effect => effect.GetProperty("kind").GetString()));
        Assert.Equal(new Dictionary<string, string> { ["w19"] = "darn" }, applied.Edits.Corrections);
        Assert.Equal(["w18"], applied.Edits.CutWordIds);
        // Windows renders zooms (track/v2-win-render-2) and translated captions (track/v2-win-render-3): the zoom applies as the clip's
        // motion cue and the translation as the words' captions; a stretch over part of a clip and the paid rewrite stay pending.
        Assert.Equal(["clip-main-ask-1"], applied.MotionCues.Select(cue => cue.Id));
        var translate = (ClipAutopilotAction.TranslateCaptions)answer.Operations.Single(operation => operation.Decision == ClipAutopilotDecision.Translate).Action;
        var translation = Assert.Single(applied.CaptionTranslations);
        Assert.Equal(new CaptionTranslation("tr-1", translate.ClipId, project.Transcript!.Words[translate.StartWord].Id, project.Transcript.Words[translate.EndWord].Id,
            translate.Language, translate.Text), translation);
        Assert.Equal([ClipAutopilotDecision.Stretch, ClipAutopilotDecision.Rewrite], pending.Select(operation => operation.Decision));
        var encoded = ProjectSerialization.Serialize(applied);
        Assert.Equal(encoded, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(encoded)));
        // One row off: the same answer without that operation leaves the others in place.
        var partial = ClipAutopilotMapping.Apply(answer.Operations.Where(operation => operation.Decision != ClipAutopilotDecision.Freeze).ToArray(), project).Project;
        Assert.Equal(["sound"], partial.ClipEffects.Select(effect => effect.GetProperty("kind").GetString()));
        // The mockup's answer is all free, and its bleep masks the amount in the captions.
        var mockup = Fixture()["replies"]!.AsArray()[0]!;
        var free = new AskClaudeValidator(Prompt(), AskClaudeScope.Resolve(Selection(mockup), project), project, Detections(mockup["detections"])).Answer(mockup["reply"]);
        Assert.Empty(free.Paid);
        var censored = ClipAutopilotMapping.Apply(free.Operations, project).Project;
        var captions = project.Transcript!.Words.Select(word => new CaptionWord(word.Id, word.Text, word.Start, word.End)).ToArray();
        var masked = ClipEffectsRendering.MaskingBleeps(captions, ClipEffects.Rendered(censored, "clip-main")).Select(word => word.Text).ToArray();
        Assert.All(masked[10..15], text => Assert.All(text, character => Assert.True(character is '×' or ',')));
        Assert.Equal("is", masked[9]);
    }

    [Fact]
    public void AStretchOverAWholeClipSetsItsSpeedAndOverPartOfOneStaysPending()
    {
        var project = Project();
        var words = project.Transcript!.Words;
        var whole = new ClipAutopilotOperation("w", ClipAutopilotDecision.Stretch, new ClipAutopilotAction.Stretch("clip-main", words[0].Start + 0.2, words[^1].End - 0.2, 1.25), "r");
        var part = new ClipAutopilotOperation("p", ClipAutopilotDecision.Stretch, new ClipAutopilotAction.Stretch("clip-main", words[2].Start, words[5].End, 1.25), "r");
        var (applied, pending) = ClipAutopilotMapping.Apply([whole, part], project);
        Assert.Equal(1.25, ClipControlsProject.Controls("clip-main", applied)!.Speed);
        Assert.Equal(["p"], pending.Select(operation => operation.Id));
        Assert.Equal("clip-main", ClipControlsProject.WholeClip(null, words[0].Start - 0.25, words[^1].End + 0.25, project));
        Assert.Null(ClipControlsProject.WholeClip("clip-main", words[0].Start - 0.26, words[^1].End, project));
    }

    [Fact]
    public void ATimeRangeResolvesItsWordsAZoomOnTheFullVideoFindsItsClipAndDuckingNeedsMusic()
    {
        var project = Project();
        var words = project.Transcript!.Words;
        var range = AskClaudeScope.Resolve(new(new AskClaudeSelection.Scope.Time(words[3].Start + 0.01, words[5].End - 0.01), null), project);
        Assert.Equal((new WordSpan(3, 5), true, (string?)null), (range.Words!.Value, range.IsTime, range.ClipId));
        var full = new AskClaudeScope(new(0, 4), words[0].Start, words[4].End, null, false, false);
        var reply = JsonNode.Parse("""{"summary":"Zoomed.","ops":[{"kind":"zoom","reason":"Punch in."},{"kind":"duck","reason":"Duck."}]}""");
        var answer = new AskClaudeValidator(Prompt(), full, project, []).Answer(reply);
        var cue = Assert.IsType<ClipAutopilotAction.Motion>(Assert.Single(answer.Operations).Action).Cue;
        Assert.Equal(("clip-main", 1), (cue.ClipID, answer.Repairs.Count));
        var clip = AskClaudeScope.Resolve(new(new AskClaudeSelection.Scope.Clip("clip-main"), "clip-main"), project);
        Assert.Equal((new WordSpan(0, words.Count - 1), true), (clip.Words!.Value, clip.IsClip));
        Assert.ThrowsAny<Exception>(() => AskClaudeScope.Resolve(new(new AskClaudeSelection.Scope.Clip("nope"), null), project));
        Assert.ThrowsAny<Exception>(() => AskClaudeScope.Resolve(new(new AskClaudeSelection.Scope.Time(1, 1.05), null), project));
    }

    [Fact]
    public void NumbersRoundAsPrintfDoesOnTheExactBinaryValue()
    {
        Assert.Equal(["0.12", "0.38", "2.67", "1.00", "0.00", "12.50", "0.00", "1.00"],
            new[] { 0.125, 0.375, 2.675, 0.999, 0, 12.5, double.NaN, 1.005 }.Select(AskClaudePrompt.Number));
    }

    /// <summary>A scripted observer: <paramref name="frame"/> answers each sampled time.</summary>
    internal sealed class StubVision(Func<double, bool, AskClaudeFrameFindings> frame) : IAskClaudeVision
    {
        internal List<(double Time, bool Text)> Calls { get; } = [];
        public Task<AskClaudeFrameFindings> ObserveAsync(double time, bool text, CancellationToken ct) { Calls.Add((time, text)); return Task.FromResult(frame(time, text)); }
    }

    [Fact]
    public async Task DetectionsMergeAcrossFramesAndAreLabelledInOrderOfAppearance()
    {
        var face = new ClipEffectRect(0.6, 0.2, 0.2, 0.3);
        var vision = new StubVision((time, _) => new(
            time < 2 ? [face] : [face with { X = 0.62 }, new ClipEffectRect(0.05, 0.1, 0.1, 0.1)],
            time > 1 ? [new AskClaudeTextLine(" INVOICE #1042 ", new(0.5, 0.3, 0.3, 0.1))] : []));
        var found = await AskClaudeVision.DetectAsync(vision, 0, 4, TestContext.Current.CancellationToken);
        Assert.Equal([0.5, 1.5, 2.5, 3.5], vision.Calls.Select(call => call.Time));
        Assert.Equal([(0.0, 4.0), (1.0, 4.0), (2.0, 4.0)], found.Select(item => (item.Start, item.End)));
        Assert.Equal(["D1", "D2", "D3"], found.Select(item => item.Label));
        Assert.Equal([AskClaudeDetectionKind.Face, AskClaudeDetectionKind.Text, AskClaudeDetectionKind.Face], found.Select(item => item.Kind));
        Assert.Equal("INVOICE #1042", found[1].Text);
        Assert.Equal(face, found[0].Rect);
        Assert.All(vision.Calls, call => Assert.True(call.Text));
    }

    [Fact]
    public async Task AFaceTrackFollowsTheNearestFaceHoldsThroughEmptyFramesAndOnlyFacesAreFollowed()
    {
        var left = new ClipEffectRect(0.1, 0.1, 0.2, 0.2);
        var vision = new StubVision((time, _) => new(time is > 0.3 and < 0.6 ? [] : [left with { X = 0.1 + time / 10 }, new ClipEffectRect(0.7, 0.1, 0.2, 0.2)], []));
        var track = await AskClaudeVision.TrackAsync(vision, "face", 0, 1, left, TestContext.Current.CancellationToken);
        Assert.Equal([0, 0.25, 0.5, 0.75, 1], track.Select(sample => sample.T));
        Assert.All(track, sample => Assert.True(sample.Rect.X < 0.3, "follows the left face, not the right one"));
        Assert.Equal(AskClaudeVision.Grown(left with { X = 0.1 }, 0.25), track[0].Rect);
        Assert.All(vision.Calls, call => Assert.False(call.Text));
        Assert.Empty(await AskClaudeVision.TrackAsync(vision, "saliency", 0, 1, left, TestContext.Current.CancellationToken));
        Assert.Empty(await AskClaudeVision.TrackAsync(vision, "none", 0, 1, left, TestContext.Current.CancellationToken));
        Assert.Equal([0, 0.25, 0.5, 0.6], AskClaudeVision.TrackTimes(0, 0.6));
    }

    internal static AskClaudeService Service() => new(new LlmRunner(new MemoryKeys(null), AiTestSupport.Catalog(), new Redactor()), AiTestSupport.Catalog(), AskClaudePrompt.Load(Root));

    [Fact]
    public async Task TheServiceSendsOneRequestAndReturnsTheCheckedAnswerAndAnEmptyInstructionSendsNothing()
    {
        var project = Project();
        var mockup = Fixture()["replies"]!.AsArray()[0]!;
        var reply = mockup["reply"]!.ToJsonString();
        var stub = new ScriptedConnector(ConnectorId.Ollama, (request, model, ct) => Task.FromResult(new RawCompletion(reply, null, model, new StopKind.Complete(), null, null)));
        var result = await Service().AskAsync("blur the invoice on screen and bleep the amount", Selection(mockup), project, Detections(mockup["detections"]), "9:16",
            stub, "fixture", TestContext.Current.CancellationToken);
        Assert.Equal([ClipAutopilotDecision.Blur, ClipAutopilotDecision.Bleep], result.Answer.Operations.Select(operation => operation.Decision));
        Assert.Equal(1, result.PromptVersion);
        var sent = Assert.Single(stub.Requests);
        Assert.Equal((LlmFeature.AskClaude, Effort.XHigh), (sent.Feature, sent.Effort!.Value));
        var silent = new ScriptedConnector(ConnectorId.Ollama, (request, model, ct) => Task.FromResult(new RawCompletion(reply, null, model, new StopKind.Complete(), null, null)));
        await Assert.ThrowsAnyAsync<Exception>(() => Service().AskAsync("   ", Selection(mockup), project, [], "9:16", silent, "fixture", TestContext.Current.CancellationToken));
        Assert.Empty(silent.Requests);
    }
}
