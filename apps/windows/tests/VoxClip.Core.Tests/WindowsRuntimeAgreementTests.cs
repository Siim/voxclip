using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Core.Tests;

public sealed class WindowsRuntimeAgreementTests
{
    [Fact]
    public void RootNoticesYieldExactPinnedTerms()
    {
        var path = RootNotices();
        var source = File.ReadAllText(path);
        var agreement = new WindowsRuntimeAgreement(path, Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")));
        var terms = agreement.LoadTerms();
        Assert.Equal(Fenced(source, "### Windows App SDK 2.5.1 redistributable terms\n"), terms.AppSdk);
        Assert.Equal(Sha256(terms.AppSdk), terms.Sha256);
        Assert.Equal("d57ece3ec0746b460f9d00007d0300276a852613d6d1ebd2a1d075255e4ebe28", terms.Sha256);
        Assert.Contains("3. DISTRIBUTABLE CODE", terms.DisplayText, StringComparison.OrdinalIgnoreCase);
        // Windows ML is excluded from the app, so its terms are neither shipped nor part of the agreement.
        Assert.DoesNotContain("Windows ML", terms.DisplayText, StringComparison.Ordinal);
        Assert.DoesNotContain("### Microsoft.Windows.AI.MachineLearning", source, StringComparison.Ordinal);
        Assert.DoesNotContain("### Windows App SDK ML", source, StringComparison.Ordinal);
    }

    [Fact]
    public void EarlierWindowsMlAgreementReceiptsAreAskedAgain()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-agreement-v1-").FullName;
        try
        {
            var stamp = Path.Combine(directory, "agreement.txt");
            var agreement = new WindowsRuntimeAgreement(RootNotices(), stamp);
            var terms = agreement.LoadTerms();
            // The format 1 receipt hash covered the Windows App SDK and Windows ML Runtime 2.1.74 terms together.
            File.WriteAllText(stamp, "format=voxclip-windows-runtime-agreement/1\nsha256=2d225eaff1555fab8ea01bc3c4799587da51bd167560a37d2e3d1a6364495f09\n");
            Assert.False(agreement.IsAccepted(terms));
            File.WriteAllText(stamp, "format=voxclip-windows-runtime-agreement/1\nsha256=" + terms.Sha256 + "\n");
            Assert.False(agreement.IsAccepted(terms));
            agreement.Accept(terms, terms.Sha256);
            Assert.Equal("format=voxclip-windows-runtime-agreement/2\nsha256=" + terms.Sha256 + "\n", File.ReadAllText(stamp));
            Assert.True(agreement.IsAccepted(terms));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void DeclineAcceptRepeatAndChangedHash()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-agreement-").FullName;
        try
        {
            var stamp = Path.Combine(directory, "agreement.txt");
            var agreement = new WindowsRuntimeAgreement(RootNotices(), stamp);
            var terms = agreement.LoadTerms();
            Assert.False(agreement.IsAccepted(terms)); // Quit writes nothing.
            Assert.False(File.Exists(stamp));
            Assert.Throws<InvalidDataException>(() => agreement.Accept(terms, new string('0', 64)));
            Assert.False(File.Exists(stamp));
            agreement.Accept(terms, terms.Sha256);
            Assert.True(agreement.IsAccepted(terms));
            Assert.DoesNotContain("Microsoft", File.ReadAllText(stamp)); // Hash and format only.
            agreement.Accept(terms, terms.Sha256);
            Assert.True(agreement.IsAccepted(terms));
            Assert.False(agreement.IsAccepted(terms with { Sha256 = new string('a', 64) }));
            File.WriteAllText(stamp, "broken");
            Assert.False(agreement.IsAccepted(terms));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void MissingAndCorruptTermsFailClosedEvenWithReceipt()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-agreement-").FullName;
        try
        {
            var notice = Path.Combine(directory, "notices.md");
            var stamp = Path.Combine(directory, "agreement.txt");
            var agreement = new WindowsRuntimeAgreement(notice, stamp);
            Assert.Throws<InvalidDataException>(agreement.LoadTerms);
            File.Copy(RootNotices(), notice);
            var terms = agreement.LoadTerms();
            agreement.Accept(terms, terms.Sha256);
            File.WriteAllText(notice, File.ReadAllText(notice).Replace("IF YOU COMPLY WITH THESE LICENSE TERMS", "IF TERMS CHANGE", StringComparison.Ordinal));
            Assert.Throws<InvalidDataException>(agreement.LoadTerms);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void CrLfNoticesHaveTheSameTermsAndReceiptButChangedTextFails()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-agreement-lines-").FullName;
        try
        {
            var notice = Path.Combine(directory, "notices.md");
            var stamp = Path.Combine(directory, "agreement.txt");
            var agreement = new WindowsRuntimeAgreement(notice, stamp);
            var source = File.ReadAllText(RootNotices()).Replace("\r\n", "\n", StringComparison.Ordinal);
            File.WriteAllText(notice, source);
            var lf = agreement.LoadTerms();
            agreement.Accept(lf, lf.Sha256);
            File.WriteAllText(notice, source.Replace("\n", "\r\n", StringComparison.Ordinal));
            var crlf = agreement.LoadTerms();
            Assert.Equal(lf, crlf);
            Assert.True(agreement.IsAccepted(crlf));
            File.WriteAllText(notice, source.Replace("IF YOU COMPLY WITH THESE LICENSE TERMS", "IF THESE TERMS CHANGE", StringComparison.Ordinal)
                .Replace("\n", "\r\n", StringComparison.Ordinal));
            Assert.Throws<InvalidDataException>(agreement.LoadTerms);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void FailedAtomicReplaceDoesNotCreateAcceptance()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-agreement-").FullName;
        try
        {
            var stamp = Path.Combine(directory, "agreement.txt");
            var files = new FailingReplaceFiles();
            var agreement = new WindowsRuntimeAgreement(RootNotices(), stamp, files);
            var terms = agreement.LoadTerms();
            Assert.Throws<IOException>(() => agreement.Accept(terms, terms.Sha256));
            Assert.False(agreement.IsAccepted(terms));
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    private sealed class FailingReplaceFiles : IRuntimeAgreementFiles
    {
        private readonly RuntimeAgreementFiles files = new();
        public string Read(string path) => files.Read(path);
        public void Write(string path, string contents) => files.Write(path, contents);
        public void Replace(string temporaryPath, string destinationPath) => throw new IOException("injected replacement failure");
        public void Delete(string path) => files.Delete(path);
    }

    private static string RootNotices()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "THIRD_PARTY_NOTICES.md");
            if (File.Exists(candidate) && Directory.Exists(Path.Combine(directory.FullName, "apps"))) return candidate;
        }
        throw new FileNotFoundException("Repository root notices were not found.");
    }
    private static string Sha256(string value) =>
        Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value)));
    private static string Fenced(string source, string heading)
    {
        var start = source.IndexOf("```text\n", source.IndexOf(heading, StringComparison.Ordinal), StringComparison.Ordinal) + 8;
        return source[start..source.IndexOf("\n```", start, StringComparison.Ordinal)];
    }
}
