import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// ⌘, took 100-130 ms because every open built the Settings window and all its views again
/// (#676). These replay an open, a close and a second open.
@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    private var controllers: [SettingsWindowController] = []

    override func tearDown() {
        for controller in controllers {
            controller.window.map(AppKitTestSupport.closeWindowSafely)
        }
        controllers = []
        super.tearDown()
    }

    /// Off screen and never key: the test host must not take focus from whoever uses the Mac (#418).
    private func makeController() -> SettingsWindowController {
        let controller = SettingsWindowController(
            frameAutosaveName: nil,
            present: { window in
                // Behind every other window and never key: it counts as shown, but takes
                // nothing from whoever uses the Mac.
                window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
                window.orderBack(nil)
            }
        )
        controllers.append(controller)
        return controller
    }

    func testOpeningAgainAfterACloseShowsTheWindowAlreadyBuilt() throws {
        let controller = makeController()
        var builds = 0
        let content = { () -> Text in
            builds += 1
            return Text(verbatim: "Settings")
        }

        controller.show { content() }
        let window = try XCTUnwrap(controller.window)
        let hosting = try XCTUnwrap(window.contentViewController)
        XCTAssertTrue(window.isVisible)

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)

        controller.show { content() }

        XCTAssertTrue(controller.window === window, "a close must not throw the window away")
        XCTAssertTrue(window.contentViewController === hosting, "nor the views in it")
        XCTAssertEqual(builds, 1, "opening again must not build the content again")
        XCTAssertEqual(controller.contentBuildCount, 1)
        XCTAssertTrue(window.isVisible)
    }

    /// A fresh window opened on Equalizer with no search and no shortcut being recorded; the
    /// kept window has to start over the same way after each close.
    func testEachOpenAfterACloseStartsOver() async throws {
        let controller = makeController()
        let appearances = AppearanceLog()
        controller.show { StateProbe(log: appearances) }
        let appeared = await AppKitTestSupport.settle(until: { !appearances.tokens.isEmpty })
        XCTAssertTrue(appeared)
        let first = try XCTUnwrap(appearances.tokens.last)

        // Shown again without a close: the same state.
        controller.show { StateProbe(log: appearances) }
        await AppKitTestSupport.settle()
        XCTAssertEqual(appearances.tokens.last, first)

        try XCTUnwrap(controller.window).performClose(nil)
        // The content starts over after the close, while the window is off screen.
        let startedOver = await AppKitTestSupport.settle(until: { appearances.disappearances == 1 })
        XCTAssertTrue(startedOver)
        controller.show { StateProbe(log: appearances) }
        let reopened = await AppKitTestSupport.settle(until: { appearances.tokens.last != first })
        XCTAssertTrue(reopened)

        let afterClose = try XCTUnwrap(appearances.tokens.last)
        XCTAssertNotEqual(afterClose, first, "state from before the close must not survive it")
        XCTAssertEqual(appearances.disappearances, 1, "the old content disappears, so its panes clean up")
    }

    /// The window is built shortly after launch, so the first ⌘, doesn't build it either: it
    /// took about 250 ms where every later one took 40.
    func testTheFirstOpenShowsTheWindowBuiltAfterLaunch() throws {
        let controller = makeController()
        var builds = 0
        controller.prepare {
            builds += 1
            return Text(verbatim: "Settings")
        }
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible, "built, not shown")

        controller.prepare { Text(verbatim: "again") }
        controller.show {
            builds += 1
            return Text(verbatim: "Settings")
        }

        XCTAssertEqual(builds, 1)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
    }

    func testTheWindowKeepsTheSettingsSceneSizeAndCantBeResized() throws {
        let controller = makeController()
        controller.show { Text(verbatim: "Settings") }
        let window = try XCTUnwrap(controller.window)

        let size = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(size.width, SpotiglassDesign.settingsWindowWidth)
        XCTAssertEqual(size.height, SpotiglassDesign.settingsWindowHeight)
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    func testOnlyItsOwnWindowCountsAsSettings() throws {
        let controller = makeController()
        controller.show { Text(verbatim: "Settings") }

        XCTAssertTrue(SettingsWindowController.isSettingsWindow(controller.window))
        let other = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        other.isReleasedWhenClosed = false
        XCTAssertFalse(SettingsWindowController.isSettingsWindow(other))
        XCTAssertFalse(SettingsWindowController.isSettingsWindow(nil))
    }

    /// The main window going behind Settings only changes a View menu title. Published by the
    /// scene registry, it re-ran the app's whole scene and menu tree on every ⌘, (about 20 ms).
    func testTheMainWindowGoingBehindSettingsLeavesTheRegistryAlone() {
        let registry = SpotiglassSceneRegistry()
        var registryChanges = 0
        var frontChanges = 0
        let registryWatch = registry.objectWillChange.sink { registryChanges += 1 }
        let frontWatch = registry.mainWindowFront.objectWillChange.sink { frontChanges += 1 }
        defer {
            registryWatch.cancel()
            frontWatch.cancel()
        }

        registry.mainWindowResignedKey()

        XCTAssertFalse(registry.mainWindowFront.isInFront)
        XCTAssertEqual(frontChanges, 1, "the View menu still hears it")
        XCTAssertEqual(registryChanges, 0, "nothing else that watches the registry does")
    }
}

@MainActor
private final class AppearanceLog {
    var tokens: [UUID] = []
    var disappearances = 0
}

/// Holds one piece of view state and reports it, like a pane's selection or search text.
private struct StateProbe: View {
    let log: AppearanceLog
    @State private var token = UUID()

    var body: some View {
        Text(verbatim: token.uuidString)
            .onAppear { log.tokens.append(token) }
            .onDisappear { log.disappearances += 1 }
    }
}
