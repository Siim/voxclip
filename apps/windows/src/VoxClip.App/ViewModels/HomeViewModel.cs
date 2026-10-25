using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
namespace VoxClip.App.ViewModels;

/// <summary>UI-thread recent-project mirror; architecture §7.2 and design Home layout.</summary>
public sealed class HomeViewModel : ObservableObject
{
    public ObservableCollection<RecentProject> RecentProjects { get; } = [];
    /// <summary>Friendly empty-state copy.</summary>
    public string EmptyMessage => "Your recent projects appear here. Your videos stay on this PC.";
    private string notice = "Checking local models…";
    public string Notice { get => notice; set => SetProperty(ref notice, value); }
}

public sealed class RecentProject(string path, string name) : ObservableObject
{
    public string Path { get; } = path;
    public string Name { get; } = name;
    private string detail = "Loading project…";
    public string Detail { get => detail; set => SetProperty(ref detail, value); }
#if !WIN_UI_TESTS
    private Microsoft.UI.Xaml.Media.ImageSource? thumbnail;
    public Microsoft.UI.Xaml.Media.ImageSource? Thumbnail { get => thumbnail; set => SetProperty(ref thumbnail, value); }
#endif
}
