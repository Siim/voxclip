using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

[Collection("CLI console")]
public sealed class VoiceLabRenderingBoundaryTests
{
    private static Project Fixture() => ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(
        FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-project.voxclip")));

    [Fact]
    public void PlanUsesExplicitScopeAndAllowsDisabledReplacements()
    {
        var project = Fixture();
        Assert.Equal(VoiceLabProjectErrorCode.UnsupportedRendering,
            Assert.Throws<VoiceLabProjectException>(() => CliOperations.BuildPlan(project, false)).Code);
        var outside = new VoxClip.Core.Domain.Editing.ClipRange("outside", "w1", "w2", "Source only",
            VoxClip.Core.Domain.Editing.ClipOrigin.Manual, null, null, true);
        project = project with { Edits = project.Edits with { Clips = project.Edits.Clips.Append(outside).ToArray(), ActiveClipId = outside.Id } };
        Assert.True(CliOperations.BuildPlan(project, true).OutputSamples > 0);
        Assert.Throws<VoiceLabProjectException>(() => CliOperations.BuildPlan(project, false));
        project = VoiceLabProject.SetEnabled(project, "vl-passage", false);
        Assert.Equal(7000, CliOperations.BuildPlan(project, false).OutputSamples);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ActualCliRefusesSyntheticPlanAndExportBeforeEncoder(bool export)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-voice-boundary-").FullName;
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            var project = Fixture();
            var path = Path.Combine(directory, "take.voxclip");
            File.WriteAllText(path, ProjectSerialization.Serialize(project));
            var destination = Path.Combine(directory, "out.mp4");
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "offline input-reader fixture");
            var media = new MediaInfo(source, 7, new(640, 360, 30, 0), new(1000, 1), new(640, 360), "h264", "aac", false, 0, 1, 0);
            var encoded = false;
            Console.SetOut(output); Console.SetError(errors);
            var args = export ? new[] { "--open", path, "--export", destination, "--style", "off", "--json" }
                : new[] { "plan", "--open", path, "--json" };
            var exit = await AcceptedCli.RunAsync(args, TestContext.Current.CancellationToken,
                (_, _) => Task.FromResult<(Project?, MediaInfo)>((project, media)),
                (_, _, _) => { encoded = true; throw new InvalidOperationException("Encoder must not run"); });
            Assert.Equal(5, exit);
            Assert.False(encoded);
            Assert.False(File.Exists(destination));
            Assert.False(File.Exists(destination + ".partial"));
            using var json = JsonDocument.Parse(output.ToString());
            Assert.Equal("exportFailed", json.RootElement.GetProperty("error").GetProperty("code").GetString());
            Assert.Contains("generated voice segments", json.RootElement.GetProperty("error").GetProperty("message").GetString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }
}
