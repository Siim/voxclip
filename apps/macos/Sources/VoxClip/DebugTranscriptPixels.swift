#if DEBUG
import AppKit
import VoxClipCore

@MainActor enum DebugTranscriptPixels {
    struct Probe: Codable {
        let name: String
        let row: Double
        let width: Double
        let matchingColumns: Int
    }
    static func run(app: AppModel, fixture: Project, directory: URL) throws -> [DebugUISuite.Result] {
        var project = fixture
        project.transcript?.words = [
            TimedWord(id: "pixel-cut", text: "stricken", start: 0, end: 0.4),
            TimedWord(id: "pixel-filler", text: "um", start: 0.5, end: 0.8),
            TimedWord(id: "pixel-low", text: "uncertain", start: 0.9, end: 1.2, conf: 0.2),
            TimedWord(id: "pixel-playing", text: "playing", start: 1.3, end: 1.6),
            TimedWord(id: "pixel-next", text: "next", start: 3.2, end: 3.5)
        ]
        project.edits = ProjectEdits(cutWordIds: ["pixel-cut"])
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.textSize = DesignValues.transcriptTextSize; model.mediaResolved = true; model.refresh()
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let scroll = TranscriptTextView.makeScrollView(model: model, coordinator: coordinator, width: 640, height: 160)
        guard let text = scroll.documentView as? TranscriptNSTextView else { throw CocoaError(.coderInvalidValue) }
        text.isSelectable = false; text.drawsBackground = true
        let renderer = coordinator.renderer
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        renderer.rebuild(model: model)
        let revision = renderer.storageRevision
        renderer.update(TranscriptAppearance(cutWords: ["pixel-cut"], fillers: ["pixel-filler"], playing: "pixel-playing", lowConfidence: true))
        guard let manager = text.textLayoutManager else { throw CocoaError(.coderInvalidValue) }
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        guard let fragment = manager.textLayoutFragment(for: manager.documentRange.location), let line = fragment.textLineFragments.first else { throw CocoaError(.coderInvalidValue) }
        let font = DesignValues.transcriptFont(size: model.textSize)
        let baseline = text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        var results: [DebugUISuite.Result] = try wordAccessibility(app: app)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let background = DesignValues.nsColor("word.playingBackground")
                let foreground = DesignValues.nsColor("word.playingForeground")
                let contrast = DesignValues.contrast(foreground, background)
                results.append(.init(name: "\(name) playing-word label contrast \(contrast):1", passed: contrast >= 4.5))
            }
        }
        let storedFont = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let style = text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        results.append(.init(name: "transcript uses the system font at 15 pt (notes.md §2)", passed: storedFont?.familyName == NSFont.systemFont(ofSize: 15).familyName && storedFont?.pointSize == 15))
        results.append(.init(name: "transcript lines are 26 high with a 14 paragraph gap (notes.md §2 and §4)", passed: style?.minimumLineHeight == 26 && style?.maximumLineHeight == 26 && style?.paragraphSpacing == 14 && abs(line.typographicBounds.height - 26) < 0.5))
        var probes: [Probe] = []
        for mode: NSAppearance.Name in [.aqua, .darkAqua] {
            let name = mode == .aqua ? "light" : "dark"
            let appearance = NSAppearance(named: mode)!
            window.appearance = appearance
            var captured: NSBitmapImageRep?
            appearance.performAsCurrentDrawingAppearance {
                text.backgroundColor = DesignValues.nsColor("bg.window")
                text.needsDisplay = true
                if let bitmap = text.bitmapImageRepForCachingDisplay(in: text.bounds) { text.cacheDisplay(in: text.bounds, to: bitmap); captured = bitmap }
            }
            guard let bitmap = captured, let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw CocoaError(.fileWriteUnknown) }
            try jpeg.write(to: directory.appendingPathComponent("transcript-decorations-\(name).jpg"))
            appearance.performAsCurrentDrawingAppearance {
                for (id, token, strike) in [("pixel-cut", "cut.stroke", true), ("pixel-filler", "word.filler", false), ("pixel-low", "word.lowConfidence", false)] {
                    guard let span = text.map.span(id: id) else { results.append(.init(name: "\(name) \(id) pixels", passed: false)); continue }
                    let lower = line.locationForCharacter(at: span.range.location).x + text.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
                    let upper = line.locationForCharacter(at: NSMaxRange(span.range)).x + text.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
                    let row = strike ? baseline - font.xHeight / 2 : baseline - font.underlinePosition + 1
                    let count = matchingColumns(bitmap, lower: lower, upper: upper, row: row, size: text.bounds.size, color: DesignValues.nsColor(token), background: text.backgroundColor)
                    probes.append(Probe(name: "\(name)-\(id)", row: row, width: upper - lower, matchingColumns: count))
                    let minimum = strike ? (upper - lower) * 0.45 : (upper - lower) * 0.15
                    results.append(.init(name: "\(name) \(id) decoration pixels at the expected row", passed: Double(count) >= minimum))
                }
            }
        }
        results.append(.init(name: "transcript decorations never relayout storage", passed: renderer.storageRevision == revision))
        var pageProject = model.project
        let unclipped = text.string
        pageProject.edits.clips = [ClipRange(id: "pixel-clip", startWordId: "pixel-low", endWordId: "pixel-playing", title: "Pixel clip")]
        model.document.replaceProject(pageProject)
        model.refresh()
        renderer.rebuild(model: model)
        var pageState = TranscriptAppearance(cutWords: model.cutWordIDs, scope: 0...0)
        renderer.update(pageState)
        results.append(.init(name: "a clip adds no characters or markers to the transcript, so its paragraphs never reflow per clip", passed:
            text.string == unclipped && text.map.spans.allSatisfy(\.selectable) && renderer.clipMarks["pixel-clip"] != nil))
        let whole = NSRange(location: 0, length: text.string.utf16.count)
        let spokenValue = text.accessibilityValue()
        let spokenText = text.accessibilityAttributedString(for: whole)
        results.append(.init(name: "VoiceOver reads the transcript's words without timecodes and keeps its length", passed:
            spokenValue == text.string && spokenText?.length == whole.length && spokenValue?.contains("0:0") == false))
        if let cut = text.map.span(id: "pixel-cut") {
            let states = spokenText?.attribute(.accessibilityCustomText, at: cut.range.location, effectiveRange: nil) as? [String]
            results.append(.init(name: "a cut word reads with its state alone and carries it as a text attribute within a line", passed:
                text.accessibilityAttributedString(for: cut.range)?.string == text.accessibilityString(for: cut.range) && text.accessibilityString(for: cut.range)?.contains(", cut") == true && states?.first == "cut"))
        }
        if let pause = model.pauses.first {
            let uncut = renderer.attributes[pause.id]?[.vcRounded] == nil
            pageProject.edits.cutPauseIds = [pause.id]
            model.document.replaceProject(pageProject)
            model.refresh()
            pageState.cutPauses = [pause.id]
            renderer.update(pageState)
            results.append(.init(name: "only a cut pause has the radius-6 chip", passed: uncut && renderer.attributes[pause.id]?[.vcRounded] is NSColor && renderer.attributes[pause.id]?[.vcRadius] as? Double == 6))
            results.append(.init(name: "the pause's accessible description includes duration and cut", passed: text.map.span(id: pause.id).flatMap { text.accessibilityString(for: $0.range) }?.hasSuffix(", cut") == true))
        }
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        for (name, mode) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: mode)!
            window.appearance = appearance
            for pauseCut in [true, false] {
            appearance.performAsCurrentDrawingAppearance {
                pageState.cutPauses = pauseCut ? Set(model.pauses.map(\.id)) : []
                renderer.update(pageState)
                text.backgroundColor = DesignValues.nsColor("bg.surface")
                text.needsDisplay = true
                guard let cached = text.bitmapImageRepForCachingDisplay(in: text.bounds) else { return }
                text.cacheDisplay(in: text.bounds, to: cached)
                guard let image = cached.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let converted = context.makeImage() else { return }
                let bitmap = NSBitmapImageRep(cgImage: converted)
                @MainActor func rect(_ id: String) -> CGRect {
                    guard let span = text.map.span(id: id), let content = manager.textContentManager,
                          let location = content.location(content.documentRange.location, offsetBy: span.range.location),
                          let fragment = manager.textLayoutFragment(for: location), let element = fragment.textElement?.elementRange else { return .zero }
                    let offset = content.offset(from: content.documentRange.location, to: element.location)
                    guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(span.range.location - offset, $0.characterRange) }) else { return .zero }
                    let start = line.locationForCharacter(at: span.range.location - offset)
                    let end = line.locationForCharacter(at: NSMaxRange(span.range) - offset)
                    return CGRect(x: text.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + min(start.x, end.x),
                                  y: text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
                                  width: max(1, abs(end.x - start.x)), height: line.typographicBounds.height)
                }
                let scopedPixels = opaquePixels(bitmap, rect: rect("pixel-low"), size: text.bounds.size, color: DesignValues.nsColor("word.outside"))
                let strikePixels = opaquePixels(bitmap, rect: rect("pixel-cut"), size: text.bounds.size, color: DesignValues.nsColor("cut.stroke"))
                if let pause = model.pauses.first {
                    let pausePixels = opaquePixels(bitmap, rect: rect(pause.id), size: text.bounds.size, color: DesignValues.nsColor("pause.background"), patch: 3)
                    results.append(.init(name: "\(name) \(pauseCut ? "cut" : "uncut") pause bitmap \(pauseCut ? "paints" : "has no") chip fill (\(pausePixels) pixels)", passed: pauseCut ? pausePixels >= 8 : pausePixels == 0))
                }
                results.append(.init(name: "\(name) out-of-clip glyphs paint opaque word.outside (\(scopedPixels) pixels)", passed: scopedPixels >= 3))
                results.append(.init(name: "\(name) cut strike matches cut.stroke within three channels (\(strikePixels) pixels)", passed: strikePixels >= 3))
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent("transcript-page-\(name)-\(pauseCut ? "cut" : "uncut")-pause.png")) }
            }
            }
        }
        try JSONEncoder().encode(probes).write(to: directory.appendingPathComponent("transcript-decoration-pixels.json"))
        results += try gutter(app: app, fixture: fixture, directory: directory)
        return results
    }
    static func wordAccessibility(app: AppModel) throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw CocoaError(.fileNoSuchFile) }
        let fixture = root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")
        let project = try JSONProjectStore.decode(Data(contentsOf: fixture))
        let plan = try VoiceLabOutputPlanner.build(project, scope: .full)
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.refresh()
        guard let piece = plan.pieces.first(where: { (piece: VoiceLabOutputPiece) -> Bool in piece.kind == .synth }) else { throw CocoaError(.coderInvalidValue) }
        let start: Double = Double(piece.sourceStartSample) / plan.sampleRate
        let end: Double = Double(piece.sourceEndSample) / plan.sampleRate
        guard let word = model.words.first(where: { (word: TimedWord) -> Bool in word.start >= start && word.end <= end }) else { throw CocoaError(.coderInvalidValue) }
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.model = model
        let renderer = TranscriptRenderer()
        renderer.text = text
        var results: [DebugUISuite.Result] = []
        for cut in [false, true] {
            for playing in [false, true] {
                for ai in [false, true] {
                    var state = project
                    for index in state.voiceLab.segments.indices { state.voiceLab.segments[index].enabled = ai }
                    model.replace(state, name: "Accessibility state")
                    model.showCuts = true
                    model.cutWordIDs = cut ? [word.id] : []
                    model.sourceTime = playing ? word.start : model.sourceDuration
                    model.voiceLabPlan = ai ? plan : nil
                    renderer.rebuild(model: model)
                    guard let span = text.map.span(id: word.id) else { throw CocoaError(.coderInvalidValue) }
                    let base = (text.string as NSString).substring(with: span.range)
                    let expected: String = (ai ? "new words" : base) + (cut && !ai ? ", cut" : "") + (playing ? ", playing" : "") + (ai ? ", AI modified" : "")
                    results.append(.init(name: "VoiceOver word states use cut, playing, AI modified order (cut=\(cut), playing=\(playing), AI=\(ai))", passed: text.accessibilityString(for: span.range) == expected))
                    results.append(.init(name: "VoiceOver attributed word reading matches (cut=\(cut), playing=\(playing), AI=\(ai))", passed: text.accessibilityAttributedString(for: span.range)?.string == expected))
                }
            }
        }
        return results
    }
    private static func opaquePixels(_ bitmap: NSBitmapImageRep, rect: CGRect, size: NSSize, color: NSColor, patch: Int = 1) -> Int {
        guard let foreground = color.usingColorSpace(.sRGB), let background = DesignValues.nsColor("bg.surface").usingColorSpace(.sRGB), rect.width > 0, rect.height > 0 else { return 0 }
        let alpha = foreground.alphaComponent
        let target = NSColor(srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
                             green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
                             blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
        let scale = Double(bitmap.pixelsWide) / size.width
        let scaledMinX: Double = rect.minX * scale
        let scaledMaxX: Double = rect.maxX * scale
        let scaledMinY: Double = rect.minY * scale
        let scaledMaxY: Double = rect.maxY * scale
        let lowerX: Int = max(0, Int(scaledMinX))
        let upperX: Int = min(bitmap.pixelsWide, Int(scaledMaxX))
        let lowerY: Int = max(0, Int(scaledMinY))
        let upperY: Int = min(bitmap.pixelsHigh, Int(scaledMaxY))
        guard lowerX < upperX, lowerY < upperY else { return 0 }
        var count = 0
        let tolerance = 3.0 / 255.0
        let radius: Int = patch / 2
        func matches(_ column: Int, _ row: Int) -> Bool {
            guard column >= lowerX, column < upperX, row >= lowerY, row < upperY,
                  let pixel = bitmap.colorAt(x: column, y: row) else { return false }
            return abs(pixel.redComponent - target.redComponent) <= tolerance && abs(pixel.greenComponent - target.greenComponent) <= tolerance && abs(pixel.blueComponent - target.blueComponent) <= tolerance
        }
        for row in lowerY..<upperY {
            for column in lowerX..<upperX {
                let filled: Bool = (-radius...radius).allSatisfy { (vertical: Int) -> Bool in
                    (-radius...radius).allSatisfy { (horizontal: Int) -> Bool in matches(column + horizontal, row + vertical) }
                }
                if filled { count += 1 }
            }
        }
        return count
    }
    private static func matchingColumns(_ bitmap: NSBitmapImageRep, lower: Double, upper: Double, row: Double, size: NSSize, color: NSColor, background: NSColor) -> Int {
        guard let color = color.usingColorSpace(.deviceRGB), let background = background.usingColorSpace(.deviceRGB) else { return 0 }
        let alpha = color.alphaComponent
        let paper = [background.redComponent, background.greenComponent, background.blueComponent]
        let ink = [color.redComponent, color.greenComponent, color.blueComponent]
        let direction = zip(ink, paper).map { ($0 - $1) * alpha }
        let magnitude = direction.reduce(0) { $0 + $1 * $1 }
        guard magnitude > 0 else { return 0 }
        let scale = Double(bitmap.pixelsWide) / size.width
        let columns = max(0, Int(lower * scale))..<min(bitmap.pixelsWide, Int(upper * scale))
        let rows = max(0, Int((row - 1.5) * scale))...min(bitmap.pixelsHigh - 1, Int((row + 1.5) * scale))
        return columns.filter { column in
            rows.contains { row in
                guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { return false }
                let components = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                let difference = zip(components, paper).map(-)
                let coverage = zip(difference, direction).reduce(0) { $0 + $1.0 * $1.1 } / magnitude
                guard coverage >= 0.25, coverage <= 1.15 else { return false }
                return zip(difference, direction).allSatisfy { abs($0 - $1 * coverage) < 0.08 }
            }
        }.count
    }
}

