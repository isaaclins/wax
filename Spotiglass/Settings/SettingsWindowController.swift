import AppKit
import SwiftUI

/// The Settings window, owned by the app instead of a SwiftUI `Settings` scene (#676).
///
/// SwiftUI throws a `Settings` scene's window away when it closes and builds the window and
/// every view in it again on the next ⌘,: 100-130 ms on a Mac mini M4, over the 50 ms every
/// interaction has (#656). Keeping that window and only hiding it didn't help, because SwiftUI
/// still rebuilt its content each time the window came back on screen. This window is built
/// once, shortly after launch (``prepare(content:)``), and kept: closing it orders it out,
/// and ⌘, only orders it back in.
///
/// Each open still starts the way a fresh window did (Equalizer, no search, no shortcut being
/// recorded): the content is rebuilt right after the close, while nothing waits on it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Tells this window apart from the main and lyrics windows.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("WaxSettingsWindow")
    /// Where AppKit keeps the window's place between launches.
    nonisolated static let frameAutosaveName = "WaxSettingsWindow"

    private(set) var window: NSWindow?
    private let session = SettingsWindowSession()
    /// How many times the content has been built.
    private(set) var contentBuildCount = 0
    private let autosaveName: String?
    private let present: (NSWindow) -> Void

    /// `autosaveName` and `present` are seams for tests, which keep their windows off screen
    /// and out of the defaults.
    init(
        frameAutosaveName: String? = SettingsWindowController.frameAutosaveName,
        present: @escaping (NSWindow) -> Void = SettingsWindowController.orderFrontThenMakeKey
    ) {
        autosaveName = frameAutosaveName
        self.present = present
    }

    /// Brings Settings forward, building it the first time. `content` is only called then.
    func show<Content: View>(@ViewBuilder content: () -> Content) {
        let window = window ?? makeWindow(content: content())
        // Read each time, so it follows a language change made while the window was closed.
        window.title = SpotiglassL10n.string("settings.window.title")
        // A closed window comes back on the Space in use, as the Settings scene's new window did:
        // over a main window in full screen too, instead of switching to the desktop Settings was
        // last shown on. Only for this show: one still open on another desktop switches there, as
        // before, and an open window doesn't follow the user from desktop to desktop.
        guard !window.isVisible else {
            present(window)
            return
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        present(window)
        // After `present`'s own turn of the run loop, which makes the window key.
        DispatchQueue.main.async { window.collectionBehavior.remove(.moveToActiveSpace) }
    }

    /// Builds the window and lays it out without showing it, so the first ⌘, after launch only
    /// has to show it too. Does nothing once the window exists.
    func prepare<Content: View>(@ViewBuilder content: () -> Content) {
        guard window == nil else { return }
        makeWindow(content: content()).contentView?.layoutSubtreeIfNeeded()
    }

    /// On screen first, key right after. Taking key makes the main window redraw as inactive,
    /// 15-20 ms that would otherwise come before Settings shows; done in the next turn of the
    /// run loop, it lands after the frame that shows Settings, long before a hand can type.
    static func orderFrontThenMakeKey(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKey()
        }
    }

    static func isSettingsWindow(_ window: NSWindow?) -> Bool {
        window?.identifier == windowIdentifier
    }

    @discardableResult
    private func makeWindow<Content: View>(content: Content) -> NSWindow {
        contentBuildCount += 1
        let root = SettingsWindowRoot(session: session, content: content)
        let hosting = NSHostingController(rootView: root)
        // A fixed size, the one the Settings scene gave the window: it isn't resizable and every
        // pane gets the same width. Letting SwiftUI track the content's size measured every pane
        // again each time the window came back on screen.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        let size = NSSize(width: SpotiglassDesign.settingsWindowWidth, height: SpotiglassDesign.settingsWindowHeight)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.identifier = Self.windowIdentifier
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        // Like the Settings scene: never reopened by itself at the next launch.
        window.isRestorable = false
        window.delegate = self
        window.setContentSize(size)
        if let autosaveName {
            // Only the place is restored: the size is fixed.
            if window.setFrameUsingName(autosaveName) { window.setContentSize(size) } else { window.center() }
            window.setFrameAutosaveName(autosaveName)
        }
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // After the close, so the window is gone from the screen before the content is rebuilt.
        DispatchQueue.main.async { [weak self] in self?.startOver() }
    }

    /// Rebuilds the content and lays it out while the window is closed: left for the next ⌘,,
    /// the layout of every pane would be done then, on the way to the screen.
    private func startOver() {
        session.startOver()
        DispatchQueue.main.async { [weak window] in
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }
}

/// Counts the closes, so the content can start over after each one.
@MainActor
final class SettingsWindowSession: ObservableObject {
    @Published private(set) var generation = 0

    func startOver() {
        generation += 1
    }
}

/// Rebuilds the settings view after every close: its panes then reset the way they did when
/// the window itself was thrown away (the pane, the search, a shortcut being recorded).
private struct SettingsWindowRoot<Content: View>: View {
    @ObservedObject var session: SettingsWindowSession
    let content: Content

    var body: some View {
        content.id(session.generation)
    }
}

/// Opens Settings from a view: the app's own window rather than SwiftUI's `openSettings`, which
/// only opens a `Settings` scene.
struct OpenWaxSettingsAction {
    let action: @MainActor () -> Void

    @MainActor
    func callAsFunction() {
        action()
    }
}

extension EnvironmentValues {
    @Entry var openWaxSettings = OpenWaxSettingsAction {}
}
