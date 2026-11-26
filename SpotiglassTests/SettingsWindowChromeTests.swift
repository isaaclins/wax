import AppKit
import SwiftUI
import XCTest

@testable import Spotiglass

@MainActor
final class SettingsWindowChromeTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func testApplyUnifiedTitlebarInstallsToolbar() {
        let window = makeWindow()
        XCTAssertNil(window.toolbar)

        UnifiedTitlebarProbeView.applyUnifiedTitlebar(to: window)

        XCTAssertEqual(window.toolbar?.identifier, UnifiedTitlebarProbeView.toolbarIdentifier)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.toolbar?.allowsUserCustomization, false)
        AppKitTestSupport.closeWindowSafely(window)
    }

    /// The Settings scene showed a Show/Hide Sidebar button over the sidebar; the app's own
    /// window gets it from the toolbar (#676).
    func testTheToolbarHasTheSystemSidebarButton() {
        let window = makeWindow()
        UnifiedTitlebarProbeView.applyUnifiedTitlebar(to: window)

        let toolbar = window.toolbar
        XCTAssertEqual(toolbar?.items.map(\.itemIdentifier), SettingsToolbarItems.itemIdentifiers)
        XCTAssertEqual(toolbar?.displayMode, .iconOnly)
        let button = toolbar?.items.first { $0.itemIdentifier == .toggleSidebar }
        XCTAssertEqual(button?.action, #selector(NSSplitViewController.toggleSidebar(_:)))
        AppKitTestSupport.closeWindowSafely(window)
    }

    func testApplyUnifiedTitlebarIsIdempotent() {
        let window = makeWindow()
        UnifiedTitlebarProbeView.applyUnifiedTitlebar(to: window)
        let first = window.toolbar

        UnifiedTitlebarProbeView.applyUnifiedTitlebar(to: window)

        XCTAssertTrue(first === window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        AppKitTestSupport.closeWindowSafely(window)
    }

    /// The probe applies the titlebar in a `DispatchQueue.main.async` block. A run-loop pump
    /// can't run that block when the test itself runs inside one on the main queue (it did on
    /// CI, #466); suspending lets the main queue go on. The main queue runs its blocks in order,
    /// so once a block queued after the probe's has run, the probe's has too, however busy the
    /// machine is (#535).
    func testProbeViewConfiguresItsWindowOnceAttached() async throws {
        let window = makeWindow()
        window.contentView?.addSubview(UnifiedTitlebarProbeView())

        await withCheckedContinuation { queuedAfterTheProbe in
            DispatchQueue.main.async { queuedAfterTheProbe.resume() }
        }

        XCTAssertEqual(window.toolbar?.identifier, UnifiedTitlebarProbeView.toolbarIdentifier)
        XCTAssertEqual(window.toolbarStyle, .unified)
        AppKitTestSupport.closeWindowSafely(window)
    }

    func testProbeViewIgnoresDetachedState() {
        let probe = UnifiedTitlebarProbeView()
        let window = makeWindow()
        window.contentView?.addSubview(probe)
        probe.removeFromSuperview()

        AppKitTestSupport.settle()

        XCTAssertNil(probe.window)
        AppKitTestSupport.closeWindowSafely(window)
    }

    /// Same race as above, through SwiftUI (#714): the probe queues its work on the main queue
    /// once SwiftUI attaches it, which can be a later layout pass on a busy machine, and the
    /// synchronous settle can't run main-queue blocks when the test runs inside one. So this
    /// waits for the toolbar itself, suspending between passes so the main queue goes on.
    func testChromeHostsInSettingsWindowAndAppliesUnifiedTitlebar() async throws {
        let controller = ViewTestHost.host(
            SettingsWindowChrome().frame(width: 0, height: 0),
            size: CGSize(width: 320, height: 240)
        )
        let window = try XCTUnwrap(controller.view.window)

        let applied = await AppKitTestSupport.settle(until: {
            window.toolbar?.identifier == UnifiedTitlebarProbeView.toolbarIdentifier
        })

        XCTAssertTrue(applied, "the probe never gave the hosting window its toolbar")
        XCTAssertEqual(window.toolbar?.identifier, UnifiedTitlebarProbeView.toolbarIdentifier)
        XCTAssertEqual(window.toolbarStyle, .unified)
    }
}
