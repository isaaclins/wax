import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// What the menu bar shows (shuffle's checkmark, repeat, whether Back is enabled) is mirrored on
/// the window's command palette manager, and the scene host passes every such change on to the
/// menu bar. The window's root view kept that scene host as an observed object, so each of those
/// changes also ran the root view's body again and re-rendered the window under it: ⌥⌘S, ⌥⌘R
/// and ⌘[ took 46-61 ms where ⌘→, which changes nothing in the menu bar, took 25-28 (#730).
@MainActor
final class RootViewRenderScopeTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testMenuStateChangesDoNotRerenderTheWindow() async throws {
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        let palette = CommandPaletteManager()
        let playbackHost = SpotiglassPlaybackHost(
            tokenProvider: MockPlaybackTokenProvider(accessToken: "test", refreshedAccessToken: "test-refresh")
        )
        let view = RootView(commandPaletteManager: palette, playbackHost: playbackHost)
            .environmentObject(try ViewTestHost.makeSettingsStore())
            .environmentObject(auth)
            .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewBodyTally.counts = [:]
        ViewTestHost.host(view, size: CGSize(width: 720, height: 520))
        let shown = await AppKitTestSupport.settle(until: { (ViewBodyTally.counts?["RootView"] ?? 0) > 0 })
        XCTAssertTrue(shown, "the window never showed")
        await AppKitTestSupport.settle()

        // The changes still reach whoever listens for them on the manager: the menu bar does.
        var heard = 0
        let listening = palette.objectWillChange.sink { heard += 1 }
        defer { listening.cancel() }

        ViewBodyTally.counts = [:]
        // What ⌘[ (Back enabled), ⌥⌘R (repeat can change) and the Settings shortcut recorder
        // change on the manager. Shuffle and repeat themselves follow the player the same way.
        palette.canNavigateBack.toggle()
        palette.canMutateRepeat.toggle()
        palette.canMutatePlaybackTransport.toggle()
        palette.isRecordingHotkey.toggle()
        await AppKitTestSupport.settle()

        XCTAssertGreaterThan(heard, 0, "the manager announced nothing")
        XCTAssertNil(ViewBodyTally.counts?["RootView"], "the window's root view ran again for a menu bar change")
    }
}
