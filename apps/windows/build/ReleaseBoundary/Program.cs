using VoxClip.ReleaseBoundary;

const string usage = """
    Usage (paths may be relative to the current directory):
      ReleaseBoundary check <win-x64|win-arm64> <Release VoxClip.dll> [--allowlist <dir>] [--evidence <dir>] [--repo-root <dir>]
      ReleaseBoundary precheck <Release VoxClip.WinCheck.dll> [--allowlist <dir>] [--evidence <dir>] [--repo-root <dir>]
      ReleaseBoundary describe <assembly> [--repo-root <dir>]
      ReleaseBoundary update <Release assembly> <allowlist file> [--repo-root <dir>]
    """;

var positional = new List<string>();
var options = new Dictionary<string, string>(StringComparer.Ordinal);
for (var index = 0; index < args.Length; index++)
{
    if (args[index] is "--allowlist" or "--evidence" or "--repo-root" && index + 1 < args.Length) options[args[index]] = args[++index];
    else positional.Add(args[index]);
}
var root = options.TryGetValue("--repo-root", out var explicitRoot) ? Path.GetFullPath(explicitRoot)
    : ReleaseCheck.FindRepositoryRoot(AppContext.BaseDirectory) ?? ReleaseCheck.FindRepositoryRoot(Environment.CurrentDirectory);
if (root is null)
{
    Console.Error.WriteLine("Cannot find the repository root; pass --repo-root.");
    return 2;
}
var allowlist = options.TryGetValue("--allowlist", out var explicitAllowlist) ? Path.GetFullPath(explicitAllowlist)
    : Path.Combine(root, ReleaseCheck.AllowlistDirectory);
options.TryGetValue("--evidence", out var evidence);

switch (positional)
{
    case ["check", var rid, var app]:
        return ReleaseCheck.Shipping(rid, app, allowlist, root, evidence, Console.Out, Console.Error);
    case ["precheck", var surrogate]:
        return ReleaseCheck.Precheck(surrogate, allowlist, root, evidence, Console.Out, Console.Error);
    case ["describe", var assembly]:
    {
        var inventory = AssemblyInspector.Read(assembly, root);
        Console.WriteLine($"# {inventory.Identity.Name} {inventory.Identity.Configuration} {inventory.Identity.Machine} pdb {inventory.Identity.PdbPath ?? "missing"}");
        foreach (var entry in inventory.Entries)
            Console.WriteLine($"{entry.Origin}\t{(entry.RequiresApproval ? "approve" : "record")}\t{entry.Key}\t{entry.Evidence}");
        foreach (var line in inventory.Forbidden) Console.WriteLine("FORBIDDEN\t" + line);
        foreach (var document in inventory.UnrecognizedDocuments) Console.WriteLine("UNRECOGNISED\t" + document);
        return inventory.Forbidden.Count == 0 && inventory.UnrecognizedDocuments.Count == 0 ? 0 : 1;
    }
    case ["update", var assembly, var file]:
    {
        var inventory = AssemblyInspector.Read(assembly, root);
        var problems = inventory.Forbidden.Concat(AssemblyInspector.IdentityErrors(inventory, inventory.Identity.Name, null, true)).ToArray();
        if (problems.Length > 0)
        {
            foreach (var problem in problems) Console.Error.WriteLine("Refusing to update the allowlist: " + problem);
            return 1;
        }
        var name = Path.GetFileNameWithoutExtension(file);
        File.WriteAllText(file, Allowlist.Render(name, inventory.AllowlistLines));
        Console.WriteLine($"Wrote {inventory.AllowlistLines.Length} lines for {name} to {file}; review the diff before committing.");
        return 0;
    }
    default:
        Console.Error.WriteLine(usage);
        return 2;
}
