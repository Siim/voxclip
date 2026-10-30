using System.Reflection.PortableExecutable;
using System.Text.Json;

namespace VoxClip.ReleaseBoundary;

/// <summary>One assembly to inspect against its checked-in allowlist.</summary>
public sealed record CheckTarget(string Name, string Path, string Allowlist, Machine? Machine = null, bool AllowAnyCpu = true);

public static class ReleaseCheck
{
    public const string AllowlistDirectory = "apps/windows/build/ReleaseBoundary/allowlist";
    public const string SurrogatePath = "apps/windows/tests/VoxClip.App.TypeCheck/bin/Release/net10.0-windows10.0.26100.0/VoxClip.WinCheck.dll";
    public static readonly string[] ShippingAssemblies = ["VoxClip", "VoxClip.Core", "VoxClip.Media"];

    public static string? FindRepositoryRoot(string start)
    {
        for (var directory = new DirectoryInfo(Path.GetFullPath(start)); directory is not null; directory = directory.Parent)
            if (Directory.Exists(Path.Combine(directory.FullName, AllowlistDirectory))) return directory.FullName;
        return null;
    }

    /// <summary>The shipping check: the exact Release App output of one RID plus the first-party assemblies beside it.</summary>
    public static int Shipping(string runtimeIdentifier, string appPath, string allowlistDirectory, string repositoryRoot,
        string? evidenceDirectory, TextWriter output, TextWriter error)
    {
        Machine machine;
        switch (runtimeIdentifier)
        {
            case "win-x64": machine = Machine.Amd64; break;
            case "win-arm64": machine = Machine.Arm64; break;
            default: error.WriteLine("Unsupported runtime identifier: " + runtimeIdentifier); return 2;
        }
        var app = Path.GetFullPath(appPath);
        if (!string.Equals(Path.GetFileName(app), "VoxClip.dll", StringComparison.OrdinalIgnoreCase))
        {
            error.WriteLine("The shipping check inspects the real App assembly VoxClip.dll, never a surrogate: " + app);
            return 1;
        }
        var directory = Path.GetDirectoryName(app)!;
        var targets = ShippingAssemblies.Select(name => new CheckTarget(name, Path.Combine(directory, name + ".dll"),
            Path.Combine(allowlistDirectory, name + ".txt"), machine, name != "VoxClip")).ToArray();
        return Run("Release boundary " + runtimeIdentifier, targets, strictStale: false, repositoryRoot,
            evidenceDirectory is null ? null : Path.Combine(evidenceDirectory, runtimeIdentifier), output, error);
    }

