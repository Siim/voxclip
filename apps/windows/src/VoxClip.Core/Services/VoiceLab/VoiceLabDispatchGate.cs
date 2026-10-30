#pragma warning disable CS1591
namespace VoxClip.Core.Services.VoiceLab;

public sealed class VoiceLabRunInvalidatedException() : Exception("The Voice Lab inputs changed.");

public sealed class VoiceLabDispatchGate
{
    private readonly object sync = new();
    private long revision;
    public VoiceLabDispatchBinding Capture()
    {
        lock (sync) return new(this, revision);
    }
    public void Invalidate()
    {
        lock (sync) revision = checked(revision + 1);
    }
    internal T Start<T>(long expected, Func<T> start)
    {
        lock (sync)
        {
            if (revision != expected) throw new VoiceLabRunInvalidatedException();
            return start();
        }
    }
}
public sealed class VoiceLabDispatchBinding
{
    private readonly VoiceLabDispatchGate gate;
    private readonly long revision;
    internal VoiceLabDispatchBinding(VoiceLabDispatchGate gate, long revision) { this.gate = gate; this.revision = revision; }
    public void Validate() => gate.Start(revision, () => true);
    internal T Start<T>(Func<T> start) => gate.Start(revision, start);
}
