using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class WholeClipAcceptanceTests
{
    [Fact]
    public void UsingASyncedDraftReplacesTheActiveRevoiceInOneUndoStep()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/whole-clip-revoice-project.voxclip"));
        var previous = Assert.Single(project.VoiceLab.WholeClipRevoices!);
        var selected = project.VoiceLab.Segments[0];
        var recipe = selected.Candidates[selected.SelectedCandidateIndex].Recipe!;
        var source = selected with { Candidates = [selected.Candidates[selected.SelectedCandidateIndex] with
            { Recipe = recipe with { Video = VoiceLabLipsync.Base(recipe.Video) } }], SelectedCandidateIndex = 0 };
        var reference = Assert.Single(project.VoiceLab.Voices!) with { Status = VoiceLabVoiceStatus.Active };
        project = project with { VoiceLab = project.VoiceLab with { Voices = [reference] } };
        var voice = new VoiceLabEditCommand.AcceptAll([source], [], reference);
        var scope = VoiceLabOutputScope.Clip(previous.ClipId);
        var draft = WholeClipRevoiceDraft.Voice(project, previous.ClipId, voice);
        var original = VoiceLabRenderContract.Prepare(draft, scope, VoiceLabLabelPosition.TopRight);
        var picture = project.VoiceLab.VideoAssets![0] with { Id = "new-picture", File = $"{project.Id}/new-picture.mp4" };
        var window = new LipsyncRenderWindow(new(recipe.Video.WindowStartSample!.Value, recipe.Video.WindowEndSample!.Value, [0]), 0, 3000);
        var record = previous with { Id = "next-revoice", SegmentIds = [source.Id], LipsyncModel = WholeClipLipsync.Sync3.RawValue() };
        var command = WholeClipRevoiceDraft.WithPicture(voice, record, original.SelectedSegmentRecipes, [new(window, picture, "new-request")]);

        var accepted = new VoiceLabEditHistory(project).Apply(command, outputScope: scope);
        Assert.Equal(record, Assert.Single(accepted.Present.VoiceLab.WholeClipRevoices!));
        Assert.Equal("Revoice whole clip", accepted.UndoActionName);
        var prepared = VoiceLabRenderContract.Prepare(accepted.Present, scope, VoiceLabLabelPosition.TopRight);
        var input = VoiceLabRenderInput.Capture(accepted.Present, prepared, Path.GetTempPath());
        Assert.Equal("new-picture", Assert.Single(input.Prepared.SelectedSegmentRecipes).Recipe.Video.AssetId);
        Assert.Same(project, accepted.Undo().Present);
    }
}