    /// <summary>The fast macOS precheck: the Release typecheck surrogate must match the allowlists exactly.</summary>
    public static int Precheck(string surrogatePath, string allowlistDirectory, string repositoryRoot, string? evidenceDirectory,
        TextWriter output, TextWriter error)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(surrogatePath))!;
        var targets = ShippingAssemblies.Select(name => name == "VoxClip"
            ? new CheckTarget("VoxClip.WinCheck", Path.GetFullPath(surrogatePath), Path.Combine(allowlistDirectory, "VoxClip.txt"))
            : new CheckTarget(name, Path.Combine(directory, name + ".dll"), Path.Combine(allowlistDirectory, name + ".txt"))).ToArray();
        return Run("Release boundary precheck (typecheck surrogate)", targets, strictStale: true, repositoryRoot, evidenceDirectory, output, error);
    }

    public static int Run(string label, IReadOnlyList<CheckTarget> targets, bool strictStale, string repositoryRoot,
        string? evidenceDirectory, TextWriter output, TextWriter error)
    {
        var failures = 0;
        var summaries = new List<object>();
        if (evidenceDirectory is not null) Directory.CreateDirectory(evidenceDirectory);
        foreach (var target in targets)
        {
            if (!File.Exists(target.Path))
            {
                error.WriteLine($"{target.Name}: missing assembly {target.Path}");
                failures++;
                continue;
            }
            var inventory = AssemblyInspector.Read(target.Path, repositoryRoot);
            var identity = AssemblyInspector.IdentityErrors(inventory, target.Name, target.Machine, target.AllowAnyCpu).ToArray();
            string[] allowlist;
            try { allowlist = Allowlist.Read(target.Allowlist); }
            catch (FileNotFoundException missing)
            {
                error.WriteLine($"{target.Name}: {missing.Message}");
                allowlist = [];
                failures++;
            }
            var result = inventory.Check(allowlist);
            var source = inventory.Entries.Where(entry => entry.Origin == EntryOrigin.Source).ToArray();
            var counts = new
            {
                types = source.Count(entry => entry.Key.StartsWith("type ", StringComparison.Ordinal)),
                generatedTypes = inventory.Entries.Count(entry => entry.Origin == EntryOrigin.Generated && entry.Key.StartsWith("type ", StringComparison.Ordinal)),
                members = source.Count(entry => entry.Key.StartsWith("member ", StringComparison.Ordinal)),
                taggedMembers = source.Count(entry => entry.Key.StartsWith("attribute ", StringComparison.Ordinal) && entry.RequiresApproval),
                literals = inventory.Entries.Count(entry => entry.Key.StartsWith("literal ", StringComparison.Ordinal)),
                switchLiterals = source.Count(entry => entry.Key.StartsWith("literal ", StringComparison.Ordinal) && entry.RequiresApproval),
                approved = inventory.AllowlistLines.Length,
            };
            output.WriteLine($"{target.Name}: {inventory.Identity.Path}");
            output.WriteLine($"  {inventory.Identity.Configuration} {inventory.Identity.Machine} sha256 {inventory.Identity.Sha256} pdb {inventory.Identity.PdbPath ?? "missing"}");
            output.WriteLine($"  {counts.types} hand-written types, {counts.generatedTypes} toolchain types, {counts.members} members, " +
                $"{counts.taggedMembers} tagged members, {counts.literals} literals ({counts.switchLiterals} switch-like), {counts.approved} allowlist lines");
            foreach (var line in identity) error.WriteLine("  IDENTITY " + line);
            foreach (var line in result.Forbidden) error.WriteLine("  FORBIDDEN " + line);
            foreach (var line in result.Unapproved) error.WriteLine($"  UNAPPROVED {line}    [{inventory.EvidenceFor(line)}]");
            foreach (var line in result.Stale) (strictStale ? error : output).WriteLine((strictStale ? "  STALE " : "  stale (warning) ") + line);
            var failed = identity.Length > 0 || !result.Passed || (strictStale && result.Stale.Length > 0);
            if (failed)
            {
                failures++;
                error.WriteLine($"  {target.Name} FAILED: {identity.Length} identity, {result.Forbidden.Length} forbidden, {result.Unapproved.Length} unapproved" +
                    (strictStale ? $", {result.Stale.Length} stale" : "") + " -> " + DisplayPath(target.Allowlist, repositoryRoot));
            }
            else output.WriteLine($"  {target.Name} passed against {DisplayPath(target.Allowlist, repositoryRoot)}");
            summaries.Add(new
            {
                target.Name, inventory.Identity.Path, inventory.Identity.Configuration, inventory.Identity.Machine, inventory.Identity.Sha256,
                Pdb = inventory.Identity.PdbPath, counts, identity, result.Forbidden, result.Unapproved, result.Stale, passed = !failed,
            });
            if (evidenceDirectory is not null)
            {
                File.WriteAllLines(Path.Combine(evidenceDirectory, target.Name + ".inventory.tsv"), inventory.Entries
                    .Select(entry => $"{entry.Origin}\t{(entry.RequiresApproval ? "approve" : "record")}\t{entry.Key}\t{entry.Evidence}"));
                File.WriteAllText(Path.Combine(evidenceDirectory, target.Name + ".allowlist.txt"), Allowlist.Render(target.Name, inventory.AllowlistLines));
            }
        }
        if (evidenceDirectory is not null)
            File.WriteAllText(Path.Combine(evidenceDirectory, "summary.json"), JsonSerializer.Serialize(new { label, passed = failures == 0, assemblies = summaries },
                new JsonSerializerOptions { WriteIndented = true }));
        if (failures > 0) error.WriteLine(HowToResolve(label, failures));
        else output.WriteLine($"{label}: {targets.Count} assemblies passed.");
        return failures == 0 ? 0 : 1;
    }

    private static string DisplayPath(string path, string repositoryRoot) =>
        Path.GetRelativePath(repositoryRoot, Path.GetFullPath(path)).Replace('\\', '/');

    public static string HowToResolve(string label, int failures) => string.Join('\n',
        $"{label}: {failures} assembly check(s) FAILED. How to resolve:",
        "  * A fake, stand-in, harness, probe, seam, test hook or other DEBUG-only code must not ship in Release:",
        "    move it under #if DEBUG or into a test project. It must never be allowlisted.",
        "  * FORBIDDEN entries (VOXCLIP_DEBUG_* strings, [Conditional(\"DEBUG\")] members) can never be allowlisted.",
        "  * An intended product change: add exactly the UNAPPROVED lines above to the named allowlist file and keep it sorted,",
        "    or regenerate the file from a Release build and review the diff. From the repository root:",
        "      dotnet run --project apps/windows/build/ReleaseBoundary -c Release -- update <Release assembly> " + AllowlistDirectory + "/<Name>.txt",
        "    The macOS Release typecheck surrogate produces the App allowlist (VoxClip.txt):",
        "      dotnet run --project apps/windows/build/ReleaseBoundary -c Release -- update " + SurrogatePath + " " + AllowlistDirectory + "/VoxClip.txt",
        "  * STALE lines name code that no longer ships: delete them (the macOS precheck requires an exact match).",
        "  * Windows CI uploads every inventory and the exact candidate allowlists as windows-release-boundary-inventories.");
}
