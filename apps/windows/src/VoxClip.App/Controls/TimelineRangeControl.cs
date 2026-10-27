using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Globalization;

namespace VoxClip.App.Controls;

internal readonly record struct TimelineRange(double Minimum, double Maximum, double Value, double SmallChange, string Text);

internal sealed class TimelineRangeControl : ContentControl
{
    internal Func<TimelineRange> Read { get; set; } = () => new(0, 1, 0, 1, "");
    internal Action<double>? Set { get; set; }
    private double reported = double.NaN;
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
        AutomationProperties.SetHelpText(this, range.Text);
        if (range.Value != reported && FrameworkElementAutomationPeer.FromElement(this) is { } peer)
            peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, double.IsNaN(reported) ? range.Value : reported, range.Value);
        reported = range.Value;
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
