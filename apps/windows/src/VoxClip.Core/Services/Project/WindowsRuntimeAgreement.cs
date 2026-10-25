using System.Security.Cryptography;
using System.Text;

namespace VoxClip.Core.Services.Project;

/// <summary>The two pinned Microsoft runtime terms, extracted verbatim from the shipped root notices.</summary>
public sealed record WindowsRuntimeTerms(string AppSdk, string MachineLearning, string Sha256)
{
    /// <summary>The two complete licence bodies with identifying labels.</summary>
    public string DisplayText => "Windows App SDK 2.5.1\n\n" + AppSdk +
        "\n\nMicrosoft Windows ML Runtime 2.1.74\n\n" + MachineLearning;
}

/// <summary>Minimal I/O seam for agreement tests. No settings, identity, or network dependency.</summary>
public interface IRuntimeAgreementFiles
{
    /// <summary>Read UTF-8 text.</summary>
    string Read(string path);
    /// <summary>Write UTF-8 text to a new file.</summary>
    void Write(string path, string contents);
    /// <summary>Atomically replace the destination with the temporary file.</summary>
    void Replace(string temporaryPath, string destinationPath);
    /// <summary>Remove a temporary file if it exists.</summary>
    void Delete(string path);
}

/// <summary>Local file implementation; the receipt is replaced atomically in its own directory.</summary>
public sealed class RuntimeAgreementFiles : IRuntimeAgreementFiles
{
    /// <inheritdoc />
    public string Read(string path) => File.ReadAllText(path, Encoding.UTF8);
    /// <inheritdoc />
    public void Write(string path, string contents)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, contents, new UTF8Encoding(false));
    }
    /// <inheritdoc />
    public void Replace(string temporaryPath, string destinationPath) => File.Move(temporaryPath, destinationPath, true);
    /// <inheritdoc />
    public void Delete(string path) { if (File.Exists(path)) File.Delete(path); }
}

/// <summary>Agreement for the pinned official Windows runtimes only; source and FFmpeg licences are separate.</summary>
public sealed class WindowsRuntimeAgreement
{
    /// <summary>Bundled root notices file name.</summary>
    public const string NoticeFileName = "THIRD_PARTY_NOTICES.md";
    /// <summary>Separate versioned per-user acceptance receipt file name.</summary>
    public const string StampFileName = "windows-runtime-agreement.txt";
    private const string AppSdkHeading = "### Windows App SDK 2.5.1 redistributable terms\n";
    private const string MachineLearningHeading = "### Microsoft.Windows.AI.MachineLearning 2.1.74 package terms\n";
    // Hashes of the exact pinned licence bodies, excluding Markdown fences and their trailing newline.
    private const string AppSdkSha256 = "d57ece3ec0746b460f9d00007d0300276a852613d6d1ebd2a1d075255e4ebe28";
    private const string MachineLearningSha256 = "d756d487ee305d582a4097f181674e9a8a97cfcf159db6f8c5f51396805aae22";
    private readonly string noticesPath;
    private readonly string stampPath;
    private readonly IRuntimeAgreementFiles files;

    /// <summary>Use explicit paths and optional I/O for offline tests.</summary>
    public WindowsRuntimeAgreement(string noticesPath, string stampPath, IRuntimeAgreementFiles? files = null)
    {
        this.noticesPath = noticesPath;
        this.stampPath = stampPath;
        this.files = files ?? new RuntimeAgreementFiles();
    }

    /// <summary>Resolve the installed notice and standard user-data locations.</summary>
    public static WindowsRuntimeAgreement ForCurrentUser() => new(
        Path.Combine(AppContext.BaseDirectory, NoticeFileName),
        Path.Combine(DataLocations.Resolve().Root, StampFileName));

    /// <summary>Read exact terms and reject absent, malformed, or changed pinned content.</summary>
    public WindowsRuntimeTerms LoadTerms()
    {
        string source;
        try { source = files.Read(noticesPath); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        { throw new InvalidDataException("The bundled Windows component terms are missing or unreadable. Reinstall VoxClip.", exception); }
        // Git checkouts may convert Markdown to CRLF on Windows. The licence bodies
        // and receipt use LF as their canonical representation on every platform.
        source = source.Replace("\r\n", "\n", StringComparison.Ordinal);
        var appSdk = Extract(source, AppSdkHeading);
        var machineLearning = Extract(source, MachineLearningHeading);
        if (Hash(appSdk) != AppSdkSha256 || Hash(machineLearning) != MachineLearningSha256)
            throw new InvalidDataException("The bundled Windows component terms do not match the pinned runtimes. Reinstall VoxClip.");
        return new(appSdk, machineLearning, Hash(appSdk + "\n\n" + machineLearning));
    }

    /// <summary>Return true only for the exact versioned receipt matching current terms.</summary>
    public bool IsAccepted(WindowsRuntimeTerms terms)
    {
        try { return files.Read(stampPath) == Receipt(terms.Sha256); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return false; }
    }

    /// <summary>Accept exactly the currently bundled terms and write the receipt atomically.</summary>
    public void Accept(WindowsRuntimeTerms terms, string suppliedSha256)
    {
        // Reload the shipped source before writing. A stale dialog or CLI hash cannot accept changed files.
        var current = LoadTerms();
        if (terms.Sha256 != current.Sha256 || suppliedSha256 != current.Sha256)
            throw new InvalidDataException("The Windows component terms changed. Review the current terms and try again.");
        var temporary = stampPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            files.Write(temporary, Receipt(current.Sha256));
            files.Replace(temporary, stampPath);
        }
        finally { files.Delete(temporary); }
    }

    private static string Receipt(string sha256) => "format=voxclip-windows-runtime-agreement/1\nsha256=" + sha256 + "\n";
    private static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private static string Extract(string source, string heading)
    {
        var start = source.IndexOf(heading, StringComparison.Ordinal);
        if (start < 0 || source.IndexOf(heading, start + heading.Length, StringComparison.Ordinal) >= 0)
            throw new InvalidDataException("The bundled Windows component terms are missing or duplicated. Reinstall VoxClip.");
        var fence = source.IndexOf("```text\n", start + heading.Length, StringComparison.Ordinal);
        var nextHeading = source.IndexOf("\n### ", start + heading.Length, StringComparison.Ordinal);
        if (fence < 0 || (nextHeading >= 0 && fence > nextHeading))
            throw new InvalidDataException("The bundled Windows component terms are malformed. Reinstall VoxClip.");
        var bodyStart = fence + "```text\n".Length;
        var end = source.IndexOf("\n```", bodyStart, StringComparison.Ordinal);
        if (end <= bodyStart || (nextHeading >= 0 && end > nextHeading))
            throw new InvalidDataException("The bundled Windows component terms are malformed. Reinstall VoxClip.");
        return source[bodyStart..end];
    }
}
