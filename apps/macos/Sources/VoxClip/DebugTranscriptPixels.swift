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
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 640, height: 160)
        text.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isEditable = false; text.isSelectable = false; text.drawsBackground = true
        text.model = model
        text.textLayoutManager?.delegate = coordinator
        coordinator.text = text; coordinator.renderer.text = text
        let renderer = coordinator.renderer
        text.textLayoutManager?.renderingAttributesValidator = { [weak renderer] _, fragment in MainActor.assumeIsolated { renderer?.validate(fragment) } }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = text
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
        results.append(.init(name: "transcript uses the system font at 19 pt", passed: storedFont?.familyName == NSFont.systemFont(ofSize: 19).familyName && storedFont?.pointSize == 19))
        results.append(.init(name: "transcript lines are 32 high with an 18 paragraph gap", passed: style?.minimumLineHeight == 32 && style?.maximumLineHeight == 32 && style?.paragraphSpacing == 18 && abs(line.typographicBounds.height - 32) < 0.5))
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
        pageProject.edits.clips = [ClipRange(id: "pixel-clip", startWordId: "pixel-low", endWordId: "pixel-playing", title: "Pixel clip")]
        model.document.replaceProject(pageProject)
        model.refresh()
        renderer.rebuild(model: model)
        var pageState = TranscriptAppearance(cutWords: model.cutWordIDs, scope: 0...0)
        renderer.update(pageState)
        let decorations = text.map.spans.filter { !$0.selectable }
        let selected = text.map.selectionRanges(in: NSRange(location: 0, length: text.string.utf16.count))
        let avoidsDecorations = decorations.allSatisfy { decoration in selected.allSatisfy { NSIntersectionRange($0, decoration.range).length == 0 } }
        results.append(.init(name: "word-snapped selection excludes clip badge and end-bracket placeholders", passed: decorations.count == 2 && avoidsDecorations && text.map.span(at: decorations[0].range.location)?.selectable == true))
        let copied = selected.flatMap { text.map.intersecting($0).filter(\.selectable) }.filter { !$0.pause }.map { (text.string as NSString).substring(with: $0.range) }.joined(separator: " ")
        results.append(.init(name: "Copy Text's word map never includes a badge or bracket", passed: !copied.contains(" ") && !copied.contains("]") && copied.contains("uncertain")))
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
                let badgePixels = opaquePixels(bitmap, rect: rect("clip-start:pixel-clip"), size: text.bounds.size, color: DesignValues.nsColor("clip.badgeBackground"))
                let scopedPixels = opaquePixels(bitmap, rect: rect("pixel-low"), size: text.bounds.size, color: DesignValues.nsColor("text.secondary"))
                let strikePixels = opaquePixels(bitmap, rect: rect("pixel-cut"), size: text.bounds.size, color: DesignValues.nsColor("cut.stroke"))
                if let pause = model.pauses.first {
                    let pausePixels = opaquePixels(bitmap, rect: rect(pause.id), size: text.bounds.size, color: DesignValues.nsColor("pause.background"), patch: 3)
                    results.append(.init(name: "\(name) \(pauseCut ? "cut" : "uncut") pause bitmap \(pauseCut ? "paints" : "has no") chip fill (\(pausePixels) pixels)", passed: pauseCut ? pausePixels >= 8 : pausePixels == 0))
                }
                results.append(.init(name: "\(name) clip badge paints clip.badgeBackground over the page (\(badgePixels) pixels)", passed: badgePixels >= 8))
                results.append(.init(name: "\(name) out-of-scope glyphs paint opaque text.secondary (\(scopedPixels) pixels)", passed: scopedPixels >= 3))
                results.append(.init(name: "\(name) cut strike matches cut.stroke within three channels (\(strikePixels) pixels)", passed: strikePixels >= 3))
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent("transcript-page-\(name)-\(pauseCut ? "cut" : "uncut")-pause.png")) }
            }
            }
        }
        try JSONEncoder().encode(probes).write(to: directory.appendingPathComponent("transcript-decoration-pixels.json"))
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
#endif
