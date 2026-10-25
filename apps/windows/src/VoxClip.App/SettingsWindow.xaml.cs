using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
namespace VoxClip.App;

/// <summary>Settings and About placeholder; architecture §11 and §13. Never handles plaintext keys.</summary>
public sealed partial class SettingsWindow : Window
{
    /// <summary>Only version source is Directory.Build.props via entry assembly metadata.</summary>
    public string VersionLabel => "VoxClip " + (Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "unknown");
    /// <summary>Dependency licenses visible in About before any runtime feature is implemented.</summary>
    public string Licences => "VoxClip — MIT. Microsoft Windows App SDK and Windows SDK BuildTools — Microsoft licences. " +
        "CommunityToolkit, SkiaSharp, HarfBuzzSharp, FFmpeg.AutoGen, Whisper.net, NAudio, Velopack, System.CommandLine — MIT; " +
        "Skia/HarfBuzz native components — BSD/MIT/Apache-2.0 and bundled notices. FFmpeg LGPL shared — LGPL-2.1-or-later; no GPL encoders. " +
        "Bundled fonts — SIL OFL; emoji — Apache-2.0. See THIRD_PARTY_NOTICES.md for versions, sources and transitive licence notices.";
    /// <summary>Initialize a separate theme-aware settings window on the UI thread.</summary>
    public SettingsWindow()
    {
        InitializeComponent();
        Title = "VoxClip Settings";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(640, 720));
    }
}
