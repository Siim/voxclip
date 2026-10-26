#if DEBUG
using System.Runtime.InteropServices;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App.Services;

/// <summary>Isolated, Debug-only WinUI-thread acceptance probe. Dispatch never invokes Velopack.</summary>
internal static class RestartNativeProbe
{
    internal static async Task RunAsync(MainWindow first, string output)
    {
        Directory.CreateDirectory(output);
        var checks = new List<string>();
        var report = Path.Combine(output, "restart-native-result.json");
        SettingsWriteQueue? queue = null;
        TaskCompletionSource? releaseSave = null;
        TaskCompletionSource? releaseFlush = null;
        Task? accepted = null;
        Task<RestartResult>? run = null;
        RestartResult? dispatchResult = null;
        Exception? dispatchError = null;
        string? languageBeforeEdit = null;
        string? languageBeforePreparation = null;
        var dispatched = 0;
        try
        {
            var fixture = "";
            for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            {
                var candidate = Path.Combine(directory.FullName, "shared", "fixtures", "projects", "interview-take.voxclip");
                if (File.Exists(candidate)) { fixture = candidate; break; }
            }
            Require(File.Exists(fixture), "project fixture missing");
            var firstPath = Path.Combine(output, "first.voxclip");
            var secondPath = Path.Combine(output, "second.voxclip");
            File.Copy(fixture, firstPath, true);
            File.Copy(fixture, secondPath, true);
            await App.Services.SetAsync("editing.pauseBreath", "natural");
            await first.OpenPathAsync(firstPath);
            var second = App.NewWindow();
            await second.OpenPathAsync(secondPath);
            Require(first.DebugEditor is not null && second.DebugEditor is not null, "both project windows must be open");
            var firstModel = first.DebugEditor!.ViewModel;
            var secondModel = second.DebugEditor!.ViewModel;
            firstModel.Select(0); firstModel.Select(1, true);
            Require(firstModel.MakeClip(), "first accepted clip");
            firstModel.Select(0); firstModel.Correct("native-r6");
            secondModel.Select(2); secondModel.Select(3, true);
            Require(secondModel.MakeClip(), "second accepted clip");
            secondModel.Select(2); secondModel.Correct("second-r6");
            checks.Add("two rendered project windows accepted clip and word edits");

            await App.Services.SetAsync("transcription.language", "auto");
            await App.Services.FlushSettingsAsync(CancellationToken.None);
            App.OpenSettings();
            await Task.Delay(250);
            var settings = App.Settings ?? throw new InvalidOperationException("Settings window did not open");
            languageBeforeEdit = (await new SettingsStore(App.Services.Data.Settings).LoadAsync(CancellationToken.None))
                .Values["transcription.language"].GetString();
            Require(languageBeforeEdit == "auto", "language baseline was not saved before editing Settings");
            Require(settings.DebugSetLanguageText("auto"), "Settings language field did not load");
            await Task.Delay(250); // Let the selected pane finish loading before leaving text uncommitted.
            Require(settings.DebugSetLanguageText("et"), "Settings language field did not load");
            var beforeCommit = await new SettingsStore(App.Services.Data.Settings).LoadAsync(CancellationToken.None);
            languageBeforePreparation = beforeCommit.Values["transcription.language"].GetString();
            Require(languageBeforePreparation != "et",
                "Settings text was already on disk before restart preparation");
            var saveStarted = NewSignal();
            var saveGate = NewSignal();
            releaseSave = saveGate;
            var flushStarted = NewSignal();
            var flushGate = NewSignal();
            releaseFlush = flushGate;
            queue = App.Services.DebugSettingsWrites;
            queue.DebugBeforeSave = async key =>
            {
                if (key != "editing.pauseBreath") return;
                saveStarted.TrySetResult();
                await saveGate.Task;
            };
            queue.DebugBeforeFlush = async () => { flushStarted.TrySetResult(); await flushGate.Task; };
            accepted = App.Services.SetAsync("editing.pauseBreath", "tight");
            await saveStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
            run = App.Restart.RunAsync(new UpdateRestartSettings(), async _ =>
            {
                dispatched++;
                try
                {
                    var savedSettings = await new SettingsStore(App.Services.Data.Settings).LoadAsync(CancellationToken.None);
                    Require(savedSettings.Values["transcription.language"].GetString() == "et", "active Settings text missing at dispatch");
                    Require(savedSettings.Values["editing.pauseBreath"].GetString() == "tight", "accepted delayed setting missing at dispatch");
                    var savedFirst = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(firstPath));
                    var savedSecond = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(secondPath));
                    Require(savedFirst.Edits.Clips.Count == 1 && savedSecond.Edits.Clips.Count == 1, "clips missing at dispatch");
                    Require(savedFirst.Edits.Corrections.Values.Contains("native-r6") && savedSecond.Edits.Corrections.Values.Contains("second-r6"), "word edits missing at dispatch");
                    Require(Math.Abs(savedFirst.Edits.PauseKeepSeconds - 0.05) < 0.001 &&
                            Math.Abs(savedSecond.Edits.PauseKeepSeconds - 0.05) < 0.001,
                        "accepted setting was not applied before final project saves");
                    checks.Add("fake dispatch read back both project files and settings from disk");
                }
                catch (Exception exception)
                {
                    dispatchError = exception;
                    throw;
                }
            }, CancellationToken.None);
            Require(App.Restart.IsPreparing && !settings.DebugNavigationEnabled, "Settings was not paused during drain");
            Require(ReferenceEquals(first, App.NewWindow()) && App.Windows.Count == 2, "new window bypassed preparation");
            await first.GoHomeAsync();
            await first.OpenPathAsync(secondPath);
            Require(first.CurrentScreen == "editor" && first.ProjectPath == firstPath, "navigation bypassed preparation");
            App.OpenSettings();
            Require(ReferenceEquals(settings, App.Settings), "Settings entry bypassed preparation");
            Require(PostMessage(WinRT.Interop.WindowNative.GetWindowHandle(first), 0x0010, 0, 0), "project native close request failed");
            Require(PostMessage(WinRT.Interop.WindowNative.GetWindowHandle(settings), 0x0010, 0, 0), "Settings native close request failed");
            await Task.Delay(150);
            Require(App.Windows.Contains(first), "project native close bypassed preparation");
            Require(ReferenceEquals(settings, App.Settings), "Settings native close bypassed preparation");
            try { await App.Services.SetAsync("probe.late", true); throw new InvalidOperationException("late write was accepted"); }
            catch (InvalidOperationException exception) when (exception.Message.Contains("paused", StringComparison.Ordinal)) { }
            Require(dispatched == 0, "dispatch preceded accepted settings drain");
            checks.Add("Settings and window entry, close, navigation, and new writes were blocked during drain");
            saveGate.TrySetResult();
            await accepted.WaitAsync(TimeSpan.FromSeconds(10));
            await flushStarted.Task.WaitAsync(TimeSpan.FromSeconds(20));
            Require(!settings.DebugNavigationEnabled, "Settings became editable during flush");
            firstModel.Select(1); firstModel.Select(2, true);
            Require(!firstModel.MakeClip(), "project edit was accepted while final flush was paused");
            try { await App.Services.SetAsync("probe.flush-late", true); throw new InvalidOperationException("flush-time write was accepted"); }
            catch (InvalidOperationException exception) when (exception.Message.Contains("paused", StringComparison.Ordinal)) { }
            Require(dispatched == 0, "dispatch preceded flush");
            checks.Add("flush-time Settings write was refused before fake dispatch");
            flushGate.TrySetResult();
            dispatchResult = await run.WaitAsync(TimeSpan.FromSeconds(30));
            if (dispatchError is not null)
                throw new InvalidOperationException("fake dispatch assertion failed", dispatchError);
            Require(dispatchResult == RestartResult.Dispatched && dispatched == 1,
                $"fake dispatch returned {dispatchResult} with {dispatched} invocation(s)");
            queue.DebugBeforeSave = null;
            queue.DebugBeforeFlush = null;
            Require(settings.DebugNavigationEnabled && !firstModel.IsLeaving && !secondModel.IsLeaving,
                "successful fake dispatch did not restore probe state");

