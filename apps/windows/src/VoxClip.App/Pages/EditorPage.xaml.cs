using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
namespace VoxClip.App.Pages;

/// <summary>Empty transcript/preview/inspector/timeline regions; design §3.3. No second caption renderer exists in XAML.</summary>
public sealed partial class EditorPage : Page
{
    /// <summary>Initialize placeholder regions only.</summary>
    public EditorPage() => InitializeComponent();
    private void HomeClicked(object sender, RoutedEventArgs args) => Frame.Navigate(typeof(HomePage));
}
