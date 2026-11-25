import AppKit
import SwiftUI

/// Gives the Settings window the same unified titlebar as the main window (#19).
///
/// The main window is a `WindowGroup` whose content declares a real SwiftUI
/// `.toolbar`, so AppKit installs an `NSToolbar` and lays the window out with
/// the taller unified titlebar: its traffic lights sit at an 18 pt inset.
/// SwiftUI installs no `NSToolbar` in the Settings window (it was a `Settings`
/// scene, and is now a window the app owns, #676), so the window would keep the
/// short standard titlebar with the lights at an 8 pt inset.
///
/// Attaching an `NSToolbar` to the window restores the unified metrics, which is
/// also what Apple's own System Settings window uses. Its only item is the system
/// sidebar button (``SettingsToolbarItems``).
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { UnifiedTitlebarProbeView() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Zero-sized helper view whose only job is to reach the hosting `NSWindow`
/// once SwiftUI has attached it, and to give its titlebar the unified layout.
final class UnifiedTitlebarProbeView: NSView {
    static let toolbarIdentifier = NSToolbar.Identifier("SpotiglassSettingsTitlebar")

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Deferred on purpose: SwiftUI's settings window controller is still in
        // its first constraint pass here, and swapping the titlebar mid-pass
        // makes it raise an NSRangeException.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            Self.applyUnifiedTitlebar(to: window)
        }
    }

    /// An empty, non-customizable toolbar is enough: AppKit only needs a
    /// toolbar to be present to lay the window out with the taller titlebar.
    /// Idempotent, so reopening the settings window keeps one toolbar.
    static func applyUnifiedTitlebar(to window: NSWindow) {
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.allowsUserCustomization = false
            toolbar.delegate = SettingsToolbarItems.shared
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
    }
}

/// The system's Show/Hide Sidebar button at the sidebar's trailing edge, with the title after it over the
/// pane: what the `Settings` scene drew in its titlebar. The app owns the Settings window now
/// (#676), and SwiftUI adds no toolbar to a window it doesn't own. The button sends
/// `toggleSidebar(_:)` up the responder chain, which the settings split view answers, as it
/// does for ⌃⌘S.
final class SettingsToolbarItems: NSObject, NSToolbarDelegate {
    static let shared = SettingsToolbarItems()

    static let itemIdentifiers: [NSToolbarItem.Identifier] = [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // All system items: AppKit builds them from the identifier.
        nil
    }
}
