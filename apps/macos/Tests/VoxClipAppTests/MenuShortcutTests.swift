#if DEBUG
import AppKit
import Testing
@testable import VoxClip

/// The main menu's key equivalents and tags stay unique as packages add commands (V3b's clip bar, V13's Rewrite, V14's
/// and V15's Keep flow): each tag names one command, each shortcut one item, apart from the pairs below that act in
/// different panes and the hidden alternates. The transcript's own change keys (V14) stay off the menu.
@Suite("Menu shortcuts", .serialized)
@MainActor struct MenuShortcutTests {
    private struct Shortcut: Hashable, CustomStringConvertible {
        let key: String, modifiers: NSEvent.ModifierFlags.RawValue
        init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
            self.key = key.lowercased()
            self.modifiers = modifiers.intersection([.command, .shift, .option, .control]).rawValue
        }
        var description: String { "\(key.unicodeScalars.map { String($0.value, radix: 16) }) \(modifiers)" }
    }
    private static let delete = String(UnicodeScalar(NSDeleteCharacter)!), carriageReturn = String(UnicodeScalar(NSCarriageReturnCharacter)!)

    /// Items that share a shortcut on purpose: one acts in the Explorer, one in the transcript (`clipRowKeyEnabled`,
    /// `validateMenuItem`), or the same command sits in two menus.
    private static let sharedOnPurpose: [Shortcut: Set<String>] = [
        Shortcut(carriageReturn, []): ["Keep Suggestion", "Rename Clip…"],
        Shortcut(delete, []): ["Cut Selection", "Dismiss Suggestion", "Remove Clip"],
        Shortcut("j", []): ["Shuttle Back", "Back 3 Seconds"],
        Shortcut("f", [.command, .control]): ["Enter Full Screen", "Toggle Full Screen"],
    ]

    private func menuItems() -> [NSMenuItem] {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        AppDelegate().installMenus()
        guard let main = NSApp.mainMenu else { return [] }
        func walk(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) } }
        return walk(main)
    }

    @Test func everyShortcutAndTagNamesOneCommand() {
        let items = menuItems()
        #expect(items.count > 60)
        let keyed = Dictionary(grouping: items.filter { !$0.keyEquivalent.isEmpty }) { Shortcut($0.keyEquivalent, $0.keyEquivalentModifierMask) }
        for (shortcut, sharing) in keyed where sharing.count > 1 {
            #expect(Set(sharing.map(\.title)) == Self.sharedOnPurpose[shortcut], "\(sharing.map(\.title)) share \(shortcut)")
        }
        // A tag is one command; its hidden alternates (⇧⌘↩ for Keep Suggestion, ⇧⌘[ and ⇧⌘] for the tabs) carry it too.
        let tagged = Dictionary(grouping: items.filter { $0.tag != 0 && !$0.isSeparatorItem }, by: \.tag)
        for (tag, sharing) in tagged {
            #expect(sharing.filter { !$0.isHidden }.count == 1 && Set(sharing.map(\.title)).count == 1, "tag \(tag): \(sharing.map(\.title))")
            let alternatesKeepTheirKey = sharing.filter(\.isHidden).allSatisfy { $0.allowsKeyEquivalentWhenHidden }
            #expect(alternatesKeepTheirKey, "tag \(tag)'s hidden alternate keeps its key")
        }
    }

    @Test func keepIsShiftCommandReturnAndTheTranscriptsChangeKeysStayOffTheMenu() {
        let items = menuItems()
        func holders(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> [NSMenuItem] {
            items.filter { Shortcut($0.keyEquivalent, $0.keyEquivalentModifierMask) == Shortcut(key, modifiers) }
        }
        // V3b: Keep on a suggestion's tab is ⇧⌘↩, Clip › Keep Suggestion's hidden alternate (tag 40).
        let keep = holders(Self.carriageReturn, [.command, .shift])
        #expect(keep.count == 1 && keep.first?.tag == 40 && keep.first?.isHidden == true && keep.first?.allowsKeyEquivalentWhenHidden == true)
        // V13: ⇧⌘R is Edit › Rewrite {scope} alone (tag 38).
        #expect(holders("r", [.command, .shift]).map(\.tag) == [38])
        // V14: ⌘↩ keeps and ⌘⌫ undoes the focused change in the transcript; ⌥↓ and ⌥↑ walk the changes. No menu item
        // takes them, so the transcript's keyDown gets them.
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!), up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        for (key, modifiers) in [(Self.carriageReturn, NSEvent.ModifierFlags.command), (Self.delete, .command), (down, .option), (up, .option)] {
            #expect(holders(key, modifiers).isEmpty, "\(holders(key, modifiers).map(\.title)) take the transcript's \(Shortcut(key, modifiers))")
        }
    }
}
#endif
