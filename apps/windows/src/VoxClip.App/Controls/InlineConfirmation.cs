using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using Windows.System;

namespace VoxClip.App.Controls;

internal sealed class InlineConfirmation : StackPanel, IDisposable
{
    private readonly Button send = new();
    private readonly Button cancel = new() { Content = "Cancel" };
    private Func<string, Task<bool>>? saveKey;
    private readonly ShellTextFocus textFocus;
    internal Control FocusTarget => cancel;

    internal InlineConfirmation(InlineApproval approval, Action? playSource = null, Func<string, Task<bool>>? saveKey = null)
    {
        textFocus = new(this);
        this.saveKey = saveKey;
        Spacing = 8;
        AutomationProperties.SetAutomationId(this, "Workflow.Confirmation");
        Children.Add(Ui.Text(approval.Request.Title, "BodyStrongTextBlockStyle"));
        Children.Add(Ui.Text(approval.Request.DataSent));
        Children.Add(Ui.Text(approval.Request.Detail, "HelperText"));
        if (approval.Request.PricingPage is { } pricing) Children.Add(new HyperlinkButton { Content = "Provider pricing", NavigateUri = pricing });
        send.Content = approval.Request.Affirmative;
        if (saveKey is not null)
        {
            send.IsEnabled = false;
            var key = new PasswordBox { Header = "API key", PasswordRevealMode = PasswordRevealMode.Hidden };
            var notice = Ui.Notice();
            var save = new Button { Content = "Save Key", IsEnabled = false, HorizontalAlignment = HorizontalAlignment.Left };
            key.PasswordChanged += (_, _) => save.IsEnabled = approval.IsPending && !string.IsNullOrWhiteSpace(key.Password);
            save.Click += async (_, _) =>
            {
                if (!approval.IsPending || this.saveKey is not { } persist) return;
                var secret = key.Password; key.Password = ""; key.IsEnabled = false; save.IsEnabled = false;
                await Ui.RunAsync(notice, async () =>
                {
                    var saved = await persist(secret);
                    if (!approval.IsPending || !ReferenceEquals(this.saveKey, persist)) return;
                    if (saved) { send.IsEnabled = true; approval.MarkShown(Environment.TickCount); Ui.Show(notice, "Key saved for your Windows account. Choose Send to approve this request."); }
                }, "Save key");
                if (approval.IsPending) key.IsEnabled = true;
            };
            Children.Add(key); Children.Add(save);
            Children.Add(Ui.Text("Saved with Windows account protection. Saving makes no provider request.", "HelperText"));
            Children.Add(notice);
        }
        AutomationProperties.SetAutomationId(send, "Workflow.Approve");
        AutomationProperties.SetAutomationId(cancel, "Workflow.Cancel");
        var actions = Ui.Stack(8); actions.Orientation = Orientation.Horizontal;
        actions.Children.Add(send); actions.Children.Add(cancel); Children.Add(actions);
        send.Click += (_, _) => approval.Approve(InlineActivation.Pointer, false, Environment.TickCount);
        cancel.Click += (_, _) => approval.Cancel();
        Loaded += (_, _) => { approval.MarkShown(Environment.TickCount); cancel.Focus(FocusState.Programmatic); };
        send.PreviewKeyDown += (_, args) =>
        {
            if (textFocus.OwnsComposition) return;
            if (args.Key == VirtualKey.Space) { args.Handled = true; if (!args.KeyStatus.WasKeyDown) playSource?.Invoke(); return; }
            if (args.Key != VirtualKey.Enter) return;
            args.Handled = true;
            if (send.IsEnabled) approval.Approve(InputState.Down(VirtualKey.Control) ? InlineActivation.ControlReturn : InlineActivation.Return,
                args.KeyStatus.WasKeyDown, MessageTime());
        };
        PreviewKeyDown += (_, args) =>
        {
            if (textFocus.OwnsComposition) return;
            if (args.Key == VirtualKey.Space && !InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot)))
            { args.Handled = true; if (!args.KeyStatus.WasKeyDown) playSource?.Invoke(); }
            else if (args.Key == VirtualKey.Escape) { args.Handled = true; approval.Cancel(); }
            else if (args.Key == VirtualKey.Enter && InputState.Down(VirtualKey.Control))
            {
                args.Handled = true;
                if (send.IsEnabled) approval.Approve(InlineActivation.ControlReturn, args.KeyStatus.WasKeyDown, MessageTime());
            }
        };
    }
    public void Dispose() { saveKey = null; textFocus.Dispose(); }

    [DllImport("user32.dll", EntryPoint = "GetMessageTime")]
    internal static extern int MessageTime();
}
