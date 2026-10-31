namespace VoxClip.App.ViewModels;

/// <summary>The Settings window's section tags (the NavigationViewItem Tag values in SettingsWindow.xaml), for
/// <c>App.OpenSettings(section)</c>.</summary>
internal static class SettingsSections
{
    internal const string LocalModels = "Local Models";
    /// <summary>Where AI connectors and their keys live on Windows; the Mac calls its pane "AI".</summary>
    internal const string ProvidersAndKeys = "Providers & Keys";

    /// <summary>Core's shared AI copy names the Mac pane ("Settings › AI"); on Windows it points at Providers &amp; Keys.</summary>
    internal static string WindowsCopy(string message) => message
        .Replace("Settings › AI", "Settings › " + ProvidersAndKeys, StringComparison.Ordinal)
        .Replace("Settings → AI", "Settings → " + ProvidersAndKeys, StringComparison.Ordinal);
}

/// <summary>One Settings → Local Models row. A finished download or removal updates the row in place, and so does one made in
/// the Transcribe dialog or the welcome tour while the page is open (<c>AppServices.ModelsChanged</c>), so it never reads "Not
/// installed." for a model that is installed (design §Settings, model row).</summary>
internal sealed class LocalModelRowState(bool installed)
{
    internal bool Installed { get; private set; } = installed;
    internal string Status => Installed ? "Installed and verified." : "Not installed.";
    internal string Action => Installed ? "Remove" : "Download";
    internal string ProgressName(string id) => (Installed ? "Removing " : "Downloading ") + id;

    /// <summary>Record this row's finished download or removal and return the notice for it.</summary>
    internal string Finish(bool removed)
    {
        Installed = !removed;
        return removed ? "Model removed." : "Model installed and verified.";
    }

    /// <summary>Follow the installed list after a change made elsewhere; true when the row has to be redrawn.</summary>
    internal bool Follow(IEnumerable<VoxClip.Core.Services.Models.InstalledModel> installed, string id)
    {
        var now = installed.Any(entry => entry.Id == id && entry.Verified);
        if (now == Installed) return false;
        Installed = now;
        return true;
    }
}
