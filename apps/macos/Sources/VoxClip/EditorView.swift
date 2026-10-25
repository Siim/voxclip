import SwiftUI
import Observation
import VoxClipCore

/// Per-window main-actor state; architecture §7.1. Algorithms are injected by the owning tracks.
@MainActor @Observable public final class EditorModel {
    public var showInspector = true
    public var playhead: Double = 0
    public var selectedWordIDs: Set<String> = []
    public init() {}
}

/// Planned editor regions; design §3.2. Empty content deliberately makes no media or transcription claims.
@MainActor public struct EditorView: View {
    @ObservedObject private var document: VoxClipDocument
    @State private var model = EditorModel()
    public init(document: VoxClipDocument) { self.document = document }
    public var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                RegionPlaceholder(title: "Transcript", symbol: "text.alignleft", detail: "Your words will appear here.")
                    .frame(minWidth: 340)
                RegionPlaceholder(title: "Preview", symbol: "play.rectangle", detail: "Your video will appear here.")
                    .frame(minWidth: 260)
            }
            Divider()
            HStack {
                Label("Timeline", systemImage: "waveform")
                Spacer()
                Text("No video imported").foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .frame(height: 56)
            .accessibilityElement(children: .combine)
        }
        .inspector(isPresented: $model.showInspector) {
            RegionPlaceholder(title: "Inspector", symbol: "slider.horizontal.3", detail: "Captions and Clips")
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .navigationTitle(document.project.title ?? "Untitled")
        .toolbar {
            Button("Inspector", systemImage: "sidebar.right") { model.showInspector.toggle() }
                .help("Show or hide the inspector")
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

@MainActor private struct RegionPlaceholder: View {
    let title: String
    let symbol: String
    let detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
