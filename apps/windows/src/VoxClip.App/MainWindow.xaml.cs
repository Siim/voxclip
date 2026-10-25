using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.Pages;
namespace VoxClip.App;

/// <summary>Mica editor shell with a custom native title bar; design §3.3.</summary>
public sealed partial class MainWindow : Window
{
    /// <summary>Construct the shell on the DispatcherQueue thread; architecture §7.2.</summary>
    public MainWindow()
    {
        InitializeComponent();
        Title = "VoxClip";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 860));
        ContentFrame.Navigate(typeof(HomePage));
    }
}
