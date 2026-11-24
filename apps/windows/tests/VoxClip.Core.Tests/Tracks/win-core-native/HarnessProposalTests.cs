using System.Text.Json;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCoreNative;

public sealed class HarnessProposalTests
{
    [Fact]
    public async Task ProposedEditsMaterializeAsAValidProjectWithoutApplyingTheMusicBrief()
    {
        using var input = JsonDocument.Parse("""
            {
              "clipId": "clip-2f1c", "reason": "Open with the main point.", "title": "A faster edit", "captionStyle": "vox-bold",
              "cuts": [{"kind": "other", "startWord": 11, "endWord": 11, "reason": "Keep the point short."}],
              "effects": [
                {"kind": "motionTitle", "startWord": 9, "endWord": 9, "text": "A faster edit", "reason": "Name the topic."},
                {"kind": "punchIn", "startWord": 14, "endWord": 15, "scale": 1.1, "reason": "Emphasize the takeaway."}
              ],
              "generateMusic": "A quiet instrumental bed"
            }
            """);
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/clip-from-long-take.voxclip"));
        var proposal = new HarnessProposal(HarnessTimeline.Read(input.RootElement), project);
        var candidate = proposal.Applying(project with { Edits = project.Edits with { ActiveClipId = "clip-9a0b" } }, FixtureLoader.SharedRoot);

        Assert.Equal("A faster edit", candidate.Edits.Clips[0].Title);
        Assert.Contains(project.Transcript!.Words[11].Id, candidate.Edits.CutWordIds);
        Assert.Equal("vox-bold", candidate.CaptionsFor("clip-2f1c").StyleId);
        Assert.Equal("title", Assert.Single(candidate.ClipEffects).GetProperty("kind").GetString());
        Assert.Equal("clip-2f1c", Assert.Single(candidate.MotionCues).ClipID);
        Assert.Equal(project.Music.ToArray(), candidate.Music.ToArray());
        Assert.Equal("clip-9a0b", candidate.Edits.ActiveClipId);

        var edited = project with { Edits = project.Edits with { CutWordIds = candidate.Edits.CutWordIds } };
        Assert.Throws<HarnessException>(() => proposal.Applying(edited, FixtureLoader.SharedRoot));

        var candidateFile = Path.Combine(Path.GetTempPath(), $"harness-candidate-{Guid.NewGuid():N}.voxclip");
        try
        {
            var ct = TestContext.Current.CancellationToken;
            await File.WriteAllTextAsync(candidateFile, ProjectSerialization.Serialize(candidate), ct);
            await SchemaPython.ValidateAsync([candidateFile], ct);
        }
        finally { File.Delete(candidateFile); }
    }
}
