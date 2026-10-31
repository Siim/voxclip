using System.Collections.Immutable;
using System.Reflection;
using System.Reflection.Emit;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace VoxClip.ReleaseBoundary;

/// <summary>Where an inventoried record comes from.</summary>
public enum EntryOrigin
{
    /// <summary>Hand-written repository C#: every type, member, tagged member and shaped literal must be allowlisted.</summary>
    Source,
    /// <summary>Toolchain output (XAML compiler, CsWinRT, source generators, package-included sources): recorded as evidence only.</summary>
    Generated,
}

/// <summary>One inventoried record. <see cref="Key"/> is the canonical allowlist line.</summary>
public sealed record InventoryEntry(string Key, EntryOrigin Origin, bool RequiresApproval, string Evidence);

public sealed record AssemblyIdentity(string Path, string Name, string Configuration, string Machine, bool IlOnly,
    bool Optimized, string Sha256, string? PdbPath);

public sealed record CheckResult(string[] Forbidden, string[] Unapproved, string[] Stale)
{
    public bool Passed => Forbidden.Length == 0 && Unapproved.Length == 0;
}

public sealed class AssemblyInventory(AssemblyIdentity identity, IReadOnlyList<InventoryEntry> entries, IReadOnlyList<string> forbidden,
    IReadOnlyList<string> unrecognizedDocuments, string repositoryRoot)
{
    public AssemblyIdentity Identity { get; } = identity;
    /// <summary>PDB documents that are neither repository sources nor recognised toolchain output. Their code is treated as
    /// hand-written, and any of them fails the identity check: the PDB paths do not match --repo-root.</summary>
    public IReadOnlyList<string> UnrecognizedDocuments { get; } = unrecognizedDocuments;
    public string RepositoryRoot { get; } = repositoryRoot;
    public int HandWrittenTypes => Entries.Count(entry => entry.Origin == EntryOrigin.Source && entry.Key.StartsWith("type ", StringComparison.Ordinal));
    /// <summary>Every enumerated type, member, attribute and literal, including toolchain-generated evidence.</summary>
    public IReadOnlyList<InventoryEntry> Entries { get; } = entries;
    /// <summary>Content that can never ship, even if someone adds it to an allowlist.</summary>
    public IReadOnlyList<string> Forbidden { get; } = forbidden;

    /// <summary>The exact sorted allowlist this assembly needs.</summary>
    public string[] AllowlistLines => Entries.Where(entry => entry.RequiresApproval).Select(entry => entry.Key)
        .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();

    public CheckResult Check(IEnumerable<string> allowlist)
    {
        var approved = Allowlist.Lines(allowlist).ToHashSet(StringComparer.Ordinal);
        var required = AllowlistLines;
        var forbidden = Forbidden.Concat(approved.Where(Rules.ForbiddenInAllowlist).Order(StringComparer.Ordinal)
            .Select(line => "Allowlist entry can never be approved: " + line)).ToArray();
        return new(forbidden, required.Where(line => !approved.Contains(line)).ToArray(),
            approved.Except(required, StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray());
    }

    public string EvidenceFor(string key) =>
        Entries.FirstOrDefault(entry => entry.Key == key && entry.RequiresApproval)?.Evidence ?? "";
}

public static class Rules
{
    /// <summary>Debug environment switches are DEBUG-only by contract and may never be allowlisted. Windows environment
    /// names are case-insensitive, so the marker matches in any case.</summary>
    public const string DebugEnvironmentMarker = "VOXCLIP_DEBUG";
    private static readonly Regex EnvironmentShape = new(@"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
    private static readonly Regex SwitchShape = new(@"^(?:--?|/)[A-Za-z][A-Za-z0-9-]*(?:[=:].*)?$", RegexOptions.CultureInvariant | RegexOptions.Singleline);
    /// <summary>Roslyn's metadata name for a C# <c>file</c> type: &lt;FileName&gt;F&lt;SHA-256 of the path&gt;__Name.</summary>
    private static readonly Regex FileLocalTypeName = new(@"^<[A-Za-z0-9_]*>F[0-9A-F]{64}__", RegexOptions.CultureInvariant);
    private static readonly Regex GeneratorTypeFolder = new(@"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$", RegexOptions.CultureInvariant);
    public const string XamlCompiler = "Microsoft.UI.Xaml.Markup.Compiler";
    /// <summary>Source generators whose output never implements a hand-written declaration: System.Text.Json contexts and the
    /// CsWinRT AOT generator. Members other generators add to hand-written types (CommunityToolkit.Mvvm [ObservableProperty]
    /// and [RelayCommand], [GeneratedRegex], [LibraryImport] and unknown generators) need approval.</summary>
    public static readonly IReadOnlySet<string> ToolchainGenerators = new HashSet<string>(StringComparer.Ordinal)
    {
        "System.Text.Json.SourceGeneration",
        "WinRT.SourceGenerator",
    };

    /// <summary>Literals that can select behaviour from the environment or command line: these need explicit approval.
    /// Environment-shaped (SNAKE_CASE in any case), command-line shaped (-x, --name, /name) or containing VOXCLIP_ in any case.</summary>
    public static bool IsSwitchLike(string literal) =>
        EnvironmentShape.IsMatch(literal) || SwitchShape.IsMatch(literal) || literal.Contains("VOXCLIP_", StringComparison.OrdinalIgnoreCase);

    public static bool HasDebugEnvironmentMarker(string text) => text.Contains(DebugEnvironmentMarker, StringComparison.OrdinalIgnoreCase);

    /// <summary>C# can only declare a type whose metadata name starts with '&lt;' as a <c>file</c> type. Every other such name
    /// (closures, state machines, anonymous types, inline arrays, &lt;Module&gt;, &lt;PrivateImplementationDetails&gt;) is compiler-generated.</summary>
    public static bool IsSynthesizedTypeName(string metadataName) => metadataName.StartsWith('<') && !FileLocalTypeName.IsMatch(metadataName);

    public static bool IsFileLocalTypeName(string metadataName) => FileLocalTypeName.IsMatch(metadataName);

    /// <summary>A JSON-style ASCII string literal: quotes, backslashes, controls and non-ASCII are escaped.</summary>
    public static string Quote(string text)
    {
        var builder = new StringBuilder(text.Length + 2).Append('"');
        foreach (var character in text)
        {
            switch (character)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                default:
                    if (character < ' ' || character > '~') builder.Append("\\u").Append(((int)character).ToString("X4", System.Globalization.CultureInfo.InvariantCulture));
                    else builder.Append(character);
                    break;
            }
        }
        return builder.Append('"').ToString();
    }

    internal static bool ForbiddenInAllowlist(string line) =>
        HasDebugEnvironmentMarker(line) ||
        line.Contains("@ System.Diagnostics.ConditionalAttribute(\"DEBUG\")", StringComparison.Ordinal);

    /// <summary>Compiler bookkeeping attributes carry no product meaning and churn with nullability and lowering.</summary>
    internal static readonly HashSet<string> BookkeepingAttributes = new(StringComparer.Ordinal)
    {
        "System.CodeDom.Compiler.GeneratedCodeAttribute",
        "System.Diagnostics.CodeAnalysis.SetsRequiredMembersAttribute",
        "System.Diagnostics.DebuggerBrowsableAttribute",
        "System.Diagnostics.DebuggerHiddenAttribute",
        "System.Diagnostics.DebuggerNonUserCodeAttribute",
        "System.Diagnostics.DebuggerStepThroughAttribute",
        "System.ParamArrayAttribute",
        "System.Reflection.DefaultMemberAttribute",
        "System.Runtime.CompilerServices.AsyncIteratorStateMachineAttribute",
        "System.Runtime.CompilerServices.AsyncStateMachineAttribute",
        "System.Runtime.CompilerServices.CompilerFeatureRequiredAttribute",
        "System.Runtime.CompilerServices.CompilerGeneratedAttribute",
        "System.Runtime.CompilerServices.DecimalConstantAttribute",
        "System.Runtime.CompilerServices.DynamicAttribute",
        "System.Runtime.CompilerServices.ExtensionAttribute",
        "System.Runtime.CompilerServices.ExtensionMarkerAttribute",
        "System.Runtime.CompilerServices.IsByRefLikeAttribute",
        "System.Runtime.CompilerServices.IsReadOnlyAttribute",
        "System.Runtime.CompilerServices.IsUnmanagedAttribute",
        "System.Runtime.CompilerServices.IteratorStateMachineAttribute",
        "System.Runtime.CompilerServices.NativeIntegerAttribute",
        "System.Runtime.CompilerServices.NullableAttribute",
        "System.Runtime.CompilerServices.NullableContextAttribute",
        "System.Runtime.CompilerServices.NullablePublicOnlyAttribute",
        "System.Runtime.CompilerServices.ParamCollectionAttribute",
        "System.Runtime.CompilerServices.PreserveBaseOverridesAttribute",
        "System.Runtime.CompilerServices.RefSafetyRulesAttribute",
        "System.Runtime.CompilerServices.RequiredMemberAttribute",
        "System.Runtime.CompilerServices.RequiresLocationAttribute",
        "System.Runtime.CompilerServices.ScopedRefAttribute",
        "System.Runtime.CompilerServices.TupleElementNamesAttribute",
    };

    /// <summary>Classifies one PDB document. Only documents positively recognised as toolchain output count as toolchain:
    /// repository obj/ and bin/ output (the XAML compiler and MSBuild), source generator documents (Roslyn names them
    /// &lt;intermediate dir&gt;/&lt;generator assembly&gt;/&lt;generator type&gt;/&lt;hint&gt;) and NuGet package sources. Anything else that is
    /// not a repository source, for example after a PathMap or with another spelling of the root, is unrecognised.</summary>
    public static DocumentFacts Classify(string document, string repositoryRoot)
    {
        var path = document.Replace('\\', '/');
        if (!path.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)) return new(DocumentKind.Mapped, document, "");
        var root = repositoryRoot.Replace('\\', '/').TrimEnd('/') + "/";
        string? relative = path.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? path[root.Length..]
            : path.StartsWith("/_/", StringComparison.Ordinal) ? path[3..] : null;
        if (relative is null) return new(IsPackageSource(path) ? DocumentKind.Package : DocumentKind.Unrecognized, document, "");
        var parts = relative.Split('/');
        if (parts.Any(part => part.Length == 0 || part is "." or "..")) return new(DocumentKind.Unrecognized, document, "");
        var output = Array.FindIndex(parts, part => part.Equals("obj", StringComparison.OrdinalIgnoreCase) || part.Equals("bin", StringComparison.OrdinalIgnoreCase));
        if (output < 0)
        {
            // Deterministic /_/ paths count only when the source really is in this checkout (package PDBs use /_/ too).
            var exists = !path.StartsWith("/_/", StringComparison.Ordinal) || File.Exists(Path.Combine(repositoryRoot, relative));
            return new(exists ? DocumentKind.HandWritten : DocumentKind.Unrecognized, document, "");
        }
        if (parts.Length - output - 1 >= 3 && GeneratorTypeFolder.IsMatch(parts[^2]))
            return new(ToolchainGenerators.Contains(parts[^3]) ? DocumentKind.ToolchainGenerator : DocumentKind.Generator, document, parts[^3] + "/" + parts[^2]);
        return new(DocumentKind.BuildOutput, document, "");
    }

    private static bool IsPackageSource(string path)
    {
        if (path.Contains("/.nuget/packages/", StringComparison.OrdinalIgnoreCase)) return true;
        var packages = Environment.GetEnvironmentVariable("NUGET_PACKAGES")?.Replace('\\', '/').TrimEnd('/');
        return !string.IsNullOrEmpty(packages) && path.StartsWith(packages + "/", StringComparison.OrdinalIgnoreCase);
    }
}

