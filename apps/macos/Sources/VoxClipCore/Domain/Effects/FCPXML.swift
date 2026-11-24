import Foundation

public enum FCPXML {
    private struct FrameGrid {
        let numerator: Int64
        let denominator: Int64

        init(_ rate: Double) {
            let ntsc: [Int64] = [24_000, 30_000, 60_000, 120_000]
            if let match = ntsc.first(where: { abs(Double($0) / 1001 - rate) < 0.005 }) {
                numerator = 1001; denominator = match
            } else {
                numerator = 1000; denominator = Int64((rate * 1000).rounded())
            }
        }

        func frame(_ seconds: Double) -> Int64 {
            let scaled: Double = seconds * Double(denominator)
            let frames: Double = scaled / Double(numerator)
            return Int64(frames.rounded())
        }
        func time(_ frames: Int64) -> String { FCPXML.time(frames * numerator, denominator) }
        func seconds(_ frames: Int64) -> Double { Double(frames * numerator) / Double(denominator) }
    }

    private struct Cut {
        let start: Int64
        let sourceSeconds: Double
        let output: Range<Int64>
    }

    public static func unsupportedReason(_ render: RenderRequest) -> String? {
        unsupportedReason(changesTiming: render.voiceLab?.prepared.outputPlan.requiresSyntheticRendering == true
            || (render.clipControls?.speed ?? 1) != 1, effects: render.effects?.effects ?? [])
    }

    public static func unsupportedReason(changesTiming: Bool, effects: [ClipEffect]) -> String? {
        if changesTiming {
            return "This edit changes the timing. Export it as a video instead."
        }
        if effects.contains(where: { $0.kind.isCensor }) {
            return "This edit hides part of the recording. Export it as a video to keep it hidden."
        }
        return nil
    }

