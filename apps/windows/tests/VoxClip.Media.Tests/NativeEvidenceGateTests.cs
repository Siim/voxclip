using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Hosted CI requires native inputs but cannot produce VM or release evidence or open an audio output device.</summary>
public sealed class NativeEvidenceGateTests
{
    [Theory]
    [InlineData(null, null, null, false, false, false)]
    [InlineData("1", null, null, true, false, false)]
    [InlineData(null, "1", null, false, true, false)]
    [InlineData(null, null, "1", false, false, true)]
    [InlineData("1", "1", null, true, true, false)]
    [InlineData("1", null, "1", true, false, true)]
    [InlineData(null, "1", "1", false, true, true)]
    [InlineData("1", "1", "1", true, true, true)]
    [InlineData("0", "0", "0", false, false, false)]
    public void EachFlagFailsOnlyItsOwnMissingInput(string? requireNative, string? requireVmEvidence, string? requireAudioOutput,
        bool prerequisiteFails, bool evidenceFails, bool audioOutputFails)
    {
        foreach (var (gate, fails) in new[] { (NativeGate.Prerequisite, prerequisiteFails), (NativeGate.Evidence, evidenceFails),
            (NativeGate.AudioOutput, audioOutputFails) })
        {
            Assert.Equal(fails ? NativeGateOutcome.Fail : NativeGateOutcome.Skip,
                NativeTest.Decide(gate, false, requireNative, requireVmEvidence, requireAudioOutput));
            Assert.Equal(NativeGateOutcome.Run, NativeTest.Decide(gate, true, requireNative, requireVmEvidence, requireAudioOutput));
        }
    }
}
