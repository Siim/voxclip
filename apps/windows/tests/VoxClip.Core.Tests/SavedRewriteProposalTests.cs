using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests;

public sealed class SavedRewriteProposalTests
{
    [Fact]
    public void PaidProposalReturnsAfterReopenAndAnInputMismatchDoesNotDiscardIt()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-rewrite-").FullName;
        try
        {
            var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/music/music-project.voxclip"));
            var scope = RewriteScope.FullTake;
            var store = new SavedRewriteProposalStore(root, project.Id, scope, null);
            var stamp = new DateTimeOffset(2026, 11, 24, 0, 0, 0, TimeSpan.Zero);
            var change = new SavedRewriteChange(new(VoiceLabDiffHunkKind.Voice, ["word"], ["New", "wording"], [], [], [], 0, 1, null),
                null, true, ["L1"], ["Clarity"], "kept");
            var request = Guid.NewGuid();
            var proposal = new SavedRewriteProposal(store.Inputs(project), "Tighten", [change], [1], [1], "voice", 1, .04m, [request]);
            store.Save(proposal, stamp);

            var reopened = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project));
            var different = reopened with { Edits = reopened.Edits with { PauseThresholdSeconds = 0.9 } };
            var freshStore = new SavedRewriteProposalStore(root, reopened.Id, scope, null);
            Assert.Null(freshStore.Load(different, stamp.AddDays(59)));
            var saved = Assert.IsType<SavedRewriteProposal>(freshStore.Load(reopened, stamp.AddDays(59)));
            Assert.Equal("Tighten", saved.Instruction);
            Assert.Equal("kept", Assert.Single(saved.Changes).State);
            Assert.Equal(new[] { "New", "wording" }, saved.Changes[0].Hunk.NewTokens);
            Assert.Equal(new[] { 1 }, saved.PricedAnyway);
            Assert.Equal(new[] { request }, saved.PatchRequests);
            Assert.Equal(.04m, saved.PatchUsd);
            Assert.Null(freshStore.Load(reopened, stamp.AddDays(60)));
            Assert.Empty(Directory.EnumerateFiles(root, "*.json", SearchOption.AllDirectories));
        }
        finally { Directory.Delete(root, true); }
    }
}