/// <summary>What produced a PDB document.</summary>
public enum DocumentKind
{
    /// <summary>Repository C# outside obj/ and bin/.</summary>
    HandWritten,
    /// <summary>Repository obj/ or bin/ output outside a source generator folder: the WinUI XAML compiler and MSBuild.</summary>
    BuildOutput,
    /// <summary>A source generator whose output never implements hand-written declarations (System.Text.Json, CsWinRT).</summary>
    ToolchainGenerator,
    /// <summary>Any other source generator. Members it adds to a hand-written type implement hand-written declarations or
    /// attributes and need approval; types it declares by itself are toolchain output.</summary>
    Generator,
    /// <summary>NuGet package sources, for example the Windows App SDK auto-initializers.</summary>
    Package,
    /// <summary>A non-C# document (#line mapped, for example XAML). It decides nothing by itself.</summary>
    Mapped,
    /// <summary>Anything else: treated as hand-written, and it fails the identity check.</summary>
    Unrecognized,
}

public readonly record struct DocumentFacts(DocumentKind Kind, string Path, string Generator);

public static class Allowlist
{
    public static IEnumerable<string> Lines(IEnumerable<string> file) =>
        file.Select(line => line.TrimEnd('\r')).Where(line => line.Length > 0 && !line.StartsWith('#'));

    public static string[] Read(string path) =>
        File.Exists(path) ? Lines(File.ReadAllLines(path)).ToArray() : throw new FileNotFoundException("Missing Release allowlist: " + path, path);

    public static string Render(string assemblyName, IEnumerable<string> lines) => string.Join('\n', new[]
    {
        "# Release allowlist for " + assemblyName + ". Every hand-written type, member, tagged member, friend",
        "# assembly and switch-like literal in the shipping Release assembly must appear here; nothing else may.",
        "# Toolchain output (WinUI XAML compiler, CsWinRT, source generators, Windows App SDK sources) is",
        "# classified from the PDB and recorded only as evidence. Regenerate after a reviewed product change:",
        "#   dotnet run --project apps/windows/build/ReleaseBoundary -c Release -- update <Release assembly> <this file>",
        "# then review the diff. Fakes, harnesses, probes, seams and DEBUG-only helpers belong under #if DEBUG.",
    }.Concat(lines)) + "\n";
}

