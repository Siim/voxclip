import AppKit
import VoxClipCore

extension TimelineCanvasView {
    func layoutItemAccessibility() {
        let visible = Dictionary(grouping: itemFragments, by: \.display.item.id)
        itemAXElements = itemAXElements.filter { visible[$0.key] != nil }
        itemAXEdges = itemAXEdges.filter { visible[$0.key] != nil }
        for lane in TimelineItemLane.allCases {
            let items = content.items.filter { $0.item.lane == lane && visible[$0.item.id] != nil }
            guard !items.isEmpty else { itemAXGroups.removeValue(forKey: lane); continue }
            let group = itemAXGroups[lane] ?? NSAccessibilityElement()
            group.setAccessibilityRole(.group)
            group.setAccessibilityLabel(lane.title.replacingOccurrences(of: "&", with: "and") + " lane")
            group.setAccessibilityParent(self)
            var children: [Any] = []
            for item in items {
                let id = item.item.id
                guard let fragments = visible[id] else { continue }
                let frame = fragments.reduce(NSRect.null) { $0.union($1.rect.intersection(itemClip)) }
                let element = itemAXElements[id] ?? TimelineSliderElement()
                element.setAccessibilityParent(group)
                element.setAccessibilityIdentifier("voxclip.timeline.item.\(id.value)")
                element.setAccessibilityFrameInParentSpace(frame)
                element.setAccessibilityLabel(item.accessibilityLabel(selected: model.timelineItemSelection.contains(id)))
                element.read = { [weak self] in
                    let start = item.ranges.first?.start ?? item.marker ?? 0
                    return (start, 0...max(0, self?.content.length ?? 0), item.item.reason ?? timelineItemTime(start))
                }
                element.adjust = { [weak self] up in self?.adjustAccessibleItem(id, up: up) }
                element.setAccessibilityCustomActions(itemAccessibilityActions(item))
                itemAXElements[id] = element
                children.append(element)
                if item.movable, !item.item.hidden, model.capabilities.edit {
                    children += accessibleItemEdges(item, fragments: fragments, parent: group)
                }
            }
            group.setAccessibilityChildren(children)
            itemAXGroups[lane] = group
        }
    }

    private func adjustAccessibleItem(_ id: TimelineItemID, up: Bool) {
        guard let item = content.items.first(where: { $0.item.id == id }), item.movable else { return }
        let original = item.item.sourceAnchor
        model.nudgeTimelineItems([id], by: .words(up ? 1 : -1))
        renderContent(keepingZoom: true)
        guard let moved = content.items.first(where: { $0.item.id == id }), moved.item.sourceAnchor != original else { return }
        let delta = (moved.ranges.first?.start ?? moved.item.sourceAnchor) - (item.ranges.first?.start ?? original)
        let word = model.word(at: moved.item.sourceAnchor, nearest: true).map { ", now on \(model.text($0))" } ?? ""
        model.announce("\(item.kind) moved \(delta < 0 ? "earlier" : "later") by \(String(format: "%.1f", abs(delta))) seconds\(word).")
    }

    private func accessibleItemEdges(_ item: TimelineItemDisplay, fragments: [TimelineItemFragment], parent: NSAccessibilityElement) -> [TimelineSliderElement] {
        let id = item.item.id
        let edges = itemAXEdges[id] ?? [TimelineSliderElement(), TimelineSliderElement()]
        itemAXEdges[id] = edges
        return zip([TimelineEdge.start, .end], edges).compactMap { edge, element in
            let fragment = fragments.first { edge == .start ? $0.hasStart : $0.hasEnd }
            guard let fragment else { return nil }
            let frame = fragment.grip(edge).intersection(itemClip)
            guard !frame.isEmpty else { return nil }
            let time = edge == .start ? fragment.range.start : fragment.range.end
            element.setAccessibilityParent(parent)
            element.setAccessibilityLabel("\(item.kind) \(edge.rawValue)")
            element.setAccessibilityFrameInParentSpace(frame)
            element.read = { [weak self] in (time, 0...max(0, self?.content.length ?? 0), timelineItemTime(time)) }
            element.adjust = { [weak self] up in self?.adjustAccessibleEdge(id, edge: edge, up: up) }
            return element
        }
    }

    private func adjustAccessibleEdge(_ id: TimelineItemID, edge: TimelineEdge, up: Bool) {
        guard let span = model.timelineItemSpan(id) else { return }
        let time = edge == .start ? span.lowerBound : span.upperBound
        let edges = model.words.lazy.map { edge == .start ? $0.start : $0.end }
        let next = up ? edges.first { $0 > time + 0.0001 } : edges.last { $0 < time - 0.0001 }
        guard let next else { return }
        model.commitTimelineItemEdit(.trim(item: id, edge: edge, toSource: next))
        renderContent(keepingZoom: true)
    }

    private func itemAccessibilityActions(_ item: TimelineItemDisplay) -> [NSAccessibilityCustomAction] {
        let id = item.item.id
        func action(_ title: String, _ perform: @escaping @MainActor (TimelineCanvasView) -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: title) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    perform(self)
                    self.renderContent(keepingZoom: true)
                    return true
                }
            }
        }
        var actions = [action("Select item") { $0.selectAndRevealItem(item) }]
        switch id {
        case .effect, .footage, .motion, .music: actions.append(action("Open editor") { $0.openItem(id) })
        default: break
        }
        guard item.movable, model.capabilities.edit else { return actions }
        if item.hasHiddenWords {
            actions.append(action("Restore Words") { $0.model.restoreTimelineWords(item) })
        }
        actions += [
            action("Move earlier a frame") { $0.model.nudgeTimelineItems([id], by: .frames(-1)) },
            action("Move later a frame") { $0.model.nudgeTimelineItems([id], by: .frames(1)) },
            action("Trim start to playhead") { $0.model.trimTimelineItemToPlayhead(id, edge: .start) },
            action("Trim end to playhead") { $0.model.trimTimelineItemToPlayhead(id, edge: .end) },
            action("Split at playhead") { $0.model.splitTimelineItems([id]) },
            action("Duplicate") { $0.model.commitTimelineItemEdit(.duplicate(items: [id], toAnchor: nil)) },
            action("Delete") { $0.model.commitTimelineItemEdit(.delete(items: [id])) }
        ]
        if let fades = item.pictureFades {
            for edge in [TimelineEdge.start, .end] {
                let label = "Fade \(edge == .start ? "in" : "out")"
                actions.append(action("\(label) longer") { $0.model.commitTimelineItemEdit(.fade(item: id, edge: edge, seconds: fades[edge] + 0.1)) })
                actions.append(action("\(label) shorter") { $0.model.commitTimelineItemEdit(.fade(item: id, edge: edge, seconds: fades[edge] - 0.1)) })
            }
        }
        return actions
    }
}