            App.Services.BusyOperations++;
            try { Require(await RunNoDispatch() == RestartResult.Busy, "busy work did not veto"); }
            finally { App.Services.BusyOperations--; }
            checks.Add("busy work vetoed dispatch");
            Require(second.DebugHoldNavigation(), "could not hold navigation slot");
            try { Require(await RunNoDispatch() == RestartResult.TransitionActive, "transition did not veto"); }
            finally { second.DebugReleaseNavigation(); }
            checks.Add("owned navigation transition vetoed dispatch");
            Require(settings.DebugSetLanguageText("invalid!"), "could not edit Settings field");
            Require(await RunNoDispatch() == RestartResult.SettingsFailed, "invalid Settings field did not veto");
            Require(settings.DebugNavigationEnabled, "invalid Settings field did not restore controls");
            Require(settings.DebugSetLanguageText("et"), "could not restore Settings field");
            checks.Add("invalid Settings text vetoed dispatch and restored Settings");
            var badPath = Path.Combine(output, "save-failure.voxclip");
            Directory.CreateDirectory(badPath);
            first.SetProjectPath(badPath);
            try { Require(await RunNoDispatch() == RestartResult.SaveFailed, "project save failure did not veto"); }
            finally { first.SetProjectPath(firstPath); }
            Require(!firstModel.IsLeaving && settings.DebugNavigationEnabled, "save failure did not restore editing");
            checks.Add("project save failure vetoed dispatch and restored editing");
            queue.DebugBeforeFlush = () => throw new IOException("controlled flush failure");
            Require(await RunNoDispatch() == RestartResult.SettingsFailed, "settings flush failure did not veto");
            queue.DebugBeforeFlush = null;
            Require(!firstModel.IsLeaving && settings.DebugNavigationEnabled, "settings failure did not restore editing");
            checks.Add("settings flush failure vetoed dispatch and restored editing");
            using var cancelled = new CancellationTokenSource();
            cancelled.Cancel();
            Require(await App.Restart.RunAsync(new UpdateRestartSettings(), _ => throw new InvalidOperationException("cancel dispatched"), cancelled.Token)
                == RestartResult.Cancelled, "cancellation did not veto");
            Require(!firstModel.IsLeaving && settings.DebugNavigationEnabled, "cancellation did not restore editing");
            checks.Add("cancellation vetoed dispatch and restored editing");
            Require(await App.Restart.RunAsync(new UpdateRestartSettings(), _ => throw new IOException("fake updater failure"), CancellationToken.None)
                == RestartResult.UpdateFailed, "fake updater failure did not restore");
            Require(!firstModel.IsLeaving && settings.DebugNavigationEnabled, "updater failure did not restore editing");
            checks.Add("fake updater failure restored both windows");
            await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new { status = "passed", checks,
                dispatchResult = dispatchResult?.ToString(), languageBeforeEdit, languageBeforePreparation,
                dispatchCount = dispatched, realUpdater = false },
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception exception)
        {
            await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new { status = "failed", checks,
                dispatchResult = dispatchResult?.ToString(), dispatchCount = dispatched,
                languageBeforeEdit, languageBeforePreparation,
                dispatchError = dispatchError is null ? null : dispatchError.GetType().Name + ": " + dispatchError.Message,
                error = exception.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
            throw;
        }
        finally
        {
            releaseSave?.TrySetResult();
            releaseFlush?.TrySetResult();
            if (accepted is not null)
                try { await accepted.WaitAsync(TimeSpan.FromSeconds(10)); } catch { /* Keep the original probe result. */ }
            if (run is not null)
                try { await run.WaitAsync(TimeSpan.FromSeconds(30)); } catch { /* Keep the original probe result. */ }
            if (queue is not null)
            {
                queue.DebugBeforeSave = null;
                queue.DebugBeforeFlush = null;
            }
        }

        async Task<RestartResult> RunNoDispatch() => await App.Restart.RunAsync(new UpdateRestartSettings(),
            _ => throw new InvalidOperationException("veto unexpectedly dispatched"), CancellationToken.None);
    }

    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(IntPtr window, uint message, nuint wParam, nint lParam);
    private static void Require(bool condition, string reason)
    {
        if (!condition) throw new InvalidOperationException(reason);
    }
}
#endif
