using System.ComponentModel;
using System.Diagnostics;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinCoreNative;

internal sealed record SchemaInterpreter(string Executable, IReadOnlyList<string> Prefix);

internal static class SchemaPython
{
    private const string MissingReason = "No usable Python 3 interpreter with jsonschema and referencing was found. " +
        "Install jsonschema>=4.18,<5 or set VOXCLIP_SCHEMA_PYTHON to a prepared interpreter. WindowsApps Store aliases are ignored. " +
        "CI must set VOXCLIP_REQUIRE_SCHEMA_PYTHON=1 to require schema validation.";

    internal static async Task ValidateAsync(IEnumerable<string> files, CancellationToken ct)
    {
        var candidates = Candidates(Environment.GetEnvironmentVariable("VOXCLIP_SCHEMA_PYTHON"), OperatingSystem.IsWindows(), ResolveExecutable);
        var interpreter = Require(await SelectAsync(candidates, ProbeAsync, ct),
            Environment.GetEnvironmentVariable("VOXCLIP_REQUIRE_SCHEMA_PYTHON") == "1");
        TestContext.Current.TestOutputHelper?.WriteLine("Schema interpreter: " + interpreter.Executable + " " + string.Join(" ", interpreter.Prefix));
        var validator = Path.Combine(Path.GetDirectoryName(FixtureLoader.SharedRoot)!, "tools", "schemas", "validate.py");
        var result = await RunAsync(interpreter, new[] { validator }.Concat(files), TimeSpan.FromSeconds(60), ct);
        Assert.True(result.ExitCode == 0, "Schema validation failed.\n" + result.Output + result.Error);
    }

    internal static SchemaInterpreter Require(SchemaInterpreter? interpreter, bool required)
    {
        if (interpreter is not null) return interpreter;
        if (required) Assert.Fail(MissingReason);
        Assert.Skip(MissingReason);
        throw new InvalidOperationException(MissingReason);
    }

    internal static IEnumerable<SchemaInterpreter> Candidates(string? configured, bool windows, Func<string, IEnumerable<string>> resolve)
    {
        var commands = !string.IsNullOrWhiteSpace(configured) ? new[] { configured }
            : windows ? new[] { "python3", "py", "python" } : new[] { "python3", "python" };
        foreach (var command in commands)
            foreach (var executable in resolve(command))
                if (!IsStoreAlias(executable))
                    yield return new(executable, string.IsNullOrWhiteSpace(configured) && command == "py" ? ["-3"] : []);
    }

    internal static async Task<SchemaInterpreter?> SelectAsync(IEnumerable<SchemaInterpreter> candidates,
        Func<SchemaInterpreter, CancellationToken, Task<bool>> probe, CancellationToken ct)
    {
        foreach (var candidate in candidates)
        {
            ct.ThrowIfCancellationRequested();
            if (await probe(candidate, ct)) return candidate;
        }
        return null;
    }

    private static bool IsStoreAlias(string path)
        => path.Split('/', '\\').Any(part => part.Equals("WindowsApps", StringComparison.OrdinalIgnoreCase));

    private static IEnumerable<string> ResolveExecutable(string command)
    {
        var extensions = OperatingSystem.IsWindows() && !Path.HasExtension(command) ? new[] { ".exe", "" } : new[] { "" };
        var explicitPath = Path.IsPathFullyQualified(command) || command.Contains(Path.DirectorySeparatorChar) || command.Contains(Path.AltDirectorySeparatorChar);
        var directories = explicitPath
            ? new[] { "" } : (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator);
        foreach (var directory in directories.Where(directory => !string.IsNullOrWhiteSpace(directory) || explicitPath))
            foreach (var extension in extensions)
            {
                var path = Path.GetFullPath(Path.Combine(directory.Trim('"'), command + extension));
                if (File.Exists(path)) yield return path;
            }
    }

    private static async Task<bool> ProbeAsync(SchemaInterpreter interpreter, CancellationToken ct)
    {
        try
        {
            var result = await RunAsync(interpreter,
                ["-c", "import sys; assert sys.version_info.major == 3; import jsonschema, referencing; print(sys.executable)"], TimeSpan.FromSeconds(10), ct);
            return result.ExitCode == 0 && !string.IsNullOrWhiteSpace(result.Output) && !IsStoreAlias(result.Output.Trim());
        }
        catch (Exception error) when (error is Win32Exception or IOException) { return false; }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return false; }
    }

    private static async Task<(int ExitCode, string Output, string Error)> RunAsync(SchemaInterpreter interpreter,
        IEnumerable<string> arguments, TimeSpan timeout, CancellationToken ct)
    {
        var start = new ProcessStartInfo(interpreter.Executable)
        {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true
        };
        foreach (var argument in interpreter.Prefix.Concat(arguments)) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("The schema interpreter could not start.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(timeout);
            await process.WaitForExitAsync(deadline.Token);
            return (process.ExitCode, await output, await error);
        }
        finally
        {
            if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(CancellationToken.None); }
            await Task.WhenAll(output, error);
        }
    }
}
