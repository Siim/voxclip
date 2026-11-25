import SwiftUI

@MainActor struct StoryOutlineRow: View {
    let shell: WorkspaceShell
    let editor: EditorModel
    let entry: ExplorerOutlineEntry
    @State private var dropTarget = false

    private var partID: String { entry.partID ?? "" }
    private var selected: Bool { editor.selectedStoryPartIndex == entry.id }
    private var editable: Bool { editor.capabilities.edit }
    private var partCount: Int { editor.activeClip?.playParts.count ?? 0 }
    private var dragPrefix: String { "voxclip-part/\(editor.project.id)/\(editor.activeClip?.id ?? "")/" }

    var body: some View {
        HStack(spacing: 5) {
            if editable {
                grip.onDrag {
                    editor.draggedStoryPartID = partID
                    return NSItemProvider(object: (dragPrefix + partID) as NSString)
                }
            } else { grip }
            Text("\(entry.id + 1)").font(DesignValues.mono(10)).bold().foregroundStyle(.black)
                .frame(width: 17, height: 17)
                .background(StoryClipPresentation.color(entry.id), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
            Text(entry.title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Text(entry.time).font(DesignValues.mono(10)).fixedSize().foregroundStyle(.secondary).accessibilityHidden(true)
            removeButton
        }
        .padding(.horizontal, 3).frame(height: ExplorerMetrics.rowHeight)
        .background(selected ? Color.secondary.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in acceptDrop(items.first) } isTargeted: { dropTarget = $0 }
        .overlay(alignment: dropAtBottom ? .bottom : .top) {
            if dropTarget, editable, let dragged = editor.draggedStoryPartID, dragged != partID {
                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Play Part \(entry.id + 1)") { editor.playStoryPart(at: entry.id) }
        .accessibilityAction(named: "Show in Take") { shell.showStoryPartInTake(entry) }
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.secondary)
            .frame(width: 12).help("Drag to move part").accessibilityHidden(true)
    }

    private var removeButton: some View {
        Button { editor.removeStoryPart(partID) } label: {
            Image(systemName: "xmark").font(.system(size: 9)).frame(width: 13, height: 18)
        }
        .buttonStyle(.borderless).disabled(!editable || partCount <= 1)
        .help(partCount <= 1 ? StoryClipPresentation.removeReason : "Remove Part (⌫)")
        .accessibilityLabel("Remove Part \(entry.id + 1)")
    }

    private var dropAtBottom: Bool {
        guard let source = editor.activeClip?.playParts.firstIndex(where: { $0.id == editor.draggedStoryPartID }) else { return false }
        return source < entry.id
    }

    private func acceptDrop(_ item: String?) -> Bool {
        defer { editor.draggedStoryPartID = nil }
        guard editable, let item, item.hasPrefix(dragPrefix) else { return false }
        let id = String(item.dropFirst(dragPrefix.count))
        guard id != partID, editor.activeClip?.playParts.contains(where: { $0.id == id }) == true else { return false }
        editor.moveStoryPart(id, to: entry.id)
        return true
    }
}

@MainActor struct StoryOutlineMenu: View {
    let shell: WorkspaceShell
    let editor: EditorModel
    let entry: ExplorerOutlineEntry

    var body: some View {
        if let id = entry.partID, let parts = editor.activeClip?.parts {
            Button("Play Part \(entry.id + 1)") { editor.playStoryPart(at: entry.id) }
            Button("Show in Take") { shell.showStoryPartInTake(entry) }
            Divider()
            Button("Move Up") { editor.moveStoryPart(id, to: entry.id - 1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(entry.id == 0 || !editor.capabilities.edit)
            Button("Move Down") { editor.moveStoryPart(id, to: entry.id + 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(entry.id + 1 == parts.count || !editor.capabilities.edit)
            Button("Make Clip of This Part") { editor.makeClipsOfStoryParts([id]) }.disabled(!editor.capabilities.edit)
            Divider()
            Button("Remove Part") { editor.removeStoryPart(id) }
                .disabled(parts.count <= 1 || !editor.capabilities.edit)
                .help(parts.count <= 1 ? StoryClipPresentation.removeReason : "Remove Part (⌫)")
        }
    }
}

@MainActor struct StoryOutlineAdd: View {
    let editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { editor.addSelectionAsStoryPart() } label: { Label("Add Selection as Part", systemImage: "plus") }
                .disabled(editor.addStoryPartReason != nil)
            if let reason = editor.storyPartError ?? editor.addStoryPartReason {
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
