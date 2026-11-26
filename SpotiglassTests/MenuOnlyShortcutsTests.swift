import AppKit
import XCTest
@testable import Spotiglass

/// ⌥⌘S, ⌥⌘R and ⌘[ run their menu items from the key monitor instead of waiting for the menu
/// bar's search, which took 15-23 ms before the command ran (#730). Keys are made the way the
/// keyboard makes them (`InteractionLatencyProbe.keyEvent`), on this Mac's layout.
@MainActor
final class MenuOnlyShortcutsTests: XCTestCase {
    private final class Target: NSObject {
        var fired: [String] = []

        @objc func shuffle(_ sender: NSMenuItem) { fired.append("shuffle") }
        @objc func other(_ sender: NSMenuItem) { fired.append("other") }
    }

    private let target = Target()

    /// A main menu like the app's: Shuffle on ⌥⌘S in a Playback menu, and an item outside the
    /// three with a shortcut of its own.
    private func menu(shuffleEnabled: Bool = true, shuffleKey: String = "s") -> NSMenu {
        let main = NSMenu()
        let playback = NSMenu(title: "Playback")
        playback.autoenablesItems = false
        let shuffle = NSMenuItem(title: "Shuffle", action: #selector(Target.shuffle(_:)), keyEquivalent: shuffleKey)
        shuffle.keyEquivalentModifierMask = [.option, .command]
        shuffle.target = target
        shuffle.isEnabled = shuffleEnabled
        playback.addItem(shuffle)
        let other = NSMenuItem(title: "Something else", action: #selector(Target.other(_:)), keyEquivalent: "e")
        other.keyEquivalentModifierMask = [.option, .command]
        other.target = target
        playback.addItem(other)
        let top = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
        top.submenu = playback
        main.addItem(top)
        return main
    }

    private func key(_ character: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        let code = try XCTUnwrap(InteractionLatencyProbe.keyCode(typing: character), "no key types \(character)")
        return try XCTUnwrap(InteractionLatencyProbe.keyEvent(code: code, modifiers, arrow: false, keyDown: true))
    }

    func testTheShortcutRunsItsItem() throws {
        let handled = MenuOnlyShortcuts.perform(try key("s", [.option, .command]), in: menu(), titles: ["Shuffle"])
        XCTAssertTrue(handled)
        XCTAssertEqual(target.fired, ["shuffle"])
    }

    /// A switched-off item is the menu bar's to refuse (it beeps), as before.
    func testADisabledItemIsLeftToTheMenuBar() throws {
        let handled = MenuOnlyShortcuts.perform(
            try key("s", [.option, .command]), in: menu(shuffleEnabled: false), titles: ["Shuffle"]
        )
        XCTAssertFalse(handled)
        XCTAssertEqual(target.fired, [])
    }

    func testOtherKeysAndModifiersAreLeftAlone() throws {
        for event in [
            try key("s", [.command]),
            try key("s", [.option, .command, .shift]),
            try key("r", [.option, .command]),
        ] {
            XCTAssertFalse(MenuOnlyShortcuts.perform(event, in: menu(), titles: ["Shuffle"]))
        }
        XCTAssertEqual(target.fired, [])
    }

    /// Only the three menu-only commands take this path; every other shortcut stays with the menu
    /// bar and the keymap.
    func testItemsOutsideTheThreeAreLeftToTheMenuBar() throws {
        let handled = MenuOnlyShortcuts.perform(try key("e", [.option, .command]), in: menu(), titles: ["Shuffle"])
        XCTAssertFalse(handled)
        XCTAssertEqual(target.fired, [])
    }

    /// The key the menu shows is the one that counts: macOS moves ⌘[ to ⌘ö on a Swiss German
    /// layout, and the item then carries ö.
    func testTheKeyTheMenuShowsIsTheOneThatCounts() throws {
        let handled = MenuOnlyShortcuts.perform(
            try key("m", [.option, .command]), in: menu(shuffleKey: "m"), titles: ["Shuffle"]
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(target.fired, ["shuffle"])
    }
}
