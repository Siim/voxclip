#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing

/// A one-run probe of SwiftUI focus on hosted CI's macOS 26 runtime, where the Director
/// panel's keyboard handover does not reach the panel (DirectorTaskTests). It prints how
/// each way of focusing a pane like the Director panel's behaves after a text field had the
/// keyboard, and records no issue. Removed once the handover is fixed.
@MainActor private final class FocusProbe: ObservableObject {
    @Published var pane = false
    @Published var trigger = 0
    let inner: Bool, deferred: Bool, outerBinding: Bool
    var innerFocused = false, outerFocused = false
    init(inner: Bool, deferred: Bool, outerBinding: Bool) { self.inner = inner; self.deferred = deferred; self.outerBinding = outerBinding }
}

@MainActor private struct FocusProbeRoot: View {
    @ObservedObject var probe: FocusProbe
    var body: some View {
        if probe.pane { FocusProbePane(probe: probe) } else { FocusProbeField() }
    }
}

@MainActor private struct FocusProbeField: View {
    @FocusState private var focused: Bool
    @State private var text = ""
    var body: some View {
        TextField("Instruction", text: $text).focused($focused).task { focused = true }
    }
}

@MainActor private struct FocusProbePane: View {
    @ObservedObject var probe: FocusProbe
    @FocusState private var inner: Bool
    @FocusState private var outer: Bool
    var body: some View {
        if probe.outerBinding { pane.focused($outer) } else { pane }
    }
    private var pane: some View {
        VStack { Text("Pane") }
            .frame(width: 200, height: 200)
            .focusable().focused($inner).focusSection().focusEffectDisabled(true)
            .onChange(of: inner) { _, value in probe.innerFocused = value }
            .onChange(of: outer) { _, value in probe.outerFocused = value }
            .onChange(of: probe.trigger) { _, _ in take() }
            .task { if !probe.deferred { take() } }
    }
    private func take() {
        if probe.inner { inner = true } else { outer = true }
    }
}

@Suite("Director focus probe", .serialized)
@MainActor struct DirectorFocusProbeTests {
    private func settle(_ host: NSView, turns: Int) async {
        for _ in 0..<turns {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }
    private func responder(_ window: NSWindow, _ host: NSView, _ elsewhere: NSView) -> String {
        guard let first = window.firstResponder else { return "nil" }
        if first === host { return "host" }
        if first === elsewhere { return "elsewhere" }
        if first === window { return "window" }
        if let text = first as? NSTextView, text.isDescendant(of: host) { return "field" }
        return String(describing: type(of: first))
    }

    @Test func printsHowEachWayOfFocusingThePaneBehaves() async {
        print("PROBE26 os \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for outerBinding in [true, false] {
            for inner in [false, true] where outerBinding || inner {
                for deferred in [false, true] {
                    for hostFirst in [false, true] {
                        let probe = FocusProbe(inner: inner, deferred: deferred, outerBinding: outerBinding)
                        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 404, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        let host = NSHostingView(rootView: FocusProbeRoot(probe: probe))
                        host.frame = CGRect(x: 0, y: 0, width: 404, height: 600)
                        window.contentView = host
                        let elsewhere = NSTextView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
                        host.addSubview(elsewhere)
                        await settle(host, turns: 300)
                        let start = responder(window, host, elsewhere)
                        if hostFirst { _ = window.makeFirstResponder(host) }
                        probe.pane = true
                        await settle(host, turns: 300)
                        if deferred { probe.trigger += 1; await settle(host, turns: 300) }
                        let taken = "responder \(responder(window, host, elsewhere)) inner \(probe.innerFocused) outer \(probe.outerFocused)"
                        _ = window.makeFirstResponder(elsewhere)
                        await settle(host, turns: 300)
                        let left = "responder \(responder(window, host, elsewhere)) inner \(probe.innerFocused) outer \(probe.outerFocused)"
                        print("PROBE26 set \(inner ? "inner" : "outer") outerBinding \(outerBinding) deferred \(deferred) hostFirst \(hostFirst) start \(start): taken: \(taken) | elsewhere: \(left)")
                        window.close()
                    }
                }
            }
        }
    }
}
#endif
