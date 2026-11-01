using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace VoxClip.App.Controls;

internal sealed class ShellTextFocus : IDisposable
{
    private readonly FrameworkElement root;
    private readonly ConditionalWeakTable<TextBox, object> observed = new();
    private readonly KeyEventHandler keyUp;
    private WeakReference<TextBox>? composing;
    private bool compositionJustEnded;
    private bool disposed;
    internal bool OwnsComposition => composing?.TryGetTarget(out _) == true || compositionJustEnded;

    internal ShellTextFocus(FrameworkElement root)
    {
        this.root = root;
        keyUp = (_, _) => compositionJustEnded = false;
        root.GotFocus += FocusChanged;
        root.AddHandler(UIElement.KeyUpEvent, keyUp, true);
    }

    private void FocusChanged(object sender, RoutedEventArgs args)
    {
        for (var element = FocusManager.GetFocusedElement(root.XamlRoot) as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
        {
            if (element is not TextBox field) continue;
            if (observed.TryGetValue(field, out _)) return;
            observed.Add(field, new());
            field.TextCompositionStarted += (_, _) => { if (!disposed) composing = new(field); };
            field.TextCompositionEnded += (_, _) =>
            {
                if (disposed) return;
                if (composing?.TryGetTarget(out var previous) == true && ReferenceEquals(previous, field)) composing = null;
                compositionJustEnded = true;
            };
            return;
        }
    }

    public void Dispose()
    {
        disposed = true;
        root.GotFocus -= FocusChanged;
        root.RemoveHandler(UIElement.KeyUpEvent, keyUp);
        composing = null;
    }
}
