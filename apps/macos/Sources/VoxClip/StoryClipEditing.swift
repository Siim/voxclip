import AppKit
import SwiftUI
import VoxClipCore

func storyTakeTime(_ seconds: Double) -> String { durationLabel(seconds.rounded(.down)) }

enum StoryClipPresentation {
    static func metadata(_ clip: ClipRange, editedDuration: Double) -> (badge: String?, length: String) {
        let badge = clip.parts.map { clip.kind == .showreel ? "reel" : "\($0.count) parts" }
        return (badge, durationLabel(editedDuration))
    }

    static let addReason = "Select words outside the clip's parts to add them."
    static let removeReason = "A clip needs one part. Remove Clip instead."
    static let rewriteReason = "Voice changes work on one part at a time. Make a clip of the part first."

    static func lipSyncReason(partCount: Int) -> String {
        let seams = partCount - 1
        return "Lip sync can't run across the \(seams) \(seams == 1 ? "seam" : "seams") of a story clip yet. Make a clip of the part first."
    }

    static func color(_ index: Int) -> Color { Color(nsColor: nsColor(index)) }

    static func nsColor(_ index: Int) -> NSColor {
        let colors: [UInt32] = [0x5aa9ff, 0xb48cff, 0x5fd3a8, 0xffb35c, 0xff7aa8, 0x9ad25a]
        let rgb = colors[index % colors.count]
        return NSColor(srgbRed: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }
}

extension EditorModel {
    func storyClip(for scope: RewriteScope?) -> ClipRange? {
        let clip: ClipRange?
        if case .clip(let id) = scope { clip = project.edits.clips.first { $0.id == id } }
        else if case .fullTake = scope { clip = nil }
        else { clip = activeClip }
        return clip?.parts == nil ? nil : clip
    }

    func storyRewriteReason(for scope: RewriteScope? = nil) -> String? {
        storyClip(for: scope) == nil ? nil : StoryClipPresentation.rewriteReason
    }

    var selectedStoryPartIndex: Int {
        guard let parts = activeClip?.parts else { return 0 }
        if let id = selectedStoryPartID, let position = parts.firstIndex(where: { $0.id == id }) { return position }
        if let word = selectedIDs.first, let position = index(word),
           let ranges = activeClip?.playPartIndices(in: words), let part = ranges.firstIndex(where: { $0.contains(position) }) { return part }
        return 0
    }

    private var partSelection: ClosedRange<Int>? {
        guard let lower = selectedIDs.first.flatMap({ index($0) }),
              let upper = selectedIDs.last.flatMap({ index($0) }),
              selectedWordIDs.count == upper - lower + 1,
              let ranges = activeClip?.playPartIndices(in: words) else { return nil }
        let span = lower...upper
        return ranges.contains { $0.overlaps(span) } ? nil : span
    }

    var addStoryPartReason: String? {
        if !capabilities.edit { return "This clip is read-only." }
        if let clip = activeClip, clip.playParts.count >= 12 { return "A clip can have up to 12 parts." }
        return partSelection == nil ? StoryClipPresentation.addReason : nil
    }

    func addSelectionAsStoryPart() {
        guard addStoryPartReason == nil, let clip = activeClip, let span = partSelection else { return }
        let part = ClipPart(id: UUID().uuidString.lowercased(), startWordId: words[span.lowerBound].id, endWordId: words[span.upperBound].id)
        let parts = clip.playParts + [part]
        if editStoryParts(clip, parts: parts, name: "Add part", message: "Part \(parts.count) added.") {
            selectedStoryPartID = part.id
        }
    }

    func moveStoryPart(_ id: String, to destination: Int) {
        guard let clip = activeClip, var parts = clip.parts, parts.indices.contains(destination),
              let source = parts.firstIndex(where: { $0.id == id }), source != destination else { return }
        parts.insert(parts.remove(at: source), at: destination)
        if editStoryParts(clip, parts: parts, name: "Move part", message: "Part \(source + 1) moved to \(destination + 1) of \(parts.count)") {
            selectedStoryPartID = id
        }
    }

