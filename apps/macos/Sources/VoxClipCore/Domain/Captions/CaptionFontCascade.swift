import Foundation

public struct CaptionFontRun: Sendable {
    public var file: String
    public var text: String
    public var clusters: [Int]
}

public enum CaptionFontCascade {
    public static func resolve(_ request: GlyphShapeRequest, resources: CaptionResources) throws -> (runs: [CaptionFontRun], dropped: [String], clusters: Int) {
        let primary = try resources.font(request.fontFile)
        let fallbackWeight = [400, 600, 700, 900].sorted {
            abs($0 - primary.weight) == abs($1 - primary.weight) ? $0 > $1 : abs($0 - primary.weight) < abs($1 - primary.weight)
        }[0]
        let fallback = [400: "NotoSans-Regular.ttf", 600: "NotoSans-SemiBold.ttf", 700: "NotoSans-Bold.ttf", 900: "NotoSans-Black.ttf"][fallbackWeight]!
        let cascade = try ([request.fontFile] + request.fallbackFiles + [fallback]).map { try resources.font($0) }
        var runs: [CaptionFontRun] = [], dropped: [String] = []
        var clusterIndex = 0
        func ignorable(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 0x200C || scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) }
        for cluster in request.text {
            let scalars = Array(cluster.unicodeScalars), core = scalars.filter { !ignorable($0) }
            guard let first = core.first,
                  let chosen = cascade.first(where: { font in core.allSatisfy(font.covers) }) ?? cascade.first(where: { $0.covers(first) }) else {
                dropped.append(String(cluster)); continue
            }
            let kept = scalars.filter { ignorable($0) || chosen.covers($0) }
            let text = String(String.UnicodeScalarView(kept))
            if runs.last?.file == chosen.file {
                runs[runs.count - 1].text += text
                runs[runs.count - 1].clusters += Array(repeating: clusterIndex, count: kept.count)
            } else { runs.append(.init(file: chosen.file, text: text, clusters: Array(repeating: clusterIndex, count: kept.count))) }
            clusterIndex += 1
        }
        return (runs, dropped, clusterIndex)
    }
}