/// V6 on the five-questions take in a 652 × 488 transcript, the buffer of notes.md §1:
/// paragraphs, the gutter, the band, the range bar, out-of-clip text, the overview ruler and
/// the Clips rotor. Writes `v2-transcript-*-dark.png` beside the results.
extension DebugTranscriptPixels {
    static func gutter(app: AppModel, fixture: Project, directory: URL) throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let model = EditorModel(document: VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: fixture), demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.textSize = DesignValues.transcriptTextSize; model.mediaResolved = true; model.refresh()
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let text = pane.text, renderer = pane.renderer, words = model.words
        func clip(_ id: String) throws -> ClipRange { guard let clip = model.project.edits.clips.first(where: { $0.id == id }) else { throw CocoaError(.coderInvalidValue) }; return clip }
        func first(of clip: ClipRange) -> Int { text.map.span(id: clip.startWordId)?.range.location ?? 0 }
        func last(of clip: ClipRange) -> Int { text.map.span(id: clip.endWordId).map { NSMaxRange($0.range) - 1 } ?? 0 }

        let split = TranscriptParagraphs.split(words: words)
        check("the transcript shows TranscriptParagraphs' \(split.count) paragraphs, one text paragraph each (\(renderer.paragraphs.map(\.firstWord)))",
              renderer.paragraphs.map(\.firstWord) == split.map(\.lowerBound) && text.string.split(separator: "\n", omittingEmptySubsequences: false).count == split.count)
        let origin = text.textContainerOrigin
        check("text starts at the gutter's edge, x 80, and the measure leaves 44 at the right (\(origin.x), container \(text.textContainer?.size.width ?? 0))",
              origin.x == 80 && text.textContainer?.lineFragmentPadding == 0 && text.textContainer?.size.width == 652 - 80 - 44)

