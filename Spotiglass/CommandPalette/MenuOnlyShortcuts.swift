import AppKit

/// Shuffle (⌥⌘S), Repeat (⌥⌘R) and Back (⌘[) are menu-only commands: no keymap entry has them,
/// so their keys went all the way to the menu bar. There the menu bar looks for the item through
/// every menu and brings SwiftUI's menus up to date first, which took 15-23 ms before the command
/// even ran. ⌘→ and the other keymap shortcuts run from the key monitor in under 2 ms (#730).
///
/// So the key monitor runs these items itself, as the menu bar would: the same item, only when it
/// is enabled, with the key its menu shows (macOS moves ⌘[ to ⌘ö on a Swiss German layout). A key
/// that matches no enabled item goes on to the menu bar as before.
@MainActor
enum MenuOnlyShortcuts {
    /// The titles of the items, as the menu bar shows them.
    static var titles: Set<String> {
        [
            SpotiglassL10n.string("menu.playback.shuffle"),
            SpotiglassL10n.string("menu.playback.repeat"),
            SpotiglassL10n.string("menu.view.back"),
        ]
    }

    /// Runs the enabled item of `menu` among ``titles`` that `event` is the shortcut of; `false`
    /// when there is none.
    static func perform(_ event: NSEvent, in menu: NSMenu? = NSApp.mainMenu, titles: Set<String>? = nil) -> Bool {
        // All three carry ⌘: every other key (Space, typing) is past here at once.
        guard event.type == .keyDown, event.modifierFlags.contains(.command), let menu,
              let item = item(for: event, in: menu, titles: titles ?? Self.titles),
              let owner = item.menu else { return false }
        owner.performActionForItem(at: owner.index(of: item))
        return true
    }

    private static func item(for event: NSEvent, in menu: NSMenu, titles: Set<String>) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu {
                if let found = self.item(for: event, in: submenu, titles: titles) { return found }
                continue
            }
            guard matches(event, item), item.isEnabled, !item.isHidden, titles.contains(item.title) else { continue }
            return item
        }
        return nil
    }

    /// Whether `event` is the shortcut `item` shows.
    static func matches(_ event: NSEvent, _ item: NSMenuItem) -> Bool {
        let key = item.keyEquivalent
        guard !key.isEmpty, let typed = event.charactersIgnoringModifiers, !typed.isEmpty else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        var wanted = item.keyEquivalentModifierMask.intersection(relevant)
        // An upper-case key equivalent means Shift, as AppKit reads it.
        if key != key.lowercased() { wanted.insert(.shift) }
        return typed.lowercased() == key.lowercased() && event.modifierFlags.intersection(relevant) == wanted
    }
}