public static class AssemblyInspector
{
    private static readonly Guid TypeDefinitionDocuments = new("932E74BC-DBA9-4478-8D46-0F32A7BAB3D3");
    private static readonly Dictionary<short, OperandType> Operands = typeof(OpCodes).GetFields(BindingFlags.Public | BindingFlags.Static)
        .Select(field => (OpCode)field.GetValue(null)!).GroupBy(code => code.Value).ToDictionary(group => group.Key, group => group.First().OperandType);

    public static AssemblyInventory Read(string path, string repositoryRoot)
    {
        var full = Path.GetFullPath(path);
        var bytes = File.ReadAllBytes(full);
        using var pe = new PEReader(new MemoryStream(bytes));
        var reader = pe.GetMetadataReader();
        MetadataReaderProvider? pdbProvider = null;
        string? pdbPath = null;
        var hasPdb = pe.TryOpenAssociatedPortablePdb(full, candidate => File.Exists(candidate) ? File.OpenRead(candidate) : null,
            out pdbProvider, out pdbPath);
        using (pdbProvider)
        {
            var pdb = hasPdb ? pdbProvider!.GetMetadataReader() : null;
            var scan = new Scan(reader, pe, pdb, repositoryRoot);
            scan.Run();
            var identity = new AssemblyIdentity(full, reader.GetString(reader.GetAssemblyDefinition().Name), scan.Configuration,
                pe.PEHeaders.CoffHeader.Machine.ToString(), (pe.PEHeaders.CorHeader!.Flags & CorFlags.ILOnly) != 0, scan.Optimized,
                Convert.ToHexString(SHA256.HashData(bytes)), hasPdb ? (pdbPath ?? "embedded") : null);
            return new(identity, scan.Entries, scan.Forbidden.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
                scan.Unrecognized.Order(StringComparer.Ordinal).ToArray(), repositoryRoot);
        }
    }

    /// <summary>Identity errors for a shipping assembly: wrong name (for example the typecheck surrogate), Debug, unoptimized,
    /// missing PDB (needed to classify toolchain output), the wrong architecture, or a classification that cannot be trusted
    /// because PDB documents are outside --repo-root or no hand-written type was found.</summary>
    public static IEnumerable<string> IdentityErrors(AssemblyInventory inventory, string expectedName, Machine? requiredMachine, bool allowAnyCpu)
    {
        var identity = inventory.Identity;
        if (identity.Name != expectedName) yield return $"{expectedName}: expected assembly {expectedName}, found {identity.Name} at {identity.Path}";
        if (identity.Configuration != "Release") yield return $"{expectedName}: expected Release configuration, found '{identity.Configuration}'";
        if (!identity.Optimized) yield return $"{expectedName}: the assembly is not optimized (DebuggableAttribute disables optimizations)";
        if (identity.PdbPath is null) yield return $"{expectedName}: no matching portable PDB beside {identity.Path}; it is required to classify toolchain output";
        if (requiredMachine is { } machine && identity.Machine != machine.ToString() &&
            !(allowAnyCpu && identity.IlOnly && identity.Machine == nameof(Machine.I386)))
            yield return $"{expectedName}: expected {machine} code, found {identity.Machine}";
        if (inventory.UnrecognizedDocuments.Count > 0)
            yield return $"{expectedName}: {inventory.UnrecognizedDocuments.Count} PDB document(s) are neither under --repo-root {inventory.RepositoryRoot} " +
                $"nor recognised toolchain output, for example {inventory.UnrecognizedDocuments[0]}. Pass the repository root exactly as the " +
                "compiler saw it (not a symlink alias) and build without PathMap; their code was treated as hand-written";
        if (identity.PdbPath is not null && inventory.HandWrittenTypes == 0)
            yield return $"{expectedName}: no hand-written types were found, so the classification collapsed; check --repo-root and the PDB paths";
    }

    private sealed class Scan(MetadataReader reader, PEReader pe, MetadataReader? pdb, string repositoryRoot)
    {
        private readonly Names names = new(reader);
        private readonly Dictionary<TypeDefinitionHandle, TypeFacts> types = [];
        private readonly Dictionary<TypeDefinitionHandle, bool> buildOutputTypes = [];
        private readonly Dictionary<DocumentHandle, DocumentFacts> documents = [];
        private readonly Dictionary<MethodDefinitionHandle, Decision?> methodDecisions = [];
        private readonly Dictionary<int, List<MethodDefinitionHandle>> literalUses = [];
        private readonly HashSet<int> environmentNames = [];
        private readonly Dictionary<int, bool> environmentApis = [];
        private readonly Dictionary<TypeDefinitionHandle, List<TypeDefinitionHandle>> implementers = [];
        private readonly Dictionary<FieldDefinitionHandle, List<MethodDefinitionHandle>> fieldUses = [];
        private Dictionary<MethodDefinitionHandle, MethodDefinitionHandle>? stateMachines;
        internal readonly List<InventoryEntry> Entries = [];
        internal readonly List<string> Forbidden = [];
        internal readonly HashSet<string> Unrecognized = new(StringComparer.Ordinal);
        internal string Configuration = "";
        internal bool Optimized = true;

        private sealed record TypeFacts(string Name, bool CompilerGenerated, EntryOrigin Origin, string Evidence);

        /// <summary>The origin decided by a set of PDB documents. <see cref="Kind"/> is the deciding document kind;
        /// <see cref="Detail"/> names the generator of a generator document or the path of a mapped document.</summary>
        private sealed record Decision(EntryOrigin Origin, string Evidence, DocumentKind Kind, string Detail);

        internal void Run()
        {
            foreach (var handle in reader.TypeDefinitions)
                foreach (var implementation in reader.GetTypeDefinition(handle).GetInterfaceImplementations())
                    if (reader.GetInterfaceImplementation(implementation).Interface is { Kind: HandleKind.TypeDefinition } contract)
                    {
                        if (!implementers.TryGetValue((TypeDefinitionHandle)contract, out var list)) implementers[(TypeDefinitionHandle)contract] = list = [];
                        list.Add(handle);
                    }
            foreach (var method in reader.MethodDefinitions) ScanBody(method);
            foreach (var handle in reader.TypeDefinitions)
            {
                var facts = Type(handle);
                var type = reader.GetTypeDefinition(handle);
                if (facts.CompilerGenerated) continue;
                Add("type " + facts.Name, facts.Origin, facts.Evidence);
                foreach (var method in type.GetMethods())
                {
                    if (reader.GetString(reader.GetMethodDefinition(method).Name).StartsWith('<')) continue;
                    var (origin, evidence) = Method(method, facts);
                    Add("member " + MethodOwner(method), origin, evidence);
                }
                foreach (var fieldHandle in type.GetFields())
                {
                    if (reader.GetString(reader.GetFieldDefinition(fieldHandle).Name).StartsWith('<')) continue;
                    var (origin, evidence) = Field(fieldHandle, facts);
                    Add("member " + FieldOwner(fieldHandle), origin, evidence);
                }
            }
            foreach (var handle in reader.CustomAttributes) Attribute(reader.GetCustomAttribute(handle));
            Literals();
            Constants();
        }

