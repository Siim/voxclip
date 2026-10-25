using VoxClip.Cli;
using VoxClip.Core.Services.Project;

namespace VoxClip.Media.Tests;

/// <summary>Existing CLI behavior tests run after real acceptance in isolated user data.</summary>
internal static class AcceptedCli
{
    internal static async Task<int> RunAsync(string[] args, CancellationToken ct,
        ExportInputReader? openExport = null, ExportPreparer? prepareExport = null)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-cli-accepted-").FullName;
        try
        {
            var agreement = new WindowsRuntimeAgreement(FindNotices(), Path.Combine(directory, WindowsRuntimeAgreement.StampFileName));
            var terms = agreement.LoadTerms();
            agreement.Accept(terms, terms.Sha256);
            return await CliApplication.RunAsync(args, ct, openExport, prepareExport, agreement);
        }
        finally { Directory.Delete(directory, true); }
    }

    internal static string FindNotices()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, WindowsRuntimeAgreement.NoticeFileName);
            if (File.Exists(candidate) && Directory.Exists(Path.Combine(directory.FullName, "apps"))) return candidate;
        }
        throw new FileNotFoundException("Repository root notices were not found.");
    }
}
