using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Hosted CI requires native inputs but cannot produce VM or release evidence.</summary>
public sealed class NativeEvidenceGateTests
{
    [Theory]
    [InlineData(null, null, false, false)]
    [InlineData("1", null, true, false)]
    [InlineData(null, "1", false, true)]
    [InlineData("1", "1", true, true)]
    public void EachFlagFailsOnlyItsOwnMissingInput(string? requireNative, string? requireVmEvidence,
        bool prerequisiteFails, bool evidenceFails)
    {
        Assert.Equal(prerequisiteFails ? NativeGateOutcome.Fail : NativeGateOutcome.Skip,
            NativeTest.Decide(NativeGate.Prerequisite, false, requireNative, requireVmEvidence));
        Assert.Equal(evidenceFails ? NativeGateOutcome.Fail : NativeGateOutcome.Skip,
            NativeTest.Decide(NativeGate.Evidence, false, requireNative, requireVmEvidence));
        Assert.Equal(NativeGateOutcome.Run,
            NativeTest.Decide(NativeGate.Prerequisite, true, requireNative, requireVmEvidence));
        Assert.Equal(NativeGateOutcome.Run,
            NativeTest.Decide(NativeGate.Evidence, true, requireNative, requireVmEvidence));
    }
}
