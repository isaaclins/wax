import Combine
import XCTest

@testable import Spotiglass

/// The menu bar and the app's scenes observe the scene registry, and rebuilding them takes about
/// 35 ms. When they heard of a change in the same frame that showed it, ⌥⌘S lit the shuffle button
/// after 65 ms instead of 29 and ⌘[ went back after 58 (#677). They now hear of it once, after
/// that frame.
@MainActor
final class SceneRegistryMenuRefreshTests: XCTestCase {
    func testTheMenuBarHearsOfAChangeOnceAfterTheFrame() {
        let manager = CommandPaletteManager()
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.register(scene)

        var heard = 0
        let subscription = registry.objectWillChange.sink { heard += 1 }
        defer { subscription.cancel() }

        // What ⌥⌘S and ⌘[ change, as they change it: several values in one frame.
        manager.canNavigateBack = true
        manager.canMutatePlaybackTransport = true
        manager.canNavigateBack = false
        XCTAssertEqual(heard, 0, "the menu bar must not rebuild inside the frame that shows the change")

        // One turn of the run loop: the frame is committed before it sleeps.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(heard, 1, "one rebuild for every change in that frame")

        manager.canNavigateBack = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(heard, 2, "a change in a later frame is heard again")
    }

    func testAnotherWindowBecomingActiveIsHeardAtOnce() {
        let registry = SpotiglassSceneRegistry()
        let first = SpotiglassSceneHost(commandPaletteManager: CommandPaletteManager())
        let second = SpotiglassSceneHost(commandPaletteManager: CommandPaletteManager())
        registry.register(first)
        var heard = 0
        let subscription = registry.objectWillChange.sink { heard += 1 }
        defer { subscription.cancel() }

        // The menu has to act on the window in front from the next key press on.
        registry.activate(second)
        XCTAssertGreaterThan(heard, 0)
        XCTAssertTrue(registry.activeScene === second)
    }
}