        private void Add(string key, EntryOrigin origin, string evidence, bool? approval = null)
        {
            Entries.Add(new(key, origin, approval ?? origin == EntryOrigin.Source, evidence));
            if (Rules.HasDebugEnvironmentMarker(key)) Forbidden.Add("Debug environment name: " + key);
        }

        /// <summary>Hand-written (or unrecognised) documents make a record hand-written. Otherwise a non-exempt source generator
        /// document, then any toolchain document decides. Mapped (#line) documents never decide when other documents exist; a
        /// record with only mapped documents is resolved by <see cref="Mapped"/>.</summary>
        private Decision? Decide(IEnumerable<DocumentFacts> seen)
        {
            DocumentFacts? handWritten = null, unrecognized = null, generator = null, toolchain = null, mapped = null;
            foreach (var document in seen)
            {
                switch (document.Kind)
                {
                    case DocumentKind.HandWritten: handWritten ??= document; break;
                    case DocumentKind.Unrecognized: unrecognized ??= document; Unrecognized.Add(document.Path); break;
                    case DocumentKind.Generator: generator ??= document; break;
                    case DocumentKind.Mapped: mapped ??= document; break;
                    default: toolchain ??= document; break;
                }
            }
            if (handWritten is { } source) return new(EntryOrigin.Source, Relative(source.Path), DocumentKind.HandWritten, "");
            if (unrecognized is null && generator is null && toolchain is null && mapped is { } lonely)
                return new(EntryOrigin.Source, "#line-mapped document " + lonely.Path, DocumentKind.Mapped, lonely.Path);
            if (unrecognized is { } unknown)
                return new(EntryOrigin.Source, "unrecognised document " + unknown.Path + " (outside --repo-root and the NuGet root): treated as hand-written",
                    DocumentKind.Unrecognized, "");
            if (generator is { } driven)
                return new(EntryOrigin.Generated, "source generator " + driven.Generator + " document " + Relative(driven.Path), DocumentKind.Generator, driven.Generator);
            if (toolchain is { } output)
                return new(EntryOrigin.Generated, "generated document " + Relative(output.Path), output.Kind, output.Generator);
            return null;
        }

        /// <summary>Code whose every sequence point is #line-mapped to a non-C# file (for example a .xaml file, possibly by a
        /// relative path) is XAML compiler output only inside a type that has obj/ XAML output. Anywhere else it is unrecognised:
        /// treated as hand-written, and it fails the identity check.</summary>
        private Decision Mapped(Decision decision, TypeDefinitionHandle owner)
        {
            if (!owner.IsNil && HasBuildOutput(owner))
                return new(EntryOrigin.Generated, decision.Evidence + " in a type with obj/ XAML output", DocumentKind.BuildOutput, "");
            Unrecognized.Add(decision.Detail);
            return new(EntryOrigin.Source, "unrecognised " + decision.Evidence + ": treated as hand-written", DocumentKind.Unrecognized, "");
        }

        private TypeFacts Type(TypeDefinitionHandle handle)
        {
            if (types.TryGetValue(handle, out var known)) return known;
            var type = reader.GetTypeDefinition(handle);
            var name = names.Definition(handle);
            var declaring = type.GetDeclaringType();
            var parent = declaring.IsNil ? null : Type(declaring);
            var compilerGenerated = Rules.IsSynthesizedTypeName(reader.GetString(type.Name)) || parent?.CompilerGenerated == true;
            TypeFacts facts;
            var own = Decide(OwnDocuments(handle));
            if (own is { Kind: DocumentKind.Mapped } mapped) own = Mapped(mapped, declaring);
            if (own is { } decision)
                facts = new(name, compilerGenerated, decision.Origin, decision.Kind == DocumentKind.Generator
                    ? "declared entirely by " + decision.Evidence : decision.Evidence);
            else if (!declaring.IsNil && GeneratedCodeTool(type.GetCustomAttributes()) == Rules.XamlCompiler && HasBuildOutput(declaring))
                facts = new(name, compilerGenerated, EntryOrigin.Generated, "GeneratedCode " + Rules.XamlCompiler + " in a type with obj/ XAML output");
            else if (GeneratedImplementers(handle) is { } implementer)
                facts = new(name, compilerGenerated, EntryOrigin.Generated, "interface implemented only by generated " + implementer);
            else if (XamlCompanion(handle) is { } companion)
                facts = new(name, compilerGenerated, EntryOrigin.Generated, "XAML compiler companion of " + companion);
            else if (parent is not null)
                facts = new(name, compilerGenerated, parent.Origin, "nested in " + parent.Name + ": " + parent.Evidence);
            else
                facts = new(name, compilerGenerated, EntryOrigin.Source, pdb is null ? "no PDB: treated as hand-written" : "no source document: treated as hand-written");
            types[handle] = facts;
            return facts;
        }

        /// <summary>Whether a type has WinUI XAML compiler (obj/ build) output among its own documents.</summary>
        private bool HasBuildOutput(TypeDefinitionHandle handle)
        {
            if (!buildOutputTypes.TryGetValue(handle, out var known))
                buildOutputTypes[handle] = known = OwnDocuments(handle).Any(document => document.Kind == DocumentKind.BuildOutput);
            return known;
        }

        /// <summary>Documents of a type's own methods (async and iterator kickoffs through their state machines), its
        /// compiler-generated closures and state machines, and Roslyn's TypeDefinitionDocuments for body-less top-level types.
        /// Nested types without documents are covered by the declaring type, exactly as Roslyn records them.</summary>
        private IEnumerable<DocumentFacts> OwnDocuments(TypeDefinitionHandle handle)
        {
            var type = reader.GetTypeDefinition(handle);
            foreach (var document in type.GetMethods().SelectMany(MethodDocuments).Concat(DefinitionDocuments(handle))) yield return document;
            foreach (var nested in type.GetNestedTypes())
                if (Rules.IsSynthesizedTypeName(reader.GetString(reader.GetTypeDefinition(nested).Name)))
                    foreach (var document in OwnDocuments(nested)) yield return document;
        }

