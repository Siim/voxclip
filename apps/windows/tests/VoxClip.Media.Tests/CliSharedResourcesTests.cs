using System.Diagnostics;
using System.Text.Json;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Tests.E2E;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The CLI's launch check on shared/data/share-text.json, as the App's (publishing §2.1): a missing or unreadable file
/// stops every command but help and version with exit 3 and <c>sharedResourcesMissing</c>. A process keeps its first load, so
/// each run is a child process of the built CLI.</summary>
public sealed class CliSharedResourcesTests
{
    [Fact]
    public async Task CommandsNeedReadableShareTextRules()
    {
        var ct = TestContext.Current.CancellationToken;
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-share-text-").FullName;
        // A copy of the parts of shared/ the launch check reads, inside this run's own directory (beside VOXCLIP_DATA_DIR).
        var shared = Path.Combine(directory, "shared");
        try
        {
            foreach (var part in new[] { "caption-styles", "data" }) Copy(Path.Combine(FixtureLoader.SharedRoot, part), Path.Combine(shared, part));
            var rules = Path.Combine(shared, "data", "share-text.json");
            var media = Path.Combine(directory, "absent.mov");
            // The intact copy passes the check, so probing a missing file fails on the file instead.
            var intact = await Run(["probe", media, "--json"], shared, directory, ct);
            Assert.Equal((3, "mediaMissing"), (intact.Exit, Code(intact.Stdout)));
            foreach (var broken in new string?[] { null, "{" })
            {
                File.Delete(rules);
                if (broken is not null) File.WriteAllText(rules, broken);
                var failed = await Run(["probe", media, "--json"], shared, directory, ct);
                Assert.Equal((3, "sharedResourcesMissing"), (failed.Exit, Code(failed.Stdout)));
                foreach (var informational in new[] { "--help", "--version", "version" })
                    Assert.Equal(0, (await Run([informational], shared, directory, ct)).Exit);
            }
        }
        finally { Directory.Delete(directory, true); }
    }

    /// <summary>MVP28 CI: <c>TestProcess.IsRunning</c> read a static array declared after it, so every process that is not a
    /// test host (the App, the CLI) threw on its first data path and every command ended in <c>unexpectedFailure</c>. A test
    /// host short-circuits before that read, so this child drops the test platforms' variables, as the App never has them.</summary>
    [Fact]
    public async Task TheCliStartsOutsideATestHost()
    {
        var ct = TestContext.Current.CancellationToken;
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-outside-tests-").FullName;
        try
        {
            var terms = await Run(["--runtime-terms", "--json"], FixtureLoader.SharedRoot, directory, ct, outsideTestHost: true);
            Assert.True(terms.Exit == 0, terms.Stdout);
            using var document = JsonDocument.Parse(terms.Stdout);
            Assert.True(document.RootElement.GetProperty("ok").GetBoolean(), terms.Stdout);
        }
        finally { Directory.Delete(directory, true); }
    }

    private static async Task<(int Exit, string Stdout)> Run(string[] arguments, string shared, string directory, CancellationToken ct,
        bool outsideTestHost = false)
    {
        var cli = Path.GetFullPath(Environment.GetEnvironmentVariable("VOXCLIP_CLI") ?? Path.Combine(NativePipelineTests.TestRoot,
            "..", "..", "src", "VoxClip.Cli", "bin", "Release", "net10.0", "voxclip-cli.dll"));
        Assert.True(File.Exists(cli), $"Built CLI is missing: {cli}");
        // On Windows the terms gate runs before the launch check; accept the terms as MediaCliE2ETests does.
        var data = Path.Combine(directory, "data");
        var agreement = new WindowsRuntimeAgreement(Path.Combine(Path.GetDirectoryName(cli)!, WindowsRuntimeAgreement.NoticeFileName),
            Path.Combine(data, WindowsRuntimeAgreement.StampFileName));
        var terms = agreement.LoadTerms();
        agreement.Accept(terms, terms.Sha256);
        var start = new ProcessStartInfo(cli.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? "dotnet" : cli)
        { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        if (cli.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(cli);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment["VOXCLIP_SHARED_DIR"] = shared;
        start.Environment["VOXCLIP_DATA_DIR"] = data;
        start.Environment["VOXCLIP_LIVE_TESTS"] = "0";
        start.Environment["VOXCLIP_TEST_DOWNLOAD"] = "0";
        if (outsideTestHost)
            foreach (var name in start.Environment.Keys.Where(name => new[] { "VSTEST_", "TESTINGPLATFORM_", "XUNIT_" }
                .Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))).ToArray())
                start.Environment.Remove(name);
        return await MediaCliE2ETests.RunProcess(start, (_, _) => Task.CompletedTask, ct, TimeSpan.FromMinutes(1));
    }

    private static string Code(string stdout)
    {
        using var document = JsonDocument.Parse(stdout);
        return document.RootElement.GetProperty("error").GetProperty("code").GetString() ?? "";
    }

    private static void Copy(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var copy = Path.Combine(target, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(file, copy);
        }
    }
}
