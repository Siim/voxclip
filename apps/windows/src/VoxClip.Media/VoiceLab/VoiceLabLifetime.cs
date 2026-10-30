using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

internal sealed class VoiceLabLifetime(Action cleanup)
{
    private readonly object sync = new();
    private readonly Dictionary<Guid, Func<Task>> consumers = [];
    private Task? invalidation;
    private bool valid = true;
    internal bool IsValid { get { lock (sync) return valid; } }
    internal IDisposable Attach(Func<Task> stop)
    {
        ArgumentNullException.ThrowIfNull(stop);
        lock (sync)
        {
            if (!valid) throw new VoiceLabException(VoiceLabErrorKind.InvalidAudio);
            var id = Guid.NewGuid();
            consumers.Add(id, stop);
            return new Lease(this, id);
        }
    }
    internal Task InvalidateAsync()
    {
        lock (sync)
        {
            if (invalidation is not null) return invalidation;
            valid = false;
            var stops = consumers.Values.ToArray();
            consumers.Clear();
            invalidation = Task.Run(async () =>
            {
                try { await Task.WhenAll(stops.Select(async stop => await stop().ConfigureAwait(false))).ConfigureAwait(false); }
                finally { cleanup(); }
            });
            return invalidation;
        }
    }
    private sealed class Lease(VoiceLabLifetime owner, Guid id) : IDisposable
    {
        public void Dispose() { lock (owner.sync) owner.consumers.Remove(id); }
    }
}
