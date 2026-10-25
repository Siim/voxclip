// GENERATED from shared/design/tokens.json - do not edit
import AppKit
import CoreText
import SwiftUI
import VoxClipCore

extension Color {
    static let vcBgWindow = Color(nsColor: NSColor(name: NSColor.Name("vcBgWindow")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 11.0 / 255, green: 12.0 / 255, blue: 15.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 240.0 / 255, green: 240.0 / 255, blue: 237.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgSurface = Color(nsColor: NSColor(name: NSColor.Name("vcBgSurface")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 18.0 / 255, green: 19.0 / 255, blue: 23.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 250.0 / 255, blue: 248.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgElevated = Color(nsColor: NSColor(name: NSColor.Name("vcBgElevated")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 29.0 / 255, green: 31.0 / 255, blue: 37.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 254.0 / 255, green: 254.0 / 255, blue: 253.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgMuted = Color(nsColor: NSColor(name: NSColor.Name("vcBgMuted")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 40.0 / 255, green: 41.0 / 255, blue: 47.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 225.0 / 255, green: 226.0 / 255, blue: 230.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgInput = Color(nsColor: NSColor(name: NSColor.Name("vcBgInput")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 21.0 / 255, green: 22.0 / 255, blue: 27.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 255.0 / 255, green: 255.0 / 255, blue: 255.0 / 255, alpha: 255.0 / 255)
    })

    static let vcLineDefault = Color(nsColor: NSColor(name: NSColor.Name("vcLineDefault")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 43.0 / 255, green: 44.0 / 255, blue: 51.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 217.0 / 255, green: 218.0 / 255, blue: 216.0 / 255, alpha: 255.0 / 255)
    })

    static let vcLineSubtle = Color(nsColor: NSColor(name: NSColor.Name("vcLineSubtle")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 36.0 / 255, green: 37.0 / 255, blue: 42.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 231.0 / 255, green: 232.0 / 255, blue: 234.0 / 255, alpha: 255.0 / 255)
    })

    static let vcLineStrong = Color(nsColor: NSColor(name: NSColor.Name("vcLineStrong")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 66.0 / 255, green: 68.0 / 255, blue: 75.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 195.0 / 255, green: 197.0 / 255, blue: 205.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextPrimary = Color(nsColor: NSColor(name: NSColor.Name("vcTextPrimary")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 240.0 / 255, blue: 231.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 19.0 / 255, green: 20.0 / 255, blue: 25.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextSecondary = Color(nsColor: NSColor(name: NSColor.Name("vcTextSecondary")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 222.0 / 255, green: 222.0 / 255, blue: 219.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 54.0 / 255, green: 56.0 / 255, blue: 64.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextMuted = Color(nsColor: NSColor(name: NSColor.Name("vcTextMuted")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 176.0 / 255, green: 179.0 / 255, blue: 189.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 81.0 / 255, green: 84.0 / 255, blue: 95.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextTertiary = Color(nsColor: NSColor(name: NSColor.Name("vcTextTertiary")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 164.0 / 255, green: 167.0 / 255, blue: 176.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 107.0 / 255, green: 111.0 / 255, blue: 128.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextDisabled = Color(nsColor: NSColor(name: NSColor.Name("vcTextDisabled")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 119.0 / 255, green: 124.0 / 255, blue: 141.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 147.0 / 255, green: 150.0 / 255, blue: 164.0 / 255, alpha: 255.0 / 255)
    })

    static let vcAccentDefault = Color(nsColor: NSColor(name: NSColor.Name("vcAccentDefault")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 236.0 / 255, green: 233.0 / 255, blue: 223.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 33.0 / 255, green: 35.0 / 255, blue: 43.0 / 255, alpha: 255.0 / 255)
    })

    static let vcAccentOn = Color(nsColor: NSColor(name: NSColor.Name("vcAccentOn")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 14.0 / 255, green: 14.0 / 255, blue: 17.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 250.0 / 255, blue: 248.0 / 255, alpha: 255.0 / 255)
    })

    static let vcSelectionText = Color(nsColor: NSColor(name: NSColor.Name("vcSelectionText")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.selectedTextBackgroundColor
            : NSColor.selectedTextBackgroundColor
    })

    static let vcWordPlayingBackground = Color(nsColor: NSColor(name: NSColor.Name("vcWordPlayingBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 240.0 / 255, blue: 231.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 33.0 / 255, green: 35.0 / 255, blue: 43.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordPlayingForeground = Color(nsColor: NSColor(name: NSColor.Name("vcWordPlayingForeground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 14.0 / 255, green: 14.0 / 255, blue: 17.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 250.0 / 255, blue: 248.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordCut = Color(nsColor: NSColor(name: NSColor.Name("vcWordCut")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 149.0 / 255, green: 153.0 / 255, blue: 166.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 110.0 / 255, green: 113.0 / 255, blue: 125.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordLowConfidence = Color(nsColor: NSColor(name: NSColor.Name("vcWordLowConfidence")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 176.0 / 255, green: 179.0 / 255, blue: 189.0 / 255, alpha: 128.0 / 255)
            : NSColor(srgbRed: 81.0 / 255, green: 84.0 / 255, blue: 95.0 / 255, alpha: 128.0 / 255)
    })

    static let vcWordCorrectionDot = Color(nsColor: NSColor(name: NSColor.Name("vcWordCorrectionDot")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 176.0 / 255, green: 179.0 / 255, blue: 189.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 81.0 / 255, green: 84.0 / 255, blue: 95.0 / 255, alpha: 255.0 / 255)
    })

    static let vcCutStroke = Color(nsColor: NSColor(name: NSColor.Name("vcCutStroke")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 143.0 / 255, blue: 131.0 / 255, alpha: 179.0 / 255)
            : NSColor(srgbRed: 196.0 / 255, green: 69.0 / 255, blue: 63.0 / 255, alpha: 217.0 / 255)
    })

    static let vcCutFill = Color(nsColor: NSColor(name: NSColor.Name("vcCutFill")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 143.0 / 255, blue: 131.0 / 255, alpha: 140.0 / 255)
            : NSColor(srgbRed: 196.0 / 255, green: 69.0 / 255, blue: 63.0 / 255, alpha: 230.0 / 255)
    })

    static let vcCutPauseFill = Color(nsColor: NSColor(name: NSColor.Name("vcCutPauseFill")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 176.0 / 255, green: 179.0 / 255, blue: 189.0 / 255, alpha: 89.0 / 255)
            : NSColor(srgbRed: 81.0 / 255, green: 84.0 / 255, blue: 95.0 / 255, alpha: 89.0 / 255)
    })

    static let vcPauseBackground = Color(nsColor: NSColor(name: NSColor.Name("vcPauseBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 44.0 / 255, green: 46.0 / 255, blue: 53.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 231.0 / 255, green: 232.0 / 255, blue: 234.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusWarning = Color(nsColor: NSColor(name: NSColor.Name("vcStatusWarning")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 242.0 / 255, green: 196.0 / 255, blue: 107.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 158.0 / 255, green: 102.0 / 255, blue: 0.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusDangerForeground = Color(nsColor: NSColor(name: NSColor.Name("vcStatusDangerForeground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 171.0 / 255, blue: 171.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 180.0 / 255, green: 35.0 / 255, blue: 42.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusDangerBackground = Color(nsColor: NSColor(name: NSColor.Name("vcStatusDangerBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 39.0 / 255, green: 27.0 / 255, blue: 32.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 252.0 / 255, green: 237.0 / 255, blue: 238.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusSuccess = Color(nsColor: NSColor(name: NSColor.Name("vcStatusSuccess")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemGreen
            : NSColor.systemGreen
    })

    static let vcRecordButton = Color(nsColor: NSColor(name: NSColor.Name("vcRecordButton")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 229.0 / 255, green: 72.0 / 255, blue: 77.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 229.0 / 255, green: 72.0 / 255, blue: 77.0 / 255, alpha: 255.0 / 255)
    })

    static let vcRecordLive = Color(nsColor: NSColor(name: NSColor.Name("vcRecordLive")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 255.0 / 255, green: 92.0 / 255, blue: 92.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 255.0 / 255, green: 92.0 / 255, blue: 92.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTimelineTrack = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineTrack")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 26.0 / 255, green: 27.0 / 255, blue: 32.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 225.0 / 255, green: 226.0 / 255, blue: 230.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTimelineKept = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineKept")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 58.0 / 255, green: 60.0 / 255, blue: 69.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 195.0 / 255, green: 197.0 / 255, blue: 205.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTimelineWaveform = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineWaveform")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 176.0 / 255, green: 179.0 / 255, blue: 189.0 / 255, alpha: 89.0 / 255)
            : NSColor(srgbRed: 81.0 / 255, green: 84.0 / 255, blue: 95.0 / 255, alpha: 89.0 / 255)
    })

    static let vcTimelineClipBracket = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineClipBracket")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 240.0 / 255, blue: 231.0 / 255, alpha: 204.0 / 255)
            : NSColor(srgbRed: 19.0 / 255, green: 20.0 / 255, blue: 25.0 / 255, alpha: 204.0 / 255)
    })

    static let vcTimelineClipBand = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineClipBand")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 236.0 / 255, green: 233.0 / 255, blue: 223.0 / 255, alpha: 31.0 / 255)
            : NSColor(srgbRed: 33.0 / 255, green: 35.0 / 255, blue: 43.0 / 255, alpha: 31.0 / 255)
    })

    static let vcTimelinePlayhead = Color(nsColor: NSColor(name: NSColor.Name("vcTimelinePlayhead")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 240.0 / 255, blue: 231.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 19.0 / 255, green: 20.0 / 255, blue: 25.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStage = Color(nsColor: NSColor(name: NSColor.Name("vcStage")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.0 / 255, green: 0.0 / 255, blue: 0.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 0.0 / 255, green: 0.0 / 255, blue: 0.0 / 255, alpha: 255.0 / 255)
    })

    static let vcOverlayScrim = Color(nsColor: NSColor(name: NSColor.Name("vcOverlayScrim")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 13.0 / 255, green: 14.0 / 255, blue: 17.0 / 255, alpha: 199.0 / 255)
            : NSColor(srgbRed: 13.0 / 255, green: 14.0 / 255, blue: 17.0 / 255, alpha: 199.0 / 255)
    })

    static let vcOverlayTransportOpaque = Color(nsColor: NSColor(name: NSColor.Name("vcOverlayTransportOpaque")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 13.0 / 255, green: 14.0 / 255, blue: 17.0 / 255, alpha: 235.0 / 255)
            : NSColor(srgbRed: 13.0 / 255, green: 14.0 / 255, blue: 17.0 / 255, alpha: 235.0 / 255)
    })

    static let vcOverlayDrop = Color(nsColor: NSColor(name: NSColor.Name("vcOverlayDrop")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 18.0 / 255, green: 19.0 / 255, blue: 23.0 / 255, alpha: 235.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 250.0 / 255, blue: 248.0 / 255, alpha: 235.0 / 255)
    })

    static let vcOverlayDropBorder = Color(nsColor: NSColor(name: NSColor.Name("vcOverlayDropBorder")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 240.0 / 255, blue: 231.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 19.0 / 255, green: 20.0 / 255, blue: 25.0 / 255, alpha: 255.0 / 255)
    })

    static let vcOverlayDropZoneBorder = Color(nsColor: NSColor(name: NSColor.Name("vcOverlayDropZoneBorder")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 243.0 / 255, green: 240.0 / 255, blue: 231.0 / 255, alpha: 102.0 / 255)
            : NSColor(srgbRed: 19.0 / 255, green: 20.0 / 255, blue: 25.0 / 255, alpha: 102.0 / 255)
    })

    static let vcFocusRing = Color(nsColor: NSColor(name: NSColor.Name("vcFocusRing")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 236.0 / 255, green: 233.0 / 255, blue: 223.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 33.0 / 255, green: 35.0 / 255, blue: 43.0 / 255, alpha: 255.0 / 255)
    })
}

enum VCTokens {
    static let spacing0: CGFloat = 0
    static let spacing1: CGFloat = 2
    static let spacing2: CGFloat = 4
    static let spacing3: CGFloat = 8
    static let spacing4: CGFloat = 12
    static let spacing5: CGFloat = 16
    static let spacing6: CGFloat = 20
    static let spacing7: CGFloat = 24
    static let spacing8: CGFloat = 32
    static let spacing9: CGFloat = 48
    static let spacingPanePaddingMacos: CGFloat = 20
    static let spacingPanePaddingWindows: CGFloat = 24
    static let spacingInspectorRowGap: CGFloat = 8
    static let spacingInspectorSectionGap: CGFloat = 20
    static let spacingTileGap: CGFloat = 8
    static let spacingClipRowPadding: CGFloat = 12
    static let spacingTranscriptParagraphGap: CGFloat = 12
    static let spacingTranscriptGutter: CGFloat = 64
    static let spacingWordHitSlopVertical: CGFloat = 2
    static let radiusXs: CGFloat = 4
    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12
    static let radiusXl: CGFloat = 16
    static let radiusFull: CGFloat = 9999
    static let strokeCutStrike: CGFloat = 1.5
    static let strokeFocusRing: CGFloat = 2
    static let strokeFocusRingOffset: CGFloat = 2
    static let strokePlayhead: CGFloat = 2
    static let strokePlayheadHead: CGFloat = 7
    static let strokeClipBracket: CGFloat = 2
    static let strokeSelectedTileBorder: CGFloat = 2
    static let strokeDropBorder: CGFloat = 2
    static let strokeHatchStripe: CGFloat = 2
    static let strokeCorrectionDot: CGFloat = 2
    static let motionDurationFast: CGFloat = 120
    static let motionDurationBase: CGFloat = 150
    static let motionDurationSlow: CGFloat = 240
    static let motionTransportFadeDelay: CGFloat = 2000
    static let motionEaseOutX1: CGFloat = 0.23
    static let motionEaseOutY1: CGFloat = 1
    static let motionEaseOutX2: CGFloat = 0.32
    static let motionEaseOutY2: CGFloat = 1
    static let motionEaseInOutX1: CGFloat = 0.77
    static let motionEaseInOutY1: CGFloat = 0
    static let motionEaseInOutX2: CGFloat = 0.175
    static let motionEaseInOutY2: CGFloat = 1
    static let motionSpringResponse: CGFloat = 0.32
    static let motionSpringDampingFraction: CGFloat = 0.82
    static let motionReduceMotion: String = "instant"
    static let sizeWindowDefaultWidth: CGFloat = 1280
    static let sizeWindowDefaultHeight: CGFloat = 800
    static let sizeWindowMinWidth: CGFloat = 960
    static let sizeWindowMinHeight: CGFloat = 600
    static let sizeTranscriptMinWidth: CGFloat = 440
    static let sizeTranscriptMeasureMax: CGFloat = 680
    static let sizePreviewColumnMin: CGFloat = 300
    static let sizePreviewColumnIdeal: CGFloat = 380
    static let sizePreviewColumnMax: CGFloat = 560
    static let sizeInspectorMin: CGFloat = 260
    static let sizeInspectorIdeal: CGFloat = 300
    static let sizeInspectorMax: CGFloat = 380
    static let sizeTimelineHeight: CGFloat = 56
    static let sizeTimelineTrackHeight: CGFloat = 24
    static let sizeFooterStatusHeightWindows: CGFloat = 32
    static let sizeTransportPillHeight: CGFloat = 36
    static let sizeCaptionTileWidth: CGFloat = 128
    static let sizeCaptionTileHeight: CGFloat = 80
    static let sizeSettingsWindowMacosWidth: CGFloat = 600
    static let sizeSettingsWindowMacosHeight: CGFloat = 480
    static let sizeSettingsWindowWindowsDefaultItem0: CGFloat = 760
    static let sizeSettingsWindowWindowsDefaultItem1: CGFloat = 600
    static let sizeSettingsWindowWindowsMinItem0: CGFloat = 560
    static let sizeSettingsWindowWindowsMinItem1: CGFloat = 480
    static let sizeOnboardingWidth: CGFloat = 560
    static let sizeOnboardingHeight: CGFloat = 480
    static let sizeWelcomeWindowWidth: CGFloat = 720
    static let sizeWelcomeWindowHeight: CGFloat = 480
    static let sizeExportSheetWidth: CGFloat = 640
    static let sizeExportSheetHeight: CGFloat = 440
    static let sizeMinHitTargetMacos: CGFloat = 22
    static let sizeMinHitTargetWindows: CGFloat = 32
    static let sizeBreakpointThreeColumn: CGFloat = 1200
    static let sizeBreakpointStack: CGFloat = 960
    static let fontDmSans: String = "DM Sans"
    static let fontGeistMono: String = "Geist Mono"
    static let typographyStatusFontFamily: String = "Geist Mono"
    static let typographyStatusFontWeight: CGFloat = 400
    static let typographyStatusFontSize: CGFloat = 10
    static let typographyStatusLineHeight: CGFloat = 14
    static let typographyStatusLetterSpacing: CGFloat = 0.65
    static let typographyStatusTextCase: String = "upper"
    static let typographyStatusFeaturesItem0: String = "tnum"
    static let typographyCaptionFontFamily: String = "system"
    static let typographyCaptionFontWeight: CGFloat = 400
    static let typographyCaptionFontSize: CGFloat = 10
    static let typographyCaptionLineHeight: CGFloat = 13
    static let typographyCaptionSystemStyle: String = "caption"
    static let typographyFootnoteFontFamily: String = "system"
    static let typographyFootnoteFontWeight: CGFloat = 400
    static let typographyFootnoteFontSize: CGFloat = 11
    static let typographyFootnoteLineHeight: CGFloat = 14
    static let typographyFootnoteSystemStyle: String = "subheadline"
    static let typographyBodyFontFamily: String = "system"
    static let typographyBodyFontWeight: CGFloat = 400
    static let typographyBodyFontSize: CGFloat = 13
    static let typographyBodyLineHeight: CGFloat = 17
    static let typographyBodySystemStyle: String = "body"
    static let typographyBodyStrongFontFamily: String = "system"
    static let typographyBodyStrongFontWeight: CGFloat = 600
    static let typographyBodyStrongFontSize: CGFloat = 13
    static let typographyBodyStrongLineHeight: CGFloat = 17
    static let typographyBodyStrongSystemStyle: String = "headline"
    static let typographySectionFontFamily: String = "system"
    static let typographySectionFontWeight: CGFloat = 600
    static let typographySectionFontSize: CGFloat = 15
    static let typographySectionLineHeight: CGFloat = 20
    static let typographySectionSystemStyle: String = "title3"
    static let typographyTitleFontFamily: String = "system"
    static let typographyTitleFontWeight: CGFloat = 600
    static let typographyTitleFontSize: CGFloat = 22
    static let typographyTitleLineHeight: CGFloat = 28
    static let typographyTitleLetterSpacing: CGFloat = -0.4
    static let typographyTitleSystemStyle: String = "title"
    static let typographyTranscriptFontFamily: String = "DM Sans"
    static let typographyTranscriptFontWeight: CGFloat = 400
    static let typographyTranscriptFontSize: CGFloat = 17
    static let typographyTranscriptLineHeight: CGFloat = 28
    static let typographyTranscriptZoomMin: CGFloat = 13
    static let typographyTranscriptZoomMax: CGFloat = 28
    static let typographyTranscriptLineHeightMultiplier: CGFloat = 1.65
    static let typographyPauseTokenFontFamily: String = "Geist Mono"
    static let typographyPauseTokenFontWeight: CGFloat = 400
    static let typographyPauseTokenFontSize: CGFloat = 11
    static let typographyPauseTokenLineHeight: CGFloat = 14
    static let typographyPauseTokenFeaturesItem0: String = "tnum"
    static let typographyTimecodeFontFamily: String = "Geist Mono"
    static let typographyTimecodeFontWeight: CGFloat = 500
    static let typographyTimecodeFontSize: CGFloat = 12
    static let typographyTimecodeLineHeight: CGFloat = 16
    static let typographyTimecodeFeaturesItem0: String = "tnum"
    static let typographyTransportFontFamily: String = "Geist Mono"
    static let typographyTransportFontWeight: CGFloat = 600
    static let typographyTransportFontSize: CGFloat = 15
    static let typographyTransportLineHeight: CGFloat = 20
    static let typographyTransportFeaturesItem0: String = "tnum"
}

extension Font {
    @MainActor static func vcDmSans(size: CGFloat, weight: Int = 400) -> Font {
        VoxClipTokenFonts.dmSans(size: size, weight: weight)
    }

    @MainActor static func vcGeistMono(size: CGFloat, weight: Int = 400) -> Font {
        VoxClipTokenFonts.geistMono(size: size, weight: weight)
    }

    @MainActor static func vcStatus(size: CGFloat = VCTokens.typographyStatusFontSize) -> Font {
        VoxClipTokenFonts.geistMono(size: size, weight: 400).monospacedDigit()
    }

    @MainActor static func vcCaption(size: CGFloat = VCTokens.typographyCaptionFontSize) -> Font {
        Font.system(size: size, weight: .regular)
    }

    @MainActor static func vcFootnote(size: CGFloat = VCTokens.typographyFootnoteFontSize) -> Font {
        Font.system(size: size, weight: .regular)
    }

    @MainActor static func vcBody(size: CGFloat = VCTokens.typographyBodyFontSize) -> Font {
        Font.system(size: size, weight: .regular)
    }

    @MainActor static func vcBodyStrong(size: CGFloat = VCTokens.typographyBodyStrongFontSize) -> Font {
        Font.system(size: size, weight: .semibold)
    }

    @MainActor static func vcSection(size: CGFloat = VCTokens.typographySectionFontSize) -> Font {
        Font.system(size: size, weight: .semibold)
    }

    @MainActor static func vcTitle(size: CGFloat = VCTokens.typographyTitleFontSize) -> Font {
        Font.system(size: size, weight: .semibold)
    }

    @MainActor static func vcTranscript(size: CGFloat = VCTokens.typographyTranscriptFontSize) -> Font {
        VoxClipTokenFonts.dmSans(size: size, weight: 400)
    }

    @MainActor static func vcPauseToken(size: CGFloat = VCTokens.typographyPauseTokenFontSize) -> Font {
        VoxClipTokenFonts.geistMono(size: size, weight: 400).monospacedDigit()
    }

    @MainActor static func vcTimecode(size: CGFloat = VCTokens.typographyTimecodeFontSize) -> Font {
        VoxClipTokenFonts.geistMono(size: size, weight: 500).monospacedDigit()
    }

    @MainActor static func vcTransport(size: CGFloat = VCTokens.typographyTransportFontSize) -> Font {
        VoxClipTokenFonts.geistMono(size: size, weight: 600).monospacedDigit()
    }
}

@MainActor private enum VoxClipTokenFonts {
    private static var descriptors: [String: CTFontDescriptor] = [:]

    private static func load(file: String?, size: CGFloat, weight: Int, monospaced: Bool) -> Font {
        let fallback = Font.system(size: size, weight: fontWeight(weight), design: monospaced ? .monospaced : .default)
        guard let file, let shared = try? SharedResources.locate() else { return fallback }
        if descriptors[file] == nil {
            let url = shared.root.appendingPathComponent("fonts", isDirectory: true).appendingPathComponent(file)
            guard let available = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = available.first else { return fallback }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            descriptors[file] = descriptor
        }
        guard let descriptor = descriptors[file] else { return fallback }
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    private static func fontWeight(_ weight: Int) -> Font.Weight {
        switch weight {
        case 100: .ultraLight
        case 200: .thin
        case 300: .light
        case 400: .regular
        case 500: .medium
        case 600: .semibold
        case 700: .bold
        case 800: .heavy
        case 900: .black
        default: .regular
        }
    }

    static func dmSans(size: CGFloat, weight: Int) -> Font {
        let files: [Int: String] = [500: "dm-sans/DMSans-Medium.ttf"]
        return load(file: files[weight], size: size, weight: weight, monospaced: false)
    }

    static func geistMono(size: CGFloat, weight: Int) -> Font {
        let files: [Int: String] = [:]
        return load(file: files[weight], size: size, weight: weight, monospaced: true)
    }
}
