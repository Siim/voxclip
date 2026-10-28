import Foundation
import VoxClipCore
@testable import VoxClipMedia

enum CaptionMediaFixtures {
    static func shared() throws -> SharedResources {
        try .init(root: FixtureLoader.sharedRoot())
    }
    static func urls() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: shared().root.appendingPathComponent("fixtures/captions/layout"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func style(_ id: String, shared: SharedResources) throws -> CaptionStyle {
        try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.root.appendingPathComponent("caption-styles/styles/\(id).json")))
    }
    static func rect(_ rect: CaptionRect) -> [String: Any] { ["x": rect.x, "y": rect.y, "w": rect.width, "h": rect.height] }
    static func paint(_ paint: CaptionPaint, style: CaptionStyle) throws -> String {
        switch paint {
        case .linear: return "linear"
        case .solid(let token):
            let color = try CaptionColor(token, style: style)
            return String(format: "#%02X%02X%02X%02X", CaptionMath.roundHalfUp(color.red * 255), CaptionMath.roundHalfUp(color.green * 255), CaptionMath.roundHalfUp(color.blue * 255), CaptionMath.roundHalfUp(color.alpha * 255))
        }
    }
    static func runs(_ runs: [ShapedRun]) -> [[String: Any]] {
        runs.map { ["file": $0.file, "text": $0.text, "units": $0.units, "glyphs": $0.glyphs.map(\.id), "advances": $0.glyphs.map(\.advance), "offsets": $0.glyphs.map { [$0.offsetX, $0.offsetY] }, "clusters": $0.glyphs.map(\.cluster)] }
    }
    static func page(_ layout: CaptionPageLayout, track: CaptionLayoutResult) -> [String: Any] {
        let page = layout.page
        let cap = Double(track.font.capHeight) / Double(track.unitsPerEm) * page.fontPx
        let lines: [[String: Any]] = page.lines.map { ["words": $0.words, "units": $0.units, "x": $0.rect.x, "top": $0.rect.y, "baseline": $0.baseline, "width": $0.rect.width] }
        let rects: [[String: Any]] = page.wordRects.enumerated().map { local, rectangle in
            let word = layout.indices[local], lineIndex = page.lines.firstIndex { $0.words.contains(word) }!, line = page.lines[lineIndex]
            return ["word": word, "line": lineIndex, "x": rectangle.x, "y": rectangle.y, "w": rectangle.width, "h": rectangle.height, "baseline": line.baseline,
                    "cx": rectangle.x + rectangle.width / 2, "cy": line.baseline - cap / 2]
        }
        let boxes: [[String: Any]] = layout.boxes.map {
            var output = rect($0.rect); output["kind"] = $0.kind.rawValue; output["r"] = $0.radius
            if let word = $0.word { output["word"] = word }
            return output
        }
        var emphasis: [[String: Any]] = []
        for word in layout.emphasised.keys.sorted() { emphasis.append(["word": word, "paletteColor": layout.emphasised[word]!.map { $0 as Any } ?? NSNull()]) }
        var emoji: Any = NSNull()
        if let geometry = layout.emoji { emoji = ["word": geometry.word, "codepoints": geometry.codepoints, "x": geometry.rect.x, "y": geometry.rect.y, "size": geometry.rect.width] as [String: Any] }
        return ["index": page.index, "words": layout.indices, "start": page.start, "end": page.end, "fontPx64": layout.fontPx64, "fontPx": page.fontPx, "shrunk": layout.shrunk,
                "lines": lines, "wordRects": rects, "block": rect(page.block), "visual": rect(page.visual), "boxes": boxes, "emphasised": emphasis, "emoji": emoji, "clampShift": [layout.clampShift.x, layout.clampShift.y]]
    }
    static func sample(_ sample: CaptionFrameState, track: CaptionLayoutResult) throws -> [String: Any] {
        guard let page = sample.page else { return ["t": sample.time, "page": NSNull()] }
        var words: [[String: Any]] = []
        for word in sample.words {
            var output: [String: Any] = ["word": word.word, "state": word.state, "visible": word.visible, "opacity": word.opacity, "scale": word.scale, "dy": word.dy,
                "fill": try paint(word.fill, style: track.style), "fillSource": word.fillSource]
            if word.boxContrast { output["boxContrast"] = true }
            if word.wipeFromBoxContrast { output["wipeFromBoxContrast"] = true }
            if let wipe = word.wipe { output["wipe"] = wipe; output["wipeFrom"] = try paint(word.wipeFrom!, style: track.style) }
            if let visible = word.visibleClusters { output["visibleClusters"] = visible }
            words.append(output)
        }
        var cursor: Any = NSNull()
        if let value = sample.cursor { var data = rect(value.rect); data["visible"] = value.visible; data["word"] = value.word; cursor = data }
        return ["t": sample.time, "page": page, "activeWord": sample.activeWord!, "progress": sample.progress, "pageAlpha": sample.motion.alpha, "pageScale": sample.motion.scale,
                "pageDy": sample.motion.dy, "jitter": [sample.jitter.x, sample.jitter.y], "words": words, "cursor": cursor]
    }
    static func project(_ track: CaptionLayoutResult, samples: [[String: Any]]) throws -> [String: Any] {
        let style = track.style
        let portrait = track.aspect == "portrait"
        let words: [[String: Any]] = track.words.map {
            var output: [String: Any] = ["sourceIndex": $0.sourceIndex, "id": $0.input.id, "raw": $0.raw, "text": $0.shaped.word.text, "start": $0.input.start, "end": $0.input.end,
                "units": $0.shaped.units, "clusters": $0.shaped.clusters, "runs": runs($0.shaped.runs), "emphasisPoints": $0.emphasisPoints, "emphasisCandidate": $0.emphasisCandidate]
            if let emphasis = $0.emphasisShaped { output["emphasisUnits"] = emphasis.units; output["emphasisRuns"] = runs(emphasis.runs) }
            if !$0.shaped.droppedClusters.isEmpty { output["droppedClusters"] = $0.shaped.droppedClusters }
            return output
        }
        let resolved: [String: Any] = ["sizeSh": style.font.sizeSh, "sizeScale": style.font.sizeScale, "x": style.position.x, "y": style.position.y, "anchorX": style.position.anchorX.rawValue,
            "anchorY": style.position.anchorY.rawValue, "maxLineWidthW": style.layout.maxLineWidthW, "maxWords": style.layout.maxWords, "transform": style.text.transform.rawValue,
            "punctuation": style.text.punctuation.rawValue, "accent": style.accent.map { $0 as Any } ?? NSNull()]
        return ["aspect": track.aspect, "preset": track.preset.map { $0 as Any } ?? NSNull(), "resolved": resolved, "fontPx64": track.fontPx64, "fontPx": Double(track.fontPx64) / 64,
            "safeRect": rect(track.safeRect), "safeInsets": ["left": portrait ? 0.06 : 0.05, "right": portrait ? 0.06 : 0.05, "top": portrait ? 0.06 : 0.05, "bottom": portrait ? 0.10 : 0.07],
            "limitPx": track.limitPx, "limitPx64": track.limitPx64, "unitsPerEm": track.unitsPerEm, "gapUnits": track.gapUnits, "words": words,
            "dropped": track.dropped.map { ["sourceIndex": $0.sourceIndex, "text": $0.text, "reason": $0.reason] as [String: Any] },
            "pages": track.pages.map { page($0, track: track) }, "samples": try samples.map { try sample(CaptionTimeline.evaluate(track, time: $0["t"] as! Double), track: track) }]
    }

    static func differences(_ actual: Any, _ expected: Any, path: String = "") -> [String] {
        if let expected = expected as? [String: Any], let actual = actual as? [String: Any] {
            return expected.keys.sorted().filter { $0 != "golden" }.flatMap { key -> [String] in
                guard let value = actual[key] else { return [path + "." + key + " missing"] }
                return differences(value, expected[key]!, path: path + "." + key)
            }
        }
        if let expected = expected as? [Any], let actual = actual as? [Any] {
            guard actual.count == expected.count else { return ["\(path) count \(actual.count) != \(expected.count)"] }
            return expected.indices.flatMap { differences(actual[$0], expected[$0], path: "\(path)[\($0)]") }
        }
        if let expected = expected as? NSNumber, let actual = actual as? NSNumber {
            let exact: Set<String> = ["units", "glyphs", "advances", "offsets", "clusters", "fontPx64", "limitPx64", "gapUnits", "emphasisUnits", "emphasisPoints", "activeWord", "visibleClusters", "words", "sourceIndex", "word", "line", "page", "index", "size"]
            let lastComponent: Substring = path.split(separator: ".").last ?? ""
            let field: String = String(lastComponent.split(separator: "[").first ?? "")
            let fractions: Set<String> = ["sizeSh", "sizeScale", "x", "y", "maxLineWidthW"]
            let pixels: Set<String> = ["x", "y", "w", "h", "r", "top", "baseline", "width", "height", "cx", "cy", "fontPx", "pageDy", "dy", "jitter", "clampShift"]
            let tolerance: Double
            if path.hasPrefix(".resolved."), fractions.contains(field) { tolerance = 1e-9 }
            else if exact.contains(field) { tolerance = 0 }
            else if field == "limitPx" { tolerance = 0.000_500_001 }
            else if ["start", "end", "left", "right", "bottom"].contains(field) || path.hasPrefix(".safeInsets.") { tolerance = 1e-9 }
            else if ["progress", "pageAlpha", "pageScale", "opacity", "scale", "wipe"].contains(field) { tolerance = 2e-6 }
            else if pixels.contains(field), !path.hasPrefix(".resolved.") { tolerance = 0.5 }
            else { tolerance = 0 }
            return abs(actual.doubleValue - expected.doubleValue) <= tolerance ? [] : ["\(path) \(actual) != \(expected)"]
        }
        return String(describing: actual) == String(describing: expected) ? [] : ["\(path) \(actual) != \(expected)"]
    }
}
