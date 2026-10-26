using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Domain.Editing;
using VoxClip.Media.Pipeline;
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
            Assert.Contains("reviewed v3 render recipe", json.RootElement.GetProperty("error").GetProperty("message").GetString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("passage-render-v3.voxclip", null, true)]
    [InlineData("full-take-render-v3.voxclip", null, true)]
    [InlineData("passage-render-v3.voxclip", "outside", false)]
    [InlineData("passage-render-v3.voxclip", "disabled", false)]
    public async Task ExportCapturesExactlyTheSelectedV3Scope(string fixture, string? outside, bool synthetic)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-voice-cli-").FullName;
        var oldOut = Console.Out; var oldError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(
                FixtureLoader.SharedRoot, "fixtures", "voice-lab", fixture)));
            var source = Path.Combine(directory, "source.mkv");
            File.WriteAllText(source, "fake probe owns this path");
            project = project with { Media = project.Media with { Source = project.Media.Source with
                { AbsolutePath = source, SizeBytes = new FileInfo(source).Length } } };
            if (fixture == "full-take-render-v3.voxclip")
                project = project with { Edits = project.Edits with { ActiveClipId = null } };
            if (outside == "disabled") project = VoiceLabProject.SetEnabled(project, "vl-passage", false);
            else if (outside is not null)
            {
                var clip = new ClipRange(outside, "w1", "w2", "Source only", ClipOrigin.Manual, null, null, true);
                project = project with { Edits = project.Edits with { Clips = project.Edits.Clips.Append(clip).ToArray(), ActiveClipId = clip.Id } };
            }
            var projectPath = Path.Combine(directory, "take.voxclip");
            File.WriteAllText(projectPath, ProjectSerialization.Serialize(project));
            var destination = Path.Combine(directory, "out.mp4");
            var sourceInfo = project.Media.Source;
            var media = new MediaInfo(source, sourceInfo.DurationSeconds, sourceInfo.Video, sourceInfo.Audio,
                new(sourceInfo.Video!.Width, sourceInfo.Video.Height), "h264", "aac", false, 0, 1, 0);
            ExportJob? captured = null;
            Task<ExportResult> Prepare(ExportJob job, IProgress<ExportProgress>? _, CancellationToken _ct)
            {
                captured = job;
                File.WriteAllText(destination + ".partial", "video");
                if (synthetic) File.WriteAllText(destination + ".provenance.json.partial", "sidecar");
                return Task.FromResult(new ExportResult(destination, null, job.Snapshot.Timeline.Duration, 1920, 1080, 30,
                    210, 48_000, job.Snapshot.Timeline.OutputSamples, "h264", "test", 0));
            }
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(["--open", projectPath, "--export", destination, "--style", "off", "--json"],
                TestContext.Current.CancellationToken, (_, _) => Task.FromResult<(Project?, MediaInfo)>((project, media)), Prepare);
            Assert.True(exit == 0, $"CLI exit {exit}: {output} {errors}");
            Assert.NotNull(captured);
            Assert.Equal(synthetic, captured.Snapshot.VoiceLab is not null);
            if (project.Edits.ActiveClipId is { } selected)
                Assert.Equal(selected, Assert.IsType<ExportTarget.Clip>(captured.Target).Id);
            else Assert.IsType<ExportTarget.FullEdit>(captured.Target);
            Assert.Equal(synthetic ? "sidecar" : null, File.Exists(destination + ".provenance.json")
                ? File.ReadAllText(destination + ".provenance.json") : null);
            Assert.Equal("video", File.ReadAllText(destination));
            if (synthetic)
            {
                var prepared = captured.Snapshot.VoiceLab!.Prepared;
                Assert.Equal(prepared.OutputPlan.OutputSamples, captured.Snapshot.Timeline.OutputSamples);
                Assert.Equal(prepared.OutputPlan.Captions.Count, VoiceLabOutputPlanner.Build(project,
                    project.Edits.ActiveClipId is { } clipId ? VoiceLabOutputScope.Clip(clipId) : VoiceLabOutputScope.Full).Captions.Count);
                Assert.Equal(4, CliOperations.ExportDestinations(captured.Snapshot, destination,
                    Path.Combine(directory, "captions.srt"), Path.Combine(directory, "audio.wav")).Length);
            }
            else Assert.IsType<VoxClip.Core.Domain.VoiceLab.RenderTimeline.Legacy>(captured.Snapshot.Timeline);
        }
        finally { Console.SetOut(oldOut); Console.SetError(oldError); Directory.Delete(directory, true); }
    }
}
