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
        let picture: String
        let source: Range<Double>
        let output: Range<Int64>
        let retimed: Bool
        let edited: Range<Double>
        let speed: Double
    }

    public struct PictureSpan: Sendable {
        public let assetID: String
        public let source: Range<Double>
        public let edited: Range<Double>

        public init(assetID: String = "picture", source: Range<Double>, edited: Range<Double>) {
            self.assetID = assetID; self.source = source; self.edited = edited
        }
    }

    public struct Media: Sendable {
        public let url: URL
        public let probe: MediaProbeResult
        public init(url: URL, probe: MediaProbeResult) { self.url = url; self.probe = probe }
    }

    public static func pictureID(for recording: RenderRecording) -> String {
        recording.region.prefix.isEmpty ? "picture" : "picture-\(recording.region.prefix.dropLast())"
    }

    public static func unsupportedReason(effects: [ClipEffect]) -> String? {
        if effects.contains(where: { $0.kind.isCensor }) {
            return "This edit hides part of the recording. Export it as a video to keep it hidden."
        }
        if effects.contains(where: { $0.kind == .freeze }) {
            return "This edit holds a picture still. Use video export to keep the freeze frame."
        }
        if effects.contains(where: { ![.title, .lowerThird, .speedForPart].contains($0.kind) ||
            $0.fadeInSeconds != nil || $0.fadeOutSeconds != nil }) {
            return "This edit has effects an editable timeline can't carry. Use video export to keep them."
        }
        return nil
    }

    public static func unsupportedReason(_ render: RenderRequest) -> String? {
        if let reason = unsupportedReason(effects: render.effects?.effects ?? []) { return reason }
        if !render.footage.isEmpty || render.contextDemo != nil {
            return "This edit uses additional footage. Use video export to keep its placement."
        }
        return nil
    }

    public static func document(name: String, render: RenderRequest, source: MediaProbeResult,
                                musicAudio: MediaAudio? = nil, renderedVoice: Media? = nil,
                                pictureSpans: [PictureSpan]? = nil, replacementPictures: [String: Media] = [:]) throws -> Data {
        if let reason = unsupportedReason(render) { throw VoxClipError.exportFailed(reason) }
        guard (0.01...1000).contains(render.output.fps),
              (1...1_000_000).contains(render.plan.sampleRate), (0...1_000_000).contains(source.durationSeconds) else {
            throw VoxClipError.exportFailed("The original video format is unavailable for FCPXML.")
        }
        let synthetic = render.voiceLab?.prepared.outputPlan.requiresSyntheticRendering == true
        guard !synthetic || (pictureSpans != nil && renderedVoice?.probe.audio != nil) else {
            throw VoxClipError.exportFailed("The rendered voice is unavailable for the editable timeline.")
        }
        let grid = FrameGrid(render.output.fps)
        let timing = render.speedTiming
        let root = element("fcpxml", ["version": "1.10"])
        let resources = append("resources", to: root)
        format("sequence-format", size: render.output.size, grid: grid, in: resources)
        let recordings = Dictionary(uniqueKeysWithValues: render.recordings.map { (pictureID(for: $0), $0.region) })
        var pictures = replacementPictures
        if recordings.isEmpty || recordings["picture"] != nil { pictures["picture"] = Media(url: render.sourceURL, probe: source) }
        var pictureGrids: [String: FrameGrid] = [:]
        for (id, media) in pictures.sorted(by: { $0.key < $1.key }) {
            guard let video = media.probe.video, (1...1000).contains(video.frameRate),
                  (0...1_000_000).contains(media.probe.durationSeconds) else {
                throw VoxClipError.exportFailed("A picture source is unavailable for the editable timeline.")
            }
            let pictureGrid = FrameGrid(video.frameRate)
            pictureGrids[id] = pictureGrid
            let formatID = "\(id)-format"
            format(formatID, size: media.probe.orientedSize ?? PixelSize(width: video.width, height: video.height), grid: pictureGrid, in: resources)
            asset(id, url: media.url, duration: seconds(media.probe.durationSeconds),
                  audio: recordings[id] != nil ? media.probe.audio : id == "picture" ? source.audio : nil,
                  videoFormat: formatID, in: resources)
        }
        let spans = try pictureSpans ?? legacySpans(render)
        let cuts = try cuts(spans, timing: timing, pictures: pictures, grids: pictureGrids, sequence: grid)
        guard let last = cuts.last else { throw VoxClipError.everythingCut }
        if let renderedVoice {
            guard let voiceAudio = renderedVoice.probe.audio, (0.001...1_000_000).contains(renderedVoice.probe.durationSeconds),
                  renderedVoice.probe.durationSeconds + grid.seconds(1) >= last.edited.upperBound else {
                throw VoxClipError.exportFailed("The rendered voice does not cover the editable timeline.")
            }
            asset("rendered-voice", url: renderedVoice.url, duration: seconds(renderedVoice.probe.durationSeconds), audio: voiceAudio, in: resources)
        }
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
        let musicRate = 48_000.0
        let musicFrames = Int((grid.seconds(last.output.upperBound) * musicRate).rounded())
        let musicPlacements = render.music.flatMap { music in
            music.entry.segments.map { segments in
                MusicMix.segmentPieces(segments, trackFrames: Int((music.entry.asset.durationSeconds * musicRate).rounded()),
                                       outputFrames: musicFrames, rate: musicRate) {
                    timing.rendered(render.timeline.mapTime($0))
                }
            }
        }
        var titleIndex = 0
        for cut in cuts {
            guard let picture = pictures[cut.picture] else { throw VoxClipError.exportFailed("A picture source is missing.") }
            let durationFrames = cut.output.upperBound - cut.output.lowerBound
            let duration = grid.seconds(durationFrames)
            let wrapped = cut.retimed
            let parent = wrapped ? append("gap", ["offset": grid.time(cut.output.lowerBound), "start": "0s",
                "duration": grid.time(durationFrames)], to: spine) : spine
            let part = render.plan.partSeams.prefix { Double($0) / render.plan.sampleRate <= cut.edited.lowerBound + 0.000_001 }.count + 1
            let label = recordings[cut.picture].map { "\($0.label) · part \(part)" } ?? picture.url.lastPathComponent
            var attributes = ["name": label, "ref": cut.picture,
                "offset": wrapped ? "0s" : grid.time(cut.output.lowerBound), "start": seconds(cut.source.lowerBound),
                "duration": grid.time(durationFrames), "srcEnable": "video"]
            if wrapped { attributes["lane"] = "1" }
            let videoClip = append("asset-clip", attributes, to: parent)
            if cut.retimed { timeMap(cut.source, duration: duration, in: videoClip) }
            append("adjust-conform", ["type": "fill"], to: videoClip)
            let clip = wrapped ? parent : videoClip
            let start = wrapped ? 0 : cut.source.lowerBound
            if render.clipControls?.muteSource != true {
                if let renderedVoice {
                    let available = min(duration, (renderedVoice.probe.durationSeconds - cut.edited.lowerBound) / cut.speed)
                    if available > 0 {
                        audio("Rendered voice", ref: "rendered-voice", role: "dialogue", lane: "-1", offset: start,
                              start: cut.edited.lowerBound, duration: available, gain: render.clipControls?.gainDb ?? 0,
                              mapping: cut.speed == 1 ? nil : cut.edited, in: clip)
                    }
                } else if picture.probe.audio != nil {
                    audio("Voice", ref: cut.picture, role: "dialogue", lane: "-1", offset: start,
                          start: cut.source.lowerBound, duration: duration,
                          gain: (render.clipControls?.gainDb ?? 0) + (recordings[cut.picture]?.gainDb ?? 0),
                          mapping: cut.retimed ? cut.source : nil, in: clip)
                }
            }
            if let music = render.music {
                let outputStart = grid.seconds(cut.output.lowerBound)
                if let musicPlacements {
                    addMusicSegments(music.entry, placements: musicPlacements, rate: musicRate, parentStart: start,
                                     cut: outputStart..<grid.seconds(cut.output.upperBound),
                                     end: grid.seconds(last.output.upperBound), in: clip)
                } else {
                    addMusic(music.entry, parentStart: start, outputStart: outputStart, duration: duration, in: clip)
                }
            }
            for (index, effect) in effects.enumerated() {
                guard let text = effect.text, !text.isEmpty, effect.start.isFinite, effect.end.isFinite else { continue }
                let position = position(effect.position ?? (effect.kind == .lowerThird ? .bottom : .top))
                addTitle(text, role: "title", lane: index + 3, position: position, size: 64,
                    start: timing.rendered(render.timeline.mapTime(effect.start)), end: timing.rendered(render.timeline.mapEndTime(effect.end)),
                    cut: cut, parentStart: start, sequence: grid, index: &titleIndex, in: clip)
            }
            for page in render.captions.pages {
                let text = page.words.map(\.text).joined(separator: " ")
                addTitle(text, role: "caption", lane: wrapped ? 2 : 1, position: "0 -37", size: page.fontPx,
                    start: timing.rendered(page.start), end: timing.rendered(page.end), cut: cut, parentStart: start,
                    sequence: grid, index: &titleIndex, in: clip)
            }
        }
        let xml = XMLDocument(rootElement: root)
        let dtd = XMLDTD(); dtd.name = "fcpxml"; xml.dtd = dtd
        xml.version = "1.0"; xml.characterEncoding = "UTF-8"
        return xml.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
    }

    private static func legacySpans(_ render: RenderRequest) throws -> [PictureSpan] {
        let plan = render.plan
        let recordings = Dictionary(uniqueKeysWithValues: render.recordings.map { ($0.key, $0) })
        guard recordings.isEmpty || render.spanSources.count == plan.kept.count else {
            throw VoxClipError.exportFailed("The picture cuts have invalid recordings.")
        }
        var outputSamples: Int64 = 0
        return try plan.kept.enumerated().compactMap { index, kept in
            guard kept.startSample >= 0, kept.endSample >= kept.startSample, kept.endSample <= plan.totalSamples,
                  Double(kept.endSample) / plan.sampleRate <= 1_000_000 else {
                throw VoxClipError.exportFailed("The cut plan has invalid timing.")
            }
            guard kept.count > 0 else { return nil }
            let lower = Double(outputSamples) / plan.sampleRate
            outputSamples += kept.count
            let recording = recordings.isEmpty ? nil : recordings[render.spanSources[index]]
            let offset = Int64(recording?.region.offsetSamples ?? 0)
            return PictureSpan(assetID: recording.map(pictureID(for:)) ?? "picture",
                               source: (Double(kept.startSample - offset) / plan.sampleRate)..<(Double(kept.endSample - offset) / plan.sampleRate),
                               edited: lower..<(Double(outputSamples) / plan.sampleRate))
        }
    }

    private static func cuts(_ spans: [PictureSpan], timing: ClipSpeedTiming, pictures: [String: Media],
                             grids: [String: FrameGrid], sequence: FrameGrid) throws -> [Cut] {
        var result: [Cut] = []
        let speed = timing.segments(through: spans.last?.edited.upperBound ?? 0)
        var previous = 0.0
        for span in spans {
            guard let grid = grids[span.assetID], let media = pictures[span.assetID],
                  (0...media.probe.durationSeconds + grid.seconds(1)).contains(span.source.upperBound),
                  span.source.lowerBound >= 0, !span.source.isEmpty, !span.edited.isEmpty,
                  abs(span.edited.lowerBound - previous) < 0.000_001, (0...1_000_000).contains(span.edited.upperBound) else {
                throw VoxClipError.exportFailed("The picture cuts have invalid timing.")
            }
            previous = span.edited.upperBound
            let sourceRate = (span.source.upperBound - span.source.lowerBound) / (span.edited.upperBound - span.edited.lowerBound)
            func sourceTime(_ time: Double) -> Double { span.source.lowerBound + (time - span.edited.lowerBound) * sourceRate }
            for segment in speed where segment.end > span.edited.lowerBound && segment.start < span.edited.upperBound {
                let lower = max(segment.start, span.edited.lowerBound), upper = min(segment.end, span.edited.upperBound)
                let startFrame = sequence.frame(timing.rendered(lower)), endFrame = sequence.frame(timing.rendered(upper))
                guard endFrame > startFrame else { continue }
                let sourceStart = grid.seconds(grid.frame(sourceTime(lower)))
                let sourceEnd = grid.seconds(grid.frame(sourceTime(upper)))
                let retimed = abs(sourceRate * segment.rate - 1) > 0.000_001
                guard !retimed || sourceEnd > sourceStart else {
                    throw VoxClipError.exportFailed("A speed change is shorter than a source frame. Use video export to keep it.")
                }
                result.append(Cut(picture: span.assetID, source: sourceStart..<max(sourceStart, sourceEnd),
                                  output: startFrame..<endFrame, retimed: retimed, edited: lower..<upper, speed: segment.rate))
            }
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
                              start: Double, duration: Double, gain: Double, mapping: Range<Double>? = nil, in parent: XMLElement) {
        let item = append("audio", ["name": name, "ref": ref, "role": role, "lane": lane,
            "offset": seconds(offset), "start": seconds(start), "duration": seconds(duration)], to: parent)
        if let mapping { timeMap(mapping, duration: duration, in: item) }
        if gain.isFinite, gain != 0 { append("adjust-volume", ["amount": "\(gain)dB"], to: item) }
    }

    private static func timeMap(_ source: Range<Double>, duration: Double, in parent: XMLElement) {
        let map = append("timeMap", ["preservesPitch": "1"], to: parent)
        append("timept", ["time": seconds(source.lowerBound), "value": seconds(source.lowerBound), "interp": "linear"], to: map)
        append("timept", ["time": seconds(source.lowerBound + duration), "value": seconds(source.upperBound), "interp": "linear"], to: map)
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

    private static func addMusicSegments(_ entry: ProjectMusic, placements: [MusicMix.SegmentPlacement], rate: Double,
                                         parentStart: Double, cut: Range<Double>, end: Double, in parent: XMLElement) {
        for placement in placements {
            let span = placement.span, segment = placement.segment
            for piece in placement.pieces {
                let start = Double(span.outputStart + piece.outputStart) / rate
                guard cut.contains(start) else { continue }
                let count = min(piece.count, span.count - piece.outputStart, Int(((end - start) * rate).rounded()))
                guard count > 0 else { continue }
                let source = Double(piece.sourceStart) / rate
                let item = append("asset-clip", ["name": entry.title, "ref": "music-bed", "audioRole": "music", "lane": "-2",
                    "offset": seconds(parentStart + (start - cut.lowerBound)), "start": seconds(source),
                    "duration": seconds(Double(count) / rate), "srcEnable": "audio"], to: parent)
                let base = entry.gainDb + segment.gainDb
                let points = segment.gainPoints ?? []
                let animated = !points.isEmpty || segment.fadeInSeconds > 0 || segment.fadeOutSeconds > 0 ||
                    [span.fadeIn, span.fadeOut, piece.fadeIn, piece.fadeOut].contains(where: { $0 > 0 })
                guard animated else {
                    if base != 0 { append("adjust-volume", ["amount": volume(base)], to: item) }
                    continue
                }
                let adjust = append("adjust-volume", to: item)
                let param = append("param", ["name": "amount"], to: adjust)
                let animation = append("keyframeAnimation", to: param)
                let localStart = piece.outputStart, localEnd = localStart + count
                var frames: Set<Int> = [localStart, localEnd]
                for point in points where point.t <= Double(localEnd) / rate {
                    frames.insert(Int((point.t * rate).rounded()))
                }
                let length = Int((min(segment.lengthSeconds, Double(localEnd) / rate + 10) * rate).rounded())
                let fades = [(0, Int((segment.fadeInSeconds * rate).rounded())),
                    (length - Int((segment.fadeOutSeconds * rate).rounded()), length),
                    (0, span.fadeIn), (span.count - span.fadeOut, span.count),
                    (localStart, localStart + piece.fadeIn), (localStart + piece.count - piece.fadeOut, localStart + piece.count)]
                for (first, last) in fades where first < last {
                    let lower = max(first, localStart), upper = min(last, localEnd)
                    if lower <= upper {
                        frames.formUnion(stride(from: lower, through: upper, by: Int(rate / 20)))
                        frames.insert(upper)
                    }
                }
                for frame in frames.sorted() where frame >= localStart && frame <= localEnd {
                    let localTime = Double(frame) / rate
                    let fade = MusicMix.fadeFactor(at: localTime, duration: segment.lengthSeconds,
                                                   fadeIn: segment.fadeInSeconds, fadeOut: segment.fadeOutSeconds)
                    let weight = fade * MusicMix.pieceWeight(span, at: frame) * MusicMix.pieceWeight(piece, at: frame - localStart)
                    let db = base + MusicMix.envelopeDb(at: localTime, points: points) + 20 * log10(max(1e-6, weight))
                    let time = source + Double(frame - localStart) / rate
                    append("keyframe", ["time": seconds(time), "value": volume(max(-96, db)), "interp": "linear", "curve": "linear"], to: animation)
                }
            }
        }
    }

    private static func volume(_ db: Double) -> String {
        let rounded = (db * 1_000).rounded() / 1_000
        return rounded == rounded.rounded() ? "\(Int(rounded))dB" : "\(rounded)dB"
    }

    private static func addTitle(_ text: String, role: String, lane: Int, position: String, size: Double, start: Double,
                                 end: Double, cut: Cut, parentStart: Double, sequence: FrameGrid, index: inout Int, in parent: XMLElement) {
        guard !text.isEmpty, start.isFinite, end.isFinite,
              end > sequence.seconds(cut.output.lowerBound), start < sequence.seconds(cut.output.upperBound) else { return }
        let lower = sequence.frame(max(start, sequence.seconds(cut.output.lowerBound)))
        let upper = sequence.frame(min(end, sequence.seconds(cut.output.upperBound)))
        guard upper > lower else { return }
        index += 1
        let offset = parentStart + sequence.seconds(lower - cut.output.lowerBound)
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
