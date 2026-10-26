using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

/// <summary>Picks the NavigationView item template for each sidebar row; design §3.4. The templates live in MainWindow.xaml.</summary>
public sealed partial class SidebarItems : DataTemplateSelector
{
    public DataTemplate? Home { get; set; }
    public DataTemplate? Separator { get; set; }
    public DataTemplate? Project { get; set; }
    public DataTemplate? FullTake { get; set; }
    public DataTemplate? Clip { get; set; }
    public DataTemplate? SuggestedHeader { get; set; }
    public DataTemplate? Suggestion { get; set; }
    public DataTemplate? Action { get; set; }
    public DataTemplate? RecentHeader { get; set; }
    public DataTemplate? Recent { get; set; }

    /// <summary>Fluent glyph for an action row: New clip from selection, or Find clips with AI.</summary>
    public static string ActionGlyph(string key) => key == "action:find" ? "\uE721" : "\uE710";

    protected override DataTemplate? SelectTemplateCore(object item) => item is not SidebarRow row ? null : row.Kind switch
    {
        SidebarKind.Home => Home,
        SidebarKind.Separator => Separator,
        SidebarKind.Project => Project,
        SidebarKind.FullTake => FullTake,
        SidebarKind.Clip => Clip,
        SidebarKind.SuggestedHeader => SuggestedHeader,
        SidebarKind.Suggestion => Suggestion,
        SidebarKind.Action => Action,
        SidebarKind.RecentHeader => RecentHeader,
        _ => Recent
    };

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
