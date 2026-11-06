using System.Text;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary><c>&lt;data&gt;/VoiceLab/per-video.json</c> (<c>voxclip-voice-per-video/1</c>, voice-lab.md §6.13; Mac <c>VoicePerVideoStore</c>):
/// which voice each video uses. App data, private (0700 folder, 0600 file), written atomically; never inside a project file. A missing or
/// unreadable file reads as empty, so a damaged book only forgets which voices were per-video (they stay listed and removable in
/// Settings › Voices). Calls are serialised, so two changes never overwrite each other.</summary>
public sealed class VoicePerVideoStore
{
    private readonly SemaphoreSlim gate = new(1, 1);

    /// <summary>The book's file.</summary>
    public string FilePath { get; }

    /// <summary>The store under <paramref name="locations"/>' data folder.</summary>
    public VoicePerVideoStore(DataLocations locations) : this(Path.Combine(locations.Root, "VoiceLab", "per-video.json")) { }

    /// <summary>The store at <paramref name="filePath"/>.</summary>
    public VoicePerVideoStore(string filePath) => FilePath = Path.GetFullPath(filePath);

    /// <summary>The stored book, or an empty one when there is none or it can't be read or doesn't validate.</summary>
    public async Task<VoicePerVideoBook> LoadAsync(CancellationToken ct = default)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try { return await ReadAsync(ct).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    /// <summary>Validates and stores <paramref name="book"/>.</summary>
    public async Task SaveAsync(VoicePerVideoBook book, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try { await WriteAsync(book, ct).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    /// <summary>Loads, changes and saves in one step; returns the book as stored.</summary>
    public async Task<VoicePerVideoBook> UpdateAsync(Func<VoicePerVideoBook, VoicePerVideoBook> change, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(change);
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var next = change(await ReadAsync(ct).ConfigureAwait(false));
            await WriteAsync(next, ct).ConfigureAwait(false);
            return next;
        }
        finally { gate.Release(); }
    }

    private async Task<VoicePerVideoBook> ReadAsync(CancellationToken ct)
    {
        try
        {
            var book = VoicePerVideoBook.Decode(await File.ReadAllTextAsync(FilePath, Encoding.UTF8, ct).ConfigureAwait(false));
            book.Validate();
            return book;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or VoiceLabException) { return new(); }
    }

    private Task WriteAsync(VoicePerVideoBook book, CancellationToken ct)
    {
        book.Validate();
        var folder = Path.GetDirectoryName(FilePath)!;
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(folder);
        else Directory.CreateDirectory(folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return AtomicFile.WriteAsync(FilePath, book.Encoded(), ct, unixCreateMode: UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
}
