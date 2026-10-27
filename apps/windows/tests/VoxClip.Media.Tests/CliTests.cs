using System.Text.Json;
using System.Text.Json.Nodes;
using System.Globalization;
using VoxClip.Cli;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

[Collection("CLI console")]
public sealed class CliTests
{
    [Fact]
    public void VersionUsesSharedRuntimeDisplayFallback() => Assert.Equal(AppVersion.Current, CliApplication.Version);

    [Theory]
    [InlineData("version --json", 0, true, "version")]
    [InlineData("--json", 2, false, "export")]
    [InlineData("--fps -1 --json", 2, false, "export")]
    [InlineData("--fps 0 --json", 2, false, "export")]
    [InlineData("--fps 61 --json", 2, false, "export")]
    [InlineData("--unknown --json", 2, false, "export")]
    [InlineData("--range 5 --json", 2, false, "export")]
    [InlineData("--range a:b --json", 2, false, "export")]
    [InlineData("--range -1:3 --json", 2, false, "export")]
    [InlineData("--range 9:2 --json", 2, false, "export")]
    [InlineData("--range 0:1:2 --json", 2, false, "export")]
    [InlineData("probe missing-file.mp4 --json", 3, false, "probe")]
    [InlineData("render-caption --case missing-file.json --out unused.png --json", 3, false, "render-caption")]
    [InlineData("render-caption --out unused.png --json", 2, false, "render-caption")]
    [InlineData("--open missing.mp4 --export unused.mp4 --json", 3, false, "export")]
    public async Task CommandsReturnOneFinalJsonObject(string command, int expectedExit, bool ok, string name)
    {
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(command.Split(' '), TestContext.Current.CancellationToken);
            Assert.Equal(expectedExit, exit);
            using var document = JsonDocument.Parse(output.ToString());
            Assert.Equal(ok, document.RootElement.GetProperty("ok").GetBoolean());
            Assert.Equal(name, document.RootElement.GetProperty("command").GetString());
            Assert.DoesNotContain("Unhandled exception", errors.ToString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("0")]
    [InlineData("61")]
    [InlineData("NaN")]
    [InlineData("Infinity")]
    [InlineData("-1")]
    public async Task InvalidFpsFailsBeforeInputWithPinnedJsonMessage(string value)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            var source = Path.Combine(directory, "source.mp4"); File.WriteAllText(source, "input marker");
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(["--open", source, "--export", Path.Combine(directory, "out.mp4"),
                "--fps", value, "--json"], TestContext.Current.CancellationToken,
                (_, _) => throw new InvalidOperationException("Input must not open"));
            Assert.Equal(2, exit);
            using var json = JsonDocument.Parse(output.ToString());
            Assert.Equal("usageError", json.RootElement.GetProperty("error").GetProperty("code").GetString());
            Assert.Equal("--fps must be greater than zero and at most 60",
                json.RootElement.GetProperty("error").GetProperty("message").GetString());
            Assert.Equal(1, output.ToString().Count(character => character == '\n'));
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task InvariantFpsIsAcceptedUnderGermanCulture()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        var previousCulture = CultureInfo.CurrentCulture;
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            var source = Path.Combine(directory, "source.mp4"); File.WriteAllText(source, "input marker");
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("de-DE");
            Console.SetOut(output); Console.SetError(errors);
            var opened = false;
            var exit = await AcceptedCli.RunAsync(["--open", source, "--export", Path.Combine(directory, "out.mp4"),
                "--fps", "29.97", "--json"], TestContext.Current.CancellationToken,
                (_, _) => { opened = true; throw new VoxClipException(VoxClipErrorCode.DecodeFailed, "probe stopped"); });
            Assert.True(opened); Assert.Equal(3, exit);
        }
        finally { CultureInfo.CurrentCulture = previousCulture; Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("missing-style")]
    [InlineData("../bad-style")]
    public async Task InvalidStyleFailsBeforeOpeningInput(string style)
    {
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(["--open", "missing.mp4", "--export", "unused.mp4",
                "--style", style, "--json"], TestContext.Current.CancellationToken,
                (_, _) => throw new InvalidOperationException("Input must not open"));
            Assert.Equal(2, exit);
            using var json = JsonDocument.Parse(output.ToString());
            Assert.Equal("usageError", json.RootElement.GetProperty("error").GetProperty("code").GetString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); }
    }

    [Theory]
    [InlineData(VoxClipErrorCode.DecodeFailed, 3)]
    [InlineData(VoxClipErrorCode.NoAudioTrack, 3)]
    [InlineData(VoxClipErrorCode.FfmpegLicenceGate, 3)]
    [InlineData(VoxClipErrorCode.KeyPermissionMissing, 4)]
    [InlineData(VoxClipErrorCode.MediaTooLong, 4)]
    public async Task RemappedCodesKeepTheirExitStatusDuringExport(VoxClipErrorCode code, int expected)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "probed by the test");
            Console.SetOut(output); Console.SetError(errors);
            var exit = await AcceptedCli.RunAsync(["--open", source, "--export", Path.Combine(directory, "out.mp4"), "--json"],
                TestContext.Current.CancellationToken, (_, _) => throw new VoxClipException(code, "safe diagnostic"));
            Assert.Equal(expected, exit);
            using var json = JsonDocument.Parse(output.ToString());
            Assert.Equal(new VoxClipException(code, "").WireCode, json.RootElement.GetProperty("error").GetProperty("code").GetString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Fact]
    public void NativeDecodeCopyIncludesTheReasonAndSavedEditsReassurance()
    {
        var failure = new MediaException(-22, "Open media", "Invalid argument");
        Assert.Equal("VoxClip couldn't decode this video: Open media: Invalid argument. Your edits are saved.", CliApplication.FailureMessage(failure));
        var resource = new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        Assert.Equal(resource.Message, CliApplication.FailureMessage(resource));
    }

    [Fact]
    [Trait("Category", "RequiresFFmpeg")]
    public async Task OpeningCorruptMediaUsesDecodeCopyAndInputExit()
    {
        await NativeTest.RequireAsync();
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        var previousOutput = Console.Out; var previousError = Console.Error;
        using var output = new StringWriter(); using var errors = new StringWriter();
        try
        {
            var source = Path.Combine(directory, "corrupt.mp4");
            File.WriteAllText(source, "not media");
            Console.SetOut(output); Console.SetError(errors);
            Assert.Equal(3, await AcceptedCli.RunAsync(["--open", source, "--export", Path.Combine(directory, "out.mp4"), "--json"], TestContext.Current.CancellationToken));
            using var json = JsonDocument.Parse(output.ToString());
            var failure = json.RootElement.GetProperty("error");
            Assert.Equal("decodeFailed", failure.GetProperty("code").GetString());
            Assert.StartsWith("VoxClip couldn't decode this video: ", failure.GetProperty("message").GetString());
            Assert.EndsWith(". Your edits are saved.", failure.GetProperty("message").GetString());
        }
        finally { Console.SetOut(previousOutput); Console.SetError(previousError); Directory.Delete(directory, true); }
    }

    [Fact]
    public void EveryBundledStyleLoadsThroughTheSharedSchema()
    {
        foreach (var file in Directory.EnumerateFiles(Path.Combine(FixtureLoader.SharedRoot, "caption-styles", "styles"), "*.json"))
        {
            var id = Path.GetFileNameWithoutExtension(file);
            Assert.Equal(id, CaptionRendering.LoadStyle(id).Id);
        }
    }

    [Theory]
    [InlineData("emoji-accent-portrait-et", -1, "1f60d")]
    [InlineData("two-tone-portrait-numbers", 1, null)]
    public async Task CaptionCaseBuildPreservesManualWordChoices(string caseId, int emphasisedWord, string? emoji)
    {
        var path = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "captions", "layout", caseId + ".json");
        var input = JsonNode.Parse(File.ReadAllText(path))!["input"]!;
        var track = await CaptionRendering.BuildCaseAsync(input, TestContext.Current.CancellationToken);
        Assert.Equal(emoji, track.Pages[0].Emoji?.Codepoints);
        if (emphasisedWord >= 0) Assert.Equal([emphasisedWord], track.Pages[0].Emphasised.Select(word => word.Word));
        if (caseId == "two-tone-portrait-numbers") Assert.Equal([6], track.Pages[1].Emphasised.Select(word => word.Word));
    }

    [Fact]
    public async Task CaptionTileUsesEnglishKeywordRules()
    {
        var style = CaptionRendering.LoadStyle("emoji-accent");
        var track = await CaptionRendering.BuildTileAsync(style, new(1080, 1920), TestContext.Current.CancellationToken);
        Assert.Equal("1f4a1", track.Pages[0].Emoji?.Codepoints);
    }
}

[CollectionDefinition("CLI console", DisableParallelization = true)]
public sealed class CliConsoleCollection;