    public static func document(name: String, render: RenderRequest, source: MediaProbeResult,
                                musicAudio: MediaAudio? = nil) throws -> Data {
        if let reason = unsupportedReason(render) { throw VoxClipError.exportFailed(reason) }
        guard let video = source.video, let size = source.orientedSize ?? source.video.map({ PixelSize(width: $0.width, height: $0.height) }),
              (1...1000).contains(video.frameRate), (0.01...1000).contains(render.output.fps),
              (1...1_000_000).contains(render.plan.sampleRate), (0...1_000_000).contains(source.durationSeconds) else {
            throw VoxClipError.exportFailed("The original video format is unavailable for FCPXML.")
        }
        let pictureGrid = FrameGrid(video.frameRate), grid = FrameGrid(render.output.fps)
        let cuts = try cuts(render.plan, source: pictureGrid, sequence: grid)
        guard let last = cuts.last else { throw VoxClipError.everythingCut }
        let root = element("fcpxml", ["version": "1.10"])
        let resources = append("resources", to: root)
        format("sequence-format", size: render.output.size, grid: grid, in: resources)
        format("source-format", size: size, grid: pictureGrid, in: resources)
        asset("picture", url: render.sourceURL, duration: seconds(source.durationSeconds), audio: source.audio,
              videoFormat: "source-format", in: resources)
        if let music = render.music {
            let duration = music.entry.asset.durationSeconds
            guard let musicAudio, (0.001...1_800).contains(duration), music.entry.startOffsetSeconds.isFinite else {
                throw VoxClipError.exportFailed("The background music is unavailable for FCPXML.")
            }
            asset("music-bed", url: music.assetURL, duration: seconds(duration), audio: musicAudio, in: resources)
        }
        let effects = render.effects?.effects.filter { $0.kind == .title || $0.kind == .lowerThird } ?? []
        if !effects.isEmpty || !render.captions.pages.isEmpty {
            append("effect", ["id": "basic-title", "name": "Basic Title",
                "uid": ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"], to: resources)
        }
        let project = append("project", ["name": name], to: root)
        let sequence = append("sequence", ["format": "sequence-format", "duration": grid.time(last.output.upperBound),
            "tcStart": "0s", "tcFormat": "NDF", "audioLayout": "stereo", "audioRate": "48k"], to: project)
        let spine = append("spine", to: sequence)
        var titleIndex = 0
        for cut in cuts {
            let start = pictureGrid.seconds(cut.start)
            let durationFrames = cut.output.upperBound - cut.output.lowerBound
            let duration = grid.seconds(durationFrames)
            let clip = append("asset-clip", ["name": render.sourceURL.lastPathComponent, "ref": "picture",
                "offset": grid.time(cut.output.lowerBound), "start": pictureGrid.time(cut.start),
                "duration": grid.time(durationFrames), "srcEnable": "video"], to: spine)
            append("adjust-conform", ["type": "fill"], to: clip)
            if source.audio != nil, render.clipControls?.muteSource != true {
                audio("Voice", ref: "picture", role: "dialogue", lane: "-1", offset: start,
                    start: start, duration: duration, gain: render.clipControls?.gainDb ?? 0, in: clip)
            }
            if let music = render.music {
                addMusic(music.entry, parentStart: start, outputStart: grid.seconds(cut.output.lowerBound), duration: duration, in: clip)
            }
            let outputStart = grid.seconds(cut.output.lowerBound)
            for (index, effect) in effects.enumerated() {
                guard let text = effect.text, !text.isEmpty, effect.start.isFinite, effect.end.isFinite else { continue }
                let position = position(effect.position ?? (effect.kind == .lowerThird ? .bottom : .top))
                addTitle(text, role: "title", lane: index + 2, position: position, size: 64,
                    start: outputStart + effect.start - cut.sourceSeconds, end: outputStart + effect.end - cut.sourceSeconds,
                    cut: cut, source: pictureGrid, sequence: grid, index: &titleIndex, in: clip)
            }
            for page in render.captions.pages {
                let text = page.words.map(\.text).joined(separator: " ")
                addTitle(text, role: "caption", lane: 1, position: "0 -37", size: page.fontPx,
                    start: page.start, end: page.end, cut: cut, source: pictureGrid, sequence: grid, index: &titleIndex, in: clip)
            }
        }
        let xml = XMLDocument(rootElement: root)
        let dtd = XMLDTD(); dtd.name = "fcpxml"; xml.dtd = dtd
        xml.version = "1.0"; xml.characterEncoding = "UTF-8"
        return xml.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
    }

    private static func cuts(_ plan: EditPlan, source: FrameGrid, sequence: FrameGrid) throws -> [Cut] {
        var outputSamples: Int64 = 0
        var result: [Cut] = []
        for kept in plan.kept {
            guard kept.startSample >= 0, kept.endSample >= kept.startSample, kept.endSample <= plan.totalSamples,
                  Double(kept.endSample) / plan.sampleRate <= 1_000_000 else {
                throw VoxClipError.exportFailed("The cut plan has invalid timing.")
            }
            let start = Double(kept.startSample) / plan.sampleRate
            let lower = sequence.frame(Double(outputSamples) / plan.sampleRate)
            outputSamples += kept.count
            let upper = sequence.frame(Double(outputSamples) / plan.sampleRate)
            if upper > lower { result.append(Cut(start: source.frame(start), sourceSeconds: start, output: lower..<upper)) }
        }
        return result
    }

    private static func format(_ id: String, size: PixelSize, grid: FrameGrid, in parent: XMLElement) {
        append("format", ["id": id, "width": String(size.width), "height": String(size.height),
            "frameDuration": grid.time(1)], to: parent)
    }

    private static func asset(_ id: String, url: URL, duration: String, audio: MediaAudio?, videoFormat: String? = nil, in parent: XMLElement) {
        var attrs = ["id": id, "name": url.lastPathComponent, "start": "0s", "duration": duration]
        if let videoFormat { attrs["hasVideo"] = "1"; attrs["videoSources"] = "1"; attrs["format"] = videoFormat }
        if let audio {
            attrs["hasAudio"] = "1"; attrs["audioSources"] = "1"
            attrs["audioChannels"] = String(audio.channels); attrs["audioRate"] = String(audio.sampleRate)
        }
        let asset = append("asset", attrs, to: parent)
        append("media-rep", ["kind": "original-media", "src": url.absoluteString], to: asset)
    }

    private static func audio(_ name: String, ref: String, role: String, lane: String, offset: Double,
                              start: Double, duration: Double, gain: Double, in parent: XMLElement) {
        let item = append("audio", ["name": name, "ref": ref, "role": role, "lane": lane,
            "offset": seconds(offset), "start": seconds(start), "duration": seconds(duration)], to: parent)
        if gain.isFinite, gain != 0 { append("adjust-volume", ["amount": "\(gain)dB"], to: item) }
    }

    private static func addMusic(_ entry: ProjectMusic, parentStart: Double, outputStart: Double, duration: Double, in parent: XMLElement) {
        let length = entry.asset.durationSeconds
        var start = (max(0, entry.startOffsetSeconds) + outputStart).truncatingRemainder(dividingBy: length)
        var used = 0.0
        while duration - used >= 0.000_01 {
            let take = min(duration - used, length - start)
            if take >= 0.000_01 {
                audio(entry.title, ref: "music-bed", role: "music", lane: "-2", offset: parentStart + used,
                      start: start, duration: take, gain: entry.gainDb, in: parent)
            }
            used += take; start = 0
        }
    }

    private static func addTitle(_ text: String, role: String, lane: Int, position: String, size: Double, start: Double,
                                 end: Double, cut: Cut, source: FrameGrid, sequence: FrameGrid, index: inout Int, in parent: XMLElement) {
        guard !text.isEmpty, start.isFinite, end.isFinite,
              end > sequence.seconds(cut.output.lowerBound), start < sequence.seconds(cut.output.upperBound) else { return }
        let lower = sequence.frame(max(start, sequence.seconds(cut.output.lowerBound)))
        let upper = sequence.frame(min(end, sequence.seconds(cut.output.upperBound)))
        guard upper > lower else { return }
        index += 1
        let offset = source.seconds(cut.start) + sequence.seconds(lower - cut.output.lowerBound)
        let title = append("title", ["name": role == "caption" ? "Caption" : "Title", "ref": "basic-title",
            "role": "titles.\(role)", "lane": String(lane), "offset": seconds(offset), "start": "0s",
            "duration": sequence.time(upper - lower)], to: parent)
        let styleID = "text-\(index)"
        let body = append("text", to: title)
        append("text-style", ["ref": styleID], to: body).stringValue = safeText(text)
        let style = append("text-style-def", ["id": styleID], to: title)
        append("text-style", ["fontSize": String(size.isFinite ? max(1, size) : 54), "bold": "1",
            "fontColor": "1 1 1 1", "alignment": "center", "shadowColor": "0 0 0 1"], to: style)
        append("adjust-transform", ["position": position], to: title)
    }

    private static func position(_ position: ClipEffect.Position) -> String {
        switch position {
        case .top: "0 37"
        case .center: "0 0"
        case .bottom: "0 -37"
        case .topLeft: "-25 37"
        case .topRight: "25 37"
        case .bottomLeft: "-25 -37"
        case .bottomRight: "25 -37"
        }
    }

    private static func seconds(_ value: Double) -> String { time(Int64((value * 240_000).rounded()), 240_000) }

    private static func time(_ numerator: Int64, _ denominator: Int64) -> String {
        var dividend = abs(numerator), divisor = denominator
        while divisor > 0 { (dividend, divisor) = (divisor, dividend % divisor) }
        let top = numerator / dividend, bottom = denominator / dividend
        return bottom == 1 ? "\(top)s" : "\(top)/\(bottom)s"
    }

    private static func safeText(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            switch $0.value {
            case 9, 10, 13, 32...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
            default: false
            }
        }))
    }

    private static func element(_ name: String, _ attributes: [String: String]) -> XMLElement {
        let node = XMLElement(name: name)
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            node.addAttribute(XMLNode.attribute(withName: key, stringValue: safeText(value)) as! XMLNode)
        }
        return node
    }

    @discardableResult private static func append(_ name: String, _ attributes: [String: String] = [:], to parent: XMLElement) -> XMLElement {
        let node = element(name, attributes); parent.addChild(node); return node
    }
}
