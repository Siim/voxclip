import Foundation

public enum CaptionSubtitles {
    public static func srt(_ track: CaptionLayoutResult) -> String {
        var cues: [String] = []
        for layout in track.pages where layout.page.end > layout.page.start {
            let text = layout.page.lines.map { line in
                line.words.map { CaptionTextRules.raw(track.words[$0].input.text) }.joined(separator: " ")
            }.joined(separator: "\n")
            cues.append("\(cues.count + 1)\n\(timestamp(layout.page.start)) --> \(timestamp(layout.page.end))\n\(text)\n")
        }
        return cues.isEmpty ? "" : cues.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = CaptionMath.roundHalfUp(seconds * 1000)
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000,
                      milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
