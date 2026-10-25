using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
namespace VoxClip.App.ViewModels;

/// <summary>UI-thread recent-project mirror; architecture §7.2 and design Home layout.</summary>
public sealed class HomeViewModel : ObservableObject
{
    // TODO(win-ui): populate recents from the project service without auto-opening a project at startup.
    /// <summary>Empty until win-ui wires IProjectStore. No recent file is opened automatically.</summary>
    public ObservableCollection<string> RecentProjects { get; } = [];
    /// <summary>Friendly empty-state copy.</summary>
    public string EmptyMessage => "Open a project or import a video to start cutting by words.";
}