        /// <summary>The XAML compiler always emits I&lt;Page&gt;_BindingsScopeConnector beside its GeneratedCode-tagged
        /// I&lt;Page&gt;_Bindings, even when no binding scope implements it.</summary>
        private string? XamlCompanion(TypeDefinitionHandle handle)
        {
            var type = reader.GetTypeDefinition(handle);
            var simple = reader.GetString(type.Name);
            if ((type.Attributes & TypeAttributes.Interface) == 0 || type.GetDeclaringType().IsNil ||
                !simple.EndsWith("_BindingsScopeConnector", StringComparison.Ordinal) || !HasBuildOutput(type.GetDeclaringType())) return null;
            var sibling = simple[..^"ScopeConnector".Length];
            foreach (var nested in reader.GetTypeDefinition(type.GetDeclaringType()).GetNestedTypes())
            {
                var candidate = reader.GetTypeDefinition(nested);
                if (reader.GetString(candidate.Name) == sibling && GeneratedCodeTool(candidate.GetCustomAttributes()) == Rules.XamlCompiler)
                    return names.Definition(nested);
            }
            return null;
        }

        /// <summary>The XAML compiler emits some body-less nested interfaces without GeneratedCode (for example
        /// I&lt;Page&gt;_BindingsScopeConnector). They are toolchain output when every implementer is toolchain output.</summary>
        private string? GeneratedImplementers(TypeDefinitionHandle handle)
        {
            var type = reader.GetTypeDefinition(handle);
            if ((type.Attributes & TypeAttributes.Interface) == 0 || !implementers.TryGetValue(handle, out var users) || users.Count == 0) return null;
            var facts = users.Select(Type).ToArray();
            return facts.All(user => user.Origin == EntryOrigin.Generated) ? facts[0].Name : null;
        }

        private Decision? MethodDecision(MethodDefinitionHandle handle)
        {
            if (!methodDecisions.TryGetValue(handle, out var known))
            {
                known = Decide(MethodDocuments(handle));
                if (known is { Kind: DocumentKind.Mapped } mapped) known = Mapped(mapped, reader.GetMethodDefinition(handle).GetDeclaringType());
                methodDecisions[handle] = known;
            }
            return known;
        }

        /// <summary>A method's origin is where its body is declared. A body that a non-exempt source generator adds to a
        /// hand-written type implements a hand-written declaration or attribute ([ObservableProperty] accessors,
        /// [GeneratedRegex] and [LibraryImport] partials), so it needs approval. Body-less methods follow their type.</summary>
        private (EntryOrigin Origin, string Evidence) Method(MethodDefinitionHandle handle, TypeFacts owner)
        {
            if (MethodDecision(handle) is not { } decision) return (owner.Origin, owner.Evidence);
            if (decision.Kind == DocumentKind.Generator && owner.Origin == EntryOrigin.Source)
                return (EntryOrigin.Source, decision.Evidence + ", added to hand-written " + owner.Name + " (" + owner.Evidence + ")");
            return (decision.Origin, decision.Evidence);
        }

        /// <summary>Fields have no documents. A field of a hand-written type is toolchain output only when the WinUI XAML compiler
        /// tagged it and the type has obj/ XAML output, or when only System.Text.Json or CsWinRT generated code uses it (for
        /// example JsonSerializerContext caches). Any other GeneratedCode tag or use by other generated code proves nothing.</summary>
        private (EntryOrigin Origin, string Evidence) Field(FieldDefinitionHandle handle, TypeFacts owner)
        {
            if (owner.Origin == EntryOrigin.Generated) return (owner.Origin, owner.Evidence);
            var field = reader.GetFieldDefinition(handle);
            if (GeneratedCodeTool(field.GetCustomAttributes()) == Rules.XamlCompiler && HasBuildOutput(field.GetDeclaringType()))
                return (EntryOrigin.Generated, "GeneratedCode " + Rules.XamlCompiler + " in a type with obj/ XAML output");
            if (fieldUses.TryGetValue(handle, out var uses) && uses.Count > 0)
            {
                var decisions = uses.Select(MethodDecision).ToArray();
                if (decisions.All(decision => decision is { Kind: DocumentKind.ToolchainGenerator }))
                    return (EntryOrigin.Generated, "used only by " + decisions[0]!.Detail + " output " + MethodOwner(uses[0]));
            }
            return (owner.Origin, owner.Evidence);
        }

        private IEnumerable<DocumentFacts> MethodDocuments(MethodDefinitionHandle handle)
        {
            if (pdb is null) yield break;
            var info = pdb.GetMethodDebugInformation(handle.ToDebugInformationHandle());
            if (info.SequencePointsBlob.IsNil)
            {
                if (StateMachines().TryGetValue(handle, out var moveNext))
                    foreach (var document in MethodDocuments(moveNext)) yield return document;
                yield break;
            }
            foreach (var document in info.GetSequencePoints().Select(point => point.Document).Distinct())
                yield return Document(document);
        }

        private Dictionary<MethodDefinitionHandle, MethodDefinitionHandle> StateMachines()
        {
            if (stateMachines is not null) return stateMachines;
            stateMachines = [];
            if (pdb is null) return stateMachines;
            foreach (var handle in pdb.MethodDebugInformation)
            {
                var kickoff = pdb.GetMethodDebugInformation(handle).GetStateMachineKickoffMethod();
                if (!kickoff.IsNil) stateMachines[kickoff] = handle.ToDefinitionHandle();
            }
            return stateMachines;
        }

        private IEnumerable<DocumentFacts> DefinitionDocuments(TypeDefinitionHandle handle)
        {
            if (pdb is null) yield break;
            foreach (var cdiHandle in pdb.GetCustomDebugInformation(handle))
            {
                var cdi = pdb.GetCustomDebugInformation(cdiHandle);
                if (pdb.GetGuid(cdi.Kind) != TypeDefinitionDocuments) continue;
                var blob = pdb.GetBlobReader(cdi.Value);
                while (blob.RemainingBytes > 0) yield return Document(MetadataTokens.DocumentHandle(blob.ReadCompressedInteger()));
            }
        }

        private DocumentFacts Document(DocumentHandle handle)
        {
            if (!documents.TryGetValue(handle, out var known))
                documents[handle] = known = Rules.Classify(pdb!.GetString(pdb.GetDocument(handle).Name), repositoryRoot);
            return known;
        }

        private string Relative(string path)
        {
            var normalized = path.Replace('\\', '/');
            var root = repositoryRoot.Replace('\\', '/').TrimEnd('/') + "/";
            return normalized.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? normalized[root.Length..] : normalized;
        }

        private string? GeneratedCodeTool(CustomAttributeHandleCollection attributes)
        {
            foreach (var handle in attributes)
            {
                var attribute = reader.GetCustomAttribute(handle);
                if (names.AttributeType(attribute) != "System.CodeDom.Compiler.GeneratedCodeAttribute") continue;
                return Decode(attribute) is { FixedArguments: [{ Value: string tool }, ..] } ? tool : "unknown tool";
            }
            return null;
        }

