namespace VoxClip.App.ViewModels;

/// <summary>The Settings window's section tags (the NavigationViewItem Tag values in SettingsWindow.xaml), for
/// <c>App.OpenSettings(section)</c>.</summary>
internal static class SettingsSections
{
    internal const string LocalModels = "Local Models";
}

/// <summary>One Settings → Local Models row. A finished download or removal updates the row in place, so it never reads "Not
/// installed." for a model that was just installed (design §Settings, model row).</summary>
internal sealed class LocalModelRowState(bool installed)
{
    internal bool Installed { get; private set; } = installed;
    internal string Status => Installed ? "Installed and verified." : "Not installed.";
    internal string Action => Installed ? "Remove" : "Download";
    internal string ProgressName(string id) => (Installed ? "Removing " : "Downloading ") + id;

    /// <summary>Record the finished download or removal and return the notice for it.</summary>
    internal string Finish()
    {
        Installed = !Installed;
        return Installed ? "Model installed and verified." : "Model removed.";
    }
}
