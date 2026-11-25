import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// A page change must not re-announce what didn't change (#675). The browser binds the command
/// palette again on each page change, and every value it set announced a change, also the same
/// value again: going from Home to Search announced 19 changes, to a playlist 28. Each one
/// re-renders the window from its root (the scene observes the palette) and rebuilds the menus,
/// which took ⌘F to Search 94 ms and a sidebar click 82 ms in a Release build. The player bar was
/// built again on each of them too.
@MainActor
final class PageChangeRenderScopeTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    /// The real browser window at Home, with three playlists in the sidebar.
    private func hostBrowserAtHome() async throws -> (PlaylistBrowserViewModel, CommandPaletteManager, LyricsOverlayController) {
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus"),
                PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Daily"),
                PlaylistBrowsingTestFixtures.playlist(id: "p3", name: "Gym"),
            ])],
            trackResults: ["p2": [.success((1...20).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") })]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.loadIfNeeded()
        await browserVM.selectSidebar(.home)
        let playbackHost = SpotiglassPlaybackHost(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        let palette = CommandPaletteManager()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let lyrics = LyricsOverlayController()
        let controller = ViewTestHost.host(
            PlaylistBrowserView(
                viewModel: browserVM,
                playbackHost: playbackHost,
                catalogProvider: api,
                commandPaletteManager: palette,
                signOut: {}
            )
            .environmentObject(store)
            .environmentObject(lyrics),
            size: CGSize(width: 1_600, height: 1_000)
        )
        await AppKitTestSupport.settle()
        controller.view.window?.setContentSize(NSSize(width: 1_700, height: 1_000))
        await AppKitTestSupport.settle()
        return (browserVM, palette, lyrics)
    }

    /// Records every value each of the palette's published properties announces, starting with
    /// the one it holds now, and returns those that announced a value they already had.
    private func repeatedAnnouncements(
        of palette: CommandPaletteManager,
        lyrics: LyricsOverlayController,
        during change: () async -> Void
    ) async -> [String] {
        var repeated: [String] = []
        var subscriptions: [AnyCancellable] = []
        func watch<Value: Equatable>(_ name: String, _ publisher: Published<Value>.Publisher) {
            var last: Value?
            publisher.sink { value in
                if let last, last == value { repeated.append("\(name) = \(value)") }
                last = value
            }
            .store(in: &subscriptions)
        }
        watch("canEnqueueTrackSelection", palette.$canEnqueueTrackSelection)
        watch("trackSelectionPinState", palette.$trackSelectionPinState)
        watch("canNavigateBack", palette.$canNavigateBack)
        watch("isSidebarVisible", palette.$isSidebarVisible)
        watch("canTogglePlayback", palette.$canTogglePlayback)
        watch("canToggleLyrics", palette.$canToggleLyrics)
        watch("canSkipTrack", palette.$canSkipTrack)
        watch("canConnectPlayback", palette.$canConnectPlayback)
        watch("shuffleEnabled", palette.$shuffleEnabled)
        watch("repeatMode", palette.$repeatMode)
        watch("canMutatePlaybackTransport", palette.$canMutatePlaybackTransport)
        watch("canMutateRepeat", palette.$canMutateRepeat)
        watch("prefetchProgress", palette.$prefetchProgress)
        watch("availableSearchCategories", palette.viewModel.$availableSearchCategories)
        // The scene observes the lyrics as well: every page change closes them.
        watch("lyrics.isPresented", lyrics.$isPresented)
        ViewBodyTally.counts = [:]
        await change()
        await AppKitTestSupport.settle()
        subscriptions.removeAll()
        // The player bar shows nothing of the page: building it again measured its whole layout
        // before the new page could show.
        for bar in ["BrowserTransportBar", "PlaybackControlsView"] {
            XCTAssertNil(ViewBodyTally.counts?[bar], "\(bar) was built again for a page change")
        }
        ViewBodyTally.counts = nil
        return repeated
    }

    func testOpeningSearchAnnouncesOnlyWhatChanged() async throws {
        let (browser, palette, lyrics) = try await hostBrowserAtHome()
        let repeated = await repeatedAnnouncements(of: palette, lyrics: lyrics) {
            // What ⌘F, the View menu and the palette's Search run.
            palette.execute(commandID: CommandPaletteCommandID.openSearch)
            let opened = await AppKitTestSupport.settle(until: { browser.sidebarSelection == .search })
            XCTAssertTrue(opened, "Search never opened")
        }
        XCTAssertEqual(browser.sidebarSelection, .search)
        XCTAssertEqual(repeated, [], "announced again without a change")
    }

    func testOpeningAPlaylistAnnouncesOnlyWhatChanged() async throws {
        let (browser, palette, lyrics) = try await hostBrowserAtHome()
        let repeated = await repeatedAnnouncements(of: palette, lyrics: lyrics) {
            // What a click on its sidebar row does: the list sets its selection.
            browser.sidebarSelection = .playlist("p2")
            let opened = await AppKitTestSupport.settle(until: { PlaylistBrowsingTestFixtures.playlistTracks(browser.detailState).count == 20 })
            XCTAssertTrue(opened, "the playlist never opened")
        }
        XCTAssertEqual(repeated, [], "announced again without a change")
    }
}
