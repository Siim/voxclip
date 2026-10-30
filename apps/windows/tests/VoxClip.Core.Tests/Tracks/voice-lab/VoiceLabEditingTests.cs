using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabEditingTests
{
    private sealed class Fixture
    {
        internal readonly Project Project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        internal readonly VoiceConsentRecord Consent = JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"), VoiceConsentJson.Default.VoiceConsentRecord)!;
        internal readonly VoiceLabTakeInput Input;
        internal readonly VoiceLabTakeRow Row;
        internal readonly VoiceLabPublishedTake Published;
        internal readonly VoiceLabVoiceReference Voice;
        internal readonly DateTimeOffset Date = DateTimeOffset.FromUnixTimeSeconds(1800000000);
        internal Fixture(bool fitted = false)
        {
            var stored = Project.VoiceLab.Segments[0];
            var asset = Project.VoiceLab.Assets![0];
            var audio = stored.Audio with { Stretch = 1 };
            var assets = new List<VoiceLabAsset> { asset };
            if (fitted)
            {
                var derived = asset with { Id = "fitted-test", File = VoiceLabAssetNaming.File(Project.Id, "fitted-test", "wav") };
                assets.Add(derived); audio = audio with { AssetId = derived.Id };
            }
            var window = new VoiceLabWindow(stored.Replace.FirstWordId, stored.Replace.LastWordId, [], [], 2.5, 3.2, 2500, 3200,
                new(VoiceLabSeamKind.Gap, 2.5, 2500, 20), new(VoiceLabSeamKind.Gap, 3.2, 3200, 20));
            var words = stored.Words!;
            var plan = new VoiceLabFitPlan([], new(0, 0), new(0, 0), 2400, 19200, 2.5, 3.2, 2500, 3200, 16800, words);
            Input = new("new words", "fixture-model", Consent.RecordId, "en", 7, Project.Media.Source.ContentKey, [], 1000,
                Project.Transcript!.Words, new HashSet<string>(), window, null, null, false, true);
            var take = new VoiceLabTakeAudio(24000, [], [], 0, 0, [], 0, stored.Candidates[0].Recipe!.RoomTone, new VoiceLabFitResult.Exact(plan));
            var gate = new VoiceLabActionGate();
            var quote = gate.Prepare("fixture", new("elevenlabs", VoiceLabOperation.TextToSpeech, 1, "test", 0.1m, null, "test"),
                new(VoiceLabOperation.TextToSpeech, Guid.NewGuid(), "elevenlabs", ElevenLabsRegion.Default, "/v1/text-to-speech/fixture/with-timestamps", Input.ModelId, Consent.VoiceId, null, null, Consent.RecordId));
            var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, quote.Review.Endpoint, Input.ModelId, Consent.VoiceId, quote.Review.RequestId, null, null);
            Row = new(quote.Review.RequestId, 0, 7, receipt, Quote: new(0, 7, quote, quote), Audio: take,
                Qa: new(stored.Qa.TranscriptMatch!.Value, stored.Qa.LufsJumpLu!.Value, stored.Qa.PeakDbfs!.Value, stored.Qa.SpeakerScore, []), Score: 0.9);
            Published = new(assets, audio, 3.2 - 2.5, words, stored.Candidates[0].Recipe!.Chunks);
            Voice = new(Consent.RecordId, Consent.Provider, Consent.VoiceId, Consent.RecordId, Consent.VoiceName, VoiceLabVoiceStatus.Active);
        }
        internal Project Empty => Project with { SchemaVersion = 1, VoiceLab = new([]) };
        internal VoiceLabCandidate Candidate() => VoiceLabRecipeBuilder.Candidate(Row, Input, Published, Consent, Date);
        internal VoiceLabSegment Segment() => VoiceLabRecipeBuilder.Segment("accepted-test", [Candidate()], 0, Input, Row.Audio!.Fit.Plan);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void PaidAndFittedRecipesRoundTripWithoutSourceMutation(bool fitted)
    {
        var fixture = new Fixture(fitted);
        var candidate = fixture.Candidate();
        Assert.Equal(fitted ? "fitted-test" : fixture.Published.Assets[0].Id, candidate.AssetId);
        Assert.Equal(fixture.Published.Assets[0].Id, candidate.Recipe!.Chunks[0].AssetId);
        Assert.Equal(0.2, candidate.Recipe.Cost.Usd);
        var accepted = new VoiceLabEditCommand.Accept(fixture.Segment(), fixture.Published.Assets, fixture.Voice).ApplyingTo(fixture.Empty);
        VoiceLabProject.Validate(accepted);
        Assert.Same(fixture.Project.Transcript, accepted.Transcript);
        Assert.Same(fixture.Project.Edits, accepted.Edits);
        var json = ProjectSerialization.Serialize(accepted);
        Assert.Equal(json, ProjectSerialization.Serialize(ProjectSerialization.Deserialize(json)));
        Assert.Equal(VoiceLabVideoMode.Source, candidate.Recipe.Video.Mode);
        foreach (var duration in new[] { double.PositiveInfinity, double.NaN, double.MaxValue, -1 })
            Assert.Throws<VoiceLabProjectException>(() => VoiceLabRecipeBuilder.Candidate(fixture.Row, fixture.Input, fixture.Published with { OutDuration = duration }, fixture.Consent, fixture.Date));
        Assert.Throws<VoiceLabProjectException>(() => VoiceLabRecipeBuilder.Candidate(fixture.Row with { Qa = fixture.Row.Qa! with { Failures = [VoiceLabTakeQaFailure.Speaker] } }, fixture.Input, fixture.Published, fixture.Consent, fixture.Date));
    }
    [Fact]
    public void ChangedDurationRequiresExplicitZoomCoverWithStoredFaceCenter()
    {
        var fixture = new Fixture();
        var plan = fixture.Row.Audio!.Fit.Plan with { TrimEndFrame = 20400, OutputFrames = 18000 };
        var row = fixture.Row with { Audio = fixture.Row.Audio with { Fit = new VoiceLabFitResult.ChangedDuration(plan, 0.75, 0.05) } };
        var published = fixture.Published with { OutDuration = 0.75, Audio = fixture.Published.Audio with { TrimEnd = 0.85 },
            Chunks = [fixture.Published.Chunks[0] with { AssembledEndFrame = 20400 }] };
        foreach (var choice in new VoiceLabVideoMode?[] { null, VoiceLabVideoMode.Retimed, VoiceLabVideoMode.Lipsync })
            Assert.Throws<VoiceLabProjectException>(() => VoiceLabRecipeBuilder.Candidate(row, fixture.Input, published, fixture.Consent, fixture.Date, choice, new(0.4, 0.6)));
        var candidate = VoiceLabRecipeBuilder.Candidate(row, fixture.Input, published, fixture.Consent, fixture.Date, VoiceLabVideoMode.ZoomCover, new(0.4, 0.6));
        Assert.Equal(VoiceLabVideoMode.ZoomCover, candidate.Recipe!.Video.Mode);
        Assert.Equal(1.12, candidate.Recipe.Video.Zoom);
        Assert.Equal(0.4, candidate.Recipe.Video.FaceX);
        var segment = VoiceLabRecipeBuilder.Segment("changed", [candidate], 0, fixture.Input, plan);
        VoiceLabProject.Validate(new VoiceLabEditCommand.Accept(segment, published.Assets, fixture.Voice).ApplyingTo(fixture.Empty));
    }
    [Fact]
    public void SemanticNoOpsKeepHistoryRedoDirtyStateAndTimestamp()
    {
        var fixture = new Fixture(true);
        var accepted = new VoiceLabEditHistory(fixture.Empty).Apply(new VoiceLabEditCommand.Accept(fixture.Segment(), fixture.Published.Assets, fixture.Voice));
        var history = accepted.Apply(new VoiceLabEditCommand.SetEnabled("accepted-test", false)).Undo();
        Assert.Same(history, history.Apply(new VoiceLabEditCommand.SetEnabled("accepted-test", true)));
        Assert.Same(history, history.Apply(new VoiceLabEditCommand.ChooseCandidate("accepted-test", 0), history.Present.ModifiedAt.AddSeconds(1)));
        var changed = history.Apply(new VoiceLabEditCommand.SetEnabled("accepted-test", false));
        Assert.True(changed.Present.ModifiedAt > history.Present.ModifiedAt);
        Assert.Same(history.Present, changed.Undo().Present);
        Assert.Same(changed.Present, changed.Undo().Redo().Present);
        Assert.Throws<ArgumentOutOfRangeException>(() => history.Apply(new VoiceLabEditCommand.Delete("accepted-test"), history.Present.ModifiedAt));
        Assert.Throws<ArgumentOutOfRangeException>(() => history.Apply(new VoiceLabEditCommand.Delete("accepted-test"), history.Present.ModifiedAt.AddTicks(-1)));
    }
    [Fact]
    public void CommandsUseExactProjectSnapshotsAndSingleUndoSteps()
    {
        var fixture = new Fixture(true);
        var history = new VoiceLabEditHistory(fixture.Empty).Apply(new VoiceLabEditCommand.Accept(fixture.Segment(), fixture.Published.Assets, fixture.Voice));
        Assert.Single(history.UndoStack);
        Assert.Equal("Accept Voice Lab take", history.UndoActionName);
        Assert.Same(history.UndoStack[0].Before, history.Undo().Present);
        Assert.Same(history.Present, history.Undo().Redo().Present);
        Assert.Equal(1, history.Undo().Present.SchemaVersion);
        var disabled = history.Apply(new VoiceLabEditCommand.SetEnabled("accepted-test", false));
        Assert.Equal("Turn off Voice Lab", disabled.UndoActionName);
        Assert.False(disabled.Present.VoiceLab.Segments[0].Enabled);
        Assert.Same(history.Present, disabled.Undo().Present);
        Assert.Equal("Turn on Voice Lab", disabled.Apply(new VoiceLabEditCommand.SetEnabled("accepted-test", true)).UndoActionName);
        var chosen = history.Apply(new VoiceLabEditCommand.ChooseCandidate("accepted-test", 0));
        Assert.Same(history, chosen);
        var deleted = history.Apply(new VoiceLabEditCommand.Delete("accepted-test"));
        Assert.Equal("Delete Voice Lab segment", deleted.UndoActionName);
        Assert.Empty(deleted.Present.VoiceLab.Segments);
        Assert.Equal(fixture.Published.Assets, deleted.Present.VoiceLab.Assets);
        Assert.Same(history.Present, deleted.Undo().Present);
        Assert.Empty(disabled.Undo().Apply(new VoiceLabEditCommand.Delete("accepted-test")).RedoStack);
    }
    [Fact]
    public void AcceptDeduplicatesAssetsAndRejectsConflictsAtomically()
    {
        var fixture = new Fixture();
        var accepted = new VoiceLabEditCommand.Accept(fixture.Segment(), [.. fixture.Published.Assets, .. fixture.Published.Assets], fixture.Voice).ApplyingTo(fixture.Empty);
        Assert.Single(accepted.VoiceLab.Assets!);
        var next = fixture.Segment() with { Id = "next", Enabled = false };
        Assert.Single(new VoiceLabEditCommand.Accept(next, fixture.Published.Assets, fixture.Voice).ApplyingTo(accepted).VoiceLab.Assets!);
        Assert.Throws<VoiceLabProjectException>(() => new VoiceLabEditCommand.Accept(next, [fixture.Published.Assets[0] with { Sha256 = new string('f', 64) }], fixture.Voice).ApplyingTo(accepted));
        Assert.Throws<VoiceLabProjectException>(() => new VoiceLabEditCommand.Accept(next, [], fixture.Voice with { VoiceId = "different" }).ApplyingTo(accepted));
        Assert.Throws<VoiceLabProjectException>(() => new VoiceLabEditCommand.ChooseCandidate("accepted-test", 10).ApplyingTo(accepted));
        Assert.Single(accepted.VoiceLab.Segments);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void EveryEditRestoresExactModifiedAtAndDirtyState(bool initiallyDirty)
    {
        var fixture = new Fixture(true);
        var history = new VoiceLabEditHistory(fixture.Empty, initiallyDirty);
        VoiceLabEditCommand[] commands = [new VoiceLabEditCommand.Accept(fixture.Segment(), fixture.Published.Assets, fixture.Voice),
            new VoiceLabEditCommand.SetEnabled("accepted-test", false), new VoiceLabEditCommand.SetEnabled("accepted-test", true),
            new VoiceLabEditCommand.Delete("accepted-test")];
        foreach (var command in commands)
        {
            var before = history;
            var date = history.Present.ModifiedAt.AddSeconds(1);
            history = history.Apply(command, date);
            Assert.True(history.IsDirty);
            Assert.Equal(date, history.Present.ModifiedAt);
            Assert.Equal(before.UndoStack.Count + 1, history.UndoStack.Count);
            var undone = history.Undo();
            Assert.Same(before.Present, undone.Present);
            Assert.Equal(before.IsDirty, undone.IsDirty);
            Assert.Equal(before.Present.ModifiedAt, undone.Present.ModifiedAt);
            var redone = undone.Redo();
            Assert.Same(history.Present, redone.Present);
            Assert.True(redone.IsDirty);
            Assert.Equal(date, redone.Present.ModifiedAt);
        }
    }
}
