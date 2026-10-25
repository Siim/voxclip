import Foundation
import Testing

@Test("Resolved fractions are strict and pixel tolerances are explicit")
func captionFixtureTolerances() {
    for field in ["x", "y", "sizeSh", "sizeScale", "maxLineWidthW"] {
        #expect(!CaptionMediaFixtures.differences(0.8, 0.800_001, path: ".resolved.\(field)").isEmpty)
        #expect(CaptionMediaFixtures.differences(0.8, 0.800_000_000_1, path: ".resolved.\(field)").isEmpty)
    }
    #expect(CaptionMediaFixtures.differences(900.7125, 900.712, path: ".limitPx").isEmpty)
    #expect(!CaptionMediaFixtures.differences(900.713, 900.712, path: ".limitPx").isEmpty)
    #expect(CaptionMediaFixtures.differences(100, 100.4, path: ".pages[0].block.x").isEmpty)
    #expect(!CaptionMediaFixtures.differences(100, 100.6, path: ".pages[0].block.x").isEmpty)
    #expect(!CaptionMediaFixtures.differences(1, 1.1, path: ".unexpected").isEmpty)
}
