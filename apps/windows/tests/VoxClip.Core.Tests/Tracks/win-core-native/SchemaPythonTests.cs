using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCoreNative;

public sealed class SchemaPythonTests
{
    [Fact]
    public async Task DiscoverySkipsStoreAliasesAndMissingModulesBeforeUsingWindowsLauncher()
    {
        var candidates = SchemaPython.Candidates(null, true, command => command switch
        {
            "python3" => [@"C:\Users\test\AppData\Local\Microsoft\WindowsApps\python3.exe", @"C:\Python\python3.exe"],
            "py" => [@"C:\Windows\py.exe"],
            _ => [@"C:\Python\python.exe"]
        }).ToArray();
        Assert.Equal([@"C:\Python\python3.exe", @"C:\Windows\py.exe", @"C:\Python\python.exe"], candidates.Select(candidate => candidate.Executable));
        var attempted = new List<SchemaInterpreter>();
        var selected = await SchemaPython.SelectAsync(candidates, (candidate, _) =>
        {
            attempted.Add(candidate);
            return Task.FromResult(candidate.Executable.EndsWith("py.exe", StringComparison.Ordinal));
        }, TestContext.Current.CancellationToken);
        Assert.Same(candidates[1], selected);
        Assert.NotNull(selected);
        Assert.Equal(["-3"], selected.Prefix);
        Assert.Equal(2, attempted.Count);
    }

    [Fact]
    public async Task ExplicitInterpreterIsAuthoritativeAndMissingCandidatesReturnNull()
    {
        var resolved = new List<string>();
        var candidates = SchemaPython.Candidates("/prepared/python3", false, command =>
        {
            resolved.Add(command);
            return [command];
        }).ToArray();
        Assert.Equal(["/prepared/python3"], resolved);
        Assert.Empty(Assert.Single(candidates).Prefix);
        Assert.Null(await SchemaPython.SelectAsync(candidates, (_, _) => Task.FromResult(false), TestContext.Current.CancellationToken));
        Assert.Empty(SchemaPython.Candidates(@"C:\WindowsApps\python.exe", true, command => [command]));
    }

    [Fact]
    public void MissingInterpreterSkipsLocallyButFailsWhenRequired()
    {
        Xunit.Sdk.SkipException? skipped = null;
        try { SchemaPython.Require(null, false); }
        catch (Xunit.Sdk.SkipException error) { skipped = error; }
        Assert.NotNull(skipped);
        Assert.Contains("jsonschema and referencing", skipped.Message);
        Assert.Contains("VOXCLIP_SCHEMA_PYTHON", skipped.Message);
        var failed = Assert.Throws<Xunit.Sdk.FailException>(() => SchemaPython.Require(null, true));
        Assert.Contains("VOXCLIP_REQUIRE_SCHEMA_PYTHON=1", failed.Message);
    }

    [Fact]
    public async Task UnixDiscoveryFallsBackToPythonAndHonorsCancellation()
    {
        var candidates = SchemaPython.Candidates(null, false, command => ["/usr/bin/" + command]).ToArray();
        Assert.Equal(["/usr/bin/python3", "/usr/bin/python"], candidates.Select(candidate => candidate.Executable));
        Assert.All(candidates, candidate => Assert.Empty(candidate.Prefix));
        var selected = await SchemaPython.SelectAsync(candidates, (candidate, _) => Task.FromResult(candidate.Executable.EndsWith("/python", StringComparison.Ordinal)), TestContext.Current.CancellationToken);
        Assert.Same(candidates[1], selected);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => SchemaPython.SelectAsync(candidates,
            (_, _) => throw new InvalidOperationException("Cancelled discovery must not probe."), new CancellationToken(true)));
    }
}
