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

    /// <summary>The cut edge freeze (editing §5.10) reads which scopes hold paid takes saved beside a project, without consuming or
    /// expiring any record.</summary>
    [Fact]
    public void PaidScopesListsTheScopesWithPaidTakesWithoutChangingAnything()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-rewrite-").FullName;
        try
        {
            var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/music/music-project.voxclip"));
            var stamp = new DateTimeOffset(2026, 11, 24, 0, 0, 0, TimeSpan.Zero);
            var change = new SavedRewriteChange(new(VoiceLabDiffHunkKind.Voice, ["word"], ["New"], [], [], [], 0, 1, null), null, false, [], [], "pending");
            void Save(RewriteScope scope, string? clip, int takes, DateTimeOffset at) =>
                new SavedRewriteProposalStore(root, project.Id, scope, clip).Save(new("x", "Tighten", [change], [], [], null, takes, 0, []), at);
            Save(RewriteScope.Clip("c3"), null, 1, stamp);
            Save(RewriteScope.Selection(2, 4), "c1", 2, stamp);
            Save(RewriteScope.FullTake, null, 0, stamp);
            Save(RewriteScope.Clip("old"), null, 1, stamp.AddDays(-61));
            Save(RewriteScope.Clip("c9"), null, 1, stamp);
            var other = new SavedRewriteProposalStore(root, "another-project", RewriteScope.FullTake, null);
            other.Save(new("x", "Tighten", [change], [], [], null, 1, 0, []), stamp);

            Assert.Equal(["clip:c3", "clip:c9", "selection:2-4:c1"], SavedRewriteProposalStore.PaidScopes(root, project.Id, stamp).Order(StringComparer.Ordinal));
            Assert.Empty(SavedRewriteProposalStore.PaidScopes(root, "absent", stamp));
            Assert.Empty(SavedRewriteProposalStore.PaidScopes(Path.Combine(root, "absent"), project.Id, stamp));
            Assert.Equal(6, Directory.EnumerateFiles(root, "*.json", SearchOption.AllDirectories).Count());
        }
        finally { Directory.Delete(root, true); }
    }
}