        // Clip 2 is the whole fifth paragraph; the playhead sits in the sixth, outside it.
        let muted = try clip("five-2")
        model.activate(muted)
        model.sourceTime = words[split[5].lowerBound + 3].start
        pane.update()
        pane.scroll(toCharacter: renderer.paragraphs[3].offset)
        guard let top = text.lineBox(atCharacter: first(of: muted)), let bottom = text.lineBox(atCharacter: last(of: muted)), let band = text.backdrop?.band else {
            check("the open clip shows a band", false); return results
        }
        check("the band runs from 8 pt above the clip's first line to 8 pt below its last (\(band.top)...\(band.bottom); lines \(top.minY)...\(bottom.maxY))",
              abs(band.top - (top.minY - 8)) < 0.5 && abs(band.bottom - (bottom.maxY + 8)) < 0.5 && text.backdrop?.isHidden == false)
        check("the range bar runs from 3 pt below the first line's top to 3 pt above the last line's bottom, solid for a kept clip",
              band.barTop.map { abs($0 - (top.minY + 3)) < 0.5 } == true && band.barBottom.map { abs($0 - (bottom.maxY - 3)) < 0.5 } == true && !band.suggested)
        var bitmap = try pane.bitmap("v2-transcript-clip-dark", directory: directory)
        let surface = TranscriptPane.color("bg.surface"), bandColor = TranscriptPane.color("editor.band"), clipColor = TranscriptPane.color("clip.label")
        check("the band paints editor.band in the gutter and the right padding, and only between its edges",
              pane.matches(bitmap, CGPoint(x: 72, y: band.top + 2), bandColor) && pane.matches(bitmap, CGPoint(x: 630, y: (top.midY + bottom.midY) / 2), bandColor)
              && pane.matches(bitmap, CGPoint(x: 72, y: band.bottom - 2), bandColor) && pane.matches(bitmap, CGPoint(x: 72, y: band.top - 2), surface)
              && pane.matches(bitmap, CGPoint(x: 72, y: band.bottom + 2), surface))
        let barRows = stride(from: top.minY + 4, through: bottom.maxY - 4, by: 1).map { pane.matches(bitmap, CGPoint(x: 9, y: $0), clipColor) }
        check("a kept clip's range bar is a solid 2 pt clip.label line at x 8 (\(barRows.filter { $0 }.count) of \(barRows.count) rows)",
              barRows.allSatisfy { $0 } && !pane.matches(bitmap, CGPoint(x: 11.5, y: top.midY), clipColor) && !pane.matches(bitmap, CGPoint(x: 6.5, y: top.midY), clipColor))

