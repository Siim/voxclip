import AppKit
import SwiftUI
import VoxClipCore

enum RecordingTranscriptChoice: Equatable {
    case playOrder, all, recording(String)
}

@MainActor enum RecordingPresentation {
    static func color(_ region: ProjectClock.Region) -> Color { Color(nsColor: nsColor(region)) }

    static func nsColor(_ region: ProjectClock.Region, alternate: Bool = false) -> NSColor {
        let base = DesignValues.nsColor("recording.\(region.colourIndex + 1)")
        return alternate ? base.withAlphaComponent(0.70) : base
    }
}

@MainActor struct RecordingLabel: View {
    let region: ProjectClock.Region

    var body: some View {
        Label { Text(region.label) } icon: {
            Circle().fill(RecordingPresentation.color(region)).frame(width: 6, height: 6)
        }
        .font(DesignValues.mono(10))
        .lineLimit(1)
    }
}

extension EditorModel {
    var recordingRegions: [ProjectClock.Region] { recordingClock?.regions ?? [] }
    var hasSeveralRecordings: Bool { recordingRegions.count > 1 }

    var storyRecordingRegions: [ProjectClock.Region] {
        guard hasSeveralRecordings else { return [] }
        let keys = Set(activeClip?.playParts.compactMap { recordingClock?.region(of: $0.startWordId)?.key } ?? [])
        return recordingRegions.filter { keys.contains($0.key) }
    }

    var storyRecordingHeading: String? {
        let regions = storyRecordingRegions
        guard let clip = activeClip, regions.count > 1 else { return nil }
        let labels = ListFormatter.localizedString(byJoining: regions.map(\.label))
        return "\(scopeName(clip.id)) · \(clip.playParts.count) parts · from \(labels)"
    }

    var partPickRecording: ProjectClock.Region? { recordingRegions.first { $0.key == partPickKey } }

    var transcriptRecordingScope: RecordingTranscriptChoice {
        if let choice = recordingTranscriptChoice {
            switch choice {
            case .recording(let key) where recordingRegions.contains(where: { $0.key == key }): return choice
            case .all: return choice
            case .playOrder where storyRecordingRegions.count > 1: return choice
            default: break
            }
        }
        if storyRecordingRegions.count > 1 { return .playOrder }
        return storyRecordingRegions.first.map { .recording($0.key) } ?? .all
    }

    func chooseRecordingTranscript(_ choice: RecordingTranscriptChoice, scrollTo wordID: String? = nil) {
        recordingTranscriptChoice = choice
        outlineScrollWordID = wordID
        scopeScrollRevision += 1
        if case .recording(let key) = choice, let index = recordingRegions.firstIndex(where: { $0.key == key }) {
            announce("Showing recording \(recordingRegions[index].label), \(index + 1) of \(recordingRegions.count)")
        }
    }

    func recordingVoiceRegion(for scope: RewriteScope? = nil) -> ProjectClock.Region? {
        guard hasSeveralRecordings else { return nil }
        if scope == nil, let region = selectedIDs.lazy.compactMap({ self.recordingClock?.region(of: $0) }).first(where: { !$0.prefix.isEmpty }) {
            return region
        }
        if case .fullTake = scope { return recordingRegions.dropFirst().first }
        let clip: ClipRange?
        if case .clip(let id) = scope { clip = project.edits.clips.first { $0.id == id } }
        else { clip = activeClip }
        return clip?.playParts.lazy.compactMap { self.recordingClock?.region(of: $0.startWordId) }.first { !$0.prefix.isEmpty }
    }

    func recordingVoiceReason(for scope: RewriteScope? = nil) -> String? {
        guard let first = recordingRegions.first, let other = recordingVoiceRegion(for: scope) else { return nil }
        return "Voice changes work on \(first.label)'s words for now. Open \(other.label) on its own to change its voice."
    }
}
