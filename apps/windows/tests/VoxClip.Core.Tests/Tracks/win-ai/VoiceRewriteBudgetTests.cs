using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Records every request and answers each with one canned reply; it never contacts a provider. The reply names
/// <paramref name="answered"/> as its model when given, else the requested one, and ends with <paramref name="stop"/>.</summary>
internal sealed class CapturingLlmConnector(string reply, ConnectorId id = ConnectorId.OpenAI, string? answered = null, StopKind? stop = null,
    string[]? models = null, int? context = 65536) : ILlmConnector
{
    public ConnectorId Id => id;
    public List<LlmRequest> Requests { get; } = [];
    public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
    public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => Task.FromResult<IReadOnlyList<LlmModel>>(
        (models ?? ["chosen"]).Select(model => new LlmModel(model, model, null, context, ModelSource.Discovered)).ToArray());
    public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(context);
    public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
    {
        lock (Requests) Requests.Add(request);
        return Task.FromResult(new RawCompletion(reply, null, answered ?? model, stop ?? new StopKind.Complete(), null, "synthetic-request"));
    }
}

[Trait("Track", "win-ai")]
public sealed class VoiceRewriteBudgetTests
{
    /// <summary>Reads one of the generated fixtures that <c>shared/fixtures/voice-lab/rewrite-README.md</c> describes.</summary>
    internal static JsonObject VoiceLabFixture(string name)
    {
        var path = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", name);
        Assert.True(File.Exists(path), "The shared Voice Lab fixture is required: " + name);
        var document = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        Assert.Equal(1, document["version"]!.GetValue<int>());
        return document;
    }