        // Gutter timecodes: out of the clip, in it, and the playhead's paragraph.
        func timecodeBox(_ paragraph: Int) -> CGRect? {
            text.lineBox(atCharacter: renderer.paragraphs[paragraph].offset).map { CGRect(x: 0, y: $0.minY, width: 48, height: $0.height) }
        }
        let gutterIn = TranscriptPane.color("gutter.text"), gutterOut = TranscriptPane.color("gutter.textOut"), current = TranscriptPane.color("text.secondary")
        if let outside = timecodeBox(3), let inside = timecodeBox(4), let playing = timecodeBox(5) {
            let counts = (pane.count(bitmap, in: outside, gutterOut), pane.count(bitmap, in: inside, gutterIn), pane.count(bitmap, in: playing, current))
            check("gutter timecodes paint gutter.textOut outside the clip, gutter.text in it and text.secondary for the playhead's paragraph (\(counts))",
                  counts.0 >= 2 && counts.1 >= 2 && counts.2 >= 2 && pane.count(bitmap, in: outside, gutterIn) < counts.0 && pane.count(bitmap, in: inside, gutterOut) < counts.1)
            let right = pane.inkExtent(bitmap, in: inside, background: bandColor).map(\.upperBound) ?? 0
            check("timecodes are right-aligned at x 42 in the gutter (right edge \(right))", right > 39.5 && right <= 42.5)
            check("each timecode reads the paragraph's take time as m:ss (\(TranscriptGutter.timecode(renderer.paragraphs[4].start)))",
                  TranscriptGutter.timecode(renderer.paragraphs[4].start) == TranscriptGutter.timecode(words[split[4].lowerBound].start) && TranscriptGutter.timecode(65.9) == "1:05" && TranscriptGutter.timecode(3_725) == "62:05")
            let textLine = CGRect(x: 72, y: inside.minY, width: 40, height: inside.height)
            let left = pane.inkExtent(bitmap, in: textLine, background: bandColor).map(\.lowerBound) ?? 0
            check("the clip's first words start at x 80 (left edge \(left))", left >= 79.5 && left <= 82)
        } else { check("gutter timecodes are laid out", false) }
        let outsideWord = words[split[3].lowerBound + 1].id, insideWord = words[split[4].lowerBound + 1].id
        check("words outside the clip are word.outside and words in it word.text",
              renderer.attributes[outsideWord]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.outside")
              && renderer.attributes[insideWord]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.text"))

        // The overview ruler: a sibling of the scroller at the right edge, marks by take time.
        let duration = TranscriptOverviewRuler.duration(model)
        let ruler = pane.scroll.overviewRuler
        let clipMark = ruler.marks.first { $0.kind == .clip }
        check("the overview ruler is 10 wide, 2 from the right edge, and marks the open clip by take time (\(ruler.frame))",
              ruler.frame.width == 10 && abs(ruler.frame.maxX - (pane.scroll.bounds.maxX - 2)) < 0.5 && ruler.frame.height == pane.scroll.bounds.height
              && clipMark.map { abs($0.lower - words[split[4].lowerBound].start / duration) < 1e-9 && abs($0.upper - words[split[4].upperBound - 1].end / duration) < 1e-9 } == true)
        if let span = ruler.visibleSpan, let mark = clipMark {
            check("the ruler's visible window covers the take time of the visible lines (\(span), clip \(mark.lower)...\(mark.upper))", span.lowerBound < mark.lower && span.upperBound > mark.upper)
        } else { check("the ruler shows the visible window", false) }
        let rows = TranscriptOverviewRuler.rows(ruler.marks, kind: .clip, height: ruler.bounds.height)
        if let row = rows.first {
            let mark = CGRect(x: 1, y: row.lowerBound + 0.5, width: 2, height: max(1, row.upperBound - row.lowerBound - 1))
            let inked = pane.count(bitmap, in: ruler.convert(mark, to: text), where: { !TranscriptPane.close($0, surface, 0.02) && !TranscriptPane.close($0, bandColor, 0.02) })
            check("the ruler paints the clip mark at its rows (\(inked) pixels)", inked >= 4)
        } else { check("the ruler has a clip mark", false) }

        // A suggested clip that starts inside the last paragraph: the band starts at its line and the bar is dashed.
        let suggested = try clip("five-5")
        model.activate(suggested)
        pane.update()
        pane.scroll(toCharacter: renderer.paragraphs[5].offset)
        if let suggestedTop = text.lineBox(atCharacter: first(of: suggested)), let paragraphTop = text.lineBox(atCharacter: renderer.paragraphs[6].offset), let band = text.backdrop?.band {
            bitmap = try pane.bitmap("v2-transcript-suggested-dark", directory: directory)
            let dashed = TranscriptPane.composite(clipColor, alpha: 0.85, over: bandColor)
            let samples = stride(from: suggestedTop.minY + 4, through: (band.barBottom ?? suggestedTop.maxY) - 4, by: 1).map { pane.matches(bitmap, CGPoint(x: 9, y: $0), dashed, tolerance: 0.03) }
            let runs = zip(samples, samples.dropFirst()).filter { $0 != $1 }.count
            check("a suggested clip's bar is dashed (\(runs) dash edges)", band.suggested && runs >= 4 && samples.contains(true))
            check("a clip that starts inside a paragraph starts its band at the line holding its first word (\(band.top), line \(suggestedTop.minY), paragraph \(paragraphTop.minY))",
                  abs(band.top - (suggestedTop.minY - 8)) < 0.5 && suggestedTop.minY > paragraphTop.minY)
            let before = words[split[6].lowerBound].id
            check("the same paragraph's words before the clip stay word.outside", renderer.attributes[before]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.outside"))
        } else { check("a suggested clip shows a band", false) }

        // Full Take: no band, no bar, every paragraph's timecode is in the scope.
        let fullTakeRestyles = renderer.scopeRestyles
        model.activate(nil)
        pane.update()
        pane.scroll(toCharacter: renderer.paragraphs[3].offset)
        check("Full Take shows no band or range bar and styles every word word.text", text.backdrop?.isHidden == true && text.backdrop?.band == nil
              && renderer.attributes[outsideWord]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.text") && (0..<renderer.paragraphs.count).allSatisfy(renderer.isInScope(paragraph:)))
        check("leaving a clip for Full Take restyles only the words outside it (\(renderer.scopeRestyles - fullTakeRestyles) of \(text.map.spans.count) spans)",
              renderer.scopeRestyles > fullTakeRestyles && renderer.scopeRestyles - fullTakeRestyles < text.map.spans.count)
        bitmap = try pane.bitmap("v2-transcript-fulltake-dark", directory: directory)
        if let box = text.lineBox(atCharacter: renderer.paragraphs[4].offset) {
            check("Full Take paints no band behind the paragraphs", pane.matches(bitmap, CGPoint(x: 72, y: box.minY - 6), surface) && pane.matches(bitmap, CGPoint(x: 9, y: box.midY), surface))
        }

        // A tab switch between neighbouring clips restyles only the symmetric difference.
        model.activate(muted)
        pane.update()
        let switchStart = renderer.scopeRestyles
        model.activate(try clip("five-3"))
        pane.update()
        let switched = renderer.scopeRestyles - switchStart
        let neighbours = text.map.spans.filter { span in
            guard let position = model.index(span.ids.first ?? span.id) ?? model.pauseIndex[span.id]?.afterIndex else { return false }
            return split[4].contains(position) || split[5].contains(position)
        }.count
        check("switching from clip 2 to clip 3 restyles only their words (\(switched) spans, \(neighbours) in both clips)", switched > 0 && switched <= neighbours)

        // The band follows a width change and a trim.
        model.activate(muted)
        pane.update()
        pane.scroll(toCharacter: renderer.paragraphs[3].offset)
        let narrowBand = text.backdrop?.band
        pane.resize(width: 820)
        if let wideTop = text.lineBox(atCharacter: first(of: muted)), let wideBottom = text.lineBox(atCharacter: last(of: muted)), let wide = text.backdrop?.band, let narrowBand {
            check("the band follows a width change (\(narrowBand.bottom - narrowBand.top) to \(wide.bottom - wide.top) tall)",
                  abs(wide.top - (wideTop.minY - 8)) < 0.5 && abs(wide.bottom - (wideBottom.maxY + 8)) < 0.5 && wide.bottom - wide.top < narrowBand.bottom - narrowBand.top
                  && text.backdrop?.frame.width == text.bounds.width)
        } else { check("the band follows a width change", false) }
        pane.resize(width: 652)
        model.adjustTrim(start: false, offset: -12)
        pane.update(rebuild: true)
        if let trimmed = model.activeClip, let trimmedBottom = text.lineBox(atCharacter: last(of: trimmed)), let band = text.backdrop?.band, let narrowBand {
            check("the band follows a trim to the clip's new last line (\(narrowBand.bottom) to \(band.bottom))", abs(band.bottom - (trimmedBottom.maxY + 8)) < 0.5 && band.bottom < narrowBand.bottom)
        } else { check("the band follows a trim", false) }
        model.undoManager?.undo()

        // VoiceOver: the Clips rotor names each clip; timecodes are never read as words.
        let rotor = NSAccessibilityCustomRotor(label: "Clips", itemSearchDelegate: text)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        var labels: [String] = []
        while labels.count < 8, let item = text.rotor(rotor, resultFor: parameters) {
            labels.append(item.customLabel ?? "")
            parameters.currentItem = item
        }
        check("the Clips rotor lists each clip as the Explorer names it (\(labels))", labels == ["Clip 1, Think in sentences", "Clip 2, It has to work on mute", "Clip 3, And yeah, I mess up a lot",
                                                                                                  "Clip 4, The best thirty seconds", "Suggested clip 5, One habit for a bad week"])
        check("VoiceOver reads the words alone: no timecode is in the transcript's text", text.accessibilityValue() == text.string && !text.string.contains(TranscriptGutter.timecode(renderer.paragraphs[1].start)))

        // A 400-word monologue lays out in paragraphs of at most 150 words.
        var long = model.project
        long.transcript?.words = (0..<400).map { TimedWord(id: "mono-\($0)", text: $0 % 97 == 96 ? "word." : "word", start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.3, speaker: "solo") }
        long.edits = ProjectEdits()
        model.document.replaceProject(long)
        model.refresh()
        pane.update(rebuild: true)
        let lengths = zip(renderer.paragraphs, renderer.paragraphs.dropFirst().map(\.firstWord) + [400]).map { $1 - $0.firstWord }
        check("a single-speaker monologue breaks at sentence ends after 80 words and never holds more than 150 (\(lengths))",
              lengths == TranscriptParagraphs.split(words: model.words).map(\.count) && lengths.allSatisfy { $0 <= 150 } && lengths.count > 2)
        results += try aiGlyph(app: app, directory: directory)
        return results
    }

    /// The editor at 1280 × 800 with clip 2 of the five-questions take open and the playhead
    /// in it, for side by side with f1: `v2-transcript-1280-dark` offscreen in `-uiSelfTest`,
    /// and `v2-transcript-1280` from the window server in `-sceneAudit` (`native`).
    static func scenes(app: AppModel, fixture: Project, directory: URL, native: Bool = false) async throws -> [DebugUISuite.Result] {
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try DebugSidebar.fiveQuestions(from: fixture), demo: true), selection: .clip("five-2"))
        guard let editor = shell.editor, let clip = editor.activeClip, let start = editor.index(clip.startWordId) else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        editor.sourceTime = editor.words[start + 18].start
        var band: TranscriptBackdropView.Band?
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: native ? "v2-transcript-1280" : "v2-transcript-1280-dark", size: NSSize(width: 1280, height: 800),
                                        appearance: .darkAqua, directory: directory, active: true, mainWindow: true, native: native, beforeCapture: { window in
            band = window.contentView.flatMap(transcript(in:))?.backdrop?.band
            return nil
        })
        if native { return [.init(name: "native v2 transcript: the open clip shows its band", passed: band != nil)] }
        return []
    }
    private static func transcript(in view: NSView) -> TranscriptNSTextView? {
        if let text = view as? TranscriptNSTextView { return text }
        return view.subviews.lazy.compactMap { transcript(in: $0) }.first
    }

    /// Lines holding AI-voiced words show the waveform glyph in the gutter's glyph column.
    private static func aiGlyph(app: AppModel, directory: URL) throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw CocoaError(.fileNoSuchFile) }
        let project = try JSONProjectStore.decode(Data(contentsOf: root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.textSize = DesignValues.transcriptTextSize; model.refresh()
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let bitmap = try pane.bitmap("v2-transcript-ai-dark", directory: directory)
        let text = pane.text
        guard let ai = text.map.spans.first(where: { pane.renderer.aiWordIDs.contains($0.id) }), let line = text.lineBox(atCharacter: ai.range.location) else {
            return [.init(name: "the AI passage is in the transcript", passed: false)]
        }
        let glyph = CGRect(x: 49, y: line.minY + 6, width: 14, height: 14)
        let blue = pane.count(bitmap, in: glyph) { $0.blueComponent - $0.redComponent > 0.2 }
        let plain = text.map.spans.first { !pane.renderer.aiWordIDs.contains($0.id) && text.lineBox(atCharacter: $0.range.location).map { abs($0.minY - line.minY) > 1 } == true }
        let others = plain.flatMap { text.lineBox(atCharacter: $0.range.location) }.map { pane.count(bitmap, in: CGRect(x: 49, y: $0.minY + 6, width: 14, height: 14)) { $0.blueComponent - $0.redComponent > 0.2 } }
        return [.init(name: "a line holding AI-voiced words shows the ai.tint waveform at x 49–63, other lines none (\(blue), \(others.map(String.init) ?? "no plain line"))", passed: blue >= 4 && others.map { $0 == 0 } ?? true)]
    }
}