    func removeStoryPart(_ id: String) {
        guard let clip = activeClip, var parts = clip.parts, parts.count > 1,
              let source = parts.firstIndex(where: { $0.id == id }) else { return }
        parts.remove(at: source)
        if editStoryParts(clip, parts: parts, name: "Remove part", message: "Part \(source + 1) removed.") {
            if selectedStoryPartID == id { selectedStoryPartID = parts[min(source, parts.count - 1)].id }
        }
    }

    func trimStoryPart(start: Bool, at position: Int) {
        guard let clip = activeClip, var parts = clip.parts, words.indices.contains(position),
              let ranges = clip.playPartIndices(in: words) else { return }
        let selected = selectedStoryPartIndex
        let old = ranges[selected]
        guard start ? position <= old.upperBound : position >= old.lowerBound else { return }
        let span = start ? position...old.upperBound : old.lowerBound...position
        guard !ranges.enumerated().contains(where: { $0.offset != selected && $0.element.overlaps(span) }) else {
            storyPartError = "Parts can't overlap."
            announce(storyPartError ?? "")
            return
        }
        if start { parts[selected].startWordId = words[position].id }
        else { parts[selected].endWordId = words[position].id }
        _ = editStoryParts(clip, parts: parts, name: "Trim part", message: "Part \(selected + 1) trimmed.")
    }

    func makeClipsOfStoryParts(_ partIDs: [String]) {
        guard capabilities.edit, let clip = activeClip, clip.parts != nil, !partIDs.isEmpty else { return }
        var next = project
        do {
            for id in partIDs { try next.applyEditing(.makeClipOfPart(clipId: clip.id, partId: id)) }
            guard next != project else { return }
            let count = next.edits.clips.count - project.edits.clips.count
            replace(next, name: count == 1 ? "Make clip of part" : "Make clips of parts")
            announce(count == 1 ? "Clip made." : "\(count) clips made.")
        } catch { reportStoryPartError(error) }
    }

    func playStoryPart(at position: Int) {
        guard let clip = activeClip, let parts = clip.parts, parts.indices.contains(position),
              let lower = index(parts[position].startWordId), let upper = index(parts[position].endWordId),
              let timeline = renderTimeline,
              let first = timelinePieces.pieces.first(where: { $0.source.overlaps(words[lower].start..<words[upper].end) }),
              let last = timelinePieces.pieces.last(where: { $0.source.overlaps(words[lower].start..<words[upper].end) }) else { return }
        selectedStoryPartID = parts[position].id
        Task {
            do {
                try await preview.seek(to: first.edited.lowerBound, exact: true)
                guard activeClip?.id == clip.id else { return }
                playhead = first.edited.lowerBound
                sourceTime = timeline.sourceTime(playhead)
                storyPartPlaybackEnd = last.edited.upperBound
                preview.play()
                isPlaying = preview.isPlaying
            } catch { previewError = await app.safeError(error, context: .preview) }
        }
    }

    private func editStoryParts(_ clip: ClipRange, parts: [ClipPart], name: String, message: String) -> Bool {
        guard capabilities.edit else { return false }
        storyPartError = nil
        do {
            var next = project
            try next.applyEditing(.setClipParts(id: clip.id, parts: parts))
            guard next != project else { return false }
            let copy = next.edits.activeClipId != clip.id
            preview.pause()
            isPlaying = false
            replace(next, name: name)
            announce(copy ? "\(message) Made a story copy and kept the original voice work." : message)
            return true
        } catch {
            reportStoryPartError(error)
            return false
        }
    }

    private func reportStoryPartError(_ error: any Error) {
        let message: String
        if case VoxClipError.projectUnreadable(let reason) = error { message = reason }
        else { message = "Couldn't change the clip's parts." }
        storyPartError = message
        announce(message)
    }
}
