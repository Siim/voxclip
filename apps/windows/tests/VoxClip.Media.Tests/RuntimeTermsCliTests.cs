using System.Text.Json;
using VoxClip.Cli;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Media.Tests;

[Collection("CLI console")]
public sealed class RuntimeTermsCliTests
{
    [Fact]
    public async Task JsonGatePrecedesMediaAccessAndAcceptanceFlagsDoNotBecomePaths()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-terms-").FullName;
        var previousOut = Console.Out;
        var previousError = Console.Error;
        try
        {
            var notices = AcceptedCli.FindNotices();
            var agreement = new WindowsRuntimeAgreement(notices, Path.Combine(directory, "acceptance.txt"));
            var source = Path.Combine(directory, "source.mp4");
            File.WriteAllText(source, "do not open");
            var opened = false;
            using var output = new StringWriter();
            using var error = new StringWriter();
            Console.SetOut(output); Console.SetError(error);
            var input = new[] { "--open", source, "--export", Path.Combine(directory, "output.mp4"), "--json" };
            var exit = await CliApplication.RunAsync(input, TestContext.Current.CancellationToken,
                (_, _) => { opened = true; throw new IOException("media opened"); }, runtimeAgreement: agreement);
            Assert.Equal(7, exit);
            Assert.False(opened);
            Assert.False(File.Exists(Path.Combine(directory, "output.mp4")));
            using (var json = JsonDocument.Parse(output.ToString()))
                Assert.Equal("runtimeTermsRequired", json.RootElement.GetProperty("error").GetProperty("code").GetString());
            Assert.Equal(1, output.ToString().Count(c => c == '\n'));

            output.GetStringBuilder().Clear();
            Assert.Equal(7, await CliApplication.RunAsync(["--accept-runtime-terms", new string('0', 64), "--json"],
                TestContext.Current.CancellationToken, runtimeAgreement: agreement));
            using (var json = JsonDocument.Parse(output.ToString()))
                Assert.Equal("runtimeTermsUnavailable", json.RootElement.GetProperty("error").GetProperty("code").GetString());
            Assert.False(agreement.IsAccepted(agreement.LoadTerms()));

            output.GetStringBuilder().Clear();
            Assert.Equal(0, await CliApplication.RunAsync(["--runtime-terms", "--json"], TestContext.Current.CancellationToken,
                runtimeAgreement: agreement));
            using (var json = JsonDocument.Parse(output.ToString()))
            {
                Assert.Equal("runtime-terms", json.RootElement.GetProperty("command").GetString());
                Assert.Contains(agreement.LoadTerms().AppSdk, json.RootElement.GetProperty("output").GetString());
            }
            output.GetStringBuilder().Clear();
            Assert.Equal(0, await CliApplication.RunAsync(["--accept-runtime-terms", agreement.LoadTerms().Sha256, "--json"],
                TestContext.Current.CancellationToken, runtimeAgreement: agreement));
            Assert.True(agreement.IsAccepted(agreement.LoadTerms()));
            Assert.False(opened);
            output.GetStringBuilder().Clear();
            exit = await CliApplication.RunAsync(input, TestContext.Current.CancellationToken,
                (_, _) => { opened = true; throw new IOException("media opened"); }, runtimeAgreement: agreement);
            Assert.True(opened);
            Assert.NotEqual(7, exit);
        }
        finally
        {
            Console.SetOut(previousOut); Console.SetError(previousError);
            Directory.Delete(directory, true);
        }
    }

    [Theory]
    [InlineData("--help")]
    [InlineData("-h")]
    public async Task LiteralMediaArgumentAfterSeparatorDoesNotBypassAgreement(string literal)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-help-").FullName;
        var previousOut = Console.Out;
        var previousError = Console.Error;
        try
        {
            var agreement = new WindowsRuntimeAgreement(AcceptedCli.FindNotices(), Path.Combine(directory, "acceptance.txt"));
            var inputChecked = false;
            using var output = new StringWriter();
            using var error = new StringWriter();
            Console.SetOut(output); Console.SetError(error);
            Assert.Equal(7, await CliApplication.RunAsync(["probe", "--", literal],
                TestContext.Current.CancellationToken,
                runtimeAgreement: agreement, inputExists: _ => { inputChecked = true; return true; }));
            Assert.False(inputChecked);
            Assert.False(agreement.IsAccepted(agreement.LoadTerms()));
            Assert.Contains("runtimeTermsRequired", output.ToString() + error.ToString());
            var terms = agreement.LoadTerms();
            agreement.Accept(terms, terms.Sha256);
            Assert.Equal(3, await CliApplication.RunAsync(["probe", "--", literal],
                TestContext.Current.CancellationToken,
                runtimeAgreement: agreement, inputExists: _ => { inputChecked = true; return false; }));
            Assert.True(inputChecked);
        }
        finally
        {
            Console.SetOut(previousOut); Console.SetError(previousError);
            Directory.Delete(directory, true);
        }
    }

    [Theory]
    [InlineData("--help")]
    [InlineData("-h")]
    public async Task ParsedHelpAndVersionRemainAvailableBeforeAcceptance(string help)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-help-").FullName;
        var previousOut = Console.Out;
        var previousError = Console.Error;
        try
        {
            var agreement = new WindowsRuntimeAgreement(AcceptedCli.FindNotices(), Path.Combine(directory, "acceptance.txt"));
            using var output = new StringWriter();
            using var error = new StringWriter();
            Console.SetOut(output); Console.SetError(error);
            Assert.Equal(0, await CliApplication.RunAsync(["probe", help], TestContext.Current.CancellationToken,
                runtimeAgreement: agreement));
            Assert.Contains("Usage:", output.ToString());
            output.GetStringBuilder().Clear();
            Assert.Equal(0, await CliApplication.RunAsync(["version"], TestContext.Current.CancellationToken,
                runtimeAgreement: agreement));
            Assert.Contains("VoxClip", output.ToString());
            output.GetStringBuilder().Clear();
            Assert.Equal(0, await CliApplication.RunAsync(["--version"], TestContext.Current.CancellationToken,
                runtimeAgreement: agreement));
            Assert.NotEmpty(output.ToString());
            Assert.False(agreement.IsAccepted(agreement.LoadTerms()));
        }
        finally
        {
            Console.SetOut(previousOut); Console.SetError(previousError);
            Directory.Delete(directory, true);
        }
    }

}