/// A transcript pane as the editor builds it, in an offscreen window that is never shown.
@MainActor final class TranscriptPane {
    let model: EditorModel
    let coordinator: TranscriptTextView.Coordinator
    let scroll: TranscriptScrollView
    let text: TranscriptNSTextView
    private let window: NSWindow
    var renderer: TranscriptRenderer { coordinator.renderer }

    init(model: EditorModel, size: NSSize) throws {
        self.model = model
        coordinator = TranscriptTextView.Coordinator(model: model)
        scroll = TranscriptTextView.makeScrollView(model: model, coordinator: coordinator, width: size.width, height: size.height)
        guard let text = scroll.documentView as? TranscriptNSTextView else { throw CocoaError(.coderInvalidValue) }
        self.text = text
        text.drawsBackground = true
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = scroll
        update(rebuild: true)
    }
    func close() { window.close() }

    /// Renders the model's state as `updateNSView` does, then lays the viewport out.
    func update(rebuild: Bool = false) {
        if rebuild { renderer.rebuild(model: model) }
        renderer.update(TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, fillers: model.fillerIDs, playing: model.playingWordID,
                                             scope: model.scopeBounds, activeClipID: model.activeClip?.id, playhead: model.sourceTime))
        scroll.overviewRuler.marks = TranscriptOverviewRuler.marks(model: model)
        layout()
    }
    func layout() {
        scroll.tile()
        guard let manager = text.textLayoutManager else { return }
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
    }
    /// Scrolls the line holding a character to 24 pt below the top.
    func scroll(toCharacter offset: Int) {
        guard let box = text.lineBox(atCharacter: offset) else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, box.minY - 24)))
        scroll.reflectScrolledClipView(scroll.contentView)
        layout()
    }
    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: scroll.frame.height))
        scroll.frame.size.width = width
        scroll.layoutSubtreeIfNeeded()
        layout()
    }
    /// The pane drawn in Dark, also written as `name`.png. cacheDisplay stores the token
    /// values unmatched in the display's space, so pixels compare with their sRGB components.
    func bitmap(_ name: String, directory: URL) throws -> NSBitmapImageRep {
        var result: NSBitmapImageRep?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            text.backgroundColor = DesignValues.nsColor("bg.surface")
            guard let cached = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { return }
            scroll.cacheDisplay(in: scroll.bounds, to: cached)
            result = cached
        }
        guard let result, let data = result.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        return result
    }
    /// A token's Dark value in sRGB.
    static func color(_ token: String) -> NSColor {
        var color = NSColor.black
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { color = DesignValues.nsColor(token).usingColorSpace(.sRGB) ?? .black }
        return color
    }
    static func composite(_ color: NSColor, alpha: CGFloat, over base: NSColor) -> NSColor {
        NSColor(srgbRed: color.redComponent * alpha + base.redComponent * (1 - alpha), green: color.greenComponent * alpha + base.greenComponent * (1 - alpha),
                blue: color.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
    }
    static func close(_ pixel: NSColor, _ color: NSColor, _ tolerance: CGFloat) -> Bool {
        abs(pixel.redComponent - color.redComponent) <= tolerance && abs(pixel.greenComponent - color.greenComponent) <= tolerance && abs(pixel.blueComponent - color.blueComponent) <= tolerance
    }
    private func scale(_ bitmap: NSBitmapImageRep) -> CGFloat { CGFloat(bitmap.pixelsWide) / scroll.bounds.width }
    /// The pixel under a point in the text view's coordinates.
    func pixel(_ bitmap: NSBitmapImageRep, _ point: CGPoint) -> NSColor? {
        let local = scroll.convert(point, from: text), scale = scale(bitmap)
        let y = scroll.isFlipped ? local.y : scroll.bounds.height - local.y
        let column = Int(local.x * scale), row = Int(y * scale)
        guard column >= 0, row >= 0, column < bitmap.pixelsWide, row < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: column, y: row)
    }
    func matches(_ bitmap: NSBitmapImageRep, _ point: CGPoint, _ color: NSColor, tolerance: CGFloat = 3.0 / 255) -> Bool {
        pixel(bitmap, point).map { Self.close($0, color, tolerance) } ?? false
    }
    /// Pixels in a rect of the text view's coordinates that pass `test`.
    func count(_ bitmap: NSBitmapImageRep, in rect: CGRect, where test: (NSColor) -> Bool) -> Int {
        let scale = scale(bitmap), step = 1 / scale
        var count = 0
        for y in stride(from: rect.minY + step / 2, to: rect.maxY, by: step) {
            for x in stride(from: rect.minX + step / 2, to: rect.maxX, by: step) where pixel(bitmap, CGPoint(x: x, y: y)).map(test) == true { count += 1 }
        }
        return count
    }
    func count(_ bitmap: NSBitmapImageRep, in rect: CGRect, _ color: NSColor) -> Int { count(bitmap, in: rect) { Self.close($0, color, 3.0 / 255) } }
    /// The horizontal extent, in points, of the pixels in a rect that differ from its background.
    func inkExtent(_ bitmap: NSBitmapImageRep, in rect: CGRect, background: NSColor) -> ClosedRange<CGFloat>? {
        let scale = scale(bitmap), step = 1 / scale
        var lower: CGFloat?, upper: CGFloat?
        for x in stride(from: rect.minX + step / 2, to: rect.maxX, by: step) {
            let inked = stride(from: rect.minY, to: rect.maxY, by: step).contains { y in pixel(bitmap, CGPoint(x: x, y: y)).map { !Self.close($0, background, 0.08) } == true }
            if inked { lower = lower ?? x - step / 2; upper = x + step / 2 }
        }
        guard let lower, let upper else { return nil }
        return lower...upper
    }
}
#endif
