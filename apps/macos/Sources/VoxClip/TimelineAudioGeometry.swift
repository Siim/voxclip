import AppKit
import VoxClipCore

struct TimelineDuckingContour: Equatable {
    let gains: [Double]
    let timing: ClipSpeedTiming

    func db(at editedTime: Double) -> Double {
        20 * log10(MusicMix.duckFactor(gains, at: timing.rendered(editedTime)))
    }
}

struct TimelineMusicGraphics: Equatable {
    var contour: TimelineDuckingContour? = nil
    var usesFallback = true
    var fades: [String: TimeRange] = [:]
    var loops: [String: [Double]] = [:]
}

extension EditorModel {
    func timelineMusicGraphics(track: ProjectMusic, plan: EditPlan, staged: TimelineDuckingContour?) -> TimelineMusicGraphics {
        let timeline = RenderTimeline.legacy(plan)
        let timing = staged?.timing ?? ClipSpeedTiming(speed: currentClipControls?.speed ?? 1,
            timeline: timeline, effects: ClipEffects.rendered(in: project, clipID: itemEditScope))
        let duration = timing.rendered(plan.duration)
        let contour: TimelineDuckingContour
        if let staged { contour = staged }
        else if track.ducking, duration > 0 {
            let step = MusicMix.frameSeconds
            var activity = [Bool](repeating: false, count: Int(ceil(duration / step)))
            for word in words where !cutWordIDs.contains(word.id) {
                let first = max(0, Int(ceil(timing.rendered(plan.mapTime(word.start)) / step - 0.5)))
                let end = min(activity.count, Int(ceil(timing.rendered(plan.mapTime(word.end)) / step - 0.5)))
                if first < end { for index in first..<end { activity[index] = true } }
            }
            contour = .init(gains: MusicMix.duckingGainsDb(activity: activity, depthDb: track.duckDb ?? MusicMix.duckDb), timing: timing)
        } else { contour = .init(gains: [], timing: timing) }
        var graphics = TimelineMusicGraphics(contour: contour, usesFallback: staged == nil)
        let rate = 48_000.0
        let entries = track.segments ?? [.init(id: track.id, anchorSeconds: plan.sourceTime(0), lengthSeconds: duration,
                                                songFromSeconds: track.startOffsetSeconds, loop: true,
                                                fadeInSeconds: track.fadeInSeconds, fadeOutSeconds: track.fadeOutSeconds)]
        let placements = MusicMix.segmentPieces(entries, trackFrames: Int((track.asset.durationSeconds * rate).rounded()),
                                                outputFrames: Int((duration * rate).rounded()), rate: rate) {
            timing.rendered(plan.mapTime($0))
        }
        for placement in placements {
            let id = placement.segment.id, span = placement.span
            func edited(_ frame: Int) -> Double { timing.edited(Double(frame) / rate) }
            if span.fadeIn > 0 {
                graphics.fades[id] = .init(start: edited(span.outputStart), end: edited(span.outputStart + span.fadeIn))
            }
            graphics.loops[id] = placement.pieces.dropFirst().compactMap { piece in
                piece.outputStart < span.count ? edited(span.outputStart + piece.outputStart) : nil
            }
        }
        return graphics
    }
}

extension TimelineItemFragment {
    var volumeTop: Double { rect.minY + min(10, rect.height / 3) }
    var volumeBottom: Double { rect.maxY - min(4, rect.height / 5) }
    var dbPerPoint: Double { 46 / max(1, volumeBottom - volumeTop) }

    func volumeY(_ db: Double) -> Double {
        (volumeTop + (6 - db) / dbPerPoint).clamped(to: volumeTop...volumeBottom)
    }

    private func fraction(atX x: Double) -> Double { ((x - rect.minX) / (rect.width + 1)).clamped(to: 0...1) }

    func editedTime(atX x: Double) -> Double {
        let edited = audioRange ?? range
        return edited.start + fraction(atX: x) * (edited.end - edited.start)
    }

    func audioX(at editedTime: Double) -> Double {
        let edited = audioRange ?? range
        return rect.minX + (rect.width + 1) * ((editedTime - edited.start) / max(0.00001, edited.end - edited.start)).clamped(to: 0...1)
    }

    func volumeDb(at editedTime: Double) -> Double {
        guard let audio = display.audio else { return 0 }
        let start = display.item.editedIntervals.first?.start ?? editedTime
        return audio.gainDb + MusicMix.envelopeDb(at: editedTime - start, points: audio.points)
    }

    var volumePoints: [(gain: GainPoint, center: NSPoint)] {
        guard let audio = display.audio, let start = display.item.editedIntervals.first?.start else { return [] }
        let edited = audioRange ?? range
        return audio.points.compactMap { point in
            let time = start + point.t
            guard edited.start - 1e-8 <= time, time <= edited.end + 1e-8 else { return nil }
            return (point, NSPoint(x: audioX(at: time), y: volumeY(audio.gainDb + point.db)))
        }
    }

    func volumeHit(_ point: NSPoint) -> Bool {
        display.audio != nil && abs(point.y - volumeY(volumeDb(at: editedTime(atX: point.x)))) <= 3
    }

    func volumePoint(at point: NSPoint) -> (gain: GainPoint, center: NSPoint)? {
        volumePoints.first { hypot(point.x - $0.center.x, point.y - $0.center.y) <= 5 }
    }

    func duckingY(atX x: Double, contour: TimelineDuckingContour) -> Double {
        let time = editedTime(atX: x)
        return volumeY(volumeDb(at: time) + contour.db(at: time))
    }

    func drawVolume(in context: CGContext, clip: NSRect, contour: TimelineDuckingContour? = nil) {
        guard let audio = display.audio, !display.item.hidden else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        let visible = rect.intersection(clip)
        if audio.music != nil, let contour, !contour.gains.isEmpty, !visible.isEmpty {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1)
            context.move(to: NSPoint(x: visible.minX, y: duckingY(atX: visible.minX, contour: contour)))
            for x in stride(from: visible.minX + 1, to: visible.maxX, by: 1) {
                context.addLine(to: NSPoint(x: x, y: duckingY(atX: x, contour: contour)))
            }
            context.addLine(to: NSPoint(x: visible.maxX, y: duckingY(atX: visible.maxX, contour: contour)))
            context.strokePath()
        }
        context.setStrokeColor(NSColor.systemYellow.cgColor)
        context.setFillColor(NSColor.systemYellow.cgColor)
        context.setLineWidth(1.5)
        let edited = audioRange ?? range
        context.move(to: NSPoint(x: rect.minX, y: volumeY(volumeDb(at: edited.start))))
        for point in volumePoints { context.addLine(to: point.center) }
        context.addLine(to: NSPoint(x: rect.maxX, y: volumeY(volumeDb(at: edited.end))))
        context.strokePath()
        for point in volumePoints {
            context.fillEllipse(in: NSRect(x: point.center.x - 3, y: point.center.y - 3, width: 6, height: 6))
        }
    }

    func drawAudioFades(in context: CGContext) {
        guard display.audio != nil, let fades = display.fades else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        for edge: TimelineEdge in [.start, .end] where fades[edge] > 0 {
            guard let dot = fadeGrip(edge) else { continue }
            let x = edge == .start ? rect.minX : rect.maxX
            context.move(to: NSPoint(x: x, y: rect.maxY))
            context.addLine(to: NSPoint(x: x, y: rect.minY))
            context.addLine(to: NSPoint(x: dot.midX, y: rect.minY))
            context.closePath()
            context.fillPath()
        }
    }
}
