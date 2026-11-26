using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;

namespace VoxClip.App.Controls;

internal sealed class TimelineItemControl() : TimelineRangeControl("Timeline item")
{
    internal bool Selected { get; private set; }
    internal Action<bool, bool>? SelectItem { get; set; }
    internal TimelineSelectionCanvas? Container { get; set; }

    internal void UpdateSelection(bool selected)
    {
        if (Selected == selected) return;
        var previous = Selected;
        Selected = selected;
        if (FrameworkElementAutomationPeer.FromElement(this) is not { } peer) return;
        if (AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged))
            peer.RaisePropertyChangedEvent(SelectionItemPatternIdentifiers.IsSelectedProperty, previous, selected);
        var change = selected ? AutomationEvents.SelectionItemPatternOnElementAddedToSelection : AutomationEvents.SelectionItemPatternOnElementRemovedFromSelection;
        if (AutomationPeer.ListenerExists(change)) peer.RaiseAutomationEvent(change);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new ItemPeer(this);

    private sealed class ItemPeer(TimelineItemControl owner) : RangePeer(owner), ISelectionItemProvider
    {
        protected override string GetClassNameCore() => "VoxClipTimelineItem";
        protected override object GetPatternCore(PatternInterface pattern) => pattern == PatternInterface.SelectionItem ? this : base.GetPatternCore(pattern);
        public bool IsSelected => owner.Selected;
        public IRawElementProviderSimple SelectionContainer => ProviderFromPeer(CreatePeerForElement(owner.Container!));
        public void Select() => owner.SelectItem?.Invoke(true, false);
        public void AddToSelection() => owner.SelectItem?.Invoke(true, true);
        public void RemoveFromSelection() => owner.SelectItem?.Invoke(false, true);
    }
}

internal sealed class TimelineSelectionCanvas : Canvas
{
    protected override AutomationPeer OnCreateAutomationPeer() => new SelectionPeer(this);

    private sealed class SelectionPeer(TimelineSelectionCanvas owner) : FrameworkElementAutomationPeer(owner), ISelectionProvider
    {
        protected override string GetNameCore() => "Timeline items";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
        protected override object GetPatternCore(PatternInterface pattern) => pattern == PatternInterface.Selection ? this : base.GetPatternCore(pattern);
        public bool CanSelectMultiple => true;
        public bool IsSelectionRequired => false;
        public IRawElementProviderSimple[] GetSelection() => owner.Children.OfType<TimelineItemControl>().Where(item => item.Selected)
            .Select(item => ProviderFromPeer(CreatePeerForElement(item))).ToArray();
    }
}