        private string MethodOwner(MethodDefinitionHandle handle)
        {
            var method = reader.GetMethodDefinition(handle);
            var signature = method.DecodeSignature(names, null);
            var generic = signature.GenericParameterCount > 0 ? "`" + signature.GenericParameterCount : "";
            return $"{names.Definition(method.GetDeclaringType())} :: method {Access((int)(method.Attributes & MethodAttributes.MemberAccessMask))} " +
                $"{reader.GetString(method.Name)}{generic}({string.Join(",", signature.ParameterTypes)})";
        }

        private string FieldOwner(FieldDefinitionHandle handle)
        {
            var field = reader.GetFieldDefinition(handle);
            return $"{names.Definition(field.GetDeclaringType())} :: field {Access((int)(field.Attributes & FieldAttributes.FieldAccessMask))} {reader.GetString(field.Name)}";
        }

        private static string Access(int access) => access switch
        {
            1 => "private", 2 => "private-protected", 3 => "internal", 4 => "protected", 5 => "protected-internal", 6 => "public", _ => "compiler",
        };

        private void Attribute(CustomAttribute attribute)
        {
            var type = names.AttributeType(attribute);
            var value = Decode(attribute);
            var rendered = value is null ? "(blob " + Convert.ToHexString(reader.GetBlobBytes(attribute.Value)) + ")"
                : "(" + string.Join(",", value.Value.FixedArguments.Select(Names.Value)
                    .Concat(value.Value.NamedArguments.Select(argument => argument.Name + "=" + Names.Value(argument)))) + ")";
            foreach (var text in value is null ? [] : Strings(value.Value))
                if (Rules.HasDebugEnvironmentMarker(text))
                    Forbidden.Add($"Debug environment literal {Json(text)} in {type} on {Describe(attribute.Parent)}");
            if (type == "System.Diagnostics.ConditionalAttribute" && value is { FixedArguments: [{ Value: "DEBUG" }] })
                Forbidden.Add("DEBUG-only member ships in Release: " + Describe(attribute.Parent) + " carries [Conditional(\"DEBUG\")]");
            if (attribute.Parent.Kind == HandleKind.AssemblyDefinition)
            {
                if (type == "System.Reflection.AssemblyConfigurationAttribute") Configuration = value is { FixedArguments: [{ Value: string configuration }] } ? configuration : "";
                if (type == "System.Diagnostics.DebuggableAttribute") Optimized = Optimizes(value);
                Add($"attribute assembly @ {type}{rendered}", EntryOrigin.Source, "assembly attribute",
                    approval: type == "System.Runtime.CompilerServices.InternalsVisibleToAttribute");
                return;
            }
            if (Rules.BookkeepingAttributes.Contains(type) || type.StartsWith("WinRT.", StringComparison.Ordinal)) return;
            if (Owner(attribute.Parent) is not { } owner) return;
            Add($"attribute {owner.Key} @ {type}{rendered}", owner.Origin, owner.Evidence);
        }

        private static bool Optimizes(CustomAttributeValue<string>? value) => value switch
        {
            { FixedArguments: [{ Value: int modes }] } => (modes & 0x100) == 0,
            { FixedArguments: [_, { Value: bool disableOptimizer }] } => !disableOptimizer,
            _ => true,
        };

        private (string Key, EntryOrigin Origin, string Evidence)? Owner(EntityHandle parent)
        {
            switch (parent.Kind)
            {
                case HandleKind.TypeDefinition:
                    var type = Type((TypeDefinitionHandle)parent);
                    return type.CompilerGenerated ? null : (type.Name, type.Origin, type.Evidence);
                case HandleKind.MethodDefinition:
                    var method = (MethodDefinitionHandle)parent;
                    var declaring = Type(reader.GetMethodDefinition(method).GetDeclaringType());
                    if (declaring.CompilerGenerated || reader.GetString(reader.GetMethodDefinition(method).Name).StartsWith('<')) return null;
                    var (methodOrigin, methodEvidence) = Method(method, declaring);
                    return (MethodOwner(method), methodOrigin, methodEvidence);
                case HandleKind.FieldDefinition:
                    var field = (FieldDefinitionHandle)parent;
                    var fieldType = Type(reader.GetFieldDefinition(field).GetDeclaringType());
                    if (fieldType.CompilerGenerated || reader.GetString(reader.GetFieldDefinition(field).Name).StartsWith('<')) return null;
                    var (fieldOrigin, fieldEvidence) = Field(field, fieldType);
                    return (FieldOwner(field), fieldOrigin, fieldEvidence);
                case HandleKind.PropertyDefinition:
                    var property = reader.GetPropertyDefinition((PropertyDefinitionHandle)parent);
                    var accessors = property.GetAccessors();
                    return Accessor(accessors.Getter.IsNil ? accessors.Setter : accessors.Getter, "property " + reader.GetString(property.Name));
                case HandleKind.EventDefinition:
                    var item = reader.GetEventDefinition((EventDefinitionHandle)parent);
                    return Accessor(item.GetAccessors().Adder, "event " + reader.GetString(item.Name));
                default:
                    return null;
            }
        }

        private (string Key, EntryOrigin Origin, string Evidence)? Accessor(MethodDefinitionHandle accessor, string member)
        {
            if (accessor.IsNil) return null;
            var owner = Type(reader.GetMethodDefinition(accessor).GetDeclaringType());
            if (owner.CompilerGenerated || member.Contains('<')) return null;
            var (origin, evidence) = Method(accessor, owner);
            return ($"{owner.Name} :: {member}", origin, evidence);
        }

        private string Describe(EntityHandle parent) => parent.Kind switch
        {
            HandleKind.AssemblyDefinition => "assembly",
            HandleKind.ModuleDefinition => "module",
            HandleKind.TypeDefinition => names.Definition((TypeDefinitionHandle)parent),
            HandleKind.MethodDefinition => MethodOwner((MethodDefinitionHandle)parent),
            HandleKind.FieldDefinition => FieldOwner((FieldDefinitionHandle)parent),
            HandleKind.Parameter => "parameter of a method",
            _ => parent.Kind.ToString(),
        };

        private CustomAttributeValue<string>? Decode(CustomAttribute attribute)
        {
            // Enum arguments from other assemblies are decoded as Int32; anything undecodable is rendered as its raw blob.
            try { return attribute.DecodeValue(names); }
            catch (Exception exception) when (exception is not OutOfMemoryException) { return null; }
        }

        private static IEnumerable<string> Strings(CustomAttributeValue<string> value) =>
            value.FixedArguments.Concat(value.NamedArguments.Select(argument => new CustomAttributeTypedArgument<string>(argument.Type, argument.Value)))
                .SelectMany(Strings);

        private static IEnumerable<string> Strings(CustomAttributeTypedArgument<string> argument) => argument.Value switch
        {
            string text => [text],
            ImmutableArray<CustomAttributeTypedArgument<string>> array => array.SelectMany(Strings),
            _ => [],
        };

