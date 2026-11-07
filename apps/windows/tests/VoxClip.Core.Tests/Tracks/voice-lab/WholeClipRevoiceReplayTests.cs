using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Replays shared/fixtures/voice-lab/whole-clip-revoice-cases.json (ADR-R46), as the Swift WholeClipRevoiceReplayTests do: the
/// switch rule at its edges, Claude mode's choice within the cap, the script with edits applied, its parts and hunks, the fit and its copy,
/// the price from the tables, and the ledger that never pays twice. Mac <c>WholeClipRevoiceTests</c>.</summary>
public sealed class WholeClipRevoiceReplayTests
{
    private static readonly JsonObject Cases = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/whole-clip-revoice-cases.json"))!.AsObject();
    private static JsonArray Rows(string name) => Cases[name]!.AsArray();
    private static VoiceLabPriceCatalog Catalog() => VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(FixtureLoader.SharedRoot, "catalog/voice-lab.json")));
    private static decimal? Money(JsonNode? node) => node is null ? null : decimal.Parse(node.GetValue<string>(), CultureInfo.InvariantCulture);
    private static string Canonical(decimal value) => value.ToString(CultureInfo.InvariantCulture) is var text && text.Contains('.') ? text.TrimEnd('0').TrimEnd('.') : value.ToString(CultureInfo.InvariantCulture);

    [Fact]
    public void FormatAndConstantsAreTheMacs()
    {
        Assert.Equal("voxclip-whole-clip-revoice/1", Cases["format"]!.GetValue<string>());
        Assert.Equal(["format", "constants", "rule", "autoChoice", "script", "fit", "price", "ledger"], Cases.Select(pair => pair.Key));
        var constants = Cases["constants"]!;
        Assert.Equal(WholeClipRevoice.WordSharePercent, constants["wordSharePercent"]!.GetValue<int>());
        Assert.Equal(WholeClipRevoice.NoFitPhrases, constants["noFitPhrases"]!.GetValue<int>());
        Assert.Equal(WholeClipRevoice.FitTolerance, constants["fitTolerance"]!.GetValue<double>());
        Assert.Equal(WholeClipRevoice.MaximumRewordRounds, constants["maximumRewordRounds"]!.GetValue<int>());
        Assert.Equal(WholeClipRevoice.MaximumPartSeconds, constants["maximumPartSeconds"]!.GetValue<double>());
        Assert.Equal(WholeClipRevoice.MaximumPartCharacters, constants["maximumPartCharacters"]!.GetValue<int>());
        Assert.Equal(WholeClipRevoice.MaximumClipSeconds, constants["maximumClipSeconds"]!.GetValue<double>());
        Assert.Equal(WholeClipLipsyncValues.Standard.RawValue(), constants["standardLipsync"]!.GetValue<string>());
        var models = constants["lipsyncModels"]!.AsArray();
        Assert.Equal(WholeClipLipsyncValues.All.Count, models.Count);
        foreach (var (model, row) in WholeClipLipsyncValues.All.Zip(models))
        {
            Assert.Equal(row!["rawValue"]!.GetValue<string>(), model.RawValue());
            Assert.Equal(row["endpoint"]!.GetValue<string>(), model.Endpoint());
            Assert.Equal(row["model"]?.GetValue<string>(), model.Model());
            Assert.Equal(row["name"]!.GetValue<string>(), model.Name());
            Assert.Equal(model, WholeClipLipsyncValues.FromRawValue(model.RawValue()));
        }
    }

    [Fact]
    public void TheSwitchRuleAndItsCallout()
    {
        Assert.Equal(16, Rows("rule").Count);
        foreach (var row in Rows("rule"))
        {
            var inputs = new WholeClipRevoice.RuleInputs(row!["spokenWords"]!.GetValue<int>(), row["revoicedWords"]!.GetValue<int>(), row["noFitPhrases"]!.GetValue<int>());
            var found = WholeClipRevoice.ReasonFor(inputs);
            WholeClipRevoice.Reason? expected = row["reason"] is not { } reason ? null : reason["kind"]!.GetValue<string>() == "manyWords"
                ? new WholeClipRevoice.Reason.ManyWords(reason["revoiced"]!.GetValue<int>(), reason["spoken"]!.GetValue<int>())
                : new WholeClipRevoice.Reason.PhrasesCantFit(reason["count"]!.GetValue<int>());
            Assert.Equal(expected, found);
            Assert.Equal(row["callout"]?.GetValue<string>(), found is null ? null : WholeClipRevoice.Callout(found));
        }
        Assert.Equal("These changes re-voice 58 words, a lot for a 74-word clip. Long stretches in your voice can sound stitched.",
            WholeClipRevoice.Callout(new WholeClipRevoice.Reason.ManyWords(58, 74)));
    }

    [Fact]
    public void ClaudeModeRevoicesOnlyWithinTheCapAndOffersOverIt()
    {
        Assert.Equal(10, Rows("autoChoice").Count);
        foreach (var row in Rows("autoChoice"))
        {
            WholeClipRevoice.Reason? reason = row!["stitched"]!.GetValue<bool>() ? new WholeClipRevoice.Reason.ManyWords(58, 74) : null;
            var choice = WholeClipRevoice.Choose(reason, Money(row["price"]), Money(row["remaining"]));
            var expected = row["expected"]!;
            WholeClipRevoice.AutoChoice wanted = expected["kind"]!.GetValue<string>() switch
            {
                "patch" => new WholeClipRevoice.AutoChoice.Patch(),
                "revoice" => new WholeClipRevoice.AutoChoice.Revoice(Money(expected["price"])!.Value),
                _ => new WholeClipRevoice.AutoChoice.PatchAndOffer(Money(expected["price"])!.Value)
            };
            Assert.Equal(wanted, choice);
        }
    }

    private static TimedWord Word(JsonNode node) => new(node["id"]!.GetValue<string>(), node["text"]!.GetValue<string>(),
        node["kind"]!.GetValue<string>() switch { "word" => WordKind.Word, "event" => WordKind.Event, _ => WordKind.UnlabeledSpeech },
        node["start"]!.GetValue<double>(), node["end"]!.GetValue<double>(), null, null, null, null, TimingSource.Native);

    private static string[] Strings(JsonNode? node) => node!.AsArray().Select(item => item!.GetValue<string>()).ToArray();

    [Fact]
    public void TheScriptItsPartsAndTheirVoiceChanges()
    {
        Assert.Equal(17, Rows("script").Count);
        foreach (var row in Rows("script"))
        {
            var id = row!["id"]!.GetValue<string>();
            var words = row["words"]!.AsArray().Select(node => Word(node!)).ToArray();
            var hunks = row["voiceHunks"]!.AsArray().Select(node => new VoiceLabDiffHunk(VoiceLabDiffHunkKind.Voice, Strings(node!["sourceWordIds"]),
                EditingAlgorithms.SplitWords(node["newText"]!.GetValue<string>()), [], [], [], 0, 0, null)).ToArray();
            var script = WholeClipScript.Assemble(words, Strings(row["cutWordIds"]).ToHashSet(StringComparer.Ordinal), hunks);
            if (row["expected"] is not { } expected) { Assert.True(script is null, id); continue; }
            Assert.NotNull(script);
            Assert.Equal(expected["text"]!.GetValue<string>(), script.Text);
            Assert.True(expected["words"]!.GetValue<int>() == script.Words, id);
            Assert.True(expected["characters"]!.GetValue<int>() == script.Characters, id);
            var sentences = expected["sentences"]!.AsArray();
            Assert.True(sentences.Count == script.Sentences.Count, id);
            foreach (var (want, have) in sentences.Zip(script.Sentences))
            {
                Assert.Equal(want!["text"]!.GetValue<string>(), have.Text);
                Assert.Equal(Strings(want["sourceWordIds"]), have.SourceWordIds);
                Assert.True(want["start"]!.GetValue<double>() == have.Start && want["end"]!.GetValue<double>() == have.End, id);
            }
            var parts = expected["parts"]!.AsArray();
            Assert.True(parts.Count == script.Parts.Count, id);
            foreach (var (want, have) in parts.Zip(script.Parts))
            {
                Assert.Equal(want!["text"]!.GetValue<string>(), have.Text);
                Assert.True(want["words"]!.GetValue<int>() == have.Words, id);
                Assert.Equal(Strings(want["sourceWordIds"]), have.SourceWordIds);
                Assert.True(want["start"]!.GetValue<double>() == have.Start && want["end"]!.GetValue<double>() == have.End, id);
            }
            var expectedHunks = expected["hunks"]!.AsArray();
            var made = script.Hunks(words);
            Assert.True(expectedHunks.Count == made.Count, id);
            foreach (var (want, have) in expectedHunks.Zip(made))
            {
                Assert.Equal(VoiceLabDiffHunkKind.Voice, have.Kind);
                Assert.Equal(Strings(want!["sourceWordIds"]), have.SourceWordIds);
                Assert.Equal(Strings(want["newTokens"]), have.NewTokens);
                Assert.Equal(Strings(want["absorbedItemIds"]), have.AbsorbedItemIds);
                Assert.True(want["sourceStartIndex"]!.GetValue<int>() == have.SourceStartIndex && want["sourceEndIndex"]!.GetValue<int>() == have.SourceEndIndex, id);
                Assert.Empty(have.CorrectedTexts); Assert.Empty(have.BridgeWordIds); Assert.Null(have.AnchorSeconds);
            }
        }
    }

    [Fact]
    public void TheFitAndItsCopy()
    {
        Assert.Equal(20, Rows("fit").Count);
        foreach (var row in Rows("fit"))
        {
            var voice = row!["voiceSeconds"]!.GetValue<double>(); var video = row["videoSeconds"]!.GetValue<double>();
            var fit = WholeClipRevoice.FitVoice(voice, video, row["words"]!.GetValue<int>(), row["round"]!.GetValue<int>());
            var expected = row["expected"]!;
            switch (expected["kind"]!.GetValue<string>())
            {
                case "matched":
                    var matched = Assert.IsType<WholeClipRevoice.Fit.Matched>(fit);
                    Assert.Equal(expected["factor"]!.GetValue<double>(), matched.Factor);
                    Assert.Equal(expected["copy"]!.GetValue<string>(), WholeClipRevoice.MatchedCopy(matched.Factor));
                    break;
                case "reword":
                    Assert.Equal(new WholeClipRevoice.Fit.Reword(expected["shorter"]!.GetValue<bool>(), expected["targetWords"]!.GetValue<int>()), fit);
                    break;
                default:
                    Assert.Equal(new WholeClipRevoice.Fit.CannotFit(voice, video), fit);
                    break;
            }
        }
    }

    [Fact]
    public void PricesComeFromTheTables()
    {
        var catalog = Catalog();
        Assert.Equal(8, Rows("price").Count);
        foreach (var row in Rows("price"))
        {
            var lipsync = WholeClipLipsyncValues.FromRawValue(row!["lipsync"]!.GetValue<string>())!.Value;
            var price = WholeClipRevoice.PriceFor(row["characters"]!.GetValue<int>(), row["ttsModel"]!.GetValue<string>(), row["videoSeconds"]!.GetValue<double>(), lipsync, catalog);
            var expected = row["expected"]!;
            Assert.Equal(Money(expected["voiceUsd"]), price.Voice.Usd);
            Assert.Equal(Money(expected["lipsyncUsd"]), price.Lipsync.Usd);
            Assert.Equal(Money(expected["usd"]), price.Usd);
        }
        // sync-3 at $8 a minute: 31 s is $4.1333…, shown with the shared formatter's two significant digits.
        Assert.Equal("≈ $4.10", VoiceLabCostPresentation.Format(WholeClipRevoice.LipsyncPrice(31, WholeClipLipsync.Sync3, catalog).Usd!.Value));
        // Every model a whole clip may use has a row in the tables.
        Assert.All(WholeClipLipsyncValues.All, model => Assert.NotNull(WholeClipRevoice.LipsyncPrice(1, model, catalog).Usd));
        Assert.All(WholeClipLipsyncValues.All, model => Assert.Equal(model.RawValue(), model.LipsyncModel().Id));
    }

    private static WholeClipRevoiceLedger.VoiceKey VoiceKey(JsonNode node) => new(node["script"]!.GetValue<string>(), node["recordId"]!.GetValue<string>(), node["model"]!.GetValue<string>());
    private static WholeClipRevoiceLedger.LipsyncKey? LipsyncKey(JsonNode? node) => node is null ? null
        : new(VoiceKey(node["voice"]!), node["retime"]!.GetValue<double>(), WholeClipLipsyncValues.FromRawValue(node["model"]!.GetValue<string>())!.Value);

    [Fact]
    public void APaidStepIsNeverPaidAgain()
    {
        foreach (var row in Rows("ledger"))
        {
            var ledger = new WholeClipRevoiceLedger();
            foreach (var step in row!["steps"]!.AsArray())
            {
                if (step!["total"] is { } total) Assert.Equal(Money(total), ledger.Total);
                else if (step["recordVoice"] is { } voice) ledger.Record(VoiceKey(voice), Money(step["usd"])!.Value);
                else if (step["recordLipsync"] is { } lipsync) ledger.Record(LipsyncKey(lipsync)!, Money(step["usd"])!.Value);
                else if (step["paidVoice"] is { } paidVoice) Assert.Equal(step["expected"]!.GetValue<bool>(), ledger.Paid(VoiceKey(paidVoice)));
                else if (step["paidLipsync"] is { } paidLipsync) Assert.Equal(step["expected"]!.GetValue<bool>(), ledger.Paid(LipsyncKey(paidLipsync)!));
                else
                {
                    var asked = step["remaining"]!;
                    var due = ledger.Remaining(VoiceKey(asked["voice"]!), Money(asked["voiceUsd"])!.Value, LipsyncKey(asked["lipsync"]), Money(asked["lipsyncUsd"])!.Value);
                    Assert.Equal(step["expected"]!.GetValue<string>(), Canonical(due));
                }
            }
        }
    }
}
