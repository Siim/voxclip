using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

[Collection("CLI console")]
public sealed class WindowsV4CliCallerTests
{
    private static Project Fixture(string name = "context-demo/v4-project.voxclip") =>
        ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/" + name));

    [Theory]
    [InlineData(true, false, "stored")]
    [InlineData(true, true, "full")]
    [InlineData(true, false, "range")]
    [InlineData(true, true, "clip")]
    // Context-demo placements render on Windows (ContextDemoRenderTests); a screen recording missing from the data folder stops the
    // export before the encoder, the edited WAV or publication, with no black or source frame standing in for it.
    public async Task AMissingScreenRecordingStopsBeforeEncoderAudioOrPublication(bool demo, bool motion, string scope)
    {
        var original = Fixture();
        var project = original with { ContextDemo = demo ? original.ContextDemo : null, MotionCues = motion ? original.MotionCues : [],
            Edits = original.Edits with { ActiveClipId = scope == "full" ? null : original.Edits.ActiveClipId } };
        CliOperations.BuildPlan(project, false);
        CliOperations.BuildPlan(project, true);
        var directory = Directory.CreateTempSubdirectory("voxclip-v4-cli-refusal-").FullName;
        var oldOutput = Console.Out;
        var oldError = Console.Error;
        using var output = new StringWriter();
        using var errors = new StringWriter();
        try
        {
            var input = Path.Combine(directory, "take.voxclip");
            var destination = Path.Combine(directory, "out.mp4");
            var audio = Path.Combine(directory, "out.wav");
            var before = ProjectSerialization.Serialize(project);
            File.WriteAllText(input, before);
            File.WriteAllText(destination, "previous export");
            var media = Media(project, directory);
            var arguments = new List<string> { "--open", input, "--export", destination, "--style", "off", "--audio-out", audio, "--json" };
            if (scope == "clip") arguments.AddRange(["--clip", project.Edits.Clips[0].Id]);
            if (scope == "range") arguments.AddRange(["--range", "0:1"]);
            var encoded = false;
            Console.SetOut(output);
            Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(arguments.ToArray(), TestContext.Current.CancellationToken,
                (_, _) => Task.FromResult<(Project?, MediaInfo)>((project, media)),
                (_, _, _) => { encoded = true; throw new InvalidOperationException("Encoder must not run"); });
            Assert.Equal(5, exit);
            Assert.False(encoded);
            using var result = JsonDocument.Parse(output.ToString());
            var error = result.RootElement.GetProperty("error");
            Assert.Equal("exportFailed", error.GetProperty("code").GetString());
            Assert.Equal(VoxClip.Core.Domain.ContextDemo.ContextDemoRendering.AssetMessage, error.GetProperty("message").GetString());
            Assert.Equal("previous export", File.ReadAllText(destination));
            Assert.False(File.Exists(destination + ".partial"));
            Assert.False(File.Exists(destination + ".provenance.json"));
            Assert.False(File.Exists(audio));
            Assert.False(File.Exists(audio + ".partial"));
            Assert.Equal(before, File.ReadAllText(input));
            Assert.Equal(before, ProjectSerialization.Serialize(project));
        }
        finally { Console.SetOut(oldOutput); Console.SetError(oldError); Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("metadata")]
    [InlineData("voice")]
    [InlineData("cleanAudio")]
    public async Task V4KeepsTheV3VoicePolicyAndTheEmptyMetadataRoute(string scenario)
    {
        var original = Fixture(scenario == "metadata" ? "context-demo/v4-project.voxclip" : "voice-lab/passage-render-v3.voxclip");
        var project = original with { SchemaVersion = 4, ContextDemo = original.ContextDemo is { } document ? document with { Placements = [] } : null,
            MotionCues = [] };
        if (scenario == "cleanAudio") project = project with { VoiceLab = project.VoiceLab with
        {
            Segments = [], CleanAudio = new(VoiceLabCleanAudioMode.On, project.VoiceLab.Assets![0].Id, 1)
        } };
        var directory = Directory.CreateTempSubdirectory("voxclip-v4-cli-policy-").FullName;
        var oldOutput = Console.Out;
        var oldError = Console.Error;
        using var output = new StringWriter();
        using var errors = new StringWriter();
        try
        {
            var input = Path.Combine(directory, "take.voxclip");
            var destination = Path.Combine(directory, "out.mp4");
            var media = Media(project, directory);
            project = project with { Media = new(project.Media.Source with { AbsolutePath = media.Path, SizeBytes = new FileInfo(media.Path).Length }) };
            File.WriteAllText(input, ProjectSerialization.Serialize(project));
            ExportJob? captured = null;
            Task<ExportResult> Prepare(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct)
            {
                captured = job;
                File.WriteAllText(destination + ".partial", "synthetic test export");
                if (scenario == "voice") File.WriteAllText(destination + ".provenance.json.partial", "synthetic test provenance");
                return Task.FromResult(new ExportResult(destination, null, job.Snapshot.Timeline.Duration, 1920, 1080, 30,
                    210, 48_000, job.Snapshot.Timeline.OutputSamples, "h264", "test", 0));
            }
            Console.SetOut(output);
            Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(["--open", input, "--export", destination, "--style", "off", "--json"],
                TestContext.Current.CancellationToken, (_, _) => Task.FromResult<(Project?, MediaInfo)>((project, media)), Prepare);
            if (scenario == "cleanAudio")
            {
                Assert.Equal(5, exit);
                Assert.Null(captured);
                Assert.False(File.Exists(destination));
                using var result = JsonDocument.Parse(output.ToString());
                Assert.Equal("exportFailed", result.RootElement.GetProperty("error").GetProperty("code").GetString());
                Assert.Equal("This Voice Lab Clean audio edit cannot be rendered in this build. Your video and edits are saved.",
                    result.RootElement.GetProperty("error").GetProperty("message").GetString());
                return;
            }
            Assert.True(exit == 0, $"CLI exit {exit}: {output} {errors}");
            Assert.NotNull(captured);
            Assert.Equal(scenario == "voice", captured.Snapshot.VoiceLab is not null);
            Assert.Equal("synthetic test export", File.ReadAllText(destination));
            Assert.Equal(scenario == "voice", File.Exists(destination + ".provenance.json"));
            if (scenario == "voice")
            {
                var prepared = captured.Snapshot.VoiceLab!.Prepared;
                Assert.True(prepared.OutputPlan.RequiresSyntheticRendering);
                Assert.True(prepared.Disclosure.Required);
                Assert.Equal(prepared.OutputPlan.OutputSamples, captured.Snapshot.Timeline.OutputSamples);
            }
            else Assert.IsType<RenderTimeline.Legacy>(captured.Snapshot.Timeline);
        }
        finally { Console.SetOut(oldOutput); Console.SetError(oldError); Directory.Delete(directory, true); }
    }

    private static MediaInfo Media(Project project, string directory)
    {
        var path = Path.Combine(directory, "source.mp4");
        File.WriteAllText(path, "offline injected probe input");
        var source = project.Media.Source;
        return new(path, source.DurationSeconds, source.Video, source.Audio, new(1920, 1080), "h264", "aac", false, 0, 1, 0);
    }
}