        private void ScanBody(MethodDefinitionHandle handle)
        {
            var method = reader.GetMethodDefinition(handle);
            if (method.RelativeVirtualAddress == 0) return;
            var il = pe.GetMethodBody(method.RelativeVirtualAddress).GetILReader();
            var instruction = 0;
            var recentStrings = new List<(int Instruction, int Offset)>();
            while (il.RemainingBytes > 0)
            {
                instruction++;
                short code = il.ReadByte();
                if (code == 0xFE) code = unchecked((short)(0xFE00 | il.ReadByte()));
                var operand = Operands.TryGetValue(code, out var known) ? known : throw new BadImageFormatException($"Unknown IL opcode 0x{code:X}");
                switch (operand)
                {
                    case OperandType.InlineField:
                        if (ResolveField(il.ReadInt32()) is { } field)
                        {
                            if (!fieldUses.TryGetValue(field, out var users)) fieldUses[field] = users = [];
                            users.Add(handle);
                        }
                        break;
                    case OperandType.InlineString:
                        var token = il.ReadInt32();
                        if (!literalUses.TryGetValue(token & 0xFFFFFF, out var uses)) literalUses[token & 0xFFFFFF] = uses = [];
                        uses.Add(handle);
                        recentStrings.Add((instruction, token & 0xFFFFFF));
                        if (recentStrings.Count > 4) recentStrings.RemoveAt(0);
                        break;
                    case OperandType.InlineMethod:
                        // A literal loaded just before an environment-variable call is a variable name, whatever its shape or case.
                        var callee = il.ReadInt32();
                        if (code is 0x28 or 0x6F && IsEnvironmentVariableApi(callee))
                            foreach (var recent in recentStrings)
                                if (instruction - recent.Instruction <= 3) environmentNames.Add(recent.Offset);
                        break;
                    case OperandType.InlineSwitch:
                        var targets = il.ReadInt32(); // read the count before computing the new offset
                        il.Offset += targets * 4;
                        break;
                    case OperandType.InlineI8 or OperandType.InlineR: il.Offset += 8; break;
                    case OperandType.InlineNone: break;
                    case OperandType.ShortInlineBrTarget or OperandType.ShortInlineI or OperandType.ShortInlineVar: il.Offset += 1; break;
                    case OperandType.InlineVar: il.Offset += 2; break;
                    default: il.Offset += 4; break;
                }
            }
        }

        private bool IsEnvironmentVariableApi(int token)
        {
            if (environmentApis.TryGetValue(token, out var known)) return known;
            var entity = MetadataTokens.EntityHandle(token);
            known = false;
            if (entity.Kind == HandleKind.MemberReference)
            {
                var reference = reader.GetMemberReference((MemberReferenceHandle)entity);
                if (reference.Parent.Kind == HandleKind.TypeReference)
                {
                    var type = reader.GetTypeReference((TypeReferenceHandle)reference.Parent);
                    known = reader.GetString(type.Namespace) == "System" && reader.GetString(type.Name) == "Environment" &&
                        reader.GetString(reference.Name) is "GetEnvironmentVariable" or "SetEnvironmentVariable";
                }
            }
            return environmentApis[token] = known;
        }

        private FieldDefinitionHandle? ResolveField(int token)
        {
            var entity = MetadataTokens.EntityHandle(token);
            if (entity.Kind == HandleKind.FieldDefinition) return (FieldDefinitionHandle)entity;
            if (entity.Kind != HandleKind.MemberReference) return null;
            var reference = reader.GetMemberReference((MemberReferenceHandle)entity);
            if (reference.Parent.Kind != HandleKind.TypeSpecification) return null;
            var blob = reader.GetBlobReader(reader.GetTypeSpecification((TypeSpecificationHandle)reference.Parent).Signature);
            if (blob.ReadSignatureTypeCode() != SignatureTypeCode.GenericTypeInstance) return null;
            blob.ReadSignatureTypeCode();
            if (blob.ReadTypeHandle() is not { Kind: HandleKind.TypeDefinition } generic) return null;
            var name = reader.GetString(reference.Name);
            foreach (var candidate in reader.GetTypeDefinition((TypeDefinitionHandle)generic).GetFields())
                if (reader.GetString(reader.GetFieldDefinition(candidate).Name) == name) return candidate;
            return null;
        }

        private void Literals()
        {
            if (reader.GetHeapSize(HeapIndex.UserString) <= 1) return;
            var handle = MetadataTokens.UserStringHandle(1);
            while (!handle.IsNil)
            {
                var text = reader.GetUserString(handle);
                var offset = MetadataTokens.GetHeapOffset(handle);
                var uses = literalUses.TryGetValue(offset, out var found) ? found : [];
                var origins = uses.Select(use => (use, facts: Method(use, Type(reader.GetMethodDefinition(use).GetDeclaringType())))).ToArray();
                var chosen = origins.FirstOrDefault(pair => pair.facts.Origin == EntryOrigin.Source);
                if (chosen.facts.Evidence is null && origins.Length > 0) chosen = origins[0];
                if (uses.Count == 0 && text.Length == 0) { handle = reader.GetNextHandle(handle); continue; } // heap padding
                if (uses.Count == 0) Literal(text, EntryOrigin.Source, "unreferenced user string");
                else Literal(text, chosen.facts.Origin, chosen.facts.Evidence + " via " + MethodOwner(chosen.use), environmentNames.Contains(offset));
                handle = reader.GetNextHandle(handle);
            }
        }

        private void Constants()
        {
            var parameters = reader.MethodDefinitions.SelectMany(method => reader.GetMethodDefinition(method).GetParameters()
                .Select(parameter => (parameter, method))).ToDictionary(pair => pair.parameter, pair => pair.method);
            for (var row = 1; row <= reader.GetTableRowCount(TableIndex.Constant); row++)
            {
                var constant = reader.GetConstant(MetadataTokens.ConstantHandle(row));
                if (constant.TypeCode != ConstantTypeCode.String) continue;
                var blob = reader.GetBlobReader(constant.Value);
                var text = blob.ReadUTF16(blob.Length);
                (EntryOrigin Origin, string Evidence) owner = constant.Parent.Kind switch
                {
                    HandleKind.FieldDefinition => Constant((FieldDefinitionHandle)constant.Parent),
                    HandleKind.Parameter when parameters.TryGetValue((ParameterHandle)constant.Parent, out var method) =>
                        (Method(method, Type(reader.GetMethodDefinition(method).GetDeclaringType())).Origin, "default parameter value of " + MethodOwner(method)),
                    _ => (EntryOrigin.Source, "constant on " + constant.Parent.Kind),
                };
                Literal(text, owner.Origin, owner.Evidence);
            }
        }

        private (EntryOrigin Origin, string Evidence) Constant(FieldDefinitionHandle field)
        {
            var (origin, _) = Field(field, Type(reader.GetFieldDefinition(field).GetDeclaringType()));
            return (origin, "constant " + FieldOwner(field));
        }

