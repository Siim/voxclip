using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

[Collection("CLI console")]
public sealed class CliOutputParityTests
{
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public void ExportKeepsTheStoredActiveClipWithOrWithoutEditFlags(bool fillers, bool pauses)
    {
        var transcript = new Transcript(1, [], "en", null, 1, new(TranscriptEngine.Whispercpp, null, null, "test", null), false, false, 1, "", DateTimeOffset.UnixEpoch);
        var clip = new ClipRange("stored", "first", "last", null, ClipOrigin.Manual, null, null, true);
        var state = new EditState(transcript, [], 0.5, 0.15, new HashSet<string>(), new HashSet<string>(), new Dictionary<string, string>(), [clip], clip.Id);
        var calls = new List<EditOperation>();
        var result = CliOperations.ApplyExportEdits(state, fillers, pauses, null, null, (current, operation) =>
        {
            Assert.Equal("stored", current.ActiveClipId);
            calls.Add(operation);
            return current;
        });
        Assert.Equal("stored", result.ActiveClipId);
        Assert.Equal((fillers ? 1 : 0) + (pauses ? 1 : 0), calls.Count);
        if (fillers) Assert.IsType<EditOperation.CutFillers>(calls[0]);
        if (pauses) Assert.IsType<EditOperation.TightenPauses>(calls[^1]);
    }

