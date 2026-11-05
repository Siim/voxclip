using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;

namespace VoxClip.App.Controls;

internal sealed class SelectionFlyout
{
    private readonly FrameworkElement owner;
    private readonly CommandBarFlyout flyout = new();
    private readonly AppBarButton make;
    private readonly AppBarButton cut;
    private readonly AppBarButton restore;
    private readonly AppBarButton rewrite;
    private readonly AppBarButton rewriteAs;
    private readonly AppBarButton askClaude;
    private readonly AppBarSeparator askSeparator = new();
    /// <summary>Whether ✦ Ask Claude can act on the selection (an AI is chosen and the project can change).</summary>
    internal Func<bool>? CanAskClaude { get; set; }
    /// <summary>✦ Ask Claude: opens the inline field on the selected words in the right column (design §6.8).</summary>
    internal Action? AskClaude { get; set; }
    private readonly MenuFlyout tones = new() { Placement = FlyoutPlacementMode.Bottom };
    /// <summary>The "Rewrite as" strip's items, the default first (design §6.3.1); empty hides "✦ Rewrite as ▾".</summary>
    internal Func<IReadOnlyList<VoxClip.App.ViewModels.RewriteStripItem>>? Tones { get; set; }
    /// <summary>A chip: rewrites the selected words in that tone at once.</summary>
    internal Action<VoxClip.App.ViewModels.RewriteStripItem>? RewriteAs { get; set; }
    private readonly AppBarSeparator separator = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(150) };
    private Action? pending;
    private bool restoreFocus;
    private readonly KeyEventHandler escape;
    internal bool IsOpen => flyout.IsOpen;

    internal SelectionFlyout(FrameworkElement owner, Action makeClip, Action cutWords, Action restoreWords, Action rewriteWords)
    {
        this.owner = owner;
        escape = Escape;
        make = Button("Make clip", Symbol.Add, makeClip, true);
        cut = Button("Cut", Symbol.Cut, cutWords);
        restore = Button("Restore", Symbol.Undo, restoreWords);
        rewrite = Button("Rewrite…", Symbol.Edit, rewriteWords, true);
        // "✦ Rewrite as ▾": the strip as a menu; "Rewrite…" stays for typing your own (design §6.3.1).
        rewriteAs = new AppBarButton { Label = "✦ Rewrite as", Icon = new SymbolIcon(Symbol.Edit), Height = 40, MinHeight = 40, Flyout = tones };
        AutomationProperties.SetName(rewriteAs, "Rewrite as");
        askClaude = Button("✦ Ask Claude", Symbol.Message, () => AskClaude?.Invoke(), true);
        AutomationProperties.SetAutomationId(askClaude, "Selection.AskClaude");
        ToolTipService.SetToolTip(askClaude, "Ask Claude to edit these words: bleep, blur, a title, a rewrite…");
        AutomationProperties.SetAutomationId(rewriteAs, "Selection.RewriteAs");
        ToolTipService.SetToolTip(cut, "Cut (Delete)");
        ToolTipService.SetToolTip(restore, "Restore (Shift+Backspace)");
        ToolTipService.SetToolTip(rewrite, "Rewrite… (Ctrl+R)");
        flyout.PrimaryCommands.Add(askClaude);
        flyout.PrimaryCommands.Add(askSeparator);
        flyout.PrimaryCommands.Add(make);
        flyout.PrimaryCommands.Add(cut);
        flyout.PrimaryCommands.Add(restore);
        flyout.PrimaryCommands.Add(separator);
        flyout.PrimaryCommands.Add(rewrite);
        flyout.PrimaryCommands.Add(rewriteAs);
        timer.Tick += (_, _) => { timer.Stop(); var action = pending; pending = null; action?.Invoke(); };
        flyout.Opened += (_, _) =>
        {
            ApplyEffects();
            if (flyout.ShowMode == FlyoutShowMode.Standard) (askClaude.Visibility == Visibility.Visible ? askClaude : make).Focus(FocusState.Keyboard);
        };
        flyout.Closing += (_, _) =>
        {
            timer.Stop(); pending = null;
            restoreFocus |= InputState.Down(VirtualKey.Escape);
        };
        flyout.Closed += (_, _) =>
        {
            if (!restoreFocus) return;
            restoreFocus = false;
            RestoreTranscriptFocus();
            owner.DispatcherQueue.TryEnqueue(() =>
            {
                RestoreTranscriptFocus();
            });
        };
        owner.Loaded += (_, _) => Ui.EffectsChanged += EffectsChanged;
        owner.Unloaded += (_, _) => Ui.EffectsChanged -= EffectsChanged;
    }

    private void RestoreTranscriptFocus()
    {
        if (!owner.IsLoaded || owner.XamlRoot is null || flyout.IsOpen) return;
        var focused = FocusManager.GetFocusedElement(owner.XamlRoot);
        if (focused is null || ReferenceEquals(focused, owner) || ReferenceEquals(focused, make) || ReferenceEquals(focused, cut) ||
            ReferenceEquals(focused, restore) || ReferenceEquals(focused, rewrite) || ReferenceEquals(focused, rewriteAs) || ReferenceEquals(focused, askClaude)) owner.Focus(FocusState.Keyboard);
    }

    private void EffectsChanged(object? sender, EventArgs args) => owner.DispatcherQueue.TryEnqueue(ApplyEffects);
    private void ApplyEffects()
    {
        flyout.AreOpenCloseAnimationsEnabled = Ui.EffectPolicy.Animations;
        if (owner.XamlRoot is null) return;
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(owner.XamlRoot))
            if (FindBar(popup.Child) is { } bar)
            {
                var surface = (SolidColorBrush)Ui.ThemeBrush(owner, "VcBgElevatedBrush");
                var opaque = Ui.EffectPolicy.OpaqueTransientSurfaces;
                bar.SystemBackdrop = null;
                bar.Background = opaque ? surface : new AcrylicBrush { TintColor = surface.Color, TintOpacity = 0.85, FallbackColor = surface.Color };
                bar.BorderBrush = Ui.ThemeBrush(owner, "VcLineStrongBrush");
                bar.BorderThickness = new(opaque ? 1 : 0);
                bar.RemoveHandler(UIElement.KeyDownEvent, escape);
                bar.AddHandler(UIElement.KeyDownEvent, escape, true);
            }
    }

    private AppBarButton Button(string label, Symbol symbol, Action action, bool labelled = false)
    {
        var button = new AppBarButton { Label = label, Icon = new SymbolIcon(symbol), IsCompact = !labelled,
            LabelPosition = labelled ? CommandBarLabelPosition.Default : CommandBarLabelPosition.Collapsed,
            Height = 40, MinHeight = 40 };
        AutomationProperties.SetName(button, label);
        button.Click += (_, _) => { Hide(); action(); };
        return button;
    }

    internal void Schedule(Action show)
    {
        timer.Stop();
        pending = show;
        timer.Start();
    }

    internal void Hide(bool focus = false)
    {
        timer.Stop(); pending = null;
        restoreFocus |= focus;
        flyout.Hide();
        if (focus && owner.IsLoaded) owner.Focus(FocusState.Keyboard);
    }

    internal void Show(Rect selection, bool below, bool keyboard, bool editable, bool canRestore, bool voiceLab, bool rewriteAvailable, string? existingClip)
    {
        restoreFocus = false;
        flyout.AreOpenCloseAnimationsEnabled = Ui.EffectPolicy.Animations;
        ToolTipService.SetToolTip(make, existingClip ?? "Make clip (Ctrl+Alt+K)");
        cut.IsEnabled = make.IsEnabled = editable;
        // Shown only when it can act: an AI is chosen and the project can change.
        askClaude.Visibility = askSeparator.Visibility = editable && CanAskClaude?.Invoke() == true ? Visibility.Visible : Visibility.Collapsed;
        restore.IsEnabled = editable && canRestore;
        rewrite.Visibility = separator.Visibility = voiceLab ? Visibility.Visible : Visibility.Collapsed;
        rewrite.IsEnabled = editable && rewriteAvailable;
        if (!rewriteAvailable) ToolTipService.SetToolTip(rewrite, "Rewrite is not available in this build.");
        var items = Tones?.Invoke() ?? [];
        tones.Items.Clear();
        foreach (var item in items)
        {
            var entry = new MenuFlyoutItem { Text = item.Label };
            ToolTipService.SetToolTip(entry, item.Detail);
            AutomationProperties.SetName(entry, item.Label);
            entry.Click += (_, _) => { Hide(); RewriteAs?.Invoke(item); };
            tones.Items.Add(entry);
        }
        rewriteAs.Visibility = voiceLab && items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        rewriteAs.IsEnabled = editable && rewriteAvailable && items.Count > 0;
        flyout.ShowMode = keyboard ? FlyoutShowMode.Standard : FlyoutShowMode.Transient;
        flyout.ShowAt(owner, new FlyoutShowOptions
        {
            Position = new Point(Math.Clamp(selection.Left - 4, 0, Math.Max(0, owner.ActualWidth - 300)), below ? selection.Bottom + 8 : selection.Top - 8),
            Placement = below ? FlyoutPlacementMode.BottomEdgeAlignedLeft : FlyoutPlacementMode.TopEdgeAlignedLeft,
            ShowMode = flyout.ShowMode
        });
    }

    private void Escape(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.Escape) return;
        Hide(true); args.Handled = true;
    }

    private static CommandBarFlyoutCommandBar? FindBar(DependencyObject? root)
    {
        if (root is CommandBarFlyoutCommandBar bar) return bar;
        if (root is null) return null;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            if (FindBar(VisualTreeHelper.GetChild(root, index)) is { } child) return child;
        return null;
    }
}
