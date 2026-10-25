using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Media.Tests;

[Collection("CLI console")]
public sealed class OutputSafetyTests
{
    [Fact]
    public void GuardsSourcesProjectsOutputsAndPartialNames()
    {
        var source = Path.GetFullPath("source.mp4");
        var project = Path.GetFullPath("project.voxclip");
        Assert.Throws<VoxClipException>(() => OutputSafety.Validate([source, project], [source]));
        Assert.Throws<VoxClipException>(() => OutputSafety.Validate([source, project], [project]));
        Assert.Throws<VoxClipException>(() => OutputSafety.Validate([source], ["export.mp4", "export.mp4"]));
        Assert.Throws<VoxClipException>(() => OutputSafety.Validate([source], ["export.mp4", "export.mp4.partial"]));
        Assert.Throws<VoxClipException>(() => OutputSafety.Validate([source + ".partial"], [source]));
        if (OperatingSystem.IsWindows() || OperatingSystem.IsMacOS())
            Assert.Throws<VoxClipException>(() => OutputSafety.Validate([source], [source.ToUpperInvariant()]));
        OutputSafety.Validate([source, project], ["export.mp4", "export.srt", "edited.wav"]);
    }

    [Theory]
    [InlineData("source-out")]
    [InlineData("source-raw")]
    [InlineData("outputs")]
    [InlineData("case")]
    [InlineData("link")]
    public async Task TranscribeRejectsCollisionsBeforeProbingOrTranscribing(string collision)
    {
        var directory = CreateDirectory();
        var previousOutput = Console.Out;
        var previousError = Console.Error;
        using var output = new StringWriter();
        using var errors = new StringWriter();
        try
        {
            var source = Path.Combine(directory, "source.mp4");
            var project = Path.Combine(directory, "project.voxclip");
            var raw = Path.Combine(directory, "raw.json");
            File.WriteAllText(source, "preserve source");
            if (collision == "source-out") project = source;
            if (collision == "source-raw") raw = source;
            if (collision == "outputs") raw = project;
            if (collision == "case")
            {
                if (!OperatingSystem.IsWindows() && !OperatingSystem.IsMacOS()) return;
                project = source.ToUpperInvariant();
            }
            if (collision == "link")
            {
                if (OperatingSystem.IsWindows()) Assert.True(CreateHardLink(project, source, 0));
                else File.CreateSymbolicLink(project, source);
            }
            Console.SetOut(output); Console.SetError(errors);
            Assert.Equal(2, await AcceptedCli.RunAsync(["transcribe", "--open", source, "--out", project, "--raw-out", raw, "--json"], TestContext.Current.CancellationToken));
            using var json = JsonDocument.Parse(output.ToString());
            Assert.Equal("usageError", json.RootElement.GetProperty("error").GetProperty("code").GetString());
            Assert.Equal("preserve source", File.ReadAllText(source));
            Assert.False(File.Exists(Path.Combine(directory, "raw.json")));
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Fact]
    public void StalePartialsAreDeletedAndRecreatedEmpty()
    {
        var directory = CreateDirectory();
        try
        {
            var partial = Path.Combine(directory, "export.mp4.partial");
            File.WriteAllText(partial, "stale export");
            using var stream = OutputSafety.CreatePartial(partial);
            Assert.Equal(0, stream.Length);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void ResolvesSymbolicFilesAndParentsBeforeComparing()
    {
        var directory = CreateDirectory();
        var linkedDirectory = Path.Combine(directory, "linked");
        try
        {
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "original");
            var alias = Path.Combine(directory, "alias.mp4");
            if (OperatingSystem.IsWindows())
                Assert.True(CreateHardLink(alias, source, 0), $"CreateHardLink failed: {Marshal.GetLastWin32Error()}");
            else File.CreateSymbolicLink(alias, source);
            Assert.True(OutputSafety.SameFile(alias, source));
            if (OperatingSystem.IsWindows())
            {
                using var process = Process.Start(new ProcessStartInfo("cmd.exe")
                {
                    ArgumentList = { "/c", "mklink", "/J", linkedDirectory, directory },
                    UseShellExecute = false, CreateNoWindow = true
                })!;
                var completed = process.WaitForExit(5_000);
                if (!completed) process.Kill(true);
                Assert.True(completed, "Junction creation exceeded five seconds.");
                Assert.Equal(0, process.ExitCode);
            }
            else Directory.CreateSymbolicLink(linkedDirectory, directory);
            Assert.True(OutputSafety.SameFile(Path.Combine(linkedDirectory, "source.mp4"), source));
            Assert.True(OutputSafety.SameFile(Path.Combine(linkedDirectory, "new.mp4"), Path.Combine(directory, "new.mp4")));
        }
        finally
        {
            if (Directory.Exists(linkedDirectory)) Directory.Delete(linkedDirectory);
            Directory.Delete(directory, true);
        }
    }

    [Theory]
    [InlineData("off", "--srt")]
    [InlineData("vox-bold", "--srt")]
    [InlineData("off", "--audio-out")]
    [InlineData("off", "--export")]
    public async Task CliRejectsCollisionsBeforeOpeningTheProject(string style, string flag)
    {
        var directory = CreateDirectory();
        var previousOutput = Console.Out;
        var previousError = Console.Error;
        using var output = new StringWriter();
        using var errors = new StringWriter();
        try
        {
            var project = Path.Combine(directory, "source.voxclip");
            File.WriteAllText(project, "preserve project");
            var arguments = new List<string> { "--open", project, "--export", flag == "--export" ? project : Path.Combine(directory, "export.mp4"), "--style", style, "--json" };
            if (flag != "--export") arguments.AddRange([flag, project]);
            Console.SetOut(output); Console.SetError(errors);
            Assert.Equal(2, await AcceptedCli.RunAsync(arguments.ToArray(), TestContext.Current.CancellationToken));
            using var json = JsonDocument.Parse(output.ToString());
            Assert.Equal("usageError", json.RootElement.GetProperty("error").GetProperty("code").GetString());
            Assert.Equal("preserve project", File.ReadAllText(project));
            Assert.False(File.Exists(Path.Combine(directory, "export.mp4")));
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Fact]
    public void NonzeroGapSamplesDoNotAllowAnAllCutTranscriptToExport()
    {
        var plan = TestPlan.FromKept(48_000, 1_440_000, [new(0, 147_600)]);
        var failure = Assert.Throws<VoxClipException>(() => CliOperations.RequireExportable(plan, false));
        Assert.Equal(VoxClipErrorCode.EverythingCut, failure.Code);
        Assert.Equal(5, failure.ExitCode);
        Assert.Equal("Keep at least one word before exporting.", failure.Message);
        CliOperations.RequireExportable(plan, true);
    }

    [Fact]
    public void SrtUsesRawTextWithNoTransformAndKeepsOnlyPositivePages()
    {
        var words = new[] { Word("So", "SO"), Word("here's", "HERE'S"), Word("thing,", "THING") };
        CaptionPage Page(int index, double start, double end) => new(index, [0, 1, 2], start, end, 64, 1, false,
            [new([0, 1, 2], 0, 0, 0, 0, 0)], [], new(0, 0, 0, 0), new(0, 0, 0, 0), [], [], null, new(0, 0));
        var track = new CaptionTrack(CaptionRendering.LoadStyle("vox-bold"), new(640, 360), words,
            [Page(0, 0, 0), Page(1, 0.0005, 1.2345), Page(2, 2, 1)], 3);
        var calls = 0;
        var subtitles = Exporter.Subtitles(track, (text, options) =>
        {
            Assert.Equal(CaptionTextTransformValue.None, options.Transform);
            Assert.Equal(CaptionTextPunctuationValue.Keep, options.Punctuation);
            calls++;
            return text;
        });
        Assert.Equal("1\n00:00:00,001 --> 00:00:01,235\nSo here's thing,\n\n", subtitles);
        Assert.Equal(3, calls);
    }

    private static MeasuredCaptionWord Word(string raw, string text) => new(0, raw, raw, text, 0, 1, 0, 0, [], 0, false, null, null, null);

    [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLink(string name, string existing, nint securityAttributes);

    private static string CreateDirectory()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        return directory;
    }
}
