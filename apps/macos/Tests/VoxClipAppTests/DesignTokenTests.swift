import AppKit
import Testing
@testable import VoxClip

/// The v2 tokens (notes.md sections 2 and 3, impl-plan V0): the type scale, the tint and Increase Contrast.
@Suite("v2 design tokens")
@MainActor struct DesignTokenTests {
    private func hex(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return "none" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    /// A dynamic colour as AppKit draws it in a named appearance (aqua or darkAqua).
    private func hex(_ color: NSColor, in name: NSAppearance.Name) throws -> String {
        let appearance = try #require(NSAppearance(named: name))
        var result = ""
        appearance.performAsCurrentDrawingAppearance { result = hex(color) }
        return result
    }

    @Test func typeScaleUsesOnlyTheNativeTextStyleSizes() {
        #expect(VCType.allCases.map(\.size) == [15, 13, 12, 11, 10, 9])
        #expect(VCType.title3.size == NSFont.preferredFont(forTextStyle: .title3, options: [:]).pointSize)
        #expect(VCType.body.size == NSFont.systemFontSize)
        #expect(VCType.callout.size == NSFont.preferredFont(forTextStyle: .callout, options: [:]).pointSize)
        #expect(VCType.small.size == NSFont.smallSystemFontSize)
        #expect(VCType.label.size == NSFont.labelFontSize)
        #expect(VCType.mini.size == NSFont.systemFontSize(for: .mini))
        #expect(VCType.allCases.allSatisfy { $0.lineHeight > $0.size })
        #expect(VCType.title3.lineHeight == 20 && VCType.transcriptLineHeight == 26)
    }

    @Test(arguments: VCType.allCases) func monoIsTheSameSizeInTheMonospacedDesign(type: VCType) {
        let mono = type.nsMono(.medium), text = type.nsFont()
        #expect(mono.pointSize == type.size && text.pointSize == type.size)
        #expect(mono.isFixedPitch && !text.isFixedPitch)
    }

    @Test func v2PaletteResolvesInTheDarkAppearance() throws {
        for (path, expected) in [("bg.window", "#17181A"), ("bg.surface", "#1C1D20"), ("editor.band", "#222327"), ("timeline.lane", "#111214"),
                                 ("text.primary", "#ECECEA"), ("text.tertiary", "#82858B"), ("word.gone", "#878A90"), ("tint.default", "#F26B3A")] {
            #expect(try hex(DesignValues.nsColor(path), in: .darkAqua) == expected, "\(path)")
        }
    }

    @Test func theTintIsNotTheAccent() throws {
        // accent.* stays Ink so system controls stay neutral; the orange is only ever an explicit tint.
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            #expect(try hex(DesignValues.nsColor("tint.default"), in: name) != hex(DesignValues.nsColor("accent.default"), in: name))
        }
        #expect(try hex(DesignValues.nsColor("accent.default"), in: .darkAqua) == "#6D6F73")
    }

    @Test func increaseContrastRaisesOnlyTheRecordedGreys() throws {
        // NSAppearance(named:) gives the plain aqua or darkAqua appearance for the high-contrast names,
        // which exist for bestMatch(from:), so the resolver behind every dynamic token colour is checked directly.
        #expect(TokenColorModes.appearances == [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
        let raised = [("gutter.text", "#6A6D73", "#878A90"), ("gutter.textOut", "#55585E", "#878A90"), ("fold.dot", "#5B5E64", "#707379"),
                      ("line.strong", "#34353A", "#6C6E75"), ("text.disabled", "#4E5056", "#82858B")]
        for (path, normal, increased) in raised {
            let modes = try #require(DesignValues.colorModes(path), "\(path)")
            #expect(hex(modes.resolve(.darkAqua)) == normal && hex(modes.resolve(.accessibilityHighContrastDarkAqua)) == increased, "\(path)")
            #expect(try hex(DesignValues.nsColor(path), in: .darkAqua) == normal, "\(path)")
        }
        #expect(hex(DesignValues.colorModes("gutter.text")?.resolve(.accessibilityHighContrastAqua)) == "#66696F")
        #expect(hex(DesignValues.colorModes("gutter.text")?.resolve(nil)) == "#7E8187")
        // Colours without an increaseContrast value keep their own value under Increase Contrast.
        for path in ["text.primary", "bg.surface", "tint.default"] {
            let modes = try #require(DesignValues.colorModes(path), "\(path)")
            #expect(hex(modes.resolve(.accessibilityHighContrastDarkAqua)) == hex(modes.resolve(.darkAqua)), "\(path)")
            #expect(hex(modes.resolve(.accessibilityHighContrastAqua)) == hex(modes.resolve(.aqua)), "\(path)")
        }
    }
}
