using System.ComponentModel;
using System.Diagnostics;

namespace VoxClip.Media.Tests;

internal static class TestProcessCleanup
{
    internal static async Task ReapAsync(Process process, params Task[] ownedTasks)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) { }
        catch (Win32Exception) { }

        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (InvalidOperationException) { }
        catch (Win32Exception) { }
        catch (TimeoutException) { }

        try { await Task.WhenAll(ownedTasks).WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (Exception) { /* Preserve the failure that required cleanup. */ }
    }
}
