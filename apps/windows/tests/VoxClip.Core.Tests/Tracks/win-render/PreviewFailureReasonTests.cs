using VoxClip.Core.Services.Media;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>The preview's fixed failure tags (design.md §5.4.4 g; Mac <c>PreviewFailureReason</c>): the same tags and keep-the-picture rule,
/// and the reason a failed frame's exception carries.</summary>
public sealed class PreviewFailureReasonTests
{
    [Fact]
    public void TheTagsAndTheKeepThePictureRuleAreTheMacs()
    {
        Assert.Equal(["caption-layout", "caption-raster", "disclosure", "source-frame", "lipsync-frame", "demo-frame", "resources", "frame-buffer", "title"],
            PreviewFailureReasons.All.Select(reason => reason.Tag()));
        Assert.Equal(Enum.GetValues<PreviewFailureReason>().Length, PreviewFailureReasons.All.Count);
        Assert.Equal([PreviewFailureReason.CaptionLayout, PreviewFailureReason.CaptionRaster, PreviewFailureReason.Resources, PreviewFailureReason.Title],
            PreviewFailureReasons.All.Where(reason => reason.KeepsPicture()));
    }

    [Fact]
    public void AMarkedExceptionCarriesItsReasonThroughWrapping()
    {
        var failure = new IOException("decode");
        Assert.Null(PreviewFailureReasons.Of(failure));
        PreviewFailureReasons.Mark(failure, PreviewFailureReason.SourceFrame);
        Assert.Equal(PreviewFailureReason.SourceFrame, PreviewFailureReasons.Of(failure));
        Assert.Equal(PreviewFailureReason.SourceFrame, PreviewFailureReasons.Of(new InvalidOperationException("wrapped", failure)));
        Assert.Null(PreviewFailureReasons.Of(null));
    }
}