        private void Literal(string text, EntryOrigin origin, string evidence, bool environmentName = false)
        {
            if (Rules.HasDebugEnvironmentMarker(text))
                Forbidden.Add($"Debug environment literal {Json(text)} ({evidence})");
            Entries.Add(new("literal " + Json(text), origin, origin == EntryOrigin.Source && (environmentName || Rules.IsSwitchLike(text)),
                environmentName ? "environment variable name: " + evidence : evidence));
        }

        private static string Json(string text) => Rules.Quote(text);
    }

    internal sealed class Names(MetadataReader reader) : ISignatureTypeProvider<string, object?>, ICustomAttributeTypeProvider<string>
    {
        private static readonly Regex AssemblyVersion = new(@", (?:Version|Culture|PublicKeyToken)=[^,\]]+", RegexOptions.CultureInvariant);
        private static readonly Regex Ordinals = new(@"(?<=(?:d__|b__|c__DisplayClass|f__AnonymousType|g__\w+\|))\d+(?:_\d+)?", RegexOptions.CultureInvariant);
        /// <summary>A file type's metadata name embeds the SHA-256 of its source path, which differs between checkouts.</summary>
        private static readonly Regex FileChecksum = new(@"^(<[A-Za-z0-9_]*>F)[0-9A-F]{64}(?=__)", RegexOptions.CultureInvariant);

        public string Definition(TypeDefinitionHandle handle) => GetTypeFromDefinition(reader, handle, 0);

        public string AttributeType(CustomAttribute attribute) => attribute.Constructor.Kind switch
        {
            HandleKind.MemberReference => Of(reader.GetMemberReference((MemberReferenceHandle)attribute.Constructor).Parent),
            HandleKind.MethodDefinition => Definition(reader.GetMethodDefinition((MethodDefinitionHandle)attribute.Constructor).GetDeclaringType()),
            _ => throw new BadImageFormatException("Unsupported attribute constructor"),
        };

        private string Of(EntityHandle handle) => handle.Kind switch
        {
            HandleKind.TypeDefinition => Definition((TypeDefinitionHandle)handle),
            HandleKind.TypeReference => GetTypeFromReference(reader, (TypeReferenceHandle)handle, 0),
            HandleKind.TypeSpecification => GetTypeFromSpecification(reader, null, (TypeSpecificationHandle)handle, 0),
            _ => throw new BadImageFormatException("Unsupported type handle: " + handle.Kind),
        };

        public static string Value(CustomAttributeTypedArgument<string> argument) => argument.Value switch
        {
            null => "null",
            string text => Rules.Quote(text),
            bool flag => flag ? "true" : "false",
            ImmutableArray<CustomAttributeTypedArgument<string>> array => "[" + string.Join(",", array.Select(Value)) + "]",
            IFormattable number => number.ToString(null, System.Globalization.CultureInfo.InvariantCulture),
            var other => other.ToString() ?? "",
        };

        public static string Value(CustomAttributeNamedArgument<string> argument) => Value(new CustomAttributeTypedArgument<string>(argument.Type, argument.Value));

        private static string Canonical(string name) => Ordinals.Replace(FileChecksum.Replace(name, "$1#"), "#");

        public string GetTypeFromDefinition(MetadataReader metadata, TypeDefinitionHandle handle, byte rawTypeKind)
        {
            var type = metadata.GetTypeDefinition(handle);
            var declaring = type.GetDeclaringType();
            var simple = Canonical(metadata.GetString(type.Name));
            if (!declaring.IsNil) return Definition(declaring) + "+" + simple;
            var space = metadata.GetString(type.Namespace);
            return space.Length == 0 ? simple : space + "." + simple;
        }

        public string GetTypeFromReference(MetadataReader metadata, TypeReferenceHandle handle, byte rawTypeKind)
        {
            var type = metadata.GetTypeReference(handle);
            var simple = Canonical(metadata.GetString(type.Name));
            if (type.ResolutionScope.Kind == HandleKind.TypeReference)
                return GetTypeFromReference(metadata, (TypeReferenceHandle)type.ResolutionScope, rawTypeKind) + "+" + simple;
            var space = metadata.GetString(type.Namespace);
            return space.Length == 0 ? simple : space + "." + simple;
        }

        public string GetTypeFromSpecification(MetadataReader metadata, object? genericContext, TypeSpecificationHandle handle, byte rawTypeKind) =>
            metadata.GetTypeSpecification(handle).DecodeSignature(this, genericContext);
        public string GetTypeFromSerializedName(string name) => AssemblyVersion.Replace(name, "");
        public string GetSystemType() => "System.Type";
        public bool IsSystemType(string type) => type == "System.Type";
        public PrimitiveTypeCode GetUnderlyingEnumType(string type) => PrimitiveTypeCode.Int32;
        public string GetArrayType(string elementType, ArrayShape shape) => elementType + "[" + new string(',', shape.Rank - 1) + "]";
        public string GetByReferenceType(string elementType) => elementType + "&";
        public string GetFunctionPointerType(MethodSignature<string> signature) =>
            "delegate*<" + string.Join(",", signature.ParameterTypes.Append(signature.ReturnType)) + ">";
        public string GetGenericInstantiation(string genericType, ImmutableArray<string> typeArguments) => genericType + "<" + string.Join(",", typeArguments) + ">";
        public string GetGenericMethodParameter(object? genericContext, int index) => "!!" + index;
        public string GetGenericTypeParameter(object? genericContext, int index) => "!" + index;
        public string GetModifiedType(string modifier, string unmodifiedType, bool isRequired) => unmodifiedType + (isRequired ? " modreq(" : " modopt(") + modifier + ")";
        public string GetPinnedType(string elementType) => elementType + " pinned";
        public string GetPointerType(string elementType) => elementType + "*";
        public string GetPrimitiveType(PrimitiveTypeCode typeCode) => typeCode switch
        {
            PrimitiveTypeCode.Boolean => "bool", PrimitiveTypeCode.Byte => "byte", PrimitiveTypeCode.SByte => "sbyte", PrimitiveTypeCode.Char => "char",
            PrimitiveTypeCode.Int16 => "short", PrimitiveTypeCode.UInt16 => "ushort", PrimitiveTypeCode.Int32 => "int", PrimitiveTypeCode.UInt32 => "uint",
            PrimitiveTypeCode.Int64 => "long", PrimitiveTypeCode.UInt64 => "ulong", PrimitiveTypeCode.Single => "float", PrimitiveTypeCode.Double => "double",
            PrimitiveTypeCode.String => "string", PrimitiveTypeCode.Object => "object", PrimitiveTypeCode.IntPtr => "nint", PrimitiveTypeCode.UIntPtr => "nuint",
            PrimitiveTypeCode.Void => "void", PrimitiveTypeCode.TypedReference => "System.TypedReference", _ => typeCode.ToString(),
        };
        public string GetSZArrayType(string elementType) => elementType + "[]";
    }
}