    private static VoiceRewriteRequest Rewrite(double targetSeconds = 4.1, int minChars = 10, int maxChars = 12) =>
        new(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "Hello", 0, 0.5)], "Improve it", "en", targetSeconds, minChars, maxChars);

    private static async Task<VoiceRewriteProposal> Propose(VoiceRewriteService service, VoiceRewriteRequest request, CapturingLlmConnector connector,
        string model = "chosen")
    {
        var approval = service.Approve(await service.PrepareAsync(request, connector, model, TestContext.Current.CancellationToken), true);
        return await service.ProposeAsync(request, connector, model, approval, TestContext.Current.CancellationToken);
    }

    /// <summary>Copies the catalogue and one prompt into a new shared root, so a test may change the prompt file.</summary>
    internal static DirectoryInfo SharedCopy(string prompt)
    {
        var root = Directory.CreateTempSubdirectory("voxclip-prompt-binding-");
        foreach (var relative in new[] { "catalog/llm-providers.json", prompt })
        {
            var target = Path.Combine(root.FullName, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(Path.Combine(FixtureLoader.SharedRoot, relative), target);
        }
        return root;
    }

    /// <summary>ai.md §12.8: the shared answering-model rows of <c>rewrite-checks-cases.json</c>, which every service replays.</summary>
    public static TheoryData<ConnectorId, string, string, bool> Answers()
    {
        var rows = new TheoryData<ConnectorId, string, string, bool>();
        foreach (var row in VoiceLabFixture("rewrite-checks-cases.json")["answeredBy"]!.AsArray())
            rows.Add(Connector(row!["connector"]!.GetValue<string>()), row["selected"]!.GetValue<string>(), row["answered"]!.GetValue<string>(), row["accepted"]!.GetValue<bool>());
        return rows;
    }

    internal static ConnectorId Connector(string wire) => Enum.GetValues<ConnectorId>().Single(id => LlmCatalog.WireId(id) == wire);

    /// <summary>A refusal, then truncation, after the model check, with the shared "declined to rewrite" copy (ai.md §12.8).</summary>
    public static TheoryData<string, string, LlmErrorKind, string> Stops() => new()
    {
        { "refused", "chosen", LlmErrorKind.Refused, "The model declined to rewrite this recording. Your edits are saved." },
        { "truncated", "chosen", LlmErrorKind.Truncated, "The rewrite was incomplete. Please try again. Your edits are saved." },
        { "refused", "other", LlmErrorKind.InvalidOutput, "The model's answer wasn't in the expected format. Try again or pick another model. Your edits are saved." }
    };

    internal static StopKind Stop(string stop) => stop == "refused" ? new StopKind.Refused("cyber") : new StopKind.Truncated();

    [Fact]
    public void SharedTextLengthCases()
    {
        var cases = VoiceLabFixture("text-length-cases.json")["cases"]!.AsArray();
        Assert.Equal(39, cases.Count);
        foreach (var item in cases)
        {
            var id = item!["id"]!.GetValue<string>();
            var text = item["text"]!.GetValue<string>();
            Assert.True(string.Join(' ', text.EnumerateRunes().Select(rune => $"U+{rune.Value:X4}")) == item["scalars"]!.GetValue<string>(), id + ": decoded scalars");
            Assert.True(item["length"]!.GetValue<int>() == VoiceLabTextLength.Length(text), id);
        }
    }

    /// <summary><c>rewrite-checks-cases.json</c> (ai.md §12.8): the answering model, the model id, the output cap and the context
    /// fit, each just below, at and just above its bound. Model ids also go through both services' prepare.</summary>
    [Fact]
    public async Task SharedRewriteChecks()
    {
        var document = VoiceLabFixture("rewrite-checks-cases.json");
        var catalog = Catalog();
        var factor = catalog.Data["policy"]!["tokenEstimate"]!["contextSafetyFactor"]!.GetValue<double>();
        Assert.Equal(factor, document["contextSafetyFactor"]!.GetValue<double>());
        var answers = document["answeredBy"]!.AsArray();
        Assert.Equal(37, answers.Count);
        foreach (var row in answers)
            Assert.True(row!["accepted"]!.GetValue<bool>() == VoiceLabLlmChecks.AnsweredBy(Connector(row["connector"]!.GetValue<string>()),
                row["selected"]!.GetValue<string>(), row["answered"]!.GetValue<string>()), row["id"]!.GetValue<string>());
        var models = document["modelIds"]!.AsArray();
        Assert.Equal(16, models.Count);
        var rewrites = new VoiceRewriteService(catalog);
        var patches = new PatchRewriteService(catalog);
        var patch = PatchRewriteServiceTests.Request(PatchRewriteServiceTests.Cases());
        foreach (var row in models)
        {
            var id = row!["id"]!.GetValue<string>();
            var model = row["model"]!.GetValue<string>();
            var valid = row["valid"]!.GetValue<bool>();
            Assert.True(valid == VoiceLabLlmChecks.IsValidModel(model), id);
            foreach (var prepare in new Func<Task>[]
            {
                () => rewrites.PrepareAsync(Rewrite(), new CapturingLlmConnector("{}", models: [model]), model, TestContext.Current.CancellationToken),
                () => patches.PrepareAsync(patch, new CapturingLlmConnector("{}", models: [model]), model, TestContext.Current.CancellationToken)
            })
            {
                if (valid) await prepare();
                else Assert.True((await Assert.ThrowsAsync<VoiceLabException>(prepare)).Kind == VoiceLabErrorKind.InvalidInput, id);
            }
        }
        var caps = document["outputCaps"]!.AsArray();
        Assert.Equal(12, caps.Count);
        foreach (var row in caps)
            Assert.True(row!["maxOutputTokens"]?.GetValue<int>() == VoiceLabLlmChecks.MaxOutputTokens(row["sourceTokens"]!.GetValue<int>(),
                row["promptCap"]!.GetValue<int>(), row["connectorCap"]?.GetValue<int>()), row["id"]!.GetValue<string>());
        var contexts = document["contexts"]!.AsArray();
        Assert.Equal(12, contexts.Count);
        foreach (var row in contexts)
            Assert.True(row!["fits"]!.GetValue<bool>() == VoiceLabLlmChecks.ContextFits(row["context"]!.GetValue<int>(), row["required"]!.GetValue<int>(), factor),
                row["id"]!.GetValue<string>());
    }

    /// <summary>ai.md §12.8: the output cap is checked when the quote is prepared. Apple caps output at 1,500 tokens, and this
    /// 3,999-byte source is ⌈3,999 / 2.2⌉ = 1,818 tokens.</summary>
    [Fact]
    public async Task OutputCapIsCheckedWhenTheQuoteIsPrepared()
    {
        var words = Enumerable.Range(0, 400).Select(index => Word(index, "abcdefghi", index, index + 0.5) with { Id = "w" + index }).ToArray();
        var request = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.FullTake, words, "", "en", 120, 1, 5000);
        var service = new VoiceRewriteService(Catalog());
        var refused = await Assert.ThrowsAsync<LlmException>(() => service.PrepareAsync(request, new CapturingLlmConnector("{}", ConnectorId.AppleFoundation, models: ["system"]),
            "system", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.ContextTooLong, refused.Error.Kind);
        await service.PrepareAsync(request, new CapturingLlmConnector("{}"), "chosen", TestContext.Current.CancellationToken);
    }

    /// <summary>Voice Lab §3.1: an LLM send's quote has basis <c>unknown</c> and no price, so it reaches the no-price confirmation.</summary>
    [Fact]
    public async Task QuoteWithoutAPriceAsksForConfirmation()
    {
        var rewrite = (await new VoiceRewriteService(Catalog()).PrepareAsync(Rewrite(), new CapturingLlmConnector("{}"), "chosen", TestContext.Current.CancellationToken)).Estimate;
        var patch = (await new PatchRewriteService(Catalog()).PrepareAsync(PatchRewriteServiceTests.Request(PatchRewriteServiceTests.Cases()), new CapturingLlmConnector("{}"),
            "chosen", TestContext.Current.CancellationToken)).Estimate;
        foreach (var (estimate, operation) in new[] { (rewrite, "voiceRewrite"), (patch, "patchRewrite") })
        {
            var cost = estimate.ToCostEstimate();
            Assert.Equal(new CostEstimate("openai", operation, estimate.Units, "token", null, null, "unknown"), cost);
            Assert.Equal(new VoiceLabCostPresentationResult(VoiceLabCostPresentationKind.Confirm, "VoxClip can't tell what this costs. Check OpenAI's pricing."),
                VoiceLabCostPresentation.Kind(cost, false, "OpenAI"));
        }
    }

    [Fact]
    public void NfcKeepsANoncharacterAndMakesAnUnpairedSurrogateTheReplacementCharacter()
    {
        // .NET's Normalize throws on an unpaired surrogate and on U+FFFE. A Swift string holds U+FFFD for the first and keeps
        // U+FFFE, a starter in no composition, so the runs around it are normalised on their own.
        var text = "a" + (char)0xD800 + "b" + (char)0xDC00 + (char)0xFFFE + "c";
        Assert.Equal(3, VoiceLabTextLength.Length(text));
        Assert.Equal("a" + (char)0xFFFD + "b" + (char)0xFFFD + (char)0xFFFE + "c", EditingAlgorithms.Nfc(text));
        Assert.Equal("x" + (char)0xFFFE + (char)0x301 + "y", EditingAlgorithms.Nfc("x" + (char)0xFFFE + (char)0x301 + "y"));
        Assert.Equal("" + (char)0xE9 + (char)0xFFFE + (char)0xE9, EditingAlgorithms.Nfc("e" + (char)0x301 + (char)0xFFFE + "e" + (char)0x301));
        Assert.Equal("a" + (char)0xFFFF + "b", EditingAlgorithms.Nfc("a" + (char)0xFFFF + "b"));
        // Hangul: a precomposed LV syllable takes a trailing consonant; U+11A7 and U+11C3 are no trailing consonants.
        Assert.Equal("" + (char)0xAC01, EditingAlgorithms.Nfc("" + (char)0xAC00 + (char)0x11A8));
        Assert.Equal("" + (char)0xAC00 + (char)0x11A7, EditingAlgorithms.Nfc("" + (char)0x1100 + (char)0x1161 + (char)0x11A7));
        Assert.Equal("" + (char)0xAC00 + (char)0x11C3, EditingAlgorithms.Nfc("" + (char)0xAC00 + (char)0x11C3));
    }

    [Fact]
    public void ImportAndTightenReadANoncharacter()
    {
        var cleaned = Assert.Single(EditingImport.CleanWords([new RawWord("ok" + (char)0xFFFE, 0, 0.5, null, null, WordKind.Word)]));
        Assert.Equal("ok" + (char)0xFFFE, cleaned.Text);
        var entries = new[] { new ClipWord(40, "so" + (char)0xFFFE, 0, 1), new ClipWord(41, "yes.", 1, 2) };
        var edit = new JsonObject { ["line"] = "[40-41]", ["keep"] = "yes", ["kind"] = "filler" };
        var result = TightenVerifier.Verify(new JsonArray(edit), entries, Words(42), new ClipPrompts(Catalog()).Tighten);
        Assert.Equal(["w40"], Assert.Single(result.Proposals).CutWordIds);
    }

    [Theory]
    [MemberData(nameof(Answers))]
    public async Task OnlyTheQuotedModelMayAnswer(ConnectorId connectorId, string selected, string answered, bool accepted)
    {
        var connector = new CapturingLlmConnector("{\"rewrite\":\"Hello there\"}", connectorId, answered, models: [selected]);
        var service = new VoiceRewriteService(Catalog());
        if (accepted) Assert.Equal(answered, (await Propose(service, Rewrite(), connector, selected)).Model);
        else Assert.Equal(LlmErrorKind.InvalidOutput, (await Assert.ThrowsAsync<LlmException>(() => Propose(service, Rewrite(), connector, selected))).Error.Kind);
        Assert.Single(connector.Requests);
    }

    [Theory]
    [MemberData(nameof(Stops))]
    public async Task StopIsATypedErrorAfterTheModelCheck(string stop, string answered, LlmErrorKind kind, string message)
    {
        var connector = new CapturingLlmConnector("{\"rewrite\":\"Hello there\"}", answered: answered, stop: Stop(stop));
        var error = (await Assert.ThrowsAsync<LlmException>(() => Propose(new VoiceRewriteService(Catalog()), Rewrite(), connector))).Error;
        Assert.Equal(kind, error.Kind);
        Assert.Equal(message, error.UserMessage);
    }

    [Fact]
    public async Task QuoteBindsThePromptFileButNotItsLineEndings()
    {
        var root = SharedCopy("prompts/voice-rewrite.json");
        try
        {
            var path = Path.Combine(root.FullName, "prompts", "voice-rewrite.json");
            var original = File.ReadAllText(path);
            Assert.StartsWith("{", original, StringComparison.Ordinal);
            Assert.DoesNotContain('\r', original);
            var service = new VoiceRewriteService(new LlmCatalog(root.FullName));
            var connector = new CapturingLlmConnector("{\"rewrite\":\"Hello there\"}");
            var request = Rewrite();
            var approval = service.Approve(await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken), true);
            Task Send() => service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
            // One more space changes no rendered field, yet the quote is for other prompt bytes, so nothing is sent.
            File.WriteAllText(path, "{ " + original[1..]);
            Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(Send)).Kind);
            Assert.Empty(connector.Requests);
            // CRLF line endings are the same prompt, so the unused quote still sends.
            File.WriteAllText(path, original.ReplaceLineEndings("\r\n"));
            await Send();
            Assert.Single(connector.Requests);
        }
        finally
        {
            root.Delete(true);
        }
    }

    public static TheoryData<double, int, int> InvalidBudgets() => new()
    {
        { 0, 10, 12 }, { -1, 10, 12 }, { double.NaN, 10, 12 }, { double.PositiveInfinity, 10, 12 }, { Math.BitIncrement(600), 10, 12 },
        { 4.1, 0, 12 }, { 4.1, 13, 12 }, { 4.1, 10, 5001 }
    };

    [Theory]
    [MemberData(nameof(InvalidBudgets))]
    public async Task BudgetOutsideItsBoundsIsInvalidInput(double targetSeconds, int minChars, int maxChars)
    {
        var service = new VoiceRewriteService(Catalog());
        var connector = new CapturingLlmConnector("{\"rewrite\":\"Hello\"}");
        var request = Rewrite(targetSeconds, minChars, maxChars);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken))).Kind);
        var approval = service.Approve(await service.PrepareAsync(Rewrite(), connector, "chosen", TestContext.Current.CancellationToken), true);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken))).Kind);
        Assert.Empty(connector.Requests);
    }

    [Theory]
    [InlineData(600, 5000, 5000)]
    [InlineData(double.Epsilon, 1, 1)]
    [InlineData(0.05, 1, 5000)]
    public async Task BudgetBoundsAreInclusive(double targetSeconds, int minChars, int maxChars)
    {
        var service = new VoiceRewriteService(Catalog());
        await service.PrepareAsync(Rewrite(targetSeconds, minChars, maxChars), new CapturingLlmConnector("{}"), "chosen", TestContext.Current.CancellationToken);
    }

    [Theory]
    [InlineData(17, 17, true)]
    [InlineData(18, 30, false)]
    [InlineData(1, 16, false)]
    public async Task ProposalCarriesCoresOwnLengthInsideOrOutsideTheRange(int minChars, int maxChars, bool inRange)
    {
        // 4 + 3 + 6 + 4 letters and digits; the second word has a precomposed O-tilde and the third a decomposed o-tilde.
        var text = "Tere, " + (char)0xD5 + "ie! To" + (char)0x303 + "esti 2025.";
        var service = new VoiceRewriteService(Catalog());
        var connector = new CapturingLlmConnector(new JsonObject { ["rewrite"] = text }.ToJsonString());
        var request = Rewrite(2.5, minChars, maxChars);
        var approval = service.Approve(await service.PrepareAsync(request, connector, "chosen", TestContext.Current.CancellationToken), true);
        var proposal = await service.ProposeAsync(request, connector, "chosen", approval, TestContext.Current.CancellationToken);
        Assert.Equal(text, proposal.ProposedText);
        Assert.Equal(17, proposal.ProposedLength);
        Assert.Equal(inRange, proposal.InRange);
        Assert.EndsWith($"about 2.5 seconds to say, which is {minChars} to {maxChars} letters and digits. Spaces and punctuation are not counted. Write natural wording that stays inside this range.",
            Assert.Single(connector.Requests).Instruction, StringComparison.Ordinal);
    }

    [Fact]
    public void LengthTemplateWithoutItsPlaceholdersIsAMissingResource()
    {
        var prompt = Catalog().ReadAsset("prompts/voice-rewrite.json");
        prompt["request"]!["lengthLine"] = "Keep it short.";
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing,
            Assert.Throws<VoxClipException>(() => VoiceRewriteService.RequestText(Rewrite(), "Hello", prompt)).Code);
    }
}
