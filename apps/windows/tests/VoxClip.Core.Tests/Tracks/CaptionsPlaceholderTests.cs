using Xunit;
using VoxClip.Core.Domain.Captions;
namespace VoxClip.Core.Tests.Tracks;

public sealed class CaptionsPlaceholderTests
{
    [Fact]
    public void TrackConformance()
    {
        Assert.Equal("Õ Ä Ö Ü Š Ž 03:15 SS", CaptionEngine.TransformText("õ ä ö ü š ž 03:15. ß", new(CaptionTextTransformValue.Uppercase, CaptionTextPunctuationValue.StripKeepNumeric)));
        Assert.Equal(1, CaptionMath.RoundHalfUp(0.5));
        Assert.Equal(0, CaptionMath.RoundHalfUp(-0.5));
        Assert.Equal(0, CaptionMath.RoundHalfUp(0.49999999999999994));
    }
}
