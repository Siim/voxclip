#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class ColumnBoundsGateTests
{
    [Fact]
    public void NestedDisabledOrZeroExtentViewersDeferToTheOuterScrollOwner()
    {
        var viewers = new[] { (Enabled: false, Height: 120.0), (Enabled: true, Height: 0.0), (Enabled: true, Height: 240.0) };
        Assert.Equal(2, Array.FindIndex(viewers, viewer => ColumnBoundsGate.OwnsVerticalScroll(viewer.Enabled, viewer.Height)));
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var probe = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Pages/EditorPage.FitProbe.cs"));
        Assert.Contains("ColumnBoundsGate.OwnsVerticalScroll(viewer.VerticalScrollMode != ScrollMode.Disabled, viewer.ScrollableHeight)", probe);
        Assert.Contains("rewritePanel?.DebugFitRequiredIds()", probe);
        var panel = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/RewritePanel.cs"));
        Assert.Contains("AutomationProperties.SetAutomationId(scroll, \"Rewrite.Scroll\")", panel);
        Assert.Contains("DebugFitRequiredIds()", panel);
    }

    [Fact]
    public void RewriteRequiresExactlyThePanelsCurrentPeerSet()
    {
        string[] peers = ["Rewrite.Header", "Rewrite.Generate", "Rewrite.Takes", "Rewrite.UseTake"];
        Assert.Equal(ColumnBoundsGate.Common.Concat(peers), ColumnBoundsGate.RequiredIds(ColumnFitState.Rewrite, [], peers));
    }

    [Fact]
    public void CompactTransportChecksTimeTagAndTargetsBesideTheStage()
    {
        var bar = new ColumnRect(228, 0, 112, 100);
        var back = new ColumnRect(228, 56, 32, 32);
        var play = new ColumnRect(264, 52, 40, 40);
        var forward = new ColumnRect(308, 56, 32, 32);
        var time = new ColumnRect(228, 0, 112, 20);
        var tag = new ColumnRect(228, 24, 90, 20);
        var stage = new ColumnRect(0, 0, 220, 124);
        Assert.Empty(ColumnBoundsGate.TransportFailures(bar, back, play, forward, tag, time, true, 4, stage));
        Assert.NotEmpty(ColumnBoundsGate.TransportFailures(bar, back, play, forward, tag, time, false, 4, stage));
        Assert.NotEmpty(ColumnBoundsGate.TransportFailures(bar, back, play, forward, tag, time, true, 4, stage with { X = 40 }));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void FineTuneRequiresSwatchesOnlyForAccentedStyles(bool accent)
    {
        var required = ColumnBoundsGate.RequiredIds(ColumnFitState.FineTune, ["CaptionStyle.vox-bold-plus"], accent: accent);
        Assert.Equal(accent ? CaptionFineTune.Colors.Length : 0, required.Count(id => id.StartsWith("FineTune.Colour.", StringComparison.Ordinal)));
        Assert.All(ColumnBoundsGate.FineTune, id => Assert.Contains(id, required));
    }
    private static readonly ColumnRect Column = new(700, 100, 300, 700);
    private static readonly ColumnRect Client = new(0, 0, 1000, 800);
    private static ColumnPeer Peer(string id = "PreviewStage", ColumnRect? bounds = null, bool offscreen = false,
        ColumnScrollRegion? scroll = null) => new(id, "Named " + id, "Button", bounds ?? new(720, 120, 260, 32), offscreen, scroll);

    [Theory]
    [InlineData(164, 156)]
    [InlineData(-1200, 200)]
    [InlineData(0, 0)]
    public void InProcessPeerBoundsUseTheSameScreenOriginAsTheColumn(double clientX, double clientY)
    {
        var peer = Peer() with { Bounds = Peer().Bounds.ToScreen(clientX, clientY) };
        Assert.True(ColumnBoundsGate.Assess(peer, Column.ToScreen(clientX, clientY), Client.ToScreen(clientX, clientY)).Accepted);
        var overflowing = peer with { Bounds = new ColumnRect(990, 120, 40, 32).ToScreen(clientX, clientY) };
        Assert.False(ColumnBoundsGate.Assess(overflowing, Column.ToScreen(clientX, clientY), Client.ToScreen(clientX, clientY)).Accepted);
    }

    [Fact]
    public void TranslatingAnEmptyPeerDoesNotMakeItMeasurable() =>
        Assert.False(default(ColumnRect).ToScreen(164, 156).Measurable);

    [Fact]
    public void MissingRequiredPeerFailsDespiteManyUnrelatedPeers()
    {
        var peers = Enumerable.Range(0, 30).Select(index => Peer("Unrelated" + index)).ToArray();
        Assert.Equal(["PreviewStage: missing or unrealized"], ColumnBoundsGate.RequiredFailures(["PreviewStage"], peers, Column, Client));
    }

    [Theory]
    [InlineData(0, 32)]
    [InlineData(260, 0)]
    [InlineData(-1, 32)]
    [InlineData(double.NaN, 32)]
    [InlineData(double.PositiveInfinity, 32)]
    public void ZeroSizedOrNonfiniteRequiredPeerFails(double width, double height)
    {
        var failures = ColumnBoundsGate.RequiredFailures(["PreviewStage"], [Peer(bounds: new(720, 120, width, height))], Column, Client);
        Assert.Equal(["PreviewStage: unmeasurable"], failures);
    }

    [Theory]
    [InlineData(690, 120, 100, 32)]
    [InlineData(900, 120, 110, 32)]
    [InlineData(720, 90, 100, 32)]
    [InlineData(720, 790, 100, 32)]
    public void RequiredPeerOutsideEitherColumnAxisFails(double left, double top, double width, double height)
    {
        var failures = ColumnBoundsGate.RequiredFailures(["PreviewStage"], [Peer(bounds: new(left, top, width, height))], Column, Client);
        Assert.Equal(["PreviewStage: overflow"], failures);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void PeerBelowClientWithoutOwnedScrollingFails(bool offscreen)
    {
        var peer = Peer(bounds: new(720, 810, 100, 32), offscreen: offscreen);
        Assert.False(ColumnBoundsGate.Assess(peer, new(700, 100, 300, 1000), Client).Accepted);
    }

    [Theory]
    [InlineData(690, 120)]
    [InlineData(980, 120)]
    [InlineData(720, 90)]
    [InlineData(720, 790)]
    public void EveryOnscreenPeerMustFitBothColumnAxes(double left, double top) =>
        Assert.False(ColumnBoundsGate.Assess(Peer(bounds: new(left, top, 40, 32)), Column, Client).Accepted);

    [Theory]
    [InlineData("Captions.Gallery", false)]
    [InlineData("Captions.Gallery", true)]
    [InlineData("FineTune.ScrollViewer", false)]
    [InlineData("FineTune.ScrollViewer", true)]
    [InlineData("Rewrite.ScrollViewer", false)]
    [InlineData("Rewrite.ScrollViewer", true)]
    public void OwnedCaptionGalleryFineTuneAndRewriteScrollingIsNotOverflow(string owner, bool above)
    {
        var region = new ColumnScrollRegion(owner, new(716, 400, 268, 380), 200, 1000);
        var peer = Peer(bounds: new(720, above ? 250 : 850, 260, 32), offscreen: true, scroll: region);
        Assert.Equal(new(true, "scrolled out"), ColumnBoundsGate.Assess(peer, Column, Client));
    }

    [Fact]
    public void ScrolledRequiredPeerMustBeBroughtIntoViewBeforeAcceptance()
    {
        var region = new ColumnScrollRegion("Rewrite.ScrollViewer", new(716, 400, 268, 380), 200, 1000);
        var peer = Peer(bounds: new(720, 850, 260, 32), offscreen: true, scroll: region);
        Assert.Equal(["PreviewStage: required peer is offscreen"], ColumnBoundsGate.RequiredFailures(["PreviewStage"], [peer], Column, Client));
        Assert.Empty(ColumnBoundsGate.RequiredFailures(["PreviewStage"], [peer with { Bounds = new(720, 420, 260, 32), Offscreen = false }], Column, Client));
    }

    [Theory]
    [InlineData(690, 400, 268, 380, 200, 1000)]
    [InlineData(716, 400, 300, 380, 200, 1000)]
    [InlineData(716, 90, 268, 380, 200, 1000)]
    [InlineData(716, 500, 268, 380, 200, 1000)]
    [InlineData(716, 400, 268, 380, 0, 380)]
    [InlineData(716, 400, 268, 380, -1, 1000)]
    [InlineData(716, 400, 268, 380, 700, 1000)]
    [InlineData(716, 400, 268, 380, double.NaN, 1000)]
    public void InvalidOrOverflowingScrollViewerCannotExcuseOffscreenPeers(double left, double top, double width,
        double height, double offset, double extent)
    {
        var region = new ColumnScrollRegion("owned", new(left, top, width, height), offset, extent);
        Assert.False(ColumnBoundsGate.Assess(Peer(bounds: new(720, 850, 260, 32), offscreen: true, scroll: region), Column, Client).Accepted);
    }

    [Theory]
    [InlineData(710, 850)]
    [InlineData(730, 850)]
    [InlineData(720, 100)]
    [InlineData(720, 1250)]
    [InlineData(720, 450)]
    public void OffscreenPeerMustFitScrollHorizontalAndContentExtentsAndBeVerticallyScrolled(double left, double top)
    {
        var region = new ColumnScrollRegion("owned", new(716, 400, 268, 380), 200, 1000);
        Assert.False(ColumnBoundsGate.Assess(Peer(bounds: new(left, top, 260, 32), offscreen: true, scroll: region), Column, Client).Accepted);
    }

    [Fact]
    public void ScrollViewerInsideColumnButOutsideClientFails()
    {
        var region = new ColumnScrollRegion("owned", new(716, 500, 268, 380), 200, 1000);
        Assert.False(ColumnBoundsGate.Assess(Peer(bounds: new(720, 950, 260, 32), offscreen: true, scroll: region), new(700, 100, 300, 1000), Client).Accepted);
    }

    [Fact]
    public void AnOffscreenScrollViewerCannotExcuseOffscreenPeers()
    {
        var region = new ColumnScrollRegion("owned", new(716, 400, 268, 380), 200, 1000, Onscreen: false);
        Assert.False(ColumnBoundsGate.Assess(Peer(bounds: new(720, 850, 260, 32), offscreen: true, scroll: region), Column, Client).Accepted);
    }

    [Fact]
    public void AliasedRequiredIdentityCannotHideAnUnmeasurablePeer() =>
        Assert.Equal(["PreviewStage: unmeasurable"], ColumnBoundsGate.RequiredFailures(["PreviewStage"], [Peer(), Peer(bounds: default(ColumnRect))], Column, Client));

    [Fact]
    public void RealizedDataAndContainerPeersMayBothCoverTheSameIdentity() =>
        Assert.Empty(ColumnBoundsGate.RequiredFailures(["PreviewStage"], [Peer(), Peer() with { Role = "DataItem" }], Column, Client));

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ParkedCopyNeedsAnExplicitScrollProofAndAVisibleSameIdentity(bool proven)
    {
        var region = new ColumnScrollRegion("gallery", new(716, 400, 268, 380), 200, 1000);
        var visible = Peer("CaptionGroup.Phrase", new(720, 420, 80, 20), scroll: region);
        var cached = visible with { Bounds = new(-15000, -15000, 80, 20), Offscreen = true };
        var resolved = ColumnBoundsGate.ResolveVirtualizedAliases([visible, cached], new HashSet<ColumnPeer> { cached }, proven, Column, Client);
        Assert.Equal(proven ? 1 : 2, resolved.Count);
        Assert.Equal(proven ? 0 : 1, ColumnBoundsGate.RequiredFailures([visible.Id], resolved, Column, Client).Count);
        Assert.Single(ColumnBoundsGate.ResolveVirtualizedAliases([cached], new HashSet<ColumnPeer> { cached }, true, Column, Client));
    }

    [Fact]
    public void CacheProofCannotHideARealInvalidAliasOrADifferentRequiredIdentity()
    {
        var region = new ColumnScrollRegion("gallery", new(716, 400, 268, 380), 200, 1000);
        var visible = Peer("CaptionGroup.Phrase", new(720, 420, 80, 20), scroll: region);
        var cached = visible with { Bounds = new(-15000, -15000, 80, 20), Offscreen = true };
        var invalid = visible with { Bounds = default };
        var other = cached with { Id = "CaptionGroup.Sentence" };
        var resolved = ColumnBoundsGate.ResolveVirtualizedAliases([visible, cached, invalid, other],
            new HashSet<ColumnPeer> { cached, other }, true, Column, Client);
        Assert.Equal(["CaptionGroup.Phrase: unmeasurable", "CaptionGroup.Sentence: required peer is offscreen"],
            ColumnBoundsGate.RequiredFailures([visible.Id, other.Id], resolved, Column, Client));
    }

    [Fact]
    public void CacheProofRequiresTheLiveCopyInsideBothClientAndOwningViewport()
    {
        var region = new ColumnScrollRegion("gallery", new(716, 400, 268, 380), 200, 1000);
        var cached = Peer("CaptionGroup.Phrase", new(-15000, -15000, 80, 20), offscreen: true, scroll: region);
        foreach (var live in new[] { cached with { Bounds = new(720, 120, 80, 20), Offscreen = false },
            cached with { Bounds = new(720, 810, 80, 20), Offscreen = false }, cached with { Bounds = default, Offscreen = false } })
            Assert.Equal(2, ColumnBoundsGate.ResolveVirtualizedAliases([live, cached],
                new HashSet<ColumnPeer> { cached }, true, Column, Client).Count);
    }

    [Fact]
    public void EachSampledStateRequiresItsSpecificControls()
    {
        string[] common = ["PreviewStage", "TransportBack", "TransportPlay", "TransportForward", "TransportTime",
            "Frame.9:16", "Frame.1:1", "Frame.16:9", "Frame.Original"];
        string[] captions = ["Captions.Toggle", "Captions.StyleName", "Captions.Summary", "Captions.Gallery", "CaptionStyle.first", "CaptionStyle.second"];
        string[] fineTune = ["FineTune.Size", "FineTune.Case", "FineTune.Words on screen", "FineTune.Punctuation", "FineTune.Position", "FineTune.Reset",
            "FineTune.Colour.Yellow", "FineTune.Colour.Green", "FineTune.Colour.Cyan", "FineTune.Colour.Pink", "FineTune.Colour.Paper", "FineTune.Colour.White"];
        string[] rewrite = ["Rewrite.Header", "Rewrite.Instruction", "Rewrite.Words", "Rewrite.Close", "Rewrite.Propose", "Rewrite.Apply", "Rewrite.Settings"];
        Assert.Equal(common.Concat(captions), ColumnBoundsGate.RequiredIds(ColumnFitState.Captions, ["CaptionStyle.first", "CaptionStyle.second"]));
        Assert.Equal(common.Concat(captions).Concat(fineTune), ColumnBoundsGate.RequiredIds(ColumnFitState.FineTune, ["CaptionStyle.first", "CaptionStyle.second"]));
        Assert.Equal(common.Concat(rewrite), ColumnBoundsGate.RequiredIds(ColumnFitState.Rewrite, [], rewrite));
        Assert.DoesNotContain("Rewrite.Apply", ColumnBoundsGate.RequiredIds(ColumnFitState.Rewrite, []));
        Assert.DoesNotContain("Rewrite.Settings", ColumnBoundsGate.RequiredIds(ColumnFitState.Rewrite, []));
    }

    [Fact]
    public void GalleryWithNoRealizedVisibleChoicesCannotPass()
    {
        var ids = ColumnBoundsGate.RequiredIds(ColumnFitState.Captions, []);
        var peers = ids.Where(id => id != "Captions.Gallery.VisibleChoice").Select(id => Peer(id)).ToArray();
        Assert.Equal(["Captions.Gallery.VisibleChoice: missing or unrealized"], ColumnBoundsGate.RequiredFailures(ids, peers, Column, Client));
    }

    [Fact]
    public void EveryRequiredIdentityIsEnforcedInEverySampledState()
    {
        foreach (var state in Enum.GetValues<ColumnFitState>())
        {
            var ids = ColumnBoundsGate.RequiredIds(state, ["CaptionStyle.first"], [.. ColumnBoundsGate.Rewrite, "Rewrite.Apply", "Rewrite.Settings"]);
            var peers = ids.Select(id => Peer(id)).ToArray();
            Assert.Empty(ColumnBoundsGate.RequiredFailures(ids, peers, Column, Client));
            foreach (var id in ids)
            {
                Assert.Single(ColumnBoundsGate.RequiredFailures(ids, peers.Where(peer => peer.Id != id).ToArray(), Column, Client));
                Assert.Single(ColumnBoundsGate.RequiredFailures(ids, peers.Select(peer => peer.Id == id ? peer with { Bounds = default } : peer).ToArray(), Column, Client));
            }
        }
    }

    private static readonly ColumnRect Back = new(0, 4, 32, 32), Play = new(36, 0, 40, 40), Forward = new(80, 4, 32, 32);
    private static IReadOnlyList<string> Transport(ColumnRect bar, ColumnRect? tag, ColumnRect time, bool stacked,
        ColumnRect? back = null, ColumnRect? play = null, ColumnRect? forward = null) =>
        ColumnBoundsGate.TransportFailures(bar, back ?? Back, play ?? Play, forward ?? Forward, tag, time, stacked, 4);

    [Fact]
    public void TheSpecViewerBarPassesInlineAndStackedUnderTheControls()
    {
        Assert.Empty(Transport(new(0, 0, 528, 40), new(292, 10, 72, 20), new(368, 11, 160, 18), stacked: false));
        Assert.Empty(Transport(new(0, 0, 268, 40), null, new(153, 11, 115, 18), stacked: false));
        Assert.Empty(Transport(new(0, 0, 268, 64), new(32, 44, 72, 20), new(108, 45, 160, 18), stacked: true));
    }

    [Fact]
    public void ShrunkTargetsFailEvenWhenTheRowFits() =>
        Assert.Equal(["TransportBack: 28x32, not 32x32", "TransportPlay: 36x40, not 40x40", "TransportForward: 28x32, not 32x32"],
            Transport(new(0, 0, 268, 40), null, new(108, 11, 160, 18), stacked: false, back: new(0, 4, 28, 32), play: new(32, 0, 36, 40), forward: new(72, 4, 28, 32)));

    [Fact]
    public void TheAiTagMustFollowTheControlsInlineAndStacked()
    {
        Assert.Equal(["AiModified: not after Forward on the transport's line"], Transport(new(0, 0, 528, 40), new(0, 10, 72, 20),
            new(368, 11, 160, 18), stacked: false, back: new(76, 4, 32, 32), play: new(112, 0, 40, 40), forward: new(156, 4, 32, 32)));
        Assert.Equal(["AiModified: not under the transport", "TransportTime: not under the transport", "TransportTime: does not follow AI modified on its line"],
            Transport(new(0, 0, 268, 64), new(0, 0, 72, 20), new(116, 35, 152, 18), stacked: true,
                back: new(0, 28, 32, 32), play: new(36, 24, 40, 40), forward: new(80, 28, 32, 32)));
    }

    [Fact]
    public void ATimeThatDoesNotFitBesideTheControlsCannotOverflowTheBar() =>
        Assert.Equal(["TransportTime: outside the viewer bar", "TransportTime: does not end at the bar's trailing edge"],
            Transport(new(0, 0, 268, 40), null, new(116, 11, 160, 18), stacked: false));

    [Fact]
    public void TheTagAndTimeStayBesideTheControlsWhileTheyFit() =>
        Assert.Equal(["Transport: the tag and time moved under the controls although they fit beside them"],
            Transport(new(0, 0, 528, 64), new(292, 44, 72, 20), new(368, 45, 160, 18), stacked: true));
}
#endif
