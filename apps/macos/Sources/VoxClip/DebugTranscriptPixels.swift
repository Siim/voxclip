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
        // Show cuts on, so the cut word shows struck (notes.md §5).
        model.textSize = DesignValues.transcriptTextSize; model.mediaResolved = true; model.showsCuts = true; model.refresh()
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
        renderer.update(TranscriptAppearance(cutWords: ["pixel-cut"], lowConfidence: true, playhead: 1.4))
        guard let manager = text.textLayoutManager else { throw CocoaError(.coderInvalidValue) }
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        guard let fragment = manager.textLayoutFragment(for: manager.documentRange.location), let line = fragment.textLineFragments.first else { throw CocoaError(.coderInvalidValue) }
        let font = DesignValues.transcriptFont(size: model.textSize)
        let baseline = text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        var results: [DebugUISuite.Result] = try wordAccessibility(app: app)
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
                // The removed word's 1 pt strike in its own grey; no filler underline (impl-plan item 11).
                for (id, token, strike) in [("pixel-cut", "word.gone", true), ("pixel-filler", "word.filler", false), ("pixel-low", "word.lowConfidence", false)] {
                    guard let span = text.map.span(id: id) else { results.append(.init(name: "\(name) \(id) pixels", passed: false)); continue }
                    let lower = line.locationForCharacter(at: span.range.location).x + text.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
                    let upper = line.locationForCharacter(at: NSMaxRange(span.range)).x + text.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
                    let row = strike ? baseline - font.xHeight / 2 : baseline - font.underlinePosition + 1
                    let count = matchingColumns(bitmap, lower: lower, upper: upper, row: row, size: text.bounds.size, color: DesignValues.nsColor(token), background: text.backgroundColor)
                    probes.append(Probe(name: "\(name)-\(id)", row: row, width: upper - lower, matchingColumns: count))
                    if id == "pixel-filler" {
                        results.append(.init(name: "\(name) an uncut filler has no underline (\(count) word.filler columns)", passed: count == 0))
                        continue
                    }
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
            // Show Pauses is off by default, so an uncut pause shows nothing; under Show cuts a
            // cut pause shows its length in word.gone, with no chip (notes.md §5).
            let hidden = text.map.span(id: pause.id) == nil
            pageProject.edits.cutPauseIds = [pause.id]
            model.document.replaceProject(pageProject)
            model.refresh()
            renderer.rebuild(model: model)
            pageState.cutPauses = [pause.id]
            renderer.update(pageState)
            let shown = text.map.span(id: pause.id).map { (text.string as NSString).substring(with: $0.range) }
            results.append(.init(name: "an uncut pause shows nothing and a cut one its length under Show cuts, without a chip (\(shown ?? "none"))", passed:
                hidden && shown == "\(toFixed1(pause.duration))\u{00A0}s" && renderer.attributes[pause.id]?[.backgroundColor] == nil
                && renderer.attributes[pause.id]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.gone")))
            results.append(.init(name: "the pause's accessible description includes duration and cut", passed: text.map.span(id: pause.id).flatMap { text.accessibilityString(for: $0.range) }?.hasSuffix(", cut") == true))
        }
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        for (name, mode) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: mode)!
            window.appearance = appearance
            for pauseCut in [true, false] {
            appearance.performAsCurrentDrawingAppearance {
                pageProject.edits.cutPauseIds = pauseCut ? model.pauses.map(\.id) : []
                model.document.replaceProject(pageProject)
                model.refresh()
                renderer.rebuild(model: model)
                pageState.cutPauses = pauseCut ? Set(model.pauses.map(\.id)) : []
                renderer.update(pageState)
                manager.ensureLayout(for: manager.documentRange)
                manager.textViewportLayoutController.layoutViewport()
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
                let strikePixels = opaquePixels(bitmap, rect: rect("pixel-cut"), size: text.bounds.size, color: DesignValues.nsColor("word.gone"))
                if let pause = model.pauses.first {
                    let lengthPixels = pauseCut ? opaquePixels(bitmap, rect: rect(pause.id), size: text.bounds.size, color: DesignValues.nsColor("word.gone")) : 0
                    let chipPixels = pauseCut ? opaquePixels(bitmap, rect: rect(pause.id), size: text.bounds.size, color: DesignValues.nsColor("pause.background"), patch: 3) : 0
                    results.append(.init(name: "\(name) a \(pauseCut ? "cut pause shows its length in word.gone" : "uncut pause shows nothing") and no chip (\(lengthPixels) glyph, \(chipPixels) chip pixels)",
                                         passed: pauseCut ? lengthPixels >= 3 && chipPixels == 0 : text.map.span(id: pause.id) == nil))
                }
                results.append(.init(name: "\(name) out-of-clip glyphs paint opaque word.outside (\(scopedPixels) pixels)", passed: scopedPixels >= 3))
                results.append(.init(name: "\(name) a removed word's strike is word.gone within three channels (\(strikePixels) pixels)", passed: strikePixels >= 3))
                // No red anywhere (notes.md §3): cuts are absence. The caret is the one orange.
                let caret = text.caret.map { $0.isHidden ? CGRect.null : $0.frame.insetBy(dx: -2, dy: -2) } ?? .null
                let red = (0..<bitmap.pixelsHigh).reduce(0) { count, row in
                    count + (0..<bitmap.pixelsWide).filter { column in
                        let point = CGPoint(x: (CGFloat(column) + 0.5) * text.bounds.width / CGFloat(bitmap.pixelsWide), y: (CGFloat(row) + 0.5) * text.bounds.height / CGFloat(bitmap.pixelsHigh))
                        guard !caret.contains(point), let pixel = bitmap.colorAt(x: column, y: row) else { return false }
                        return pixel.redComponent - max(pixel.greenComponent, pixel.blueComponent) > 0.2
                    }.count
                }
                results.append(.init(name: "\(name) the transcript paints no red pixels (\(red))", passed: red == 0))
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent("transcript-page-\(name)-\(pauseCut ? "cut" : "uncut")-pause.png")) }
            }
            }
        }
        try JSONEncoder().encode(probes).write(to: directory.appendingPathComponent("transcript-decoration-pixels.json"))
        results += try gutter(app: app, fixture: fixture, directory: directory)
        results += try folds(app: app, fixture: fixture, directory: directory)
        results += try proposal(app: app, fixture: fixture, directory: directory)
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
                    model.showsCuts = true
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
        let model = EditorModel(document: VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: fixture), demo: true), app: app, preview: DemoPreviewEngine())
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
        model.showsSurroundingContext = true
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
        model.showsSurroundingContext = true
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
        let fullTakeRestyles = renderer.scopeRestyles + renderer.rebuildStyles
        model.activate(nil)
        pane.update()
        pane.scroll(toCharacter: renderer.paragraphs[3].offset)
        check("Full Take shows no band or range bar and styles every word word.text", text.backdrop?.isHidden == true && text.backdrop?.band == nil
              && renderer.attributes[outsideWord]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.text") && (0..<renderer.paragraphs.count).allSatisfy(renderer.isInScope(paragraph:)))
        // The text outside the clip folds its cuts again, so the switch writes those paragraphs styled for Full Take.
        let fullTakeStyles = renderer.scopeRestyles + renderer.rebuildStyles - fullTakeRestyles
        check("leaving a clip for Full Take styles each span at most once (\(fullTakeStyles) of \(text.map.spans.count) spans)", fullTakeStyles > 0 && fullTakeStyles <= text.map.spans.count)
        bitmap = try pane.bitmap("v2-transcript-fulltake-dark", directory: directory)
        if let box = text.lineBox(atCharacter: renderer.paragraphs[4].offset) {
            check("Full Take paints no band behind the paragraphs", pane.matches(bitmap, CGPoint(x: 72, y: box.minY - 6), surface) && pane.matches(bitmap, CGPoint(x: 9, y: box.midY), surface))
        }

        // A tab switch between neighbouring clips restyles only the symmetric difference.
        model.activate(muted)
        model.showsSurroundingContext = true
        pane.update()
        let switchStart = renderer.scopeRestyles
        model.activate(try clip("five-3"))
        model.showsSurroundingContext = true
        pane.update()
        let switched = renderer.scopeRestyles - switchStart
        let neighbours = text.map.spans.filter { span in
            guard let position = model.index(span.ids.first ?? span.id) ?? model.pauseIndex[span.id]?.afterIndex else { return false }
            return split[4].contains(position) || split[5].contains(position)
        }.count
        check("switching from clip 2 to clip 3 restyles only their words (\(switched) spans, \(neighbours) in both clips)", switched > 0 && switched <= neighbours)

        // The band follows a width change and a trim.
        model.activate(muted)
        model.showsSurroundingContext = true
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
        let blanked = text.map.spans.filter { $0.kind == .fold }.reduce(text.string as NSString) { $0.replacingCharacters(in: $1.range, with: "   ") as NSString } as String
        check("VoiceOver reads the words alone: no timecode is in the transcript's text, and a fold's characters read as spaces", text.accessibilityValue() == blanked && !text.string.contains(TranscriptGutter.timecode(renderer.paragraphs[1].start)))

        // A 400-word monologue lays out in paragraphs of at most 150 words.
        var long = model.project
        long.transcript?.words = (0..<400).map { index in
            let start: Double = Double(index) * 0.4
            let end: Double = start + 0.3
            let text: String = index % 97 == 96 ? "word." : "word"
            return TimedWord(id: "mono-\(index)", text: text, start: start, end: end, speaker: "solo")
        }
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
    /// and `v2-transcript-1280` from the window server in `-sceneAudit` (`native`); then the
    /// same clip with three proposed changes, beside f3: `v2-transcript-hunks-1280(-dark)`.
    static func scenes(app: AppModel, fixture: Project, directory: URL, native: Bool = false) async throws -> [DebugUISuite.Result] {
        let shell = WorkspaceShell(app: app)
        await shell.attachForTesting(VoxClipDocument(project: try DebugExplorer.fiveQuestions(from: fixture), demo: true), selection: .clip("five-2"))
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
        // The same clip with a proposal of three changes, change 1 focused, beside f3: "that
        // matters → counts most", "if someone only reads" without "only", "caption," → "captions,".
        let ids = editor.words.map(\.id)
        guard editor.words.count > start + 28, editor.words[start + 4].text == "matters", editor.words[start + 25].text == "only", editor.words[start + 28].text == "caption," else { throw CocoaError(.coderInvalidValue) }
        editor.proposal = TranscriptProposal(clipID: clip.id, title: "Rewrite clip 2", changes: [
            TranscriptChange(ordinal: 1, parts: [.init(kind: .voice, sourceWordIDs: [ids[start + 4]], newTokens: ["counts"])]),
            TranscriptChange(ordinal: 2, parts: [.init(kind: .cut, sourceWordIDs: [ids[start + 25]])]),
            TranscriptChange(ordinal: 3, parts: [.init(kind: .textOnly, sourceWordIDs: [ids[start + 28]], newTokens: ["captions,"], correctedTexts: ["captions,"])])
        ])
        var buttons = false
        try await DebugUISuite.snapshot(WorkspaceView(shell: shell).environment(app), name: native ? "v2-transcript-hunks-1280" : "v2-transcript-hunks-1280-dark", size: NSSize(width: 1280, height: 800),
                                        appearance: .darkAqua, directory: directory, active: true, mainWindow: true, native: native, beforeCapture: { window in
            buttons = window.contentView.flatMap(transcript(in:))?.proposalLayer?.isHidden == false
            return nil
        })
        editor.proposal = nil
        if native { return [.init(name: "native v2 transcript: the open clip shows its band", passed: band != nil), .init(name: "native v2 transcript: the focused change shows Keep and Undo", passed: buttons)] }
        return []
    }
    private static func transcript(in view: NSView) -> TranscriptNSTextView? {
        if let text = view as? TranscriptNSTextView { return text }
        return view.subviews.lazy.compactMap { transcript(in: $0) }.first
    }

    /// Lines holding AI-voiced words show the waveform glyph in the gutter's glyph column,
    /// centred on the line at the default size and at the largest zoom.
    private static func aiGlyph(app: AppModel, directory: URL) throws -> [DebugUISuite.Result] {
        guard let root = app.shared?.root else { throw CocoaError(.fileNoSuchFile) }
        let project = try JSONProjectStore.decode(Data(contentsOf: root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        var results: [DebugUISuite.Result] = []
        for size in [DesignValues.transcriptTextSize, DesignValues.transcriptZoom.upperBound] {
            model.textSize = size; model.refresh()
            let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
            defer { pane.close() }
            let text = pane.text
            guard let ai = text.map.spans.first(where: { pane.renderer.aiWordIDs.contains($0.id) }), let line = text.lineBox(atCharacter: ai.range.location) else {
                results.append(.init(name: "the AI passage is in the transcript at \(Int(size)) pt", passed: false)); continue
            }
            pane.scroll(toCharacter: ai.range.location)
            let bitmap = try pane.bitmap(size == DesignValues.transcriptTextSize ? "v2-transcript-ai-dark" : "v2-transcript-ai-\(Int(size))-dark", directory: directory)
            let blue: (NSColor) -> Bool = { $0.blueComponent - $0.redComponent > 0.2 }
            // The glyph's box is centred on the line's words; the column above and below it stays clear.
            let glyph = CGRect(x: 49, y: line.midY - 7, width: 14, height: 14)
            let inside = pane.count(bitmap, in: glyph, where: blue)
            let offCentre = pane.count(bitmap, in: CGRect(x: 49, y: line.minY, width: 14, height: glyph.minY - 1 - line.minY), where: blue)
                + pane.count(bitmap, in: CGRect(x: 49, y: glyph.maxY + 1, width: 14, height: line.maxY - glyph.maxY - 1), where: blue)
            // A visible line holding no AI-voiced word shows no waveform.
            let aiLines = Set(text.map.spans.filter { pane.renderer.aiWordIDs.contains($0.id) }.compactMap { text.lineBox(atCharacter: $0.range.location).map { Int($0.minY.rounded()) } })
            let plain = text.map.spans.lazy.compactMap { text.lineBox(atCharacter: $0.range.location) }.first { !aiLines.contains(Int($0.minY.rounded())) && pane.scroll.contentView.documentVisibleRect.contains($0) }
            let others = plain.map { pane.count(bitmap, in: CGRect(x: 49, y: $0.minY, width: 14, height: $0.height), where: blue) }
            results.append(.init(name: "at \(Int(size)) pt a line holding AI-voiced words shows the ai.tint waveform at x 49–63 centred on the line (\(inside) pixels, \(offCentre) off centre), other lines none (\(others.map(String.init) ?? "no plain line"))",
                                 passed: inside >= 4 && offCentre == 0 && others.map { $0 == 0 } ?? true))
        }
        return results
    }
}

/// V8b on the mockup's folded paragraphs (ux/v2 f1, f2 and zoom-transcript): folds, the
/// filler-comma rule, Show cuts, the selection at text height, the caret, the fold popover
/// and the outside-clip rule, in a 652 × 488 transcript. Writes `v2-transcript-folds-dark`,
/// `v2-transcript-showcuts-dark` and `v2-transcript-popover-dark`.
extension DebugTranscriptPixels {
    /// The mockup's Clip 1 paragraphs as a take: fillers and the pauses `{seconds}` are cut,
    /// pauses count from 0.75 s, and the second paragraph is another speaker's.
    static func foldProject(from fixture: Project) -> Project {
        let paragraphs: [[String]] = [
            ["So,", "{1.4}", "uh,", "while", "you're", "speaking,", "{0.9}", "it,", "uh,", "{1.2}", "examines", "your,", "{1.0}", "uh,", "{0.8}", "app,", "makes", "videos,", "and", "adds", "clip", "in", "between", "your", "speech."],
            ["And", "one", "cool", "feature", "I", "added", "is", "when", "you", "want", "to", "represent", "your", "project,", "you", "include,", "uh,", "{1.0}", "um,", "source", "directory."]
        ]
        var words: [TimedWord] = [], cutWords: [String] = [], cutPauses: [String] = [], gap = 0.1, end = 0.0
        for (paragraph, tokens) in paragraphs.enumerated() {
            for token in tokens {
                if token.hasPrefix("{"), let seconds = Double(token.dropFirst().dropLast()) {
                    gap = seconds
                    if let last = words.last { cutPauses.append("pause-after-\(last.id)") }
                    continue
                }
                let start = words.isEmpty ? 0 : end + gap
                let word = TimedWord(id: "fold-\(words.count)", text: token, start: start, end: start + 0.3, speaker: "s\(paragraph)")
                if token == "uh," || token == "um," { cutWords.append(word.id) }
                words.append(word)
                end = word.end; gap = 0.1
            }
        }
        var project = fixture
        project.transcript?.words = words
        project.transcript?.durationSeconds = end + 1
        project.media.source.durationSeconds = end + 1
        project.edits = ProjectEdits(pauseThresholdSeconds: 0.75, cutWordIds: cutWords, cutPauseIds: cutPauses)
        return project
    }
    /// The text as it reads, a fold as "•".
    static func displayed(_ text: TranscriptNSTextView) -> [String] {
        text.string.replacingOccurrences(of: TranscriptFold.text, with: "•").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func folds(app: AppModel, fixture: Project, directory: URL) throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let model = EditorModel(document: VoxClipDocument(project: foldProject(from: fixture), demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.textSize = DesignValues.transcriptTextSize; model.mediaResolved = true; model.refresh()
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let text = pane.text, renderer = pane.renderer
        func id(_ index: Int) -> String { model.words[index].id }

        // Folds (notes.md §5): one dot per run of removals, glued to the word before it.
        let folded = ["So•while you're speaking,•it•examines your•app, makes videos, and adds clip in between your speech.", "And one cool feature I added is when you want to represent your project, you include•source directory."]
        let foldSpans = text.map.spans.filter { $0.kind == .fold }
        check("each run of removed words and pauses is one fold, glued to the words either side (\(displayed(text)))", displayed(text) == folded && foldSpans.count == 5)
        check("\"include, uh, um, source\" reads \"include • source\" and \"speaking, • it\" keeps its comma", displayed(text)[1].contains("include•source") && displayed(text)[0].contains("speaking,•it"))
        let itFold = text.map.span(id: id(6))
        check("a fold holds its words and pauses in reading order (\(itFold?.ids ?? []))", itFold?.kind == .fold && itFold?.ids == [id(6), "pause-after-\(id(6))"])
        check("a fold reads what it removed: \"\(itFold.map(text.spoken) ?? "")\"", itFold.map(text.spoken) == "1 cut: uh, pause 1.2 seconds")
        let rotor = NSAccessibilityCustomRotor(label: "Cuts", itemSearchDelegate: text)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        let first = text.rotor(rotor, resultFor: parameters)
        check("the Cuts rotor lands on the first fold (\(first?.customLabel ?? "nothing"))", first?.targetRange == foldSpans.first?.range && first?.customLabel?.hasPrefix("1 cut: pause 1.4 seconds, uh") == true)

        // The fold is 13 pt wide and a line never starts with it, at three measures.
        pane.scroll(toCharacter: 0)
        if let fold = foldSpans.first, let box = text.foldBox(fold) {
            check("a fold is 13 pt wide (\(box.width))", abs(box.width - 13) < 0.01)
        } else { check("the first fold is laid out", false) }
        var starts: [String] = []
        for width: CGFloat in [604, 652, 772] {
            pane.resize(width: width)
            guard let manager = text.textLayoutManager, let content = manager.textContentManager else { continue }
            manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
                guard let element = fragment.textElement?.elementRange else { return false }
                let base = content.offset(from: content.documentRange.location, to: element.location)
                for line in fragment.textLineFragments.dropFirst() {
                    let start = base + line.characterRange.location
                    if text.map.intersecting(NSRange(location: start, length: 1)).contains(where: { $0.kind == .fold && NSLocationInRange(start, $0.range) }) { starts.append("\(width):\(start)") }
                }
                return true
            }
        }
        check("no line starts with a fold at measures 480, 528 and 648 (\(starts))", starts.isEmpty)
        pane.resize(width: 652)

        // The caret stands at the playhead's word, 2 × 19, and a tick restyles no span.
        model.sourceTime = model.words[10].start + 0.05
        pane.update()
        pane.scroll(toCharacter: 0)
        let playing = text.map.span(id: id(10))
        let caretFrame = text.caret?.frame ?? .zero
        let wordBox = playing.flatMap { text.lineBox(atCharacter: $0.range.location) }
        check("the caret is 2 × 19 at the playhead's word (\(caretFrame))", text.caret?.isHidden == false && caretFrame.width == 2 && abs(caretFrame.height - 19) < 0.01
              && renderer.caretOffset == playing?.range.location && wordBox.map { caretFrame.minY > $0.minY && caretFrame.maxY < $0.maxY } == true)
        let applied = renderer.attributeUpdates, styled = renderer.rebuildStyles, moves = renderer.caretMoves
        model.sourceTime = model.words[12].start + 0.05
        pane.update()
        check("a playhead tick moves the caret and restyles no span (\(caretFrame.minX) to \(text.caret?.frame.minX ?? 0))",
              renderer.caretMoves == moves + 1 && renderer.attributeUpdates == applied && renderer.rebuildStyles == styled && text.caret?.frame.minX != caretFrame.minX)
        model.sourceTime = model.words[10].start + 0.05
        pane.update()

        // The selection at text height in tint.selection, and no native selection.
        model.selectedWordIDs = [id(3), id(4), id(5)]
        pane.update()
        let rects = text.selectionLayer?.rects ?? []
        let font = renderer.font
        check("the selection tint is the text's height, ascender to descender (\(rects.map(\.height)))", rects.count == 1 && rects.allSatisfy { abs($0.height - (font.ascender - font.descender)) < 0.01 })
        // A selection across a fold holds the words either side and what the fold holds, as ⇧→ over it does.
        if let so = text.map.span(id: id(0)), let whilst = text.map.span(id: id(2)) {
            text.setSelectedRange(NSRange(location: so.range.location, length: NSMaxRange(whilst.range) - so.range.location))
            check("a selection across a fold selects the words around it and what it holds (\(model.selectedWordIDs.sorted()), \(model.selectedPauseIDs.sorted()))",
                  model.selectedWordIDs == [id(0), id(1), id(2)] && model.selectedPauseIDs == ["pause-after-\(id(0))"])
            model.selectedPauseIDs = []
            model.selectedWordIDs = [id(3), id(4), id(5)]
            pane.update()
        }
        var bitmap = try pane.bitmap("v2-transcript-folds-dark", directory: directory)
        let surface = TranscriptPane.color("bg.surface"), dot = TranscriptPane.color("fold.dot")
        if let fold = foldSpans.first, let box = text.foldBox(fold) {
            let dotRows = pane.count(bitmap, in: CGRect(x: box.midX - 1.5, y: box.minY, width: 3, height: box.height), dot)
            check("a fold paints a fold.dot dot in its middle (\(dotRows) pixels)", dotRows >= 4)
        }
        // The orange tints are compared by hue: the capture is in the display's space, where
        // a saturated sRGB token reads different components (greys do not).
        let warm: (NSColor) -> Bool = { $0.redComponent - $0.blueComponent > 0.05 && $0.redComponent > $0.greenComponent }
        if let rect = rects.first {
            let inside = pane.count(bitmap, in: CGRect(x: rect.minX + 1, y: rect.minY + 1, width: 6, height: rect.height - 2), where: { warm($0) && !TranscriptPane.close($0, surface, 0.02) })
            let above = pane.count(bitmap, in: CGRect(x: rect.minX + 1, y: rect.minY - 3, width: 6, height: 2), where: { !TranscriptPane.close($0, surface, 3.0 / 255) })
            let below = pane.count(bitmap, in: CGRect(x: rect.minX + 1, y: rect.maxY + 1, width: 6, height: 2), where: { !TranscriptPane.close($0, surface, 3.0 / 255) })
            check("the selection paints the orange tint at text height only, no native fill (\(inside) inside, \(above) above, \(below) below)", inside >= 12 && above == 0 && below == 0)
        }
        if let caret = text.caret?.frame {
            let orange: (NSColor) -> Bool = { $0.redComponent > 0.7 && $0.redComponent - $0.blueComponent > 0.4 }
            let painted = pane.count(bitmap, in: caret.insetBy(dx: 0.25, dy: 2), where: orange)
            check("the caret paints the orange tint.text (\(painted) pixels)", painted >= 10)
            // No red anywhere (notes.md §3): cuts are absence. The caret and the ruler's selection mark are the orange.
            let ruler = pane.scroll.convert(pane.scroll.overviewRuler.frame, to: text)
            let red: (NSColor) -> Bool = { $0.redComponent - max($0.greenComponent, $0.blueComponent) > 0.2 }
            let visible = pane.scroll.convert(pane.scroll.bounds, to: text)
            let count = pane.count(bitmap, in: visible, where: red) - pane.count(bitmap, in: caret.insetBy(dx: -2, dy: -2), where: red) - pane.count(bitmap, in: ruler.intersection(visible), where: red)
            check("nothing but the caret and the ruler's selection mark paints red or orange (\(count) pixels)", count == 0)
        }

        // Hover: the dot lights with a halo and the popover lists "1.4 s uh" with Restore.
        if let fold = foldSpans.first, let box = text.foldBox(fold) {
            text.hover(at: CGPoint(x: box.midX, y: box.midY))
            text.showFoldPopover(for: fold.id)
            bitmap = try pane.bitmap("v2-transcript-popover-dark", directory: directory)
            let lit = pane.count(bitmap, in: CGRect(x: box.midX - 1.5, y: box.minY, width: 3, height: box.height), TranscriptPane.color("text.secondary"))
            check("a hovered fold's dot is text.secondary (\(lit) pixels) and its popover shows", text.hoveredFold == fold.id && lit >= 4 && text.foldPopoverVisible && text.popoverFold == fold.id)
            check("the popover lists the pause and the word in reading order", model.foldItems(fold.ids) == [.pause(1.4), .word("uh")])
            text.hover(at: nil)
            check("leaving the fold hides its popover", !text.foldPopoverVisible && text.hoveredFold == nil)
        }

        // Show cuts: every fold opens, removed words struck in word.gone, pauses as lengths.
        model.toggleShowsCuts()
        pane.update(rebuild: true)
        let shown = ["So, 1.4\u{00A0}s uh, while you're speaking, 0.9\u{00A0}s it, uh, 1.2\u{00A0}s examines your, 1.0\u{00A0}s uh, 0.8\u{00A0}s app, makes videos, and adds clip in between your speech.",
                     "And one cool feature I added is when you want to represent your project, you include, uh, 1.0\u{00A0}s um, source directory."]
        check("Show cuts opens every fold (\(displayed(text)))", displayed(text) == shown && !text.map.spans.contains { $0.kind == .fold })
        let comma = text.map.span(id: "comma:\(id(0))")
        check("a folded comma shows in word.gone, unstruck, and the filler struck in word.gone",
              comma?.kind == .comma && renderer.attributes[comma?.id ?? ""]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.gone")
              && renderer.attributes[id(1)]?[.vcStrike] as? Bool == true && renderer.attributes[id(1)]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.gone")
              && renderer.attributes["pause-after-\(id(0))"]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.gone"))
        pane.scroll(toCharacter: 0)
        bitmap = try pane.bitmap("v2-transcript-showcuts-dark", directory: directory)
        if let uh = text.map.span(id: id(1)), let (fragment, line, base) = pane.line(atCharacter: uh.range.location) {
            let origin = text.textContainerOrigin
            let left = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + line.locationForCharacter(at: uh.range.location - base).x
            let right = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + line.locationForCharacter(at: NSMaxRange(uh.range) - base).x
            let baseline = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            let row = baseline - font.xHeight / 2
            // Every column but the two partly covered ends.
            let struck = pane.inkedColumns(bitmap, left: left, right: right, row: row, ink: TranscriptPane.color("word.gone"), paper: TranscriptPane.color("bg.surface"))
            check("Show cuts strikes a removed word in word.gone (\(struck.inked) of \(struck.of) columns)", struck.of > 0 && struck.inked >= struck.of - 2)
        } else { check("the struck word is laid out", false) }
        model.toggleShowsCuts()
        pane.update(rebuild: true)

        // A click opens one fold and selects what it holds; leaving the selection folds it.
        if let yourFold = text.map.span(id: "pause-after-\(id(8))") {
            model.expandFold(yourFold.ids)
            pane.update(rebuild: true)
            check("an opened fold shows its words and pauses, and only it (\(displayed(text)[0]))",
                  displayed(text)[0] == "So•while you're speaking,•it•examines your, 1.0\u{00A0}s uh, 0.8\u{00A0}s app, makes videos, and adds clip in between your speech."
                  && model.selectedWordIDs == [id(9)] && model.selectedPauseIDs == ["pause-after-\(id(8))", "pause-after-\(id(9))"])
            model.select(id(17))
            pane.update(rebuild: true)
            check("selecting elsewhere folds it again", displayed(text) == folded && model.openFoldEnds.isEmpty)
        }

        // Restore is one undo step.
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        if let fold = text.map.span(id: id(6)) {
            undo.beginUndoGrouping()
            model.restoreFold(fold.ids)
            undo.endUndoGrouping()
            pane.update(rebuild: true)
            let restored = !model.cutWordIDs.contains(id(6)) && !model.cutPauseIDs.contains("pause-after-\(id(6))") && text.map.span(id: id(6))?.kind == .text
            check("Restore brings the fold's words and pauses back as one undo step, \"\(undo.undoActionName)\"", restored && undo.undoActionName == "Restore cut")
            undo.undo()
            pane.update(rebuild: true)
            check("one undo folds them again", displayed(text) == folded)
        }
        model.undoManager = nil

        // A decoration on the word after a fold starts at the word, the fold's 13 pt after its
        // glyph: the correction dot under "apps," in "your•apps,", never in the fold's gap.
        model.apply(.correct(id: id(10), text: "apps,"), name: "Correct spelling")
        model.sourceTime = model.words[17].start + 0.05
        pane.update()
        pane.scroll(toCharacter: 0)
        if let fold = text.map.span(id: id(9)), let box = text.foldBox(fold), let word = text.map.span(id: id(10)), let line = text.textBox(of: word.range) {
            bitmap = try pane.bitmap("v2-transcript-correction-dark", directory: directory)
            let strip = CGRect(x: box.minX + 1, y: line.maxY - 2, width: box.width + 12, height: 2)
            let background = pane.pixel(bitmap, CGPoint(x: strip.maxX + 12, y: strip.midY)) ?? surface
            let ink = pane.inkExtent(bitmap, in: strip, background: background)
            check("the correction dot under the word after a fold starts at the word (\(ink.map { "\($0.lowerBound)" } ?? "no ink"), word at \(box.maxX))",
                  ink.map { abs($0.lowerBound - box.maxX) < 1 && abs(line.minX - box.maxX) < 0.5 } == true)
        } else { check("the corrected word after a fold is laid out", false) }
        model.apply(.correct(id: id(10), text: model.words[10].text), name: "Correct spelling")
        model.sourceTime = model.words[10].start + 0.05
        pane.update()

        // Outside the open clip the words read as said: no folds, no strikes, no pauses.
        var clipped = model.project
        clipped.edits.clips = [ClipRange(id: "fold-clip", startWordId: id(20), endWordId: id(model.words.count - 1), title: "Second paragraph")]
        model.document.replaceProject(clipped)
        model.refresh()
        model.activate(model.project.edits.clips[0])
        model.showsSurroundingContext = true
        pane.update(rebuild: true)
        check("outside the open clip the text shows no folds, markers or pauses (\(displayed(text)[0]))",
              displayed(text)[0] == "So, uh, while you're speaking, it, uh, examines your, uh, app, makes videos, and adds clip in between your speech."
              && displayed(text)[1] == folded[1] && renderer.attributes[id(1)]?[.vcStrike] as? Bool == false
              && renderer.attributes[id(1)]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.outside"))
        model.toggleShowsCuts()
        pane.update(rebuild: true)
        check("under Show cuts too, only the open clip shows its cuts", displayed(text)[0] == "So, uh, while you're speaking, it, uh, examines your, uh, app, makes videos, and adds clip in between your speech."
              && displayed(text)[1] == shown[1])
        return results
    }
}

/// V14 on the mockup's proposal (ux/v2 f3 and zoom-transcript): a clip of four paragraphs with
/// five proposed changes, two cuts and three in your voice, change 1 focused. Checks each
/// treatment's pixels, the Keep and Undo buttons at three measures, the map with inserted runs,
/// Keep, Undo and Keep All, the rotor and the edit popover. Writes `v2-transcript-hunks-dark`,
/// `v2-transcript-hunks-excluded-dark` and `v2-transcript-hunk-popover-dark`.
extension DebugTranscriptPixels {
    /// The take of f3's Clip 1, between a paragraph before it and one after it. A filler and
    /// a pause are cut in the second paragraph, so a fold sits beside the changes.
    static func proposalProject(from fixture: Project) -> Project {
        let paragraphs: [[String]] = [
            ["regenerates", "basically", "your", "video", "with-", "without", "making", "it", "10", "tries", "before", "you", "can", "actually", "post", "it."],
            ["And", "one", "cool", "feature", "I", "added", "is", "when", "you", "want", "to", "represent", "your", "project,", "you", "include", "source", "directory", "to,", "to", "the", "clip."],
            ["So,", "{1.4}", "uh,", "while", "you're", "speaking,", "it", "examines", "your", "app,", "makes", "videos,", "and", "adds", "clip", "in", "between", "your", "speech."],
            ["So", "this", "is", "interesting", "way", "how", "to", "represent", "stuff", "and", "of", "course", "websites,", "whatever", "you're", "speaking", "about."],
            ["It", "just", "pulls", "the", "site,", "and", "it", "just", "gets", "the", "si-", "into", "the", "site", "and", "shows", "the", "thing", "that", "you", "are", "talking", "about.",
             "So", "it's", "like", "automatic", "clipper,", "clipping", "assistant."],
            ["Let's", "see", "how", "far", "it", "can", "go."]
        ]
        var words: [TimedWord] = [], cutWords: [String] = [], cutPauses: [String] = [], gap = 0.1, end = 230.0
        for (paragraph, tokens) in paragraphs.enumerated() {
            for token in tokens {
                if token.hasPrefix("{"), let seconds = Double(token.dropFirst().dropLast()) {
                    gap = seconds
                    if let last = words.last { cutPauses.append("pause-after-\(last.id)") }
                    continue
                }
                let start = end + gap
                let word = TimedWord(id: "hunk-\(words.count)", text: token, start: start, end: start + 0.3, speaker: "s\(paragraph % 2)")
                if token == "uh," { cutWords.append(word.id) }
                words.append(word)
                end = word.end; gap = 0.1
            }
            gap = 1.6
        }
        var project = fixture
        project.transcript?.words = words
        project.transcript?.durationSeconds = end + 1
        project.media.source.durationSeconds = end + 1
        let first = paragraphs[0].count, last = words.count - paragraphs[5].count - 1
        project.edits = ProjectEdits(pauseThresholdSeconds: 0.75, cutWordIds: cutWords, cutPauseIds: cutPauses,
                                     clips: [ClipRange(id: "hunk-clip", startWordId: words[first].id, endWordId: words[last].id, title: "Clips that show")])
        return project
    }
    /// f3's five changes over `proposalProject`, change 1 focused: "include your source directory
    /// in the clip", "is an interesting way to", two cuts and "like an automatic clipping
    /// assistant". The parts are C2's shapes: merged voice hunks with their bridges, and cuts.
    static func proposal(for model: EditorModel) -> TranscriptProposal {
        func ids(_ texts: [String], after: Int = 0) -> [String] {
            let words = model.words
            guard let start = (after..<words.count).first(where: { start in start + texts.count <= words.count && words[start..<(start + texts.count)].map(\.text) == texts }) else { return [] }
            return words[start..<(start + texts.count)].map(\.id)
        }
        let first = ids(["source", "directory", "to,", "to", "the"])
        let second = ids(["interesting", "way", "how"])
        let site = ids(["and", "it", "just", "gets", "the", "si-", "into", "the", "site"])
        let that = ids(["that"])
        let clipper = ids(["automatic", "clipper,"])
        let changes = [
            TranscriptChange(ordinal: 1, parts: [.init(kind: .voice, sourceWordIDs: first, newTokens: ["your", "source", "directory", "in", "the"], bridgeWordIDs: Array(first.prefix(2)))]),
            TranscriptChange(ordinal: 2, parts: [.init(kind: .voice, sourceWordIDs: second, newTokens: ["an", "interesting", "way"], bridgeWordIDs: Array(second.prefix(2)))]),
            TranscriptChange(ordinal: 3, parts: [.init(kind: .cut, sourceWordIDs: site)]),
            TranscriptChange(ordinal: 4, parts: [.init(kind: .cut, sourceWordIDs: that)]),
            TranscriptChange(ordinal: 5, parts: [.init(kind: .voice, sourceWordIDs: clipper, newTokens: ["an", "automatic"], bridgeWordIDs: Array(clipper.prefix(1)))])
        ]
        return TranscriptProposal(clipID: "hunk-clip", title: "Rewrite clip 1", changes: changes)
    }

    static func proposal(app: AppModel, fixture: Project, directory: URL) throws -> [DebugUISuite.Result] {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        let model = EditorModel(document: VoxClipDocument(project: proposalProject(from: fixture), demo: true), app: app, preview: DemoPreviewEngine())
        defer { model.close() }
        model.textSize = DesignValues.transcriptTextSize; model.mediaResolved = true; model.refresh()
        model.activate(model.project.edits.clips[0])
        model.showsSurroundingContext = true
        model.proposal = proposal(for: model)
        model.sourceTime = model.words[16].start + 0.05
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let text = pane.text, renderer = pane.renderer
        func id(_ index: Int) -> String { model.words[index].id }
        func spans(_ ordinal: Int) -> [TranscriptSpan] { text.map.spans.filter { $0.change?.ordinal == ordinal } }

        // The text: new words beside the words they replace, removed words kept in place, folds unchanged.
        let shown = displayed(text).map { $0.replacingOccurrences(of: TranscriptFold.text, with: "•") }
        let expected = ["regenerates basically your video with- without making it 10 tries before you can actually post it.",
                        "And one cool feature I added is when you want to represent your project, you include your source directory to, to the in the clip.•",
                        "So•while you're speaking, it examines your app, makes videos, and adds clip in between your speech.",
                        "So this is an interesting way how to represent stuff and of course websites, whatever you're speaking about.",
                        "It just pulls the site, and it just gets the si- into the site and shows the thing that you are talking about. So it's like an automatic clipper, clipping assistant.",
                        "Let's see how far it can go."]
        check("each change shows its new words beside the words it removes, and the Keep and Undo blank after \"clip.\" (\(shown))", shown == expected)
        let inserted = text.map.spans.filter { $0.kind == .inserted }
        check("new words are display-only runs, never selectable (\(inserted.count) runs)", inserted.count == 4 && inserted.allSatisfy { !$0.selectable && $0.change?.role == .new })
        check("the words a change removes are struck in word.gone and the words it keeps stay plain",
              ["to,", "to", "the", "how", "clipper,"].allSatisfy { word in text.map.spans.contains { $0.change?.role == .old && (text.string as NSString).substring(with: $0.range) == word } }
              && renderer.attributes[id(34)]?[.vcStrike] as? Bool == true && renderer.attributes[id(34)]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.gone")
              && renderer.attributes[id(32)]?[.vcStrike] as? Bool == false && text.map.span(id: id(32))?.change?.role == .kept)
        // Selection snaps around new words: a drag over "your source" holds "source" only.
        if let your = inserted.first, let source = text.map.span(id: id(32)) {
            let ranges = text.map.selectionRanges(in: NSRange(location: your.range.location, length: NSMaxRange(source.range) - your.range.location))
            check("a selection over new words skips them (\(ranges))", ranges == [source.range])
        }
        // The map round-trips with inserted runs: every span by id and by character.
        let roundTrip = text.map.spans.allSatisfy { span in text.map.span(id: span.id) == span && text.map.intersecting(span.range).contains(span) }
            && model.words.allSatisfy { word in text.map.span(id: word.id) != nil }
        check("the range map round-trips with the inserted runs", roundTrip)

        pane.scroll(toCharacter: 0)
        var bitmap = try pane.bitmap("v2-transcript-hunks-dark", directory: directory)
        let band = TranscriptPane.color("editor.band")
        // The greens are compared by hue and strength: the capture is in the display's space,
        // where a saturated sRGB token reads different components (greys do not).
        let tinted: (NSColor) -> Bool = { $0.greenComponent - $0.redComponent > 0.05 && $0.greenComponent > $0.blueComponent && $0.greenComponent < 0.35 }
        let fullBar: (NSColor) -> Bool = { $0.greenComponent - $0.redComponent > 0.3 && $0.greenComponent > 0.6 }
        let halfBar: (NSColor) -> Bool = { $0.greenComponent - $0.redComponent > 0.15 && (0.35...0.6).contains($0.greenComponent) }
        // New words on change.add at 19 %, at the text's height: above "your" only tint.
        if let your = inserted.first, let box = text.textBox(of: your.range) {
            let font = renderer.font
            let baseline = (pane.line(atCharacter: your.range.location).map { fragment, line, _ in text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y }) ?? 0
            let top = baseline - font.ascender
            let inside = pane.count(bitmap, in: CGRect(x: box.minX + 2, y: top + 1, width: box.width - 4, height: 3), where: tinted)
            let above = pane.count(bitmap, in: CGRect(x: box.minX + 2, y: top - 4, width: box.width - 4, height: 3), where: { !TranscriptPane.close($0, band, 3.0 / 255) })
            check("new words sit on change.add at 19 % at the text's height (\(inside) tinted, \(above) above)", inside >= Int((box.width - 4) * 2) && above == 0)
        } else { check("the first new words are laid out", false) }
        // The removed "how" is struck in word.gone.
        if let how = text.map.span(id: id(61)), let (fragment, line, base) = pane.line(atCharacter: how.range.location) {
            let origin = text.textContainerOrigin
            let left = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + text.glyphX(line, local: how.range.location - base)
            let right = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + text.glyphX(line, local: NSMaxRange(how.range) - base)
            let row = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y - renderer.font.xHeight / 2
            // Every column but the two partly covered ends.
            let struck = pane.inkedColumns(bitmap, left: left, right: right, row: row, ink: TranscriptPane.color("word.gone"), paper: band)
            check("a removed word is struck in word.gone (\(struck.inked) of \(struck.of) columns)", struck.of > 0 && struck.inked >= struck.of - 2)
        } else { check("\"how\" is laid out", false) }
        // Change bars at x 66: the focused change at 100 %, the others at 50 %.
        if let first = renderer.changeRange(1).flatMap({ text.lineBox(atCharacter: $0.location) }), let second = renderer.changeRange(2).flatMap({ text.lineBox(atCharacter: $0.location) }) {
            let full = pane.count(bitmap, in: CGRect(x: 66, y: first.minY + 6, width: 3, height: first.height - 12), where: fullBar)
            let half = pane.count(bitmap, in: CGRect(x: 66, y: second.minY + 6, width: 3, height: second.height - 12), where: halfBar)
            let gap = pane.count(bitmap, in: CGRect(x: 66, y: first.minY, width: 3, height: 3), where: { !TranscriptPane.close($0, band, 3.0 / 255) })
            check("the focused change's bar is change.add, the others' at 50 %, 4 pt in from the line (\(full), \(half), \(gap) at the top)", full >= 30 && half >= 30 && gap == 0)
            let unchanged = text.lineBox(atCharacter: text.map.span(id: id(40))?.range.location ?? 0)
            let none = unchanged.map { pane.count(bitmap, in: CGRect(x: 66, y: $0.minY, width: 3, height: $0.height), where: { !TranscriptPane.close($0, band, 3.0 / 255) }) } ?? -1
            check("a line no change touches has no bar (\(none))", none == 0)
            // The glyph column shows the change's kind in text.tertiary.
            let glyph = pane.count(bitmap, in: CGRect(x: 49, y: first.midY - 7, width: 14, height: 14), where: { !TranscriptPane.close($0, band, 0.04) })
            check("a changed line shows its kind's glyph at 49–63 (\(glyph) pixels)", glyph >= 6)
        } else { check("changes 1 and 2 are laid out", false) }
        // One glyph per line by precedence: a line with a cut and a voice change shows the waveform.
        let mixed: [TranscriptChangeMark] = [.init(ordinal: 4, kind: .cut, role: .old, pending: true, focused: false), .init(ordinal: 5, kind: .voice, role: .new, pending: true, focused: false)]
        check("the glyph column ranks voice over fix over cut over the AI waveform",
              TranscriptGutter.glyph(marks: mixed, aiVoice: true) == .change(.voice) && TranscriptGutter.glyph(marks: [mixed[0]], aiVoice: true) == .change(.cut)
              && TranscriptGutter.glyph(marks: [], aiVoice: true) == .aiVoice && TranscriptGutter.glyph(marks: [.init(ordinal: 1, kind: .voice, role: .slot, pending: false, focused: false)], aiVoice: false) == nil)
        // No red: the only warm pixels are the caret's and the ruler's.
        if let caret = text.caret?.frame {
            let red: (NSColor) -> Bool = { $0.redComponent - max($0.greenComponent, $0.blueComponent) > 0.2 }
            let ruler = pane.scroll.convert(pane.scroll.overviewRuler.frame, to: text), visible = pane.scroll.convert(pane.scroll.bounds, to: text)
            let count = pane.count(bitmap, in: visible, where: red) - pane.count(bitmap, in: caret.insetBy(dx: -2, dy: -2), where: red) - pane.count(bitmap, in: ruler.intersection(visible), where: red)
            check("no red anywhere: changes are green, removals grey (\(count) pixels)", count == 0)
        }

        // The buttons stand over the blank after "clip.", Keep then Undo, inside the text container at three measures.
        var placements: [String] = []
        for width: CGFloat in [604, 652, 772] {
            pane.resize(width: width)
            pane.scroll(toCharacter: renderer.changeRange(1)?.location ?? 0)
            text.updateProposalButtons()
            guard let layer = text.proposalLayer, !layer.isHidden, let spacer = renderer.spacerID.flatMap({ text.map.span(id: $0) }),
                  let clip = text.map.span(id: id(37)), let line = text.lineBox(atCharacter: clip.range.location), let container = text.textContainer else { placements.append("\(width): hidden"); continue }
            let right = text.textContainerOrigin.x + container.containerSize.width
            let clipEnd = text.textBox(of: clip.range)?.maxX ?? 0
            let ok = layer.frame.maxX <= right && abs(layer.frame.minX - clipEnd - TranscriptProposalLayer.margin) < 1 && abs(layer.frame.midY - line.midY) <= 1
                && layer.buttons.map(\.kind) == [.keep, .undo] && layer.buttons.allSatisfy { $0.frame.height == 20 } && text.lineBox(atCharacter: spacer.range.location) == line
            if !ok { placements.append("\(width): \(layer.frame) right \(right) word end \(clipEnd) line \(line)") }
        }
        check("Keep and Undo stand 10 pt after \"clip.\", centred on its line, inside the text container at measures 480, 528 and 648 (\(placements))", placements.isEmpty)
        pane.resize(width: 652)
        pane.scroll(toCharacter: 0)

        // The rotor reads each change.
        let rotor = NSAccessibilityCustomRotor(label: "Proposed changes", itemSearchDelegate: text)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        text.configureAccessibilityActions()
        let firstItem = text.rotor(rotor, resultFor: parameters)
        check("the Proposed changes rotor reads \"\(firstItem?.customLabel ?? "nothing")\"", firstItem?.customLabel == "Proposed change 1 of 5: removed to, to the; inserted your, in the" && firstItem?.targetRange == renderer.changeRange(1))
        check("the transcript offers Keep and Undo as custom actions", (text.accessibilityCustomActions() ?? []).map(\.name).contains("Keep change 1") && (text.accessibilityCustomActions() ?? []).map(\.name).contains("Undo change 1"))

        // Undo excludes change 2: original words with a dotted place, no project change, no undo step.
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let before = model.project
        model.focusChange(2, announcing: false)
        pane.update()
        model.excludeFocusedChange()
        pane.update()
        check("Undo leaves a change out with no project change and no undo step, and focuses the next pending change",
              model.project == before && !undo.canUndo && model.proposal?[2]?.state == .excluded && model.proposalDisplay?.focused == 3
              && displayed(text)[3] == "So this is interesting way how to represent stuff and of course websites, whatever you're speaking about."
              && text.map.span(id: id(61))?.change?.role == .slot && renderer.attributes[id(61)]?[.vcUnderline] as? Int == TranscriptChangeMark.slotUnderline)
        bitmap = try pane.bitmap("v2-transcript-hunks-excluded-dark", directory: directory)
        // The excluded change keeps a dotted underline under "how", which has no descender.
        if let how = text.map.span(id: id(61)), let box = text.textBox(of: how.range), let (fragment, line, _) = pane.line(atCharacter: how.range.location) {
            let baseline = text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            let row = baseline - renderer.font.underlinePosition + 1
            let dots = pane.count(bitmap, in: CGRect(x: box.minX, y: row - 1, width: box.width, height: 2), where: { !TranscriptPane.close($0, band, 0.04) })
            let gaps = pane.count(bitmap, in: CGRect(x: box.minX, y: row - 1, width: box.width, height: 2), where: { TranscriptPane.close($0, band, 0.04) })
            check("an excluded change's words keep a dotted underline (\(dots) inked, \(gaps) clear)", dots >= Int(box.width / 3) && gaps >= Int(box.width / 3))
        } else { check("\"how\" is laid out after Undo", false) }
        // Keep on a cut applies it as one undo step; the kept words fold like any cut.
        undo.beginUndoGrouping()
        model.keepFocusedChange()
        undo.endUndoGrouping()
        pane.update()
        check("Keep applies a cut as one undo step, \"\(undo.undoActionName)\", and its words fold",
              undo.undoActionName == "Keep change 3" && model.cutWordIDs.isSuperset(of: (78...86).map(id)) && text.map.span(id: id(78))?.kind == .fold && spans(3).isEmpty
              && model.proposalDisplay?.focused == 4)
        undo.undo()
        pane.update()
        check("undoing the Keep shows the change again, pending", model.proposalDisplay?.shown(3)?.state == .pending && !spans(3).isEmpty)
        // Keep on a voice change includes it for takes: no project change, no undo step, no bar.
        let kept = model.project
        model.keepChange(1)
        pane.update()
        check("Keep on a voice change includes it for takes with no project change or undo step, and its bar goes",
              model.project == kept && !undo.canUndo && model.proposal?[1]?.state == .kept && !spans(1).isEmpty && spans(1).allSatisfy { $0.change?.pending == false })
        // Keep All: every free change still pending applies as one undo step named for the scope.
        undo.beginUndoGrouping()
        model.keepAllChanges()
        undo.endUndoGrouping()
        pane.update()
        check("Keep All applies the free changes as one step, \"\(undo.undoActionName)\", and includes the voice ones",
              undo.undoActionName == "Rewrite clip 1" && model.cutWordIDs.contains(id(91)) && model.proposal?[5]?.state == .kept && model.proposal?[2]?.state == .excluded
              && !model.hasUnreviewedChanges(clipID: "hunk-clip"))
        undo.undo()
        pane.update()
        check("one undo takes Keep All back: the cuts return and the voice changes wait again",
              !model.cutWordIDs.contains(id(91)) && model.proposal?[5]?.state == .pending && model.proposal?[1]?.state == .kept && model.hasUnreviewedChanges(clipID: "hunk-clip"))
        undo.redo()
        check("and one redo keeps them all again", model.cutWordIDs.contains(id(91)) && model.proposal?[5]?.state == .kept)
        model.undoManager = nil

        // The edit popover holds the change's words; saving rediffs it locally and sends nothing.
        model.proposal = proposal(for: model)
        pane.update(rebuild: true)
        pane.scroll(toCharacter: 0)
        text.showChangePopover(1)
        if let popover = text.changePopoverAuditView, let range = renderer.changeRange(1), let line = text.lineBox(atCharacter: NSMaxRange(range) - 1) {
            bitmap = try pane.bitmap("v2-transcript-hunk-popover-dark", directory: directory)
            check("the edit popover opens under the change with its new words (\(model.changeText(1)))", popover.frame.minY >= line.maxY && model.changeText(1) == "your source directory in the")
        } else { check("the edit popover opens", false) }
        text.hideChangePopover(refocus: false)
        model.editChange(1, text: "")
        check("emptying a voice change's words turns it into a cut", model.proposal?[1]?.kind == .cut && model.proposal?[1]?.parts.first?.sourceWordIDs == (32...36).map(id))
        return results
    }
}

/// A transcript pane as the editor builds it, in an offscreen window that is never shown.
@MainActor final class TranscriptPane {
    let model: EditorModel
    let coordinator: TranscriptTextView.Coordinator
    let scroll: TranscriptScrollView
    let text: TranscriptNSTextView
    let window: NSWindow
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
        // As updateNSView: the text's own selection changes during the update are not the user's.
        coordinator.updating = true
        defer { coordinator.updating = false }
        TranscriptTextView.render(model, coordinator: coordinator, force: rebuild)
        scroll.overviewRuler.marks = TranscriptOverviewRuler.marks(model: model)
        TranscriptTextView.select(model: model, in: text)
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
    /// The laid-out line holding a character, its fragment and the fragment's first character.
    func line(atCharacter offset: Int) -> (NSTextLayoutFragment, NSTextLineFragment, Int)? {
        guard let manager = text.textLayoutManager, let content = manager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset), let fragment = manager.textLayoutFragment(for: location),
              let element = fragment.textElement?.elementRange else { return nil }
        let base = content.offset(from: content.documentRange.location, to: element.location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(offset - base, $0.characterRange) }) else { return nil }
        return (fragment, line, base)
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
    /// Of the pixel columns from `left` to `right`, those with a pixel within a point of `row`
    /// that is `ink` laid over `paper` at 40 % or more. A 1 pt line off the pixel grid fills no
    /// pixel row at 1x, as on the hosted CI runner, so none of its pixels holds the exact colour.
    func inkedColumns(_ bitmap: NSBitmapImageRep, left: CGFloat, right: CGFloat, row: CGFloat, ink: NSColor, paper: NSColor) -> (inked: Int, of: Int) {
        let step = 1 / scale(bitmap)
        let direction: [CGFloat] = [ink.redComponent - paper.redComponent, ink.greenComponent - paper.greenComponent, ink.blueComponent - paper.blueComponent]
        let magnitude: CGFloat = direction.reduce(0) { $0 + $1 * $1 }
        guard magnitude > 0 else { return (0, 0) }
        func inked(_ pixel: NSColor) -> Bool {
            let difference: [CGFloat] = [pixel.redComponent - paper.redComponent, pixel.greenComponent - paper.greenComponent, pixel.blueComponent - paper.blueComponent]
            let coverage: CGFloat = zip(difference, direction).reduce(0) { $0 + $1.0 * $1.1 } / magnitude
            return coverage >= 0.4 && coverage <= 1.1 && zip(difference, direction).allSatisfy { abs($0 - $1 * coverage) < 0.06 }
        }
        var columns = 0, total = 0
        for x in stride(from: left + step / 2, to: right, by: step) {
            let rows = stride(from: row - 1 + step / 2, to: row + 1, by: step)
            if rows.contains(where: { y in pixel(bitmap, CGPoint(x: x, y: y)).map(inked) == true }) { columns += 1 }
            total += 1
        }
        return (columns, total)
    }
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
