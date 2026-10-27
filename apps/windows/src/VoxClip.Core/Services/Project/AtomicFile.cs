using System.Text;
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("VoxClip.Core.Tests")]

namespace VoxClip.Core.Services.Project;

internal static class AtomicFile
{
    internal static async Task<string> ReadAllTextAsync(string path, Encoding encoding, CancellationToken ct, AtomicFileOperations? operations = null)
    {
        operations ??= new AtomicFileOperations();
        for (var attempt = 0; ; attempt++)
        {
            ct.ThrowIfCancellationRequested();
            try { return await operations.ReadAllTextAsync(path, encoding, ct).ConfigureAwait(false); }
            // ReplaceFile can briefly hide the name or deny a delete-sharing open; retry opens, not malformed JSON.
            catch (IOException exception) when ((exception.HResult & 0xFFFF) is 2 or 32 or 33 && attempt < 5)
            {
                await operations.DelayAsync(25 << attempt, ct).ConfigureAwait(false);
            }
        }
    }

    /// <summary><paramref name="unixCreateMode"/> sets the temporary file's mode where the platform has modes; the rename keeps it.</summary>
    internal static async Task WriteAsync(string path, string content, CancellationToken ct, AtomicFileOperations? operations = null,
        UnixFileMode? unixCreateMode = null)
    {
        operations ??= new AtomicFileOperations();
        ct.ThrowIfCancellationRequested();
        path = Path.GetFullPath(path);
        if (Directory.Exists(path)) throw new IOException("The destination is a directory.");
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        var backup = temporary + ".bak";
        var existed = operations.Exists(path);
        var staged = false;
        var committed = false;
        try
        {
            var options = new FileStreamOptions
            {
                Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None, BufferSize = 65536, Options = FileOptions.Asynchronous
            };
            if (unixCreateMode is { } mode && !OperatingSystem.IsWindows()) options.UnixCreateMode = mode;
            await using (var stream = new FileStream(temporary, options))
            {
                await stream.WriteAsync(Encoding.UTF8.GetBytes(content), ct).ConfigureAwait(false);
                await stream.FlushAsync(ct).ConfigureAwait(false);
                stream.Flush(true);
            }
            staged = true;
            for (var attempt = 0; ; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    if (!operations.Exists(path) && operations.Exists(backup)) operations.Move(backup, path, false);
                    if (operations.UseReplace && operations.Exists(path))
                    {
                        try { operations.Replace(temporary, path, backup); }
                        catch (IOException exception) when ((exception.HResult & 0xFFFF) is 50 or 87)
                        {
                            operations.Move(temporary, path, true);
                        }
                    }
                    else operations.Move(temporary, path, true);
                    committed = true;
                    break;
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    if (!operations.Exists(path))
                    {
                        try
                        {
                            if (operations.Exists(backup)) operations.Move(backup, path, false);
                            else if (existed && operations.Exists(temporary))
                            {
                                operations.Move(temporary, path, false);
                                committed = true;
                                break;
                            }
                        }
                        catch (Exception recovery) when (recovery is IOException or UnauthorizedAccessException) { }
                    }
                    if (attempt >= 5 || (exception.HResult & 0xFFFF) is not (5 or 32 or 33 or 1175) ||
                        !operations.Exists(temporary)) throw;
                    await operations.DelayAsync(25 << attempt, ct).ConfigureAwait(false);
                }
            }
        }
        finally
        {
            try { if (!staged || operations.Exists(path) || !existed && !operations.Exists(backup)) operations.Delete(temporary); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
            try { if (committed) operations.Delete(backup); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
        }
    }
}

internal class AtomicFileOperations
{
    internal virtual async Task<string> ReadAllTextAsync(string path, Encoding encoding, CancellationToken ct)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
            65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var reader = new StreamReader(stream, encoding);
        return await reader.ReadToEndAsync(ct).ConfigureAwait(false);
    }
    internal virtual bool UseReplace => OperatingSystem.IsWindows();
    internal virtual bool Exists(string path) => File.Exists(path);
    internal virtual void Replace(string temporary, string path, string backup) => File.Replace(temporary, path, backup);
    internal virtual void Move(string source, string destination, bool overwrite) => File.Move(source, destination, overwrite);
    internal virtual void Delete(string path) => File.Delete(path);
    internal virtual Task DelayAsync(int milliseconds, CancellationToken ct) => Task.Delay(milliseconds, ct);
}
