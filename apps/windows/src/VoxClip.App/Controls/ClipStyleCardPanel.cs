using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App.Controls;

/// <summary>"How should clips be made?" (design §6.6): shown once above the clip list, inline, never a dialog. A chip
/// chooses and folds the card into the status bar's "Style: …" item, which reopens it. Rows change one field and make
/// the style the user's own.</summary>
internal sealed class ClipStyleCardPanel : Grid
{
    /// <summary>A chip or a row chose <c>Style</c>; <c>Collapse</c> is true for a chip and Done.</summary>
    internal event Action<ClipStyle, bool>? Chosen;
    /// <summary>Card B's mode control (design §6.6): "claude" or "pick".</summary>
    internal event Action<string>? ModeChosen;
    /// <summary>Claude mode's Clips row: top 1, 3 or 5 per video.</summary>
    internal event Action<int>? CountChosen;
    /// <summary>Claude mode's Spend row: up to $0, $1, $2 or $5 per video.</summary>
    internal event Action<int>? CapChosen;

    private static double Token(string key) => (double)Application.Current.Resources[key];

    internal ClipStyleCardPanel()
    {
        Padding = new Thickness(Token("VcSpacingCardPadding"));
        Margin = new Thickness(Token("VcSpacingRowGap"), Token("VcSpacingLabelGap"), Token("VcSpacingRowGap"), Token("VcSpacingLabelGap"));
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        Loaded += (_, _) => { Background = Ui.ThemeBrush(this, "VcBgSurfaceBrush"); BorderBrush = Ui.ThemeBrush(this, "VcLineDefaultBrush"); };
        AutomationProperties.SetName(this, "How should clips be made?");
        AutomationProperties.SetAutomationId(this, "ClipStyle.Card");
    }

    /// <summary>Lays the card out for <paramref name="style"/>.</summary>
    internal void Show(ClipStyle style, ClipStyleCatalog catalog, IReadOnlyList<CaptionStyle> library, ClipStyle? saved,
        ClipsAutopilotSettings? autopilot = null, IReadOnlyList<RewriteTone>? tones = null)
    {
        var stack = Ui.Stack(Token("VcSpacingGroupGap"));
        if (autopilot is not null) stack.Children.Add(Mode(autopilot));
        var header = new Grid { ColumnSpacing = Token("VcSpacingRowGap") };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Ui.Text("How should clips be made?", "BodyStrongTextBlockStyle");
        title.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level3);
        var done = new HyperlinkButton { Content = "Done", Padding = new Thickness(0) };
        done.Click += (_, _) => Chosen?.Invoke(style, true);
        Grid.SetColumn(done, 1);
        header.Children.Add(title); header.Children.Add(done);
        stack.Children.Add(header);

        var chips = Ui.Stack(Token("VcSpacingLabelGap"));
        foreach (var preset in catalog.Presets)
        {
            var selected = preset.Id == style.Preset;
            var chip = new ToggleButton
            {
                Content = preset.Id == "auto" ? $"✦ {preset.Label} · {preset.Detail}" : preset.Label,
                IsChecked = selected, HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(12),
            };
            AutomationProperties.SetName(chip, string.Join(", ", new[] { preset.Label, preset.Detail }.Where(text => text is not null)));
            AutomationProperties.SetAutomationId(chip, "ClipStyle.Preset." + preset.Id);
            var id = preset.Id;
            chip.Click += (_, _) => Chosen?.Invoke(catalog.StyleFor(id, saved), true);
            chips.Children.Add(chip);
        }
        stack.Children.Add(chips);
        if (autopilot is { Mode: ClipsMode.Claude } claude)
        {
            // Claude mode's rows: how many clips per video and the spend that approves paid voice.
            var claudeRows = Ui.Stack(Token("VcSpacingLabelGap"));
            claudeRows.Children.Add(Row("Clips", ClipsMode.Counts.Select(count => $"Top {count}").ToArray(), ClipsMode.Counts.ToList().IndexOf(claude.Count),
                index => CountChosen?.Invoke(ClipsMode.Counts[index])));
            claudeRows.Children.Add(Row("Spend", ClipsMode.CapsUsd.Select(cap => cap == 0 ? "$0 · no paid voice" : $"Up to ${cap} per video").ToArray(),
                ClipsMode.CapsUsd.ToList().IndexOf(claude.CapUsd), index => CapChosen?.Invoke(ClipsMode.CapsUsd[index])));
            stack.Children.Add(claudeRows);
        }

