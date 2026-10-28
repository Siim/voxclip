using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Globalization;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal sealed class TimelineRangeControl : ContentControl
{
    internal Func<TimelineRange> Read { get; set; } = () => new(0, 1, 0, 1, "");
    internal Action<double>? Set { get; set; }
    private double reported = double.NaN;
    private TimelineRange? previous;
    internal TimelineRangeControl(string name)
    {
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetName(this, name);
        var clear = ((SolidColorBrush)Ui.ThemeBrush(this, "VcTimelineTrackBrush")).Color; clear.A = 0;
        Content = new Border { Background = new SolidColorBrush(clear) };
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
    }
    internal void Refresh()
    {
        var range = Read();
        if (previous == range) return;
        if (previous?.Text != range.Text) AutomationProperties.SetHelpText(this, range.Text);
        if (FrameworkElementAutomationPeer.FromElement(this) is { } peer)
        {
            if (range.Value != reported) peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, double.IsNaN(reported) ? range.Value : reported, range.Value);
            if (previous is { } old)
            {
                if (old.Minimum != range.Minimum) peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.MinimumProperty, old.Minimum, range.Minimum);
                if (old.Maximum != range.Maximum) peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.MaximumProperty, old.Maximum, range.Maximum);
                if (old.SmallChange != range.SmallChange) peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.SmallChangeProperty, old.SmallChange, range.SmallChange);
            }
        }
        reported = range.Value;
        previous = range;
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new RangePeer(this);
    private sealed class RangePeer(TimelineRangeControl owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider, IValueProvider
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
        protected override string GetClassNameCore() => "VoxClipTimelineRange";
        protected override object GetPatternCore(PatternInterface pattern) => pattern is PatternInterface.RangeValue or PatternInterface.Value ? this : base.GetPatternCore(pattern);
        public bool IsReadOnly => !owner.IsEnabled;
        public double LargeChange => Math.Max(SmallChange, (Maximum - Minimum) / 10);
        public double SmallChange => owner.Read().SmallChange;
        public double Maximum => owner.Read().Maximum;
        public double Minimum => owner.Read().Minimum;
        public double Value => owner.Read().Value;
        string IValueProvider.Value => owner.Read().Text;
        public void SetValue(double value)
        {
            if (IsReadOnly) throw new InvalidOperationException("The timeline control is disabled.");
            if (!double.IsFinite(value) || value < Minimum || value > Maximum) throw new ArgumentOutOfRangeException(nameof(value));
            owner.Set?.Invoke(value);
        }
        void IValueProvider.SetValue(string value) => SetValue(double.Parse(value, CultureInfo.InvariantCulture));
    }
}
