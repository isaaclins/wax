import MusicKit
import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// Opening the palette, closing it and every key typed in it reach only the palette (#671).
/// Before, each of them went from the palette through its manager and the window's scene to the
/// scene registry, so the window's root body and the menu bar's ran again before the palette could
/// show the change: 70-100 ms for ⌘K, esc and each letter in a Release build.
@MainActor
final class CommandPaletteRenderScopeTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    /// Everything a palette user does: open it, type, move the highlight, clear the field, close it.
    private func useThePalette(_ palette: CommandPaletteViewModel) {
        palette.show()
        palette.query = "m"
        palette.query = "mo"
        palette.selectedIndex = 1
        palette.query = ""
        palette.hide()
    }

    func testUsingThePaletteDoesNotChangeTheSceneOrTheMenuBar() {
        let manager = CommandPaletteManager()
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)

        var changes: [String: Int] = [:]
        let subscriptions: [AnyCancellable] = [
            manager.objectWillChange.sink { changes["manager", default: 0] += 1 },
            scene.objectWillChange.sink { changes["scene", default: 0] += 1 },
            // The menu bar observes the registry: a change here builds every menu again.
            registry.objectWillChange.sink { changes["menu bar", default: 0] += 1 },
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        useThePalette(manager.viewModel)

        XCTAssertEqual(changes, [:], "using the palette told these to redraw")
    }

    /// Hosted on Apple Music's permission screen, which has no text field of its own: a page field
    /// handing focus to the palette writes its text back into what the root observes, and that is
    /// the page's doing, not the palette's.
    func testThePaletteShowsWithoutRunningTheWindowsRootAgain() async throws {
        let services = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(
            services: [.appleMusic], active: .appleMusic
        ))
        let session = AppleMusicSession(authorization: PermissionDenied())
        await session.refresh()
        let settings = try ViewTestHost.makeSettingsStore()
        let registry = SpotiglassSceneRegistry()
        let root = RootView(
            keymapStore: CommandPaletteKeymapStore(settingsStore: settings),
            sceneRegistry: registry,
            playbackHosts: .forTests(spotify: SpotiglassPlaybackHost(tokenProvider: MockPlaybackTokenProvider(
                accessToken: "test", refreshedAccessToken: "test-refresh"
            ))),
            serviceStore: services,
            appleMusicSession: session
        )
        .environmentObject(settings)
        .environmentObject(AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {}
        ))
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        let controller = ViewTestHost.host(root, size: CGSize(width: 900, height: 640))
        let window = try XCTUnwrap(controller.view.window)
        AppKitTestSupport.activateAppIfNeeded()
        window.makeKeyAndOrderFront(nil)
        await AppKitTestSupport.settle()
        let manager = try XCTUnwrap(registry.activeScene?.commandPaletteManager)
        let field = try XCTUnwrap(
            Self.firstTextField(in: window.contentView, placeholder: Self.fieldPlaceholder),
            "the palette is built with the window"
        )
        XCTAssertFalse(field.isEnabled, "closed, the palette's field can't take focus")
        let fieldHasFocus = {
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
            return editor.delegate === field
        }

        let palette = manager.viewModel
        ViewBodyTally.counts = [:]
        palette.show()
        XCTAssertTrue(Self.settle(fieldHasFocus), "the palette's field should have focus once it opens")
        palette.query = "m"
        await AppKitTestSupport.settle()
        palette.selectedIndex = 1
        await AppKitTestSupport.settle()
        palette.hide()
        XCTAssertTrue(Self.settle { !fieldHasFocus() && !field.isEnabled }, "the palette should be closed")
        let counts = ViewBodyTally.counts ?? [:]
        ViewBodyTally.counts = nil

        XCTAssertNil(counts["RootView"], "the window's root ran its body again for the palette: \(counts)")

        // esc and ⌘K right after each other, while the panel still fades out: its field takes
        // focus again, so what you type next goes into it.
        palette.show()
        XCTAssertTrue(Self.settle(fieldHasFocus))
        palette.hide()
        await AppKitTestSupport.settle(passes: 1)
        palette.show()
        XCTAssertTrue(Self.settle(fieldHasFocus), "the field should have focus when the palette opens again at once")
    }

    /// Runs the main run loop until `done` holds: focus moves a frame or two after the palette's
    /// state changes, and its fade runs on the animation's clock.
    private static func settle(_ done: () -> Bool) -> Bool {
        AppKitTestSupport.pumpRunLoop(until: done)
    }

    private static var fieldPlaceholder: String {
        SpotiglassL10n.format("palette.searchPlaceholder.songs.all", MusicServiceSelection.current.displayName)
    }

    private static func firstTextField(in view: NSView?, placeholder: String) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        for subview in view.subviews {
            if let found = firstTextField(in: subview, placeholder: placeholder) { return found }
        }
        return nil
    }
}

private struct PermissionDenied: AppleMusicAuthorizing {
    func currentStatus() -> MusicAuthorization.Status { .denied }
    func requestAuthorization() async -> MusicAuthorization.Status { .denied }
    func canPlayCatalogContent() async -> Bool? { false }
}