        var rows = Ui.Stack(Token("VcSpacingLabelGap"));
        var ordered = library.OrderBy(caption => caption.Order).ThenBy(caption => caption.Id, StringComparer.Ordinal).ToArray();
        var captionIds = new List<string> { "auto", "off" }.Concat(ordered.Select(caption => caption.Id)).ToArray();
        var captionNames = new List<string> { "Auto · Claude picks per clip", "Off" }.Concat(ordered.Select(caption => $"{caption.Name} · {FontName(caption)}")).ToArray();
        rows.Children.Add(Row("Captions", captionNames, Array.IndexOf(captionIds, style.Captions), index => Mine(style.FixingCaptions(captionIds[index]))));
        rows.Children.Add(Row("Music", catalog.Music.Select(option => option.Detail is null ? option.Label : $"{option.Label} · {option.Detail}").ToArray(),
            catalog.Music.Select(option => option.Id).ToList().IndexOf(style.Music), index => Mine(style with { Music = catalog.Music[index].Id })));
        rows.Children.Add(Row("Length", catalog.LengthChoicesSec.Select(seconds => $"Up to {seconds} s").ToArray(),
            catalog.LengthChoicesSec.ToList().IndexOf(style.MaxLengthSec), index => Mine(style with { MaxLengthSec = catalog.LengthChoicesSec[index] })));
        var shapes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Token("VcSpacingLabelGap") };
        foreach (var shape in catalog.Shapes)
        {
            var on = style.Shapes.Contains(shape);
            // The last shape cannot be turned off: a style always makes at least one.
            var toggle = new ToggleButton { Content = shape, IsChecked = on, IsEnabled = !on || style.Shapes.Count > 1 };
            AutomationProperties.SetName(toggle, "Shape " + shape);
            toggle.Click += (_, _) => Mine(style with { Shapes = on ? style.Shapes.Where(item => item != shape).ToArray() : catalog.Shapes.Where(item => style.Shapes.Contains(item) || item == shape).ToArray() });
            shapes.Children.Add(toggle);
        }
        rows.Children.Add(Labeled("Shape", shapes));
        rows.Children.Add(Row("Rewording", catalog.Rewording.Select(option => option.Label).ToArray(),
            catalog.Rewording.Select(option => option.Id).ToList().IndexOf(style.Rewording), index => Mine(style with { Rewording = catalog.Rewording[index].Id })));
        if (tones is not null)
        {
            // The tone Claude writes each clip's words in (design §6.6 Tone row); Never reword means As I said it.
            var ids = new List<string?> { null, "as-said" }.Concat(tones.Select(tone => (string?)tone.Id)).ToArray();
            var names = new List<string> { "Auto · Claude picks per clip", "As I said it · no tone change" }.Concat(tones.Select(tone => tone.Title)).ToArray();
            var selected = Math.Max(0, Array.IndexOf(ids, style.EffectiveTone));
            var tone = Row("Tone", names, selected, index => Mine(style with { Tone = ids[index] }));
            tone.IsHitTestVisible = style.Rewording != "off";
            if (style.Rewording == "off") AutomationProperties.SetHelpText(tone, "Never reword keeps your words as said.");
            rows.Children.Add(tone);
        }
        stack.Children.Add(rows);
        Children.Clear();
        Children.Add(stack);
    }

    /// <summary>Card B's mode control: "✦ Claude does it all" or "I'll pick", one of them on.</summary>
    private FrameworkElement Mode(ClipsAutopilotSettings autopilot)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Token("VcSpacingLabelGap") };
        foreach (var (mode, label) in new[] { (ClipsMode.Claude, "✦ Claude does it all"), (ClipsMode.Pick, "I'll pick") })
        {
            var toggle = new ToggleButton { Content = label, IsChecked = autopilot.Mode == mode };
            AutomationProperties.SetAutomationId(toggle, "ClipStyle.Mode." + mode);
            toggle.Click += (_, _) => { if (autopilot.Mode != mode) ModeChosen?.Invoke(mode); else toggle.IsChecked = true; };
            row.Children.Add(toggle);
        }
        AutomationProperties.SetName(row, "Who makes the clips");
        return Labeled("Mode", row);
    }

    private void Mine(ClipStyle style) => Chosen?.Invoke(style with { Preset = "mine" }, false);

    private FrameworkElement Row(string label, IReadOnlyList<string> items, int selected, Action<int> choose)
    {
        var box = new ComboBox { ItemsSource = items, SelectedIndex = selected, HorizontalAlignment = HorizontalAlignment.Stretch, MinWidth = 0 };
        AutomationProperties.SetName(box, label);
        AutomationProperties.SetAutomationId(box, "ClipStyle." + label);
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0 && box.SelectedIndex != selected) choose(box.SelectedIndex); };
        return Labeled(label, box);
    }

    private static FrameworkElement Labeled(string label, FrameworkElement value)
    {
        var grid = new Grid { ColumnSpacing = Token("VcSpacingLabelGap") };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(68) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var text = Ui.Text(label, "HelperText");
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(value, 1);
        grid.Children.Add(text); grid.Children.Add(value);
        return grid;
    }

    /// <summary>"Roboto Black": the family and the weight's name.</summary>
    internal static string FontName(CaptionStyle style)
    {
        var weight = style.Font.Weight switch { 100 => "Thin", 200 => "ExtraLight", 300 => "Light", 500 => "Medium", 600 => "SemiBold", 700 => "Bold", 800 => "ExtraBold", 900 => "Black", _ => "" };
        return weight.Length == 0 ? style.Font.Family : $"{style.Font.Family} {weight}";
    }
}