    [Theory]
    [InlineData("b", null, "w6")]
    [InlineData(null, "3:7", "w6")]
    [InlineData(null, null, "w2")]
    public void BulkEditsUseTheSelectedExportScope(string? clip, string? range, string expectedFiller)
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot,
            "fixtures", "projects", "interview-take.voxclip")));
        var clips = new[]
        {
            new ClipRange("a", "w1", "w3", null, ClipOrigin.Manual, null, null, true),
            new ClipRange("b", "w4", "w8", null, ClipOrigin.Manual, null, null, true)
        };
        project = project with { Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Clips = clips, ActiveClipId = "a" } };
        var result = CliOperations.ApplyExportEdits(EditingEngine.FromProject(project)!, true, false, clip, range);
        Assert.Equal(expectedFiller, Assert.Single(result.CutWordIds));
        Assert.Equal(range is not null ? "cli-range" : clip ?? "a", result.ActiveClipId);
    }

    [Fact]
    public void RangeUsesANewClipWhenTheDefaultIdAlreadyExists()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot,
            "fixtures", "projects", "interview-take.voxclip")));
        project = project with { Edits = project.Edits with
        {
            CutWordIds = [], CutPauseIds = [],
            Clips = [new ClipRange("cli-range", "w1", "w3", null, ClipOrigin.Manual, null, null, true)],
            ActiveClipId = "cli-range"
        } };
        var result = CliOperations.ApplyExportEdits(EditingEngine.FromProject(project)!, true, false, null, "3:7");
        Assert.Equal("cli-range-2", result.ActiveClipId);
        Assert.Equal("w6", Assert.Single(result.CutWordIds));
        Assert.Equal("w4", result.Clips.Single(item => item.Id == "cli-range-2").StartWordId);
    }

    [Theory]
    [InlineData(false, 1.0)]
    [InlineData(true, 0.8)]
    public void NewCliProjectsUseTheCoreImportPauseThreshold(bool refined, double expected)
    {
        var transcript = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot,
            "fixtures", "projects", "interview-take.voxclip"))).Transcript! with { Refined = refined };
        var directory = RunDirectory();
        try
        {
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "probed by the test");
            var media = new MediaInfo(source, 7, new(640, 360, 30, 0), new(48_000, 1), new(640, 360), "h264", "aac", false, 0, 1, 0);
            Assert.Equal(expected, CliOperations.NewProject(media, transcript, "").Edits.PauseThresholdSeconds);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ExportPublishesTheStoredScopeWithoutEditFlagsAndReusesOneProbe(bool savedProject)
    {
        var directory = RunDirectory();
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "interview-take.voxclip")));
            var clip = new ClipRange("stored", "w3", "w7", null, ClipOrigin.Manual, null, null, true);
            project = project with
            {
                Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Clips = [clip], ActiveClipId = clip.Id },
                Captions = project.Captions with { StyleId = "off" }
            };
            var source = Path.Combine(directory, savedProject ? "source.voxclip" : "source.mp4");
            File.WriteAllText(source, savedProject ? ProjectSerialization.Serialize(project) : "opened by the test probe");
            var destination = Path.Combine(directory, "out.mp4");
            var media = new MediaInfo(source, 7, new(640, 360, 30, 0), new(48_000, 1), new(640, 360), "h264", "aac", false, 0, 1, 0);
            var probes = 0;
            Task<(Project?, MediaInfo)> Open(string path, CancellationToken ct)
            {
                Assert.Equal(source, path);
                probes++;
                return Task.FromResult<(Project?, MediaInfo)>((savedProject ? project : null, media));
            }
            var preparations = 0;
            ExportJob? prepared = null;
            Task<ExportResult> Prepare(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct)
            {
                preparations++;
                prepared = job;
                var plan = job.Snapshot.Plan;
                File.WriteAllText(job.OutputPath + ".partial", "prepared video");
                return Task.FromResult(new ExportResult(job.OutputPath, null, plan.Duration, 640, 360, 30,
                    (long)Math.Ceiling(plan.Duration * 30), 48_000, plan.OutputSamples, "h264", "test", 0));
            }
            var arguments = new List<string> { "--open", source, "--export", destination, "--style", "off", "--json" };
            if (!savedProject)
            {
                var transcript = Path.Combine(directory, "transcript.json");
                File.WriteAllText(transcript, JsonSerializer.Serialize(project.Transcript, CliDataJson.Default.Transcript));
                arguments.AddRange(["--transcript", transcript]);
            }
            Console.SetOut(output); Console.SetError(errors);
            Assert.Equal(0, await CliApplication.RunAsync(arguments.ToArray(), TestContext.Current.CancellationToken, Open, Prepare));
            Assert.Equal(1, probes); Assert.Equal(1, preparations);
            Assert.NotNull(prepared);
            Assert.Equal(savedProject ? 123_600 : 336_000, prepared.Snapshot.Plan.OutputSamples);
            Assert.Equal(new MediaInterval(savedProject ? 50_400 : 0, savedProject ? 174_000 : 336_000), Assert.Single(prepared.Snapshot.Plan.Kept));
            if (savedProject)
            {
                Assert.Equal(clip.Id, Assert.IsType<ExportTarget.Clip>(prepared.Target).Id);
                Assert.Equal(336_000, CliOperations.BuildPlan(project, false).OutputSamples);
            }
            else Assert.IsType<ExportTarget.FullEdit>(prepared.Target);
            Assert.Equal("prepared video", File.ReadAllText(destination));
            Assert.False(File.Exists(destination + ".partial"));
            Assert.Empty(Directory.GetFiles(directory, "*.rollback-*"));
            using var json = JsonDocument.Parse(output.ToString());
            Assert.True(json.RootElement.GetProperty("ok").GetBoolean());
            Assert.Equal(savedProject ? 2.575 : 7, json.RootElement.GetProperty("durationSeconds").GetDouble());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Fact]
    public void InvalidScopesAndMissingAudioAreUsageErrors()
    {
        Assert.Throws<CliUsageException>(() => CliOperations.ValidateRequestedScope([], 2, "missing", null));
        Assert.Throws<CliUsageException>(() => CliOperations.ValidateRequestedScope([], 2, null, "0:2"));
        Assert.Throws<CliUsageException>(() => CliOperations.ValidateRequestedScope([], 0, null, "0:0"));
        var failure = Assert.Throws<CliUsageException>(() => CliOperations.RequireAudioOutput(false, "audio.wav"));
        Assert.Equal("This video has no audio track, so --audio-out has nothing to write.", failure.Message);
        CliOperations.RequireAudioOutput(false, null);
        CliOperations.RequireAudioOutput(true, "audio.wav");
        Assert.Throws<CliUsageException>(() => CliOperations.RequireSrtOutput("off", "captions.srt"));
        CliOperations.RequireSrtOutput("off", null);
        CliOperations.RequireSrtOutput("vox-highlight", "captions.srt");
    }

    [Theory]
    [InlineData(false, ".voxclip")]
    [InlineData(true, ".VOXCLIP")]
    public async Task TranscriptWithProjectIsAUsageErrorBeforeOpeningAnyInput(bool exists, string extension)
    {
        var directory = RunDirectory();
        try
        {
            var source = Path.Combine(directory, "source" + extension);
            if (exists) File.WriteAllText(source, "must not be parsed");
            var message = await AssertCliFailure(["--open", source, "--export", Path.Combine(directory, "out.mp4"),
                "--transcript", Path.Combine(directory, "missing.json"), "--json"], "usageError", 2,
                (_, _) => throw new InvalidOperationException("Input was opened"));
            Assert.Equal("--transcript only applies when --open is a media file.", message);
            Assert.Equal(exists ? 1 : 0, Directory.GetFiles(directory).Length);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task OffSrtIsAUsageErrorBeforeTranscriptionOrEmptyPlanChecks(bool savedProject, bool replaceTranscript)
    {
        var directory = RunDirectory();
        try
        {
            var source = Path.Combine(directory, savedProject ? "source.voxclip" : "source.mp4");
            var project = savedProject ? ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", "interview-take.voxclip"))) : null;
            if (project is not null) project = project with { Captions = project.Captions with { StyleId = "off" } };
            File.WriteAllText(source, project is null ? "probed media" : ProjectSerialization.Serialize(project));
            var media = new MediaInfo(source, 0, new(640, 360, 30, 0), new(48_000, 2), new(640, 360), "h264", "aac", false, 0, 1, 0);
            var probed = false;
            Task<(Project?, MediaInfo)> Open(string path, CancellationToken ct)
            {
                Assert.Equal(source, path);
                Assert.False(probed);
                probed = true;
                return Task.FromResult((project, media));
            }
            var arguments = new List<string> { "--open", source, "--export", Path.Combine(directory, "out.mp4"), "--srt", Path.Combine(directory, "out.srt"), "--json" };
            if (replaceTranscript) arguments.AddRange(["--transcript", Path.Combine(directory, "missing.json")]);
            var message = await AssertCliFailure(arguments.ToArray(), "usageError", 2, Open);
            Assert.Equal(savedProject && replaceTranscript ? "--transcript only applies when --open is a media file." :
                "Captions are off, so --srt has nothing to write. Choose a caption style with --style.", message);
            Assert.Equal(!(savedProject && replaceTranscript), probed);
            Assert.Single(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task SilentAudioOutputIsAUsageErrorBeforeReadingTheTranscript()
    {
        var directory = RunDirectory();
        try
        {
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "probed media");
            var media = new MediaInfo(source, 0, new(640, 360, 30, 0), null, new(640, 360), "h264", null, false, 0, -1, 0);
            var message = await AssertCliFailure(["--open", source, "--export", Path.Combine(directory, "out.mp4"), "--audio-out", Path.Combine(directory, "out.wav"),
                "--transcript", Path.Combine(directory, "missing.json"), "--json"], "usageError", 2, (_, _) => Task.FromResult<(Project?, MediaInfo)>((null, media)));
            Assert.Equal("This video has no audio track, so --audio-out has nothing to write.", message);
            Assert.Single(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task CancelledExportJsonHasAnEmptyMessage()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        Assert.Equal(string.Empty, await AssertCliFailure(["--open", "missing.mp4", "--export", "unused.mp4", "--json"], "cancelled", 6, ct: cancellation.Token));
    }

    [Theory]
    [InlineData("--export")]
    [InlineData("--audio-out")]
    [InlineData("--srt")]
    public async Task PartialDirectoriesAreUsageErrorsBeforeInputIsOpened(string flag)
    {
        var directory = RunDirectory();
        var video = Path.Combine(directory, "video.mp4");
        var source = Path.Combine(directory, "source.mp4");
        File.WriteAllText(source, "preserve source");
        var sidecar = Path.Combine(directory, flag == "--srt" ? "out.srt" : "audio.wav");
        var partial = (flag == "--export" ? video : sidecar) + ".partial";
        Directory.CreateDirectory(partial);
        try
        {
            var arguments = new List<string> { "--open", source, "--export", video, "--json" };
            if (flag != "--export") arguments.AddRange([flag, sidecar]);
            await AssertCliFailure(arguments.ToArray(), "usageError", 2);
            Assert.True(Directory.Exists(partial));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task StagingResolvesDestinationLinksAndReplacesOnlyRegularPartials()
    {
        var directory = RunDirectory();
        try
        {
            var destination = Path.Combine(directory, "target.srt");
            var alias = Path.Combine(directory, "alias.srt");
            File.WriteAllText(destination, "old");
            File.CreateSymbolicLink(alias, destination);
            File.WriteAllText(destination + ".partial", "stale");
            await CliOperations.AtomicWriteAsync(alias, "new", TestContext.Current.CancellationToken);
            Assert.Equal("new", File.ReadAllText(destination));
            Assert.NotNull(new FileInfo(alias).LinkTarget);
            Assert.False(File.Exists(destination + ".partial"));
            Assert.False(File.Exists(alias + ".partial"));
            File.CreateSymbolicLink(destination + ".partial", destination);
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "preserve source");
            await AssertCliFailure(["--open", source, "--export", alias, "--json"], "usageError", 2);
            Assert.Equal("new", File.ReadAllText(destination));
            Assert.NotNull(new FileInfo(destination + ".partial").LinkTarget);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(-1)]
    public void PublishMp4ThenSrtThenWaveAndRestoreAllDestinationsOnFailure(int failAt)
    {
        var directory = RunDirectory();
        var destinations = new[] { "video.mp4", "captions.srt", "audio.wav" }.Select(name => Path.Combine(directory, name)).ToArray();
        try
        {
            foreach (var destination in destinations)
            {
                File.WriteAllText(destination, "old");
                File.WriteAllText(destination + ".partial", "new");
            }
            var calls = 0;
            void Move(string partial, string destination)
            {
                Assert.All(destinations.Skip(calls), item => Assert.True(File.Exists(item + ".partial")));
                Assert.All(destinations, item => Assert.Single(Directory.GetFiles(directory, Path.GetFileName(item) + ".rollback-*")));
                Assert.Equal(destinations[calls], destination);
                if (calls++ == failAt) throw new IOException("publish failed");
                File.Move(partial, destination, true);
            }
            if (failAt >= 0) Assert.Throws<IOException>(() => OutputSafety.Publish(destinations, Move, TestContext.Current.CancellationToken));
            else OutputSafety.Publish(destinations, Move, TestContext.Current.CancellationToken);
            Assert.All(destinations, destination => Assert.Equal(failAt >= 0 ? "old" : "new", File.ReadAllText(destination)));
            Assert.Empty(Directory.GetFiles(directory, "*.rollback-*"));
            if (failAt == -1) Assert.Empty(Directory.GetFiles(directory, "*.partial"));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ReadOnlySrtRestoresReplacedVideoAndPreservesEveryDestination(bool videoExisted)
    {
        var directory = RunDirectory();
        var destinations = new[] { "video.mp4", "captions.srt", "audio.wav" }.Select(name => Path.Combine(directory, name)).ToArray();
        try
        {
            foreach (var destination in destinations)
            {
                if (videoExisted || destination != destinations[0]) File.WriteAllText(destination, "old " + Path.GetFileName(destination));
                File.WriteAllText(destination + ".partial", "new " + Path.GetFileName(destination));
            }
            File.SetAttributes(destinations[1], File.GetAttributes(destinations[1]) | FileAttributes.ReadOnly);
            Assert.Throws<UnauthorizedAccessException>(() => OutputSafety.Publish(destinations, ct: TestContext.Current.CancellationToken));
            if (videoExisted) Assert.Equal("old video.mp4", File.ReadAllText(destinations[0]));
            else Assert.False(File.Exists(destinations[0]));
            Assert.Equal("old captions.srt", File.ReadAllText(destinations[1]));
            Assert.Equal("old audio.wav", File.ReadAllText(destinations[2]));
            Assert.True((File.GetAttributes(destinations[1]) & FileAttributes.ReadOnly) != 0);
            Assert.Empty(Directory.GetFiles(directory, "*.rollback-*"));
        }
        finally
        {
            File.SetAttributes(destinations[1], FileAttributes.Normal);
            Directory.Delete(directory, true);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void CancellationBetweenPublicationRenamesRestoresAllDestinations(bool videoExisted)
    {
        var directory = RunDirectory();
        var destinations = new[] { "video.mp4", "captions.srt", "audio.wav" }.Select(name => Path.Combine(directory, name)).ToArray();
        using var cancellation = new CancellationTokenSource();
        try
        {
            foreach (var destination in destinations)
            {
                if (videoExisted || destination != destinations[0]) File.WriteAllText(destination, "old");
                File.WriteAllText(destination + ".partial", "new");
            }
            void Move(string partial, string destination)
            {
                Assert.Equal(destinations[0], destination);
                File.Move(partial, destination, true);
                cancellation.Cancel();
            }
            Assert.Throws<OperationCanceledException>(() => OutputSafety.Publish(destinations, Move, cancellation.Token));
            if (videoExisted) Assert.Equal("old", File.ReadAllText(destinations[0]));
            else Assert.False(File.Exists(destinations[0]));
            Assert.All(destinations.Skip(1), destination => Assert.Equal("old", File.ReadAllText(destination)));
            Assert.Empty(Directory.GetFiles(directory, "*.rollback-*"));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("--audio-out", "audio.wav")]
    [InlineData("--clip", "missing")]
    [InlineData("--range", "0:999")]
    [InlineData("--srt", "out.srt")]
    [Trait("Category", "RequiresFFmpeg")]
    public async Task NativeInvalidOutputRequestsExitTwo(string flag, string value)
    {
        await NativeTest.RequireAsync();
        var directory = RunDirectory();
        try
        {
            var failure = await AssertCliFailure(["--open", NativeTest.Fixture("bars-4k.mkv"), "--export", Path.Combine(directory, "video.mp4"), flag, value, "--json"], "usageError", 2);
            if (flag == "--audio-out") Assert.Equal("This video has no audio track, so --audio-out has nothing to write.", failure);
            if (flag == "--srt") Assert.Equal("Captions are off, so --srt has nothing to write. Choose a caption style with --style.", failure);
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("--export", false)]
    [InlineData("--export", true)]
    [InlineData("--audio-out", false)]
    [InlineData("--audio-out", true)]
    [InlineData("--srt", false)]
    [InlineData("--srt", true)]
    public async Task UnusableDestinationsFailBeforeOpeningInput(string flag, bool missingParent)
    {
        var directory = RunDirectory();
        try
        {
            var invalid = missingParent ? Path.Combine(directory, "missing", "out") : directory;
            var arguments = new List<string> { "--open", Path.Combine(directory, "unopened.mp4"), "--export",
                flag == "--export" ? invalid : Path.Combine(directory, "video.mp4"), "--json" };
            if (flag != "--export") arguments.AddRange([flag, invalid]);
            var message = await AssertCliFailure(arguments.ToArray(), "usageError", 2, (_, _) => throw new InvalidOperationException("Input was opened"));
            var expected = missingParent ? $"The output folder does not exist for {OutputSafety.Resolve(invalid)}" :
                "An output must be a file path, not a folder or special file";
            Assert.Equal(ServicesMergeAdapter.DiagnosticRedactor().Redact(expected), message);
            Assert.Empty(Directory.GetFileSystemEntries(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task SpecialFileDestinationIsAUsageErrorWithoutOpeningInput()
    {
        var directory = RunDirectory();
        try
        {
            var special = OperatingSystem.IsWindows() ? Path.Combine(directory, "NUL") : "/dev/null";
            var message = await AssertCliFailure(["--open", Path.Combine(directory, "unopened.mp4"), "--export", special, "--json"],
                "usageError", 2, (_, _) => throw new InvalidOperationException("Input was opened"));
            Assert.Equal("An output must be a file path, not a folder or special file", message);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnknownMediaClipFailsAfterOneProbeBeforeTranscriptOrTranscription(bool suppliedTranscript)
    {
        var directory = RunDirectory();
        try
        {
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "probe only");
            var probes = 0;
            Task<(Project?, MediaInfo)> Open(string path, CancellationToken ct)
            {
                probes++;
                return Task.FromResult<(Project?, MediaInfo)>((null, new(source, 10, new(640, 360, 30, 0), new(48_000, 2), new(640, 360), "h264", "aac", false, 0, 1, 0)));
            }
            var arguments = new List<string> { "--open", source, "--clip", "missing", "--export", Path.Combine(directory, "out.mp4"), "--json" };
            if (suppliedTranscript) arguments.AddRange(["--transcript", Path.Combine(directory, "unread.json")]);
            Assert.Equal("The requested clip does not exist.", await AssertCliFailure(arguments.ToArray(), "usageError", 2, Open));
            Assert.Equal(1, probes);
            Assert.Single(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    private static async Task<string?> AssertCliFailure(string[] arguments, string code, int exit, ExportInputReader? openExport = null, CancellationToken? ct = null)
    {
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            Assert.Equal(exit, await CliApplication.RunAsync(arguments, ct ?? TestContext.Current.CancellationToken, openExport));
            using var json = JsonDocument.Parse(output.ToString());
            var failure = json.RootElement.GetProperty("error");
            Assert.Equal(code, failure.GetProperty("code").GetString());
            return failure.GetProperty("message").GetString();
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }

    [Fact]
    public void FailedSrtRestoreKeepsItsBackupAndStillRestoresTheMp4()
    {
        var directory = RunDirectory();
        var destinations = new[] { "video.mp4", "captions.srt", "audio.wav" }.Select(name => Path.Combine(directory, name)).ToArray();
        FileStream? heldSrt = null;
        try
        {
            foreach (var destination in destinations)
            {
                File.WriteAllText(destination, "old " + Path.GetFileName(destination));
                File.WriteAllText(destination + ".partial", "new " + Path.GetFileName(destination));
            }
            void Move(string partial, string destination)
            {
                if (destination == destinations[2])
                {
                    if (OperatingSystem.IsWindows()) heldSrt = File.Open(destinations[1], FileMode.Open, FileAccess.Read, FileShare.Read);
                    throw new IOException("WAV publish failed");
                }
                File.Move(partial, destination, true);
            }
            void Restore(string backup, string destination)
            {
                if (!OperatingSystem.IsWindows() && destination == destinations[1]) throw new IOException("SRT restore failed");
                File.Move(backup, destination, true);
            }
            var error = Assert.Throws<VoxClipException>(() => OutputSafety.Publish(destinations, Move,
                TestContext.Current.CancellationToken, Restore));
            Assert.Equal(VoxClipErrorCode.ExportFailed, error.Code);
            var backup = Assert.Single(Directory.GetFiles(directory, "*.rollback-*"));
            Assert.StartsWith(destinations[1] + ".rollback-", backup, StringComparison.Ordinal);
            Assert.Equal($"Couldn't put back captions.srt. The previous version is saved as {Path.GetFileName(backup)}.", error.Message);
            Assert.Equal("WAV publish failed", Assert.IsType<AggregateException>(error.InnerException).InnerExceptions[0].Message);
            Assert.Equal("old captions.srt", File.ReadAllText(backup));
            Assert.Equal("old video.mp4", File.ReadAllText(destinations[0]));
            Assert.Equal("old audio.wav", File.ReadAllText(destinations[2]));
            Assert.Empty(Directory.GetFiles(directory, "*.partial"));
        }
        finally { heldSrt?.Dispose(); Directory.Delete(directory, true); }
    }

    private static string RunDirectory()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        return directory;
    }
}
