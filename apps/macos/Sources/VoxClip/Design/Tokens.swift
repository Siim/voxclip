// GENERATED from shared/design/tokens.json - do not edit
import AppKit
import CoreText
import SwiftUI
import VoxClipCore

extension Color {
    static let vcBgWindow = Color(nsColor: NSColor(name: NSColor.Name("vcBgWindow")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 20.0 / 255, green: 21.0 / 255, blue: 23.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 240.0 / 255, green: 239.0 / 255, blue: 234.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgSurface = Color(nsColor: NSColor(name: NSColor.Name("vcBgSurface")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 27.0 / 255, green: 28.0 / 255, blue: 31.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 249.0 / 255, blue: 246.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgSunken = Color(nsColor: NSColor(name: NSColor.Name("vcBgSunken")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 20.0 / 255, green: 21.0 / 255, blue: 23.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 240.0 / 255, green: 239.0 / 255, blue: 234.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgElevated = Color(nsColor: NSColor(name: NSColor.Name("vcBgElevated")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 37.0 / 255, green: 38.0 / 255, blue: 42.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 254.0 / 255, green: 253.0 / 255, blue: 251.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgMuted = Color(nsColor: NSColor(name: NSColor.Name("vcBgMuted")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 42.0 / 255, green: 43.0 / 255, blue: 47.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 236.0 / 255, green: 234.0 / 255, blue: 228.0 / 255, alpha: 255.0 / 255)
    })

    static let vcBgInput = Color(nsColor: NSColor(name: NSColor.Name("vcBgInput")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 37.0 / 255, green: 38.0 / 255, blue: 42.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 254.0 / 255, green: 253.0 / 255, blue: 251.0 / 255, alpha: 255.0 / 255)
    })

    static let vcLineDefault = Color(nsColor: NSColor(name: NSColor.Name("vcLineDefault")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 46.0 / 255, green: 47.0 / 255, blue: 51.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 227.0 / 255, green: 225.0 / 255, blue: 219.0 / 255, alpha: 255.0 / 255)
    })

    static let vcLineStrong = Color(nsColor: NSColor(name: NSColor.Name("vcLineStrong")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 108.0 / 255, green: 110.0 / 255, blue: 117.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 133.0 / 255, green: 135.0 / 255, blue: 142.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextPrimary = Color(nsColor: NSColor(name: NSColor.Name("vcTextPrimary")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 236.0 / 255, green: 234.0 / 255, blue: 228.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 26.0 / 255, green: 27.0 / 255, blue: 31.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextSecondary = Color(nsColor: NSColor(name: NSColor.Name("vcTextSecondary")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 168.0 / 255, green: 170.0 / 255, blue: 176.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 87.0 / 255, green: 90.0 / 255, blue: 97.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextMuted = Color(nsColor: NSColor(name: NSColor.Name("vcTextMuted")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 176.0 / 255, green: 178.0 / 255, blue: 184.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 85.0 / 255, green: 88.0 / 255, blue: 95.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextTertiary = Color(nsColor: NSColor(name: NSColor.Name("vcTextTertiary")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 143.0 / 255, green: 145.0 / 255, blue: 152.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 102.0 / 255, green: 105.0 / 255, blue: 111.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTextDisabled = Color(nsColor: NSColor(name: NSColor.Name("vcTextDisabled")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 119.0 / 255, green: 124.0 / 255, blue: 141.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 147.0 / 255, green: 150.0 / 255, blue: 164.0 / 255, alpha: 255.0 / 255)
    })

    static let vcAccentDefault = Color(nsColor: NSColor(name: NSColor.Name("vcAccentDefault")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 35.0 / 255, green: 125.0 / 255, blue: 122.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 28.0 / 255, green: 107.0 / 255, blue: 105.0 / 255, alpha: 255.0 / 255)
    })

    static let vcAccentPressed = Color(nsColor: NSColor(name: NSColor.Name("vcAccentPressed")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 28.0 / 255, green: 103.0 / 255, blue: 100.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 21.0 / 255, green: 87.0 / 255, blue: 85.0 / 255, alpha: 255.0 / 255)
    })

    static let vcAccentText = Color(nsColor: NSColor(name: NSColor.Name("vcAccentText")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 99.0 / 255, green: 189.0 / 255, blue: 182.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 28.0 / 255, green: 107.0 / 255, blue: 105.0 / 255, alpha: 255.0 / 255)
    })

    static let vcAccentOn = Color(nsColor: NSColor(name: NSColor.Name("vcAccentOn")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 250.0 / 255, green: 249.0 / 255, blue: 246.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 249.0 / 255, blue: 246.0 / 255, alpha: 255.0 / 255)
    })

    static let vcAccentSoft = Color(nsColor: NSColor(name: NSColor.Name("vcAccentSoft")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 31.0 / 255, green: 63.0 / 255, blue: 61.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 211.0 / 255, green: 230.0 / 255, blue: 227.0 / 255, alpha: 255.0 / 255)
    })

    static let vcSelectionText = Color(nsColor: NSColor(name: NSColor.Name("vcSelectionText")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.selectedTextBackgroundColor
            : NSColor.selectedTextBackgroundColor
    })

    static let vcSelectionTranscript = Color(nsColor: NSColor(name: NSColor.Name("vcSelectionTranscript")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 31.0 / 255, green: 76.0 / 255, blue: 75.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 197.0 / 255, green: 215.0 / 255, blue: 212.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordPlayingBackground = Color(nsColor: NSColor(name: NSColor.Name("vcWordPlayingBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 35.0 / 255, green: 125.0 / 255, blue: 122.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 28.0 / 255, green: 107.0 / 255, blue: 105.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordPlayingForeground = Color(nsColor: NSColor(name: NSColor.Name("vcWordPlayingForeground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 250.0 / 255, green: 249.0 / 255, blue: 246.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 249.0 / 255, blue: 246.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordCut = Color(nsColor: NSColor(name: NSColor.Name("vcWordCut")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 147.0 / 255, green: 149.0 / 255, blue: 156.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 102.0 / 255, green: 104.0 / 255, blue: 111.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordFiller = Color(nsColor: NSColor(name: NSColor.Name("vcWordFiller")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 224.0 / 255, green: 174.0 / 255, blue: 85.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 154.0 / 255, green: 91.0 / 255, blue: 0.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordLowConfidence = Color(nsColor: NSColor(name: NSColor.Name("vcWordLowConfidence")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 124.0 / 255, green: 126.0 / 255, blue: 133.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 126.0 / 255, green: 128.0 / 255, blue: 135.0 / 255, alpha: 255.0 / 255)
    })

    static let vcWordCorrectionDot = Color(nsColor: NSColor(name: NSColor.Name("vcWordCorrectionDot")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 143.0 / 255, green: 145.0 / 255, blue: 152.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 102.0 / 255, green: 105.0 / 255, blue: 111.0 / 255, alpha: 255.0 / 255)
    })

    static let vcCutStroke = Color(nsColor: NSColor(name: NSColor.Name("vcCutStroke")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 238.0 / 255, green: 127.0 / 255, blue: 110.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 194.0 / 255, green: 64.0 / 255, blue: 47.0 / 255, alpha: 255.0 / 255)
    })

    static let vcCutFill = Color(nsColor: NSColor(name: NSColor.Name("vcCutFill")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 238.0 / 255, green: 127.0 / 255, blue: 110.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 194.0 / 255, green: 64.0 / 255, blue: 47.0 / 255, alpha: 255.0 / 255)
    })

    static let vcCutPauseFill = Color(nsColor: NSColor(name: NSColor.Name("vcCutPauseFill")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 132.0 / 255, green: 135.0 / 255, blue: 142.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 111.0 / 255, green: 114.0 / 255, blue: 120.0 / 255, alpha: 255.0 / 255)
    })

    static let vcPauseBackground = Color(nsColor: NSColor(name: NSColor.Name("vcPauseBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 42.0 / 255, green: 43.0 / 255, blue: 47.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 236.0 / 255, green: 234.0 / 255, blue: 228.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusWarning = Color(nsColor: NSColor(name: NSColor.Name("vcStatusWarning")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 227.0 / 255, green: 178.0 / 255, blue: 92.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 138.0 / 255, green: 82.0 / 255, blue: 0.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusWarningBackground = Color(nsColor: NSColor(name: NSColor.Name("vcStatusWarningBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 45.0 / 255, green: 38.0 / 255, blue: 22.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 240.0 / 255, blue: 220.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusDangerForeground = Color(nsColor: NSColor(name: NSColor.Name("vcStatusDangerForeground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 242.0 / 255, green: 161.0 / 255, blue: 150.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 179.0 / 255, green: 38.0 / 255, blue: 30.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusDangerBackground = Color(nsColor: NSColor(name: NSColor.Name("vcStatusDangerBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 51.0 / 255, green: 32.0 / 255, blue: 29.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 251.0 / 255, green: 236.0 / 255, blue: 233.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusSuccess = Color(nsColor: NSColor(name: NSColor.Name("vcStatusSuccess")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 124.0 / 255, green: 203.0 / 255, blue: 147.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 30.0 / 255, green: 110.0 / 255, blue: 58.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusSuccessBackground = Color(nsColor: NSColor(name: NSColor.Name("vcStatusSuccessBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 27.0 / 255, green: 42.0 / 255, blue: 32.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 231.0 / 255, green: 242.0 / 255, blue: 233.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStatusInfoBackground = Color(nsColor: NSColor(name: NSColor.Name("vcStatusInfoBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 35.0 / 255, green: 36.0 / 255, blue: 40.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 240.0 / 255, green: 239.0 / 255, blue: 234.0 / 255, alpha: 255.0 / 255)
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

    static let vcClipBadgeBackground = Color(nsColor: NSColor(name: NSColor.Name("vcClipBadgeBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 236.0 / 255, green: 234.0 / 255, blue: 228.0 / 255, alpha: 26.0 / 255)
            : NSColor(srgbRed: 26.0 / 255, green: 27.0 / 255, blue: 31.0 / 255, alpha: 23.0 / 255)
    })

    static let vcTimelineTrack = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineTrack")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 38.0 / 255, green: 39.0 / 255, blue: 43.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 228.0 / 255, green: 226.0 / 255, blue: 220.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTimelineKept = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineKept")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 122.0 / 255, green: 125.0 / 255, blue: 133.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 116.0 / 255, green: 119.0 / 255, blue: 126.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTimelineKeptBackground = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineKeptBackground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 236.0 / 255, green: 234.0 / 255, blue: 228.0 / 255, alpha: 23.0 / 255)
            : NSColor(srgbRed: 26.0 / 255, green: 27.0 / 255, blue: 31.0 / 255, alpha: 18.0 / 255)
    })

    static let vcTimelineWaveform = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineWaveform")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 236.0 / 255, green: 234.0 / 255, blue: 228.0 / 255, alpha: 148.0 / 255)
            : NSColor(srgbRed: 26.0 / 255, green: 27.0 / 255, blue: 31.0 / 255, alpha: 133.0 / 255)
    })

    static let vcTimelineScopeDim = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineScopeDim")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 20.0 / 255, green: 21.0 / 255, blue: 23.0 / 255, alpha: 158.0 / 255)
            : NSColor(srgbRed: 240.0 / 255, green: 239.0 / 255, blue: 234.0 / 255, alpha: 168.0 / 255)
    })

    static let vcTimelineClipBracket = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineClipBracket")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 99.0 / 255, green: 189.0 / 255, blue: 182.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 28.0 / 255, green: 107.0 / 255, blue: 105.0 / 255, alpha: 255.0 / 255)
    })

    static let vcTimelineClipBand = Color(nsColor: NSColor(name: NSColor.Name("vcTimelineClipBand")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 35.0 / 255, green: 125.0 / 255, blue: 122.0 / 255, alpha: 31.0 / 255)
            : NSColor(srgbRed: 28.0 / 255, green: 107.0 / 255, blue: 105.0 / 255, alpha: 31.0 / 255)
    })

    static let vcTimelinePlayhead = Color(nsColor: NSColor(name: NSColor.Name("vcTimelinePlayhead")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 99.0 / 255, green: 189.0 / 255, blue: 182.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 28.0 / 255, green: 107.0 / 255, blue: 105.0 / 255, alpha: 255.0 / 255)
    })

    static let vcStage = Color(nsColor: NSColor(name: NSColor.Name("vcStage")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.0 / 255, green: 0.0 / 255, blue: 0.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 0.0 / 255, green: 0.0 / 255, blue: 0.0 / 255, alpha: 255.0 / 255)
    })

    static let vcOverlayForeground = Color(nsColor: NSColor(name: NSColor.Name("vcOverlayForeground")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 245.0 / 255, green: 244.0 / 255, blue: 240.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 245.0 / 255, green: 244.0 / 255, blue: 240.0 / 255, alpha: 255.0 / 255)
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
            ? NSColor(srgbRed: 27.0 / 255, green: 28.0 / 255, blue: 31.0 / 255, alpha: 235.0 / 255)
            : NSColor(srgbRed: 250.0 / 255, green: 249.0 / 255, blue: 246.0 / 255, alpha: 235.0 / 255)
    })

    static let vcOverlayDropBorder = Color(nsColor: NSColor(name: NSColor.Name("vcOverlayDropBorder")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 99.0 / 255, green: 189.0 / 255, blue: 182.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 28.0 / 255, green: 107.0 / 255, blue: 105.0 / 255, alpha: 255.0 / 255)
    })

    static let vcOverlayDropZoneBorder = Color(nsColor: NSColor(name: NSColor.Name("vcOverlayDropZoneBorder")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 236.0 / 255, green: 234.0 / 255, blue: 228.0 / 255, alpha: 102.0 / 255)
            : NSColor(srgbRed: 26.0 / 255, green: 27.0 / 255, blue: 31.0 / 255, alpha: 102.0 / 255)
    })

    static let vcFocusRing = Color(nsColor: NSColor(name: NSColor.Name("vcFocusRing")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 99.0 / 255, green: 189.0 / 255, blue: 182.0 / 255, alpha: 255.0 / 255)
            : NSColor(srgbRed: 28.0 / 255, green: 107.0 / 255, blue: 105.0 / 255, alpha: 255.0 / 255)
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
    static let spacingPanePaddingMacos: CGFloat = 16
    static let spacingPanePaddingWindows: CGFloat = 16
    static let spacingInspectorRowGap: CGFloat = 8
    static let spacingInspectorSectionGap: CGFloat = 20
    static let spacingTileGap: CGFloat = 8
    static let spacingClipRowPadding: CGFloat = 12
    static let spacingTranscriptParagraphGap: CGFloat = 18
    static let spacingTranscriptGutter: CGFloat = 84
    static let spacingWordHitSlopVertical: CGFloat = 2
    static let radiusXs: CGFloat = 4
    static let radiusControl: CGFloat = 6
    static let radiusPane: CGFloat = 10
    static let radiusSheet: CGFloat = 14
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
    static let sizeSidebarMin: CGFloat = 220
    static let sizeSidebarIdeal: CGFloat = 252
    static let sizeSidebarMax: CGFloat = 320
    static let sizeRightColumnMin: CGFloat = 300
    static let sizeRightColumnIdeal: CGFloat = 360
    static let sizeRightColumnMax: CGFloat = 560
    static let sizeStagePortraitMaxWidth: CGFloat = 180
    static let sizeStagePortraitMaxHeight: CGFloat = 320
    static let sizeInspectorMin: CGFloat = 260
    static let sizeInspectorIdeal: CGFloat = 300
    static let sizeInspectorMax: CGFloat = 380
    static let sizeTimelineHeight: CGFloat = 72
    static let sizeTimelineTrackHeight: CGFloat = 30
    static let sizeSelectionBarHeight: CGFloat = 36
    static let sizeFooterStatusHeightWindows: CGFloat = 32
    static let sizeTransportPillHeight: CGFloat = 36
    static let sizeCaptionTileAspect: CGFloat = 0.45
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
    static let typographyStatusFontFamily: String = "SF Mono"
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
    static let typographyTranscriptFontFamily: String = "system"
    static let typographyTranscriptFontWeight: CGFloat = 400
    static let typographyTranscriptFontSize: CGFloat = 19
    static let typographyTranscriptLineHeight: CGFloat = 32
    static let typographyTranscriptZoomMin: CGFloat = 13
    static let typographyTranscriptZoomMax: CGFloat = 28
    static let typographyTranscriptLineHeightMultiplier: CGFloat = 1.6842
    static let typographyPauseTokenFontFamily: String = "SF Mono"
    static let typographyPauseTokenFontWeight: CGFloat = 400
    static let typographyPauseTokenFontSize: CGFloat = 11
    static let typographyPauseTokenLineHeight: CGFloat = 14
    static let typographyPauseTokenFeaturesItem0: String = "tnum"
    static let typographyTimecodeFontFamily: String = "SF Mono"
    static let typographyTimecodeFontWeight: CGFloat = 500
    static let typographyTimecodeFontSize: CGFloat = 12
    static let typographyTimecodeLineHeight: CGFloat = 16
    static let typographyTimecodeFeaturesItem0: String = "tnum"
    static let typographyTransportFontFamily: String = "SF Mono"
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
        Font.system(size: size, weight: .regular, design: .monospaced).monospacedDigit()
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
        Font.system(size: size, weight: .regular)
    }

    @MainActor static func vcPauseToken(size: CGFloat = VCTokens.typographyPauseTokenFontSize) -> Font {
        Font.system(size: size, weight: .regular, design: .monospaced).monospacedDigit()
    }

    @MainActor static func vcTimecode(size: CGFloat = VCTokens.typographyTimecodeFontSize) -> Font {
        Font.system(size: size, weight: .medium, design: .monospaced).monospacedDigit()
    }

    @MainActor static func vcTransport(size: CGFloat = VCTokens.typographyTransportFontSize) -> Font {
        Font.system(size: size, weight: .semibold, design: .monospaced).monospacedDigit()
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
